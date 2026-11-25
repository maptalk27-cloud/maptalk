import { createHash } from 'node:crypto';
import { lstatSync, realpathSync, statSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';

// Independent, frozen copies only. Never use openDatabase here: it migrates.
// backup: 14 -> 14; migration: 14 -> 16 with both new columns NULL;
// repair: 16 -> 16, permitting only explicitly allowlisted NULL -> location ID.
// This verifier never writes rows, migrates, contacts AWS, or prints row data.
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
const addedNames = ['location_name', 'post_location_id'];
const addedSQL = `, location_name TEXT
  CHECK(location_name IS NULL OR (kind = 'reel' AND length(location_name) BETWEEN 1 AND 80)),
  post_location_id TEXT CHECK(post_location_id IS NULL OR (kind = 'reel' AND length(post_location_id) = 36))`;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function sameFile(a, b) { return a.dev === b.dev && a.ino === b.ino; }
function snapshotFile(path) {
  requireCheck(isAbsolute(path ?? ''), 'Use absolute snapshot paths.');
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
  // Include autoindexes; compare definitions byte-for-byte except the one
  // ALTERed table. Never collapse whitespace inside string literals.
  return database.prepare('SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY type, name').all();
}
function columns(database, table) {
  return database.prepare(`PRAGMA table_xinfo(${identifier(table)})`).all();
}
function tokens(sql) {
  requireCheck(typeof sql === 'string', 'Missing memories table definition.');
  return sql.match(/--[^\r\n]*(?:\r?\n|$)|\/\*[\s\S]*?\*\/|'(?:[^']|'')*'|"(?:[^"]|"")*"|`(?:[^`]|``)*`|\[[^\]]*\]|[A-Za-z_][A-Za-z_0-9]*|(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?|!=|==|<=|>=|<>|\|\||->>|->|[^\s]/g) ?? [];
}
function withoutAddedColumns(sql) {
  const actual = tokens(sql), added = tokens(addedSQL), matches = [];
  for (let i = 0; i <= actual.length - added.length; i += 1) {
    if (added.every((token, offset) => actual[i + offset] === token)) matches.push(i);
  }
  requireCheck(matches.length === 1, 'Schema definition changed unexpectedly: memories.');
  actual.splice(matches[0], added.length);
  return actual;
}
function verifyObjects(before, after, mode) {
  for (const schema of [before, after]) {
    const tables = schema.filter(object => object.type === 'table' && !object.name.startsWith('sqlite_'))
      .map(object => object.name).sort();
    requireCheck(JSON.stringify(tables) === JSON.stringify(applicationTables), 'Expected all 27 application tables.');
  }
  if (mode === 'repair') withoutAddedColumns(before.find(object => object.type === 'table' && object.name === 'memories')?.sql);
  requireCheck(before.length === after.length, 'Schema object count changed unexpectedly.');
  for (let i = 0; i < before.length; i += 1) {
    const old = before[i], current = after[i];
    requireCheck(old.type === current.type && old.name === current.name && old.tbl_name === current.tbl_name,
      'Schema object identity changed.');
    const sameSQL = mode === 'migration' && old.name === 'memories' && old.type === 'table'
      ? JSON.stringify(tokens(old.sql)) === JSON.stringify(withoutAddedColumns(current.sql))
      : old.sql === current.sql;
    requireCheck(sameSQL, `Schema definition changed unexpectedly: ${applicationTables.includes(old.name) ? old.name : 'index/view/trigger'}.`);
  }
}
function verifyColumns(before, after, table, mode) {
  const additions = mode === 'migration' && table === 'memories'
    ? addedNames.map((name, index) => ({ cid: before.length + index, name, type: 'TEXT', notnull: 0,
      dflt_value: null, pk: 0, hidden: 0 })) : [];
  requireCheck(JSON.stringify([...before, ...additions]) === JSON.stringify(after), `Column definitions changed: ${table}.`);
  if (table === 'memories') {
    const sourceHasAdditions = before.some(field => addedNames.includes(field.name));
    requireCheck(mode === 'repair' ? addedNames.every(name => before.some(field => field.name === name)) : !sourceHasAdditions,
      'Unexpected location columns in source schema.');
    if (mode === 'repair') requireCheck(JSON.stringify(before.slice(-2)) === JSON.stringify(addedNames.map((name, index) => ({
      cid: before.length - 2 + index, name, type: 'TEXT', notnull: 0, dflt_value: null, pk: 0, hidden: 0,
    }))), 'Schema 16 requires exactly the expected nullable location columns.');
  }
}
function repairOptions(mode, repair) {
  if (mode !== 'repair') {
    requireCheck(repair === undefined, 'Repair allowlist is only accepted in repair mode.');
    return undefined;
  }
  requireCheck(repair && Object.keys(repair).sort().join(',') === 'locationId,ownerId,postIds',
    'Repair requires an explicit owner, Post ID allowlist and location ID.');
  requireCheck(typeof repair.ownerId === 'string' && repair.ownerId.length > 0 && repair.ownerId.length <= 128,
    'Repair requires an explicit owner.');
  requireCheck(typeof repair.locationId === 'string' && uuid.test(repair.locationId), 'Repair requires a UUID location ID.');
  requireCheck(Array.isArray(repair.postIds) && repair.postIds.length > 0 && repair.postIds.length <= 50
    && repair.postIds.every(id => typeof id === 'string' && id.length > 0 && id.length <= 128)
    && new Set(repair.postIds).size === repair.postIds.length, 'Repair requires unique explicit Post IDs.');
  return { ...repair, postIds: new Set(repair.postIds) };
}
function verifyRepairRows(source, target, repair) {
  const sql = 'SELECT owner_id, kind, post_location_id FROM memories WHERE id = ?';
  const before = source.prepare(sql), after = target.prepare(sql);
  for (const postId of repair.postIds) {
    const old = before.get(postId), current = after.get(postId);
    requireCheck(old?.owner_id === repair.ownerId && old.kind === 'reel' && old.post_location_id === null,
      'Repair source allowlist does not match unlinked Posts owned by the explicit owner.');
    requireCheck(current?.owner_id === repair.ownerId && current.kind === 'reel'
      && current.post_location_id === repair.locationId, 'Repair target does not match the exact allowlisted location ID.');
  }
}
function tableDigest(database, table, fields, repairedPosts) {
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
      // Only after verifying each exact NULL -> approved ID transition, compare
      // those values as their original NULLs. No entire row/column is ignored.
      const value = table === 'memories' && field.name === 'post_location_id' && repairedPosts?.has(row.id)
        ? null : row[field.name];
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

export function verifySchema16Copies({ mode, sourcePath, targetPath, repair }) {
  requireCheck(['backup', 'migration', 'repair'].includes(mode), 'Choose backup, migration or repair mode.');
  const allowlist = repairOptions(mode, repair);
  const sourceFile = snapshotFile(sourcePath), targetFile = snapshotFile(targetPath);
  requireCheck(sourceFile.path !== targetFile.path && !sameFile(sourceFile.stat, targetFile.stat),
    'Source and target must be independent database copies.');
  const sourceSchema = mode === 'repair' ? 16 : 14, targetSchema = mode === 'backup' ? 14 : 16;
  let source, target;
  try {
    source = new DatabaseSync(sourceFile.path, { readOnly: true, timeout: 5000 });
    target = new DatabaseSync(targetFile.path, { readOnly: true, timeout: 5000 });
    validate(source, sourceSchema); validate(target, targetSchema);
    requireCheck(source.prepare('PRAGMA application_id').get().application_id
      === target.prepare('PRAGMA application_id').get().application_id, 'Database application ID changed.');
    const sourceObjects = objects(source), targetObjects = objects(target);
    verifyObjects(sourceObjects, targetObjects, mode);
    if (allowlist) verifyRepairRows(source, target, allowlist);
    const tables = [];
    let comparedColumnCount = 0;
    for (const table of applicationTables) {
      const before = columns(source, table), after = columns(target, table);
      verifyColumns(before, after, table, mode);
      const original = tableDigest(source, table, before);
      const restored = tableDigest(target, table, before, allowlist?.postIds);
      requireCheck(original.count === restored.count && original.sha256 === restored.sha256, `Stored rows changed: ${table}.`);
      comparedColumnCount += before.length;
      tables.push({ table, ...original });
    }
    if (mode === 'migration') requireCheck(target.prepare(`SELECT COUNT(*) AS n FROM memories
      WHERE location_name IS NOT NULL OR post_location_id IS NOT NULL`).get().n === 0,
    'Migration unexpectedly populated new location columns.');
    return { ok: true, mode, sourceSchema, targetSchema, tableCount: tables.length,
      schemaObjectCount: sourceObjects.length, comparedColumnCount,
      comparedRowCount: tables.reduce((sum, table) => sum + table.count, 0),
      sourceSchemaSha256: createHash('sha256').update(JSON.stringify(sourceObjects)).digest('hex'),
      targetSchemaSha256: createHash('sha256').update(JSON.stringify(targetObjects)).digest('hex'),
      addedColumns: mode === 'migration' ? addedNames : [],
      repairedPostCount: allowlist?.postIds.size ?? 0, tables };
  } finally { target?.close(); source?.close(); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [mode, sourcePath, targetPath, ...extra] = process.argv.slice(2);
  try {
    requireCheck(mode === 'repair' ? extra.length >= 3 : extra.length === 0, 'Unexpected or missing arguments.');
    const [ownerId, locationId, ...postIds] = extra;
    console.log(JSON.stringify(verifySchema16Copies({ mode, sourcePath, targetPath,
      ...(mode === 'repair' ? { repair: { ownerId, locationId, postIds } } : {}) })));
  } catch (error) {
    // Native diagnostics and arbitrary schema object names can expose data.
    console.error(JSON.stringify({ ok: false,
      error: error instanceof VerificationError ? error.message : 'Unable to verify database copies.' }));
    process.exitCode = 1;
  }
}
