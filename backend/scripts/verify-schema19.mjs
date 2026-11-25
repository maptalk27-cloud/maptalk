import { createHash } from 'node:crypto';
import { lstatSync, realpathSync, statSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';

// Read-only frozen copies: backup 18 -> 18, migration 18 -> 19 with the new
// table empty, same-schema 19 -> 19. Never open or migrate a live database.
class VerificationError extends Error {}
function requireCheck(condition, message) { if (!condition) throw new VerificationError(message); }
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const identifier = name => `"${name.replaceAll('"', '""')}"`;
const applicationTables = [
  'apple_auth_challenges', 'apple_refresh_tokens', 'apple_used_codes',
  'archive_hidden', 'auth_identities', 'beta_invites', 'beta_members',
  'cluster_media', 'comments', 'content_reports', 'deleted_memories', 'direct_messages', 'media',
  'media_likes', 'media_upload_chunks', 'media_upload_requests', 'media_upload_sessions',
  'memories', 'memory_clusters', 'memory_feedback', 'memory_media', 'oauth_auth_challenges',
  'oauth_used_codes', 'place_sources', 'places', 'saved_places', 'server_metadata', 'sessions',
  'user_blocks', 'user_profiles', 'users',
];
const addedTable = 'memory_custom_feelings';
const livePaths = ['/srv/maptalk/data/maptalk.sqlite', '/var/lib/maptalk/maptalk.sqlite'];
// Independent contract, not imported from the migration being verified.
const referenceSQL = `CREATE TABLE memory_custom_feelings (
  memory_id TEXT PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,
  emoji TEXT NOT NULL CHECK(length(emoji) BETWEEN 1 AND 16)
) STRICT;`;

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
  return (sql.match(/--[^\r\n]*(?:\r?\n|$)|\/\*[\s\S]*?\*\/|'(?:[^']|'')*'|"(?:[^"]|"")*"|`(?:[^`]|``)*`|\[[^\]]*\]|[A-Za-z_][A-Za-z_0-9]*|(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?|!=|==|<=|>=|<>|\|\||->>|->|[^\s]/g) ?? [])
    .filter(token => !token.startsWith('--') && !token.startsWith('/*'));
}
function customObjects(schema) {
  return schema.filter(object => object.tbl_name === addedTable).map(object => ({ ...object, sql: tokens(object.sql) }));
}
function verifyObjects(source, target, before, after, mode, reference) {
  for (const [database, schema, version] of [[source, before, mode === 'same-schema' ? 19 : 18],
    [target, after, mode === 'backup' ? 18 : 19]]) {
    const expected = [...applicationTables, ...(version === 19 ? [addedTable] : [])].sort();
    const tables = schema.filter(object => object.type === 'table' && !object.name.startsWith('sqlite_'))
      .map(object => object.name).sort();
    requireCheck(equal(tables, expected), `Expected exactly ${expected.length} application tables.`);
    if (version === 19) {
      requireCheck(equal(customObjects(schema), customObjects(objects(reference))), 'Unexpected schema19 table/index definition.');
      requireCheck(equal(columns(database, addedTable), columns(reference, addedTable)), 'Unexpected schema19 columns.');
      for (const pragma of ['foreign_key_list', 'index_list']) requireCheck(equal(
        database.prepare(`PRAGMA ${pragma}(${identifier(addedTable)})`).all(),
        reference.prepare(`PRAGMA ${pragma}(${identifier(addedTable)})`).all()), 'Unexpected schema19 constraints/indexes.');
    }
  }
  requireCheck(equal(before, mode === 'migration' ? after.filter(object => object.tbl_name !== addedTable) : after),
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

export function verifySchema19Copies({ mode, sourcePath, targetPath }) {
  requireCheck(['backup', 'migration', 'same-schema'].includes(mode), 'Choose backup, migration or same-schema mode.');
  const sourceFile = snapshotFile(sourcePath), targetFile = snapshotFile(targetPath);
  requireCheck(sourceFile.path !== targetFile.path && !sameFile(sourceFile.stat, targetFile.stat),
    'Source and target must be independent database copies.');
  const sourceSchema = mode === 'same-schema' ? 19 : 18, targetSchema = mode === 'backup' ? 18 : 19;
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
    const tables = [], comparedTables = [...applicationTables, ...(mode === 'same-schema' ? [addedTable] : [])].sort();
    let comparedColumnCount = 0;
    for (const table of comparedTables) {
      const originalColumns = columns(source, table), restoredColumns = columns(target, table);
      requireCheck(equal(originalColumns, restoredColumns), `Column definitions changed: ${table}.`);
      const original = tableDigest(source, table, originalColumns), restored = tableDigest(target, table, restoredColumns);
      requireCheck(equal(original, restored), `Stored rows changed: ${table}.`);
      comparedColumnCount += originalColumns.length; tables.push({ table, ...original });
    }
    const customFeelingCount = targetSchema === 19 ? target.prepare('SELECT COUNT(*) AS n FROM memory_custom_feelings').get().n : 0;
    requireCheck(mode !== 'migration' || customFeelingCount === 0, 'Migration unexpectedly populated custom feelings.');
    return { ok: true, mode, sourceSchema, targetSchema, tableCount: tables.length,
      sourceSchemaObjectCount: before.length, targetSchemaObjectCount: after.length,
      comparedColumnCount, comparedRowCount: tables.reduce((sum, table) => sum + table.count, 0),
      sourceSchemaSha256: createHash('sha256').update(JSON.stringify(before)).digest('hex'),
      targetSchemaSha256: createHash('sha256').update(JSON.stringify(after)).digest('hex'),
      addedTables: mode === 'migration' ? [addedTable] : [], customFeelingCount, tables };
  } finally { reference?.close(); target?.close(); source?.close(); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [mode, sourcePath, targetPath, ...extra] = process.argv.slice(2);
  try {
    requireCheck(extra.length === 0, 'Unexpected arguments.');
    console.log(JSON.stringify(verifySchema19Copies({ mode, sourcePath, targetPath })));
  } catch (error) {
    console.error(JSON.stringify({ ok: false,
      error: error instanceof VerificationError ? error.message : 'Unable to verify database copies.' }));
    process.exitCode = 1;
  }
}
