import { createHash } from 'node:crypto';
import { lstatSync, realpathSync, statSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';

// Independent frozen copies only; never import openDatabase (it migrates).
// backup: 16 -> 16; migration: 16 -> 17 with empty feedback;
// same-schema: 17 -> 17, including every existing feedback row.
// No writes, cloud calls, stored values, paths or arbitrary schema names in output.
class VerificationError extends Error {}
function requireCheck(condition, message) {
  if (!condition) throw new VerificationError(message);
}
function identifier(name) { return `"${name.replaceAll('"', '""')}"`; }
const applicationTables = [
  'apple_auth_challenges', 'apple_refresh_tokens', 'apple_used_codes',
  'archive_hidden', 'auth_identities', 'beta_invites', 'beta_members',
  'cluster_media', 'comments', 'content_reports', 'deleted_memories', 'media',
  'media_upload_chunks', 'media_upload_requests', 'media_upload_sessions',
  'memories', 'memory_clusters', 'memory_media', 'oauth_auth_challenges',
  'oauth_used_codes', 'place_sources', 'places', 'server_metadata', 'sessions',
  'user_blocks', 'user_profiles', 'users',
];
const livePaths = ['/srv/maptalk/data/maptalk.sqlite', '/var/lib/maptalk/maptalk.sqlite'];
const feedbackSQL = `CREATE TABLE memory_feedback (
  memory_id TEXT PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,
  endorsement TEXT CHECK(endorsement IS NULL OR endorsement IN ('hype', 'solid', 'meh', 'questionable')),
  comment TEXT NOT NULL CHECK(length(comment) <= 1000),
  CHECK(endorsement IS NOT NULL OR length(comment) > 0)
) STRICT`;
const feedbackColumns = [
  { cid: 0, name: 'memory_id', type: 'TEXT', notnull: 1, dflt_value: null, pk: 1, hidden: 0 },
  { cid: 1, name: 'endorsement', type: 'TEXT', notnull: 0, dflt_value: null, pk: 0, hidden: 0 },
  { cid: 2, name: 'comment', type: 'TEXT', notnull: 1, dflt_value: null, pk: 0, hidden: 0 },
];
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
function validate(database, expectedVersion) {
  database.exec('PRAGMA query_only = ON; PRAGMA temp_store = MEMORY; BEGIN;');
  requireCheck(database.prepare('PRAGMA user_version').get().user_version === expectedVersion,
    `Expected schema ${expectedVersion}.`);
  const integrity = database.prepare('PRAGMA integrity_check').all();
  requireCheck(integrity.length === 1 && integrity[0].integrity_check === 'ok', 'SQLite integrity check failed.');
  requireCheck(database.prepare('PRAGMA foreign_key_check').all().length === 0, 'SQLite foreign key check failed.');
}
function objects(database) {
  return database.prepare('SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY type, name').all();
}
function columns(database, table) {
  return database.prepare(`PRAGMA table_xinfo(${identifier(table)})`).all();
}
function tokens(sql) {
  // Ignore only token-separating whitespace, never whitespace inside literals.
  requireCheck(typeof sql === 'string', 'Missing feedback table definition.');
  return sql.match(/--[^\r\n]*(?:\r?\n|$)|\/\*[\s\S]*?\*\/|'(?:[^']|'')*'|"(?:[^"]|"")*"|`(?:[^`]|``)*`|\[[^\]]*\]|[A-Za-z_][A-Za-z_0-9]*|(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?|!=|==|<=|>=|<>|\|\||->>|->|[^\s]/g) ?? [];
}
function equal(a, b) { return JSON.stringify(a) === JSON.stringify(b); }
function verifyFeedback(database, schema) {
  const additions = schema.filter(object => object.tbl_name === 'memory_feedback');
  requireCheck(additions.length === 2
    && additions[0].type === 'index' && additions[0].name === 'sqlite_autoindex_memory_feedback_1'
    && additions[0].sql === null && additions[1].type === 'table' && additions[1].name === 'memory_feedback',
  'Expected only the feedback table and its primary-key autoindex.');
  requireCheck(equal(tokens(additions[1].sql), tokens(feedbackSQL)), 'Unexpected feedback table definition.');
  requireCheck(equal(columns(database, 'memory_feedback'), feedbackColumns), 'Unexpected feedback columns.');
  requireCheck(equal(database.prepare('PRAGMA foreign_key_list(memory_feedback)').all(), [
    { id: 0, seq: 0, table: 'memories', from: 'memory_id', to: 'id', on_update: 'NO ACTION', on_delete: 'CASCADE', match: 'NONE' },
  ]), 'Unexpected feedback foreign key.');
  requireCheck(equal(database.prepare('PRAGMA index_list(memory_feedback)').all(), [
    { seq: 0, name: 'sqlite_autoindex_memory_feedback_1', unique: 1, origin: 'pk', partial: 0 },
  ]), 'Unexpected feedback index.');
}
function verifyObjects(source, target, before, after, mode) {
  for (const [database, schema, version] of [[source, before, mode === 'same-schema' ? 17 : 16],
    [target, after, mode === 'backup' ? 16 : 17]]) {
    const expected = version === 17 ? [...applicationTables, 'memory_feedback'].sort() : applicationTables;
    const tables = schema.filter(object => object.type === 'table' && !object.name.startsWith('sqlite_'))
      .map(object => object.name).sort();
    requireCheck(equal(tables, expected), `Expected exactly ${expected.length} application tables.`);
    if (version === 17) verifyFeedback(database, schema);
  }
  const preservedTarget = mode === 'migration' ? after.filter(object => object.tbl_name !== 'memory_feedback') : after;
  // All old objects, including autoindexes, must retain their exact SQL.
  requireCheck(equal(before, preservedTarget), 'Existing schema objects or definitions changed.');
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
        const bytes = Buffer.allocUnsafe(8); bytes.writeDoubleBE(value);
        hash.update('real:'); hash.update(bytes);
      } else if (typeof value === 'bigint' || typeof value === 'string') {
        const bytes = Buffer.from(String(value));
        hash.update(`${typeof value}:${bytes.byteLength}:`); hash.update(bytes);
      } else throw new VerificationError(`Unsupported SQLite value type: ${table}.`);
      hash.update(';');
    }
    count += 1;
  }
  return { count, sha256: hash.digest('hex') };
}

export function verifySchema17Copies({ mode, sourcePath, targetPath }) {
  requireCheck(['backup', 'migration', 'same-schema'].includes(mode), 'Choose backup, migration or same-schema mode.');
  const sourceFile = snapshotFile(sourcePath), targetFile = snapshotFile(targetPath);
  requireCheck(sourceFile.path !== targetFile.path && !sameFile(sourceFile.stat, targetFile.stat),
    'Source and target must be independent database copies.');
  const sourceSchema = mode === 'same-schema' ? 17 : 16, targetSchema = mode === 'backup' ? 16 : 17;
  let source, target;
  try {
    source = new DatabaseSync(sourceFile.path, { readOnly: true, timeout: 5000 });
    target = new DatabaseSync(targetFile.path, { readOnly: true, timeout: 5000 });
    validate(source, sourceSchema); validate(target, targetSchema);
    requireCheck(source.prepare('PRAGMA application_id').get().application_id
      === target.prepare('PRAGMA application_id').get().application_id, 'Database application ID changed.');
    const sourceObjects = objects(source), targetObjects = objects(target);
    verifyObjects(source, target, sourceObjects, targetObjects, mode);
    const tables = [], comparedTables = mode === 'same-schema'
      ? [...applicationTables, 'memory_feedback'].sort() : applicationTables;
    let comparedColumnCount = 0;
    for (const table of comparedTables) {
      const before = columns(source, table), after = columns(target, table);
      requireCheck(equal(before, after), `Column definitions changed: ${table}.`);
      const original = tableDigest(source, table, before), restored = tableDigest(target, table, after);
      requireCheck(original.count === restored.count && original.sha256 === restored.sha256, `Stored rows changed: ${table}.`);
      comparedColumnCount += before.length;
      tables.push({ table, ...original });
    }
    const feedbackCount = targetSchema === 17
      ? target.prepare('SELECT COUNT(*) AS n FROM memory_feedback').get().n : 0;
    requireCheck(mode !== 'migration' || feedbackCount === 0, 'Migration unexpectedly populated feedback.');
    return { ok: true, mode, sourceSchema, targetSchema, tableCount: tables.length,
      sourceSchemaObjectCount: sourceObjects.length, targetSchemaObjectCount: targetObjects.length,
      comparedColumnCount, comparedRowCount: tables.reduce((sum, table) => sum + table.count, 0),
      sourceSchemaSha256: createHash('sha256').update(JSON.stringify(sourceObjects)).digest('hex'),
      targetSchemaSha256: createHash('sha256').update(JSON.stringify(targetObjects)).digest('hex'),
      addedTables: mode === 'migration' ? ['memory_feedback'] : [], feedbackCount, tables };
  } finally { target?.close(); source?.close(); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [mode, sourcePath, targetPath, ...extra] = process.argv.slice(2);
  try {
    requireCheck(extra.length === 0, 'Unexpected arguments.');
    console.log(JSON.stringify(verifySchema17Copies({ mode, sourcePath, targetPath })));
  } catch (error) {
    // Native diagnostics and arbitrary schema object names may expose data.
    console.error(JSON.stringify({ ok: false,
      error: error instanceof VerificationError ? error.message : 'Unable to verify database copies.' }));
    process.exitCode = 1;
  }
}
