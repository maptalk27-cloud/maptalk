import { createHash } from 'node:crypto';
import { lstatSync, realpathSync, statSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';

// Schema-14 release verification only: compare two independent, frozen copies.
// Never migrate, repair, back up, open the live database, or print stored data.
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
function validate(database) {
  database.exec('PRAGMA query_only = ON; PRAGMA temp_store = MEMORY; BEGIN;');
  requireCheck(database.prepare('PRAGMA user_version').get().user_version === 14, 'Expected schema 14 on both copies.');
  const integrity = database.prepare('PRAGMA integrity_check').all();
  requireCheck(integrity.length === 1 && integrity[0].integrity_check === 'ok', 'SQLite integrity check failed.');
  requireCheck(database.prepare('PRAGMA foreign_key_check').all().length === 0, 'SQLite foreign key check failed.');
}
function objects(database) {
  // Include SQLite autoindexes. Do not normalize SQL: whitespace inside a
  // string literal can change a CHECK/default/trigger even in the same schema.
  return database.prepare('SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY type, name').all();
}
function columns(database, table) {
  return database.prepare(`PRAGMA table_xinfo(${identifier(table)})`).all();
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
        const bytes = Buffer.allocUnsafe(8);
        bytes.writeDoubleBE(value);
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

export function verifySameSchemaCopies({ sourcePath, targetPath }) {
  const sourceFile = snapshotFile(sourcePath), targetFile = snapshotFile(targetPath);
  requireCheck(sourceFile.path !== targetFile.path && !sameFile(sourceFile.stat, targetFile.stat),
    'Source and target must be independent database copies.');
  let source, target;
  try {
    source = new DatabaseSync(sourceFile.path, { readOnly: true, timeout: 5000 });
    target = new DatabaseSync(targetFile.path, { readOnly: true, timeout: 5000 });
    validate(source); validate(target);
    const sourceObjects = objects(source), targetObjects = objects(target);
    for (const schema of [sourceObjects, targetObjects]) {
      const tables = schema.filter(object => object.type === 'table' && !object.name.startsWith('sqlite_'))
        .map(object => object.name).sort();
      requireCheck(JSON.stringify(tables) === JSON.stringify(applicationTables), 'Expected all 27 schema-14 application tables.');
    }
    requireCheck(JSON.stringify(sourceObjects) === JSON.stringify(targetObjects), 'Schema objects or definitions changed.');
    const tables = [];
    for (const table of applicationTables) {
      const sourceColumns = columns(source, table), targetColumns = columns(target, table);
      requireCheck(JSON.stringify(sourceColumns) === JSON.stringify(targetColumns), `Column definitions changed: ${table}.`);
      const original = tableDigest(source, table, sourceColumns);
      const restored = tableDigest(target, table, targetColumns);
      requireCheck(original.count === restored.count && original.sha256 === restored.sha256, `Stored rows changed: ${table}.`);
      tables.push({ table, ...original });
    }
    return { ok: true, sourceSchema: 14, targetSchema: 14, tableCount: tables.length,
      schemaObjectCount: sourceObjects.length,
      schemaSha256: createHash('sha256').update(JSON.stringify(sourceObjects)).digest('hex'), tables };
  } finally { target?.close(); source?.close(); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [sourcePath, targetPath, ...extra] = process.argv.slice(2);
  try {
    requireCheck(extra.length === 0, 'Unexpected arguments.');
    console.log(JSON.stringify(verifySameSchemaCopies({ sourcePath, targetPath })));
  } catch (error) {
    // Native errors and arbitrary schema definitions can contain private data.
    console.error(JSON.stringify({ ok: false,
      error: error instanceof VerificationError ? error.message : 'Unable to verify database copies.' }));
    process.exitCode = 1;
  }
}
