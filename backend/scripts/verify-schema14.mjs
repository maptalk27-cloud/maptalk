import { createHash } from 'node:crypto';
import { realpathSync, statSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';

// Compare independent, isolated copies only, never a live database. This tool
// does not back up, restore, migrate, write rows, contact AWS, or print data.
// backup: schema-12 frozen snapshot vs authenticated schema-12 restored copy.
// migration: the same schema-12 snapshot vs a schema-14 migrated copy.
class VerificationError extends Error {}
function requireCheck(condition, message) {
  if (!condition) throw new VerificationError(message);
}
function identifier(name) { return `"${name.replaceAll('"', '""')}"`; }
function normalizedSQL(sql) { return sql?.replace(/\s+/g, ' ').trim() ?? null; }

const oldTables = [
  'apple_auth_challenges', 'apple_refresh_tokens', 'apple_used_codes',
  'archive_hidden', 'auth_identities', 'beta_invites', 'beta_members',
  'comments', 'content_reports', 'deleted_memories', 'media', 'media_upload_chunks',
  'media_upload_requests', 'media_upload_sessions', 'memories', 'memory_media',
  'oauth_auth_challenges', 'oauth_used_codes', 'place_sources', 'places',
  'server_metadata', 'sessions', 'user_blocks', 'user_profiles', 'users',
];

const additions = [
  { type: 'table', name: 'memory_clusters', tbl_name: 'memory_clusters',
    sql: `CREATE TABLE memory_clusters (
      memory_id TEXT PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,
      title TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 160),
      members_json TEXT NOT NULL CHECK(json_valid(members_json)
        AND json_type(members_json) = 'array' AND json_array_length(members_json) BETWEEN 1 AND 50)
    ) STRICT` },
  { type: 'table', name: 'cluster_media', tbl_name: 'cluster_media',
    sql: `CREATE TABLE cluster_media (
      memory_id TEXT NOT NULL REFERENCES memory_clusters(memory_id) ON DELETE CASCADE,
      media_id TEXT NOT NULL REFERENCES media(id),
      PRIMARY KEY(memory_id, media_id)
    ) STRICT` },
  { type: 'index', name: 'cluster_media_asset', tbl_name: 'cluster_media',
    sql: 'CREATE INDEX cluster_media_asset ON cluster_media(media_id)' },
];

function placeSQL(categories) {
  return `CREATE TABLE places (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    category TEXT NOT NULL CHECK(category IN (${categories.map(value => `'${value}'`).join(', ')})),
    latitude REAL NOT NULL CHECK(latitude BETWEEN -90 AND 90),
    longitude REAL NOT NULL CHECK(longitude BETWEEN -180 AND 180),
    directory_kind TEXT CHECK(directory_kind IS NULL OR directory_kind = 'airport')
  ) STRICT`;
}
const oldCategories = ['viewpoint', 'restaurant', 'coffee', 'nightlife', 'art', 'market', 'other'];
const newCategories = [...oldCategories.slice(0, -1), 'hotel', 'airport', 'other'];

// SQLite quotes the table name after RENAME and ALTER ADD COLUMN changes comma
// spacing. Tokenize only this known table definition; preserve string literals
// exactly so a weakened CHECK or changed enum value cannot be normalized away.
function placeTokens(sql) {
  requireCheck(typeof sql === 'string', 'Missing places table definition.');
  return JSON.stringify(sql.replace(/^CREATE TABLE "places"(?=\s*\()/, 'CREATE TABLE places')
    .match(/'(?:[^']|'')*'|"(?:[^"]|"")*"|[A-Za-z_][A-Za-z_0-9]*|\d+|[^\s]/g));
}

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
        hash.update(`blob:${value.byteLength}:`); hash.update(value);
      } else if (typeof value === 'number') {
        const bytes = Buffer.allocUnsafe(8);
        bytes.writeDoubleBE(value);
        hash.update('real:'); hash.update(bytes);
      } else if (typeof value === 'bigint' || typeof value === 'string') {
        const bytes = Buffer.from(String(value));
        hash.update(`${typeof value}:${bytes.byteLength}:`); hash.update(bytes);
      } else throw new VerificationError(`Unsupported SQLite value type in ${table}.`);
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
  const integrity = database.prepare('PRAGMA integrity_check').all();
  requireCheck(integrity.length === 1 && integrity[0].integrity_check === 'ok', 'SQLite integrity check failed.');
  requireCheck(database.prepare('PRAGMA foreign_key_check').all().length === 0, 'SQLite foreign key check failed.');
}
function verifySchemaObjects(before, after, mode) {
  const expected = [...before, ...(mode === 'migration' ? additions : [])];
  requireCheck(after.length === expected.length, 'Schema object count changed unexpectedly.');
  const actualByName = new Map(after.map(object => [object.name, object]));
  for (const object of expected) {
    const actual = actualByName.get(object.name);
    requireCheck(actual?.type === object.type && actual?.tbl_name === object.tbl_name,
      `Schema object identity changed: ${object.name}.`);
    const matches = mode === 'migration' && object.name === 'places'
      ? placeTokens(actual.sql) === placeTokens(placeSQL(newCategories))
      : normalizedSQL(actual.sql) === normalizedSQL(object.sql);
    requireCheck(matches, `Schema definition changed unexpectedly: ${object.name}.`);
  }
}
function rejectKnownLivePath(path) {
  requireCheck(!['/srv/maptalk/data/maptalk.sqlite', '/var/lib/maptalk/maptalk.sqlite'].includes(resolve(path)),
    'Use independent snapshot copies, not the production database.');
}

export function verifySchema14Copies({ mode, sourcePath, targetPath }) {
  requireCheck(['backup', 'migration'].includes(mode), 'Choose backup or migration mode.');
  requireCheck(isAbsolute(sourcePath ?? '') && isAbsolute(targetPath ?? ''), 'Use absolute copy paths.');
  rejectKnownLivePath(sourcePath); rejectKnownLivePath(targetPath);
  const sourceFile = realpathSync(sourcePath), targetFile = realpathSync(targetPath);
  rejectKnownLivePath(sourceFile); rejectKnownLivePath(targetFile);
  const sourceStat = statSync(sourceFile), targetStat = statSync(targetFile);
  requireCheck(sourceStat.isFile() && targetStat.isFile(), 'Both inputs must be regular database files.');
  requireCheck(sourceFile !== targetFile && (sourceStat.dev !== targetStat.dev || sourceStat.ino !== targetStat.ino),
    'Source and target must be independent database copies.');
  let source, target;
  try {
    source = new DatabaseSync(sourceFile, { readOnly: true, timeout: 5000 });
    target = new DatabaseSync(targetFile, { readOnly: true, timeout: 5000 });
    validateDatabase(source, 12);
    validateDatabase(target, mode === 'migration' ? 14 : 12);
    const oldObjects = objects(source), newObjects = objects(target);
    requireCheck(!oldObjects.some(object => additions.some(addition => addition.name === object.name)),
      'Schema-12 source already contains a schema-13 object.');
    const tables = oldObjects.filter(object => object.type === 'table').map(object => object.name).sort();
    requireCheck(JSON.stringify(tables) === JSON.stringify([...oldTables].sort()),
      'Expected all 25 schema-12 application tables.');
    requireCheck(placeTokens(oldObjects.find(object => object.name === 'places')?.sql) === placeTokens(placeSQL(oldCategories)),
      'Schema-12 places definition differs from the historical category constraint.');
    verifySchemaObjects(oldObjects, newObjects, mode);
    const compared = [];
    for (const table of tables) {
      const oldFields = columns(source, table), newFields = columns(target, table);
      requireCheck(JSON.stringify(oldFields) === JSON.stringify(newFields), `Column definitions changed: ${table}.`);
      const original = tableDigest(source, table, oldFields), restored = tableDigest(target, table, oldFields);
      requireCheck(original.count === restored.count && original.sha256 === restored.sha256, `Stored rows changed: ${table}.`);
      compared.push({ table, ...original });
    }
    if (mode === 'migration') {
      for (const table of ['memory_clusters', 'cluster_media']) {
        requireCheck(target.prepare(`SELECT COUNT(*) AS n FROM ${identifier(table)}`).get().n === 0,
          `Migration unexpectedly populated ${table}.`);
      }
    }
    return { ok: true, mode, sourceSchema: 12, targetSchema: mode === 'migration' ? 14 : 12,
      tableCount: compared.length, tables: compared,
      ...(mode === 'migration' ? { addedTables: ['memory_clusters', 'cluster_media'], addedIndexCount: 1,
        widenedPlaceCategories: ['hotel', 'airport'] } : {}) };
  } finally { target?.close(); source?.close(); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [mode, sourcePath, targetPath, ...extra] = process.argv.slice(2);
  try {
    requireCheck(extra.length === 0, 'Unexpected arguments.');
    console.log(JSON.stringify(verifySchema14Copies({ mode, sourcePath, targetPath })));
  } catch (error) {
    // Native SQLite/filesystem messages are not trusted to be free of row data.
    console.error(JSON.stringify({ ok: false,
      error: error instanceof VerificationError ? error.message : 'Unable to verify database copies.' }));
    process.exitCode = 1;
  }
}
