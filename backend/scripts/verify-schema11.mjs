import { createHash } from 'node:crypto';
import { realpathSync, statSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';

// Compare isolated copies only, never the live database. This script does not
// create backups, decrypt, migrate, write data, connect to AWS, or print rows.
// backup:    consistent schema-10 snapshot vs authenticated restored copy.
// migration: same schema-10 snapshot vs isolated schema-11 migration rehearsal.
function requireCheck(condition, message) {
  if (!condition) throw new Error(message);
}

function identifier(name) { return `"${name.replaceAll('"', '""')}"`; }
function normalizedSQL(sql) { return sql?.replace(/\s+/g, ' ').trim() ?? null; }

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

export function verifySchema11Copies({ mode, sourcePath, targetPath }) {
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
    validateDatabase(source, 10);
    validateDatabase(target, mode === 'migration' ? 11 : 10);
    const oldObjects = objects(source), newObjects = objects(target);
    requireCheck(oldObjects.length === newObjects.length, 'Schema object count changed.');
    for (let index = 0; index < oldObjects.length; index += 1) {
      const before = oldObjects[index], after = newObjects[index];
      requireCheck(before.type === after.type && before.name === after.name && before.tbl_name === after.tbl_name,
        'Schema object identity changed.');
      let afterSQL = after.sql;
      if (mode === 'migration' && before.type === 'table' && before.name === 'places') {
        const addition = /,\s*directory_kind\s+TEXT\s+CHECK\s*\(\s*directory_kind\s+IS\s+NULL\s+OR\s+directory_kind\s*=\s*'airport'\s*\)/i;
        requireCheck(addition.test(afterSQL), 'Airport column CHECK constraint is missing.');
        afterSQL = afterSQL.replace(addition, '');
      }
      requireCheck(normalizedSQL(before.sql) === normalizedSQL(afterSQL), `Schema definition changed unexpectedly: ${before.name}.`);
    }
    const tables = oldObjects.filter(object => object.type === 'table').map(object => object.name);
    requireCheck(tables.length === 24, 'Expected all 24 schema-10 application tables.');
    const compared = [];
    for (const table of tables) {
      const oldFields = columns(source, table), newFields = columns(target, table);
      if (mode === 'migration' && table === 'places') {
        const addition = newFields.at(-1);
        requireCheck(addition?.name === 'directory_kind' && addition.type === 'TEXT'
          && addition.notnull === 0 && addition.dflt_value === null && addition.pk === 0 && addition.hidden === 0,
        'Unexpected airport column definition.');
        requireCheck(JSON.stringify(newFields.slice(0, -1)) === JSON.stringify(oldFields), 'Existing place columns changed.');
        requireCheck(target.prepare('SELECT COUNT(*) AS n FROM places WHERE directory_kind IS NOT NULL').get().n === 0,
          'Migration unexpectedly classified an existing place.');
      } else requireCheck(JSON.stringify(oldFields) === JSON.stringify(newFields), `Column definitions changed: ${table}.`);
      const original = tableDigest(source, table, oldFields);
      const restored = tableDigest(target, table, oldFields);
      requireCheck(original.count === restored.count && original.sha256 === restored.sha256, `Stored rows changed: ${table}.`);
      compared.push({ table, ...original });
    }
    return { ok: true, mode, sourceSchema: 10, targetSchema: mode === 'migration' ? 11 : 10,
      tableCount: compared.length, tables: compared };
  } finally {
    target?.close(); source?.close();
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [mode, sourcePath, targetPath, ...extra] = process.argv.slice(2);
  try {
    requireCheck(extra.length === 0, 'Unexpected arguments.');
    console.log(JSON.stringify(verifySchema11Copies({ mode, sourcePath, targetPath })));
  } catch (error) {
    // Do not dump databases, row values, tokens, key material, or raw SQL errors.
    console.error(JSON.stringify({ ok: false, error: error.message }));
    process.exitCode = 1;
  }
}
