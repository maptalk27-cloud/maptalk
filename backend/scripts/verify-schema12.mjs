import { createHash } from 'node:crypto';
import { realpathSync, statSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';

// Compare isolated copies only, never the live database. This script does not
// create backups, decrypt, migrate, write data, connect to AWS, or print rows.
// backup:    consistent schema-11 snapshot vs authenticated restored copy.
// migration: same schema-11 snapshot vs isolated schema-12 migration rehearsal.
function requireCheck(condition, message) {
  if (!condition) throw new Error(message);
}

function identifier(name) { return `"${name.replaceAll('"', '""')}"`; }
function normalizedSQL(sql) { return sql?.replace(/\s+/g, ' ').trim() ?? null; }

const additions = [
  {
    type: 'table', name: 'comments', tbl_name: 'comments',
    sql: `CREATE TABLE comments (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      memory_id TEXT REFERENCES memories(id) ON DELETE CASCADE,
      place_id TEXT REFERENCES places(id) ON DELETE CASCADE,
      text TEXT NOT NULL CHECK(length(text) BETWEEN 1 AND 1000),
      created_at INTEGER NOT NULL,
      CHECK((memory_id IS NOT NULL) != (place_id IS NOT NULL))
    ) STRICT`,
  },
  { type: 'index', name: 'comments_memory_time', tbl_name: 'comments',
    sql: 'CREATE INDEX comments_memory_time ON comments(memory_id, created_at DESC, id DESC)' },
  { type: 'index', name: 'comments_place_time', tbl_name: 'comments',
    sql: 'CREATE INDEX comments_place_time ON comments(place_id, created_at DESC, id DESC)' },
  { type: 'index', name: 'comments_author_time', tbl_name: 'comments',
    sql: 'CREATE INDEX comments_author_time ON comments(user_id, created_at DESC)' },
];

function objects(database) {
  return database.prepare("SELECT type, name, tbl_name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name").all();
}

function columns(database, table) {
  return database.prepare(`PRAGMA table_xinfo(${identifier(table)})`).all().map(row => ({ ...row }));
}

function tableDigest(database, table, fields) {
  const primaryKey = fields.filter(field => field.pk > 0).sort((a, b) => a.pk - b.pk);
  requireCheck(primaryKey.length > 0, `Cannot compare a table without a stable primary key: ${table}.`);
  const query = database.prepare(`SELECT ${fields.map(field => identifier(field.name)).join(', ')}
    FROM ${identifier(table)} ORDER BY ${primaryKey.map(field => identifier(field.name)).join(', ')}`);
  query.setReadBigInts(true);
  const hash = createHash('sha256');
  let count = 0;
  for (const row of query.iterate()) {
    hash.update('row:');
    for (const field of fields) {
      const value = row[field.name];
      if (value === null) { hash.update('null;'); continue; }
      if (value instanceof Uint8Array) {
        hash.update(`blob:${value.byteLength}:`);
        hash.update(value);
      } else if (typeof value === 'number') {
        const bytes = Buffer.allocUnsafe(8);
        bytes.writeDoubleBE(value);
        hash.update('real:'); hash.update(bytes);
      } else if (typeof value === 'bigint' || typeof value === 'string') {
        const bytes = Buffer.from(String(value));
        hash.update(`${typeof value}:${bytes.byteLength}:`); hash.update(bytes);
      } else throw new Error(`Unsupported SQLite value type in ${table}.`);
      hash.update(';');
    }
    count += 1;
  }
  return { count, sha256: hash.digest('hex') };
}

function validateDatabase(database, expectedVersion) {
  database.exec('PRAGMA query_only = ON; PRAGMA temp_store = MEMORY; BEGIN;');
  requireCheck(database.prepare('PRAGMA user_version').get().user_version === expectedVersion,
    `Expected schema ${expectedVersion}.`);
  requireCheck(database.prepare('PRAGMA integrity_check').all().every(row => row.integrity_check === 'ok'),
    'SQLite integrity check failed.');
  requireCheck(database.prepare('PRAGMA foreign_key_check').all().length === 0,
    'SQLite foreign key check failed.');
}

function verifySchemaObjects(before, after, mode) {
  const expected = [...before, ...(mode === 'migration' ? additions : [])];
  requireCheck(after.length === expected.length, 'Schema object count changed unexpectedly.');
  const actualByName = new Map(after.map(object => [object.name, object]));
  for (const object of expected) {
    const actual = actualByName.get(object.name);
    requireCheck(actual?.type === object.type && actual?.tbl_name === object.tbl_name,
      `Schema object identity changed: ${object.name}.`);
    requireCheck(normalizedSQL(actual.sql) === normalizedSQL(object.sql),
      `Schema definition changed unexpectedly: ${object.name}.`);
  }
}

export function verifySchema12Copies({ mode, sourcePath, targetPath }) {
  requireCheck(['backup', 'migration'].includes(mode), 'Choose backup or migration mode.');
  requireCheck(isAbsolute(sourcePath ?? '') && isAbsolute(targetPath ?? ''), 'Use absolute copy paths.');
  const sourceFile = realpathSync(sourcePath), targetFile = realpathSync(targetPath);
  const sourceStat = statSync(sourceFile), targetStat = statSync(targetFile);
  requireCheck(sourceStat.isFile() && targetStat.isFile(), 'Both inputs must be regular database files.');
  requireCheck(sourceFile !== targetFile && (sourceStat.dev !== targetStat.dev || sourceStat.ino !== targetStat.ino),
    'Source and target must be independent database copies.');
  let source, target;
  try {
    source = new DatabaseSync(sourceFile, { readOnly: true, timeout: 5000 });
    target = new DatabaseSync(targetFile, { readOnly: true, timeout: 5000 });
    validateDatabase(source, 11);
    validateDatabase(target, mode === 'migration' ? 12 : 11);
    const oldObjects = objects(source), newObjects = objects(target);
    requireCheck(!oldObjects.some(object => additions.some(addition => addition.name === object.name)),
      'Schema-11 source already contains a schema-12 object.');
    verifySchemaObjects(oldObjects, newObjects, mode);
    const tables = oldObjects.filter(object => object.type === 'table').map(object => object.name);
    requireCheck(tables.length === 24, 'Expected all 24 schema-11 application tables.');
    const compared = [];
    for (const table of tables) {
      const oldFields = columns(source, table), newFields = columns(target, table);
      requireCheck(JSON.stringify(oldFields) === JSON.stringify(newFields), `Column definitions changed: ${table}.`);
      const original = tableDigest(source, table, oldFields);
      const restored = tableDigest(target, table, oldFields);
      requireCheck(original.count === restored.count && original.sha256 === restored.sha256, `Stored rows changed: ${table}.`);
      compared.push({ table, ...original });
    }
    if (mode === 'migration') {
      requireCheck(target.prepare('SELECT COUNT(*) AS n FROM comments').get().n === 0,
        'Migration unexpectedly created comments.');
    }
    return { ok: true, mode, sourceSchema: 11, targetSchema: mode === 'migration' ? 12 : 11,
      tableCount: compared.length, tables: compared,
      ...(mode === 'migration' ? { addedTables: ['comments'], addedIndexCount: 3 } : {}) };
  } finally {
    target?.close(); source?.close();
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [mode, sourcePath, targetPath, ...extra] = process.argv.slice(2);
  try {
    requireCheck(extra.length === 0, 'Unexpected arguments.');
    console.log(JSON.stringify(verifySchema12Copies({ mode, sourcePath, targetPath })));
  } catch (error) {
    // Do not dump databases, row values, tokens, key material, or raw SQL errors.
    console.error(JSON.stringify({ ok: false, error: error.message }));
    process.exitCode = 1;
  }
}
