import { createHash } from 'node:crypto';
import { lstatSync, realpathSync, statSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { poiVisitDay, POI_VISIT_DAY_POLICY } from '../src/poi-visit-day.mjs';

// Frozen independent copies only. Never import openDatabase: it migrates.
// backup 17 -> 17; migration 17 -> 18 (new tables empty); same-schema 18 -> 18.
// Input files are read-only. Only an ephemeral in-memory reference schema is
// created, independently of production migration code. No data/path output.
class VerificationError extends Error {}
function requireCheck(condition, message) { if (!condition) throw new VerificationError(message); }
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const identifier = name => `"${name.replaceAll('"', '""')}"`;
const applicationTables = [
  'apple_auth_challenges', 'apple_refresh_tokens', 'apple_used_codes',
  'archive_hidden', 'auth_identities', 'beta_invites', 'beta_members',
  'cluster_media', 'comments', 'content_reports', 'deleted_memories', 'media',
  'media_upload_chunks', 'media_upload_requests', 'media_upload_sessions',
  'memories', 'memory_clusters', 'memory_feedback', 'memory_media', 'oauth_auth_challenges',
  'oauth_used_codes', 'place_sources', 'places', 'server_metadata', 'sessions',
  'user_blocks', 'user_profiles', 'users',
];
const addedTables = ['direct_messages', 'media_likes', 'saved_places'];
const addedIndex = 'memories_place_owner_visits';
const livePaths = ['/srv/maptalk/data/maptalk.sqlite', '/var/lib/maptalk/maptalk.sqlite'];
const referenceSQL = `
  CREATE TABLE memories(place_id TEXT, owner_id TEXT, kind TEXT);
  CREATE TABLE memory_feedback (
    memory_id TEXT PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,
    endorsement TEXT CHECK(endorsement IS NULL OR endorsement IN ('hype', 'solid', 'meh', 'questionable')),
    comment TEXT NOT NULL CHECK(length(comment) <= 1000),
    CHECK(endorsement IS NOT NULL OR length(comment) > 0)
  ) STRICT;
  CREATE TABLE media_likes (
    memory_id TEXT NOT NULL,
    media_id TEXT NOT NULL,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    PRIMARY KEY(memory_id, media_id, user_id),
    FOREIGN KEY(memory_id, media_id) REFERENCES memory_media(memory_id, media_id) ON DELETE CASCADE
  ) STRICT;
  CREATE TABLE saved_places (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    place_id TEXT NOT NULL REFERENCES places(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    PRIMARY KEY(user_id, place_id)
  ) STRICT;
  CREATE INDEX saved_places_page ON saved_places(user_id, created_at DESC, place_id DESC);
  CREATE TABLE direct_messages (
    id TEXT PRIMARY KEY,
    sender_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipient_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    text TEXT NOT NULL CHECK(length(text) <= 1000),
    context_memory_id TEXT,
    context_media_id TEXT,
    request_hash TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    CHECK(sender_id != recipient_id),
    CHECK((context_memory_id IS NULL) = (context_media_id IS NULL)),
    CHECK(length(text) > 0 OR context_memory_id IS NOT NULL)
  ) STRICT;
  CREATE INDEX direct_messages_sent ON direct_messages(sender_id, recipient_id, created_at DESC, id DESC);
  CREATE INDEX direct_messages_received ON direct_messages(recipient_id, sender_id, created_at DESC, id DESC);
  CREATE INDEX memories_place_owner_visits ON memories(place_id, owner_id) WHERE kind = 'poi';
`;

function sameFile(a, b) { return a.dev === b.dev && a.ino === b.ino; }
function snapshotFile(path) {
  requireCheck(typeof path === 'string' && isAbsolute(path), 'Use absolute snapshot paths.');
  requireCheck(!livePaths.includes(resolve(path)), 'Use snapshot copies, not the production database.');
  const leaf = lstatSync(path);
  requireCheck(!leaf.isSymbolicLink(), 'Snapshot files must not be symbolic links.');
  requireCheck(leaf.isFile(), 'Both inputs must be regular database files.');
  const realPath = realpathSync(path), stat = statSync(realPath);
  requireCheck(!livePaths.includes(realPath), 'Use snapshot copies, not the production database.');
  for (const livePath of livePaths) {
    let liveStat;
    try { liveStat = statSync(livePath); } catch (error) {
      if (error.code !== 'ENOENT' && error.code !== 'ENOTDIR') throw error;
    }
    requireCheck(!liveStat || !sameFile(stat, liveStat), 'Use snapshot copies, not the production database.');
  }
  requireCheck(stat.nlink === 1, 'Snapshot files must not have hard links.');
  return { path: realPath, stat };
}

function validate(database, version) {
  database.exec('PRAGMA query_only = ON; PRAGMA temp_store = MEMORY; BEGIN;');
  requireCheck(database.prepare('PRAGMA user_version').get().user_version === version, `Expected schema ${version}.`);
  const integrity = database.prepare('PRAGMA integrity_check').all();
  requireCheck(integrity.length === 1 && integrity[0].integrity_check === 'ok', 'SQLite integrity check failed.');
  requireCheck(database.prepare('PRAGMA foreign_key_check').all().length === 0, 'SQLite foreign key check failed.');
}
function objects(database) {
  return database.prepare('SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY type, name').all();
}
function columns(database, table) { return database.prepare(`PRAGMA table_xinfo(${identifier(table)})`).all(); }
function tokens(sql) {
  if (sql === null) return null;
  requireCheck(typeof sql === 'string', 'Missing schema definition.');
  // Ignore SQL comments/formatting only, never whitespace inside literals.
  return (sql.match(/--[^\r\n]*(?:\r?\n|$)|\/\*[\s\S]*?\*\/|'(?:[^']|'')*'|"(?:[^"]|"")*"|`(?:[^`]|``)*`|\[[^\]]*\]|[A-Za-z_][A-Za-z_0-9]*|(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?|!=|==|<=|>=|<>|\|\||->>|->|[^\s]/g) ?? [])
    .filter(token => !token.startsWith('--') && !token.startsWith('/*'));
}
const isAddition = object => addedTables.includes(object.tbl_name) || object.name === addedIndex;
function fixedObjects(schema, filter) {
  return schema.filter(filter).map(object => ({ ...object, sql: tokens(object.sql) }));
}
function verifyObjects(source, target, before, after, mode, reference) {
  const fixed = objects(reference);
  for (const [database, schema, version] of [[source, before, mode === 'same-schema' ? 18 : 17],
    [target, after, mode === 'backup' ? 17 : 18]]) {
    const expected = [...applicationTables, ...(version === 18 ? addedTables : [])].sort();
    const tables = schema.filter(object => object.type === 'table' && !object.name.startsWith('sqlite_'))
      .map(object => object.name).sort();
    requireCheck(equal(tables, expected), `Expected exactly ${expected.length} application tables.`);
    requireCheck(equal(fixedObjects(schema, object => object.tbl_name === 'memory_feedback'),
      fixedObjects(fixed, object => object.tbl_name === 'memory_feedback')), 'Unexpected feedback schema definition.');
    if (version === 18) {
      requireCheck(equal(fixedObjects(schema, isAddition), fixedObjects(fixed, isAddition)), 'Unexpected schema18 table/index definition.');
      for (const table of addedTables) {
        requireCheck(equal(columns(database, table), columns(reference, table)), 'Unexpected schema18 columns.');
        for (const pragma of ['foreign_key_list', 'index_list']) requireCheck(equal(
          database.prepare(`PRAGMA ${pragma}(${identifier(table)})`).all(),
          reference.prepare(`PRAGMA ${pragma}(${identifier(table)})`).all()), 'Unexpected schema18 constraints/indexes.');
      }
    }
  }
  // Existing objects (including SQL and autoindexes) must remain byte-for-byte.
  requireCheck(equal(before, mode === 'migration' ? after.filter(object => !isAddition(object)) : after),
    'Existing schema objects or definitions changed.');
}

function tableDigest(database, table, fields) {
  const primaryKey = fields.filter(field => field.pk > 0).sort((a, b) => a.pk - b.pk);
  requireCheck(primaryKey.length > 0, `Missing stable primary key: ${table}.`);
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
        const bytes = Buffer.allocUnsafe(8); bytes.writeDoubleBE(value); hash.update('real:'); hash.update(bytes);
      } else if (typeof value === 'bigint' || typeof value === 'string') {
        const bytes = Buffer.from(String(value)); hash.update(`${typeof value}:${bytes.byteLength}:`); hash.update(bytes);
      } else throw new VerificationError(`Unsupported SQLite value type: ${table}.`);
      hash.update(';');
    }
    count++;
  }
  return { count, sha256: hash.digest('hex') };
}

function visitDayDigest(database) {
  const hash = createHash('sha256');
  let count = 0;
  for (const row of database.prepare(`SELECT m.id, m.owner_id, m.place_id,
    COALESCE(m.published_at, m.created_at) AS timestamp, p.latitude, p.longitude
    FROM memories m JOIN places p ON p.id = m.place_id WHERE m.kind = 'poi' ORDER BY m.id`).iterate()) {
    const day = poiVisitDay(row.timestamp, row.latitude, row.longitude);
    requireCheck(/^\d{4}-\d{2}-\d{2}$/.test(day), 'Invalid canonical visit day.');
    hash.update(JSON.stringify([row.id, row.owner_id, row.place_id, day])); hash.update('\n'); count++;
  }
  return { policy: POI_VISIT_DAY_POLICY, count, sha256: hash.digest('hex') };
}
function verifyDayPolicy() {
  for (const [time, lat, lon, expected] of [
    ['2026-11-24T08:30:00Z', 21.3099, -157.8581, '2026-11-23'],
    ['2026-11-24T16:30:00Z', 30.5728, 104.0668, '2026-11-25'],
    ['2026-07-01T07:30:00Z', 34.0522, -118.2437, '2026-07-01'],
    ['2026-01-01T07:30:00Z', 34.0522, -118.2437, '2025-12-31'],
  ]) requireCheck(poiVisitDay(Date.parse(time), lat, lon) === expected, 'Canonical place timezone policy check failed.');
}

export function verifySchema18Copies({ mode, sourcePath, targetPath }) {
  requireCheck(['backup', 'migration', 'same-schema'].includes(mode), 'Choose backup, migration or same-schema mode.');
  const sourceFile = snapshotFile(sourcePath), targetFile = snapshotFile(targetPath);
  requireCheck(sourceFile.path !== targetFile.path && !sameFile(sourceFile.stat, targetFile.stat),
    'Source and target must be independent database copies.');
  const sourceSchema = mode === 'same-schema' ? 18 : 17, targetSchema = mode === 'backup' ? 17 : 18;
  let source, target, reference;
  try {
    source = new DatabaseSync(sourceFile.path, { readOnly: true, timeout: 5000 });
    target = new DatabaseSync(targetFile.path, { readOnly: true, timeout: 5000 });
    validate(source, sourceSchema); validate(target, targetSchema);
    requireCheck(source.prepare('PRAGMA application_id').get().application_id
      === target.prepare('PRAGMA application_id').get().application_id, 'Database application ID changed.');
    reference = new DatabaseSync(':memory:'); reference.exec(referenceSQL);
    const before = objects(source), after = objects(target);
    verifyObjects(source, target, before, after, mode, reference);
    const tables = [], comparedTables = [...applicationTables, ...(mode === 'same-schema' ? addedTables : [])].sort();
    let comparedColumnCount = 0;
    for (const table of comparedTables) {
      const originalColumns = columns(source, table), restoredColumns = columns(target, table);
      requireCheck(equal(originalColumns, restoredColumns), `Column definitions changed: ${table}.`);
      const original = tableDigest(source, table, originalColumns), restored = tableDigest(target, table, restoredColumns);
      requireCheck(equal(original, restored), `Stored rows changed: ${table}.`);
      comparedColumnCount += originalColumns.length; tables.push({ table, ...original });
    }
    const newTableCounts = targetSchema === 18 ? Object.fromEntries(addedTables.map(table => [table,
      target.prepare(`SELECT COUNT(*) AS n FROM ${identifier(table)}`).get().n])) : {};
    requireCheck(mode !== 'migration' || Object.values(newTableCounts).every(count => count === 0), 'Migration unexpectedly populated new tables.');
    verifyDayPolicy();
    const visitDays = visitDayDigest(source);
    requireCheck(equal(visitDays, visitDayDigest(target)), 'Canonical visit days changed.');
    return { ok: true, mode, sourceSchema, targetSchema, tableCount: tables.length,
      sourceSchemaObjectCount: before.length, targetSchemaObjectCount: after.length,
      comparedColumnCount, comparedRowCount: tables.reduce((sum, table) => sum + table.count, 0),
      sourceSchemaSha256: createHash('sha256').update(JSON.stringify(before)).digest('hex'),
      targetSchemaSha256: createHash('sha256').update(JSON.stringify(after)).digest('hex'),
      addedTables: mode === 'migration' ? addedTables : [], newTableCounts, visitDays, tables };
  } finally { reference?.close(); target?.close(); source?.close(); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [mode, sourcePath, targetPath, ...extra] = process.argv.slice(2);
  try {
    requireCheck(extra.length === 0, 'Unexpected arguments.');
    console.log(JSON.stringify(verifySchema18Copies({ mode, sourcePath, targetPath })));
  } catch (error) {
    console.error(JSON.stringify({ ok: false,
      error: error instanceof VerificationError ? error.message : 'Unable to verify database copies.' }));
    process.exitCode = 1;
  }
}
