import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { link, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { openDatabase } from '../src/database.mjs';
import { backupDatabase } from '../src/backup.mjs';
import { verifySameSchemaCopies } from '../scripts/verify-same-schema.mjs';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-same-schema-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const sourcePath = join(directory, 'snapshot.sqlite'), targetPath = join(directory, 'restored.sqlite');
  const db = openDatabase(sourcePath);
  db.exec(`
    INSERT INTO users(id, handle, password_hash, created_at) VALUES ('owner', 'alice', 'kept-secret-hash', 1);
    INSERT INTO places VALUES ('place', 'Private Airport Café', 'airport', 47.45, -122.31, 'airport');
    INSERT INTO media VALUES ('photo', 'owner', 'image/jpeg', 3, X'010203', 2);
    INSERT INTO media VALUES ('video', 'owner', 'video/mp4', 4, X'05060708', 2);
    INSERT INTO memories(id, owner_id, kind, visibility, latitude, longitude, caption, place_id,
      created_at, expires_at, request_hash, published_at)
      VALUES ('visit', 'owner', 'poi', 'public', 47.4501, -122.31, '', 'place', 3, 259200004, 'original-hash', 4);
    INSERT INTO memory_media VALUES ('visit', 'photo', 0);
    INSERT INTO memory_media VALUES ('visit', 'video', 1);
    INSERT INTO memory_clusters VALUES ('visit', 'Private cluster title', '[{"caption":"Private member caption"}]');
    INSERT INTO cluster_media VALUES ('visit', 'photo');
    INSERT INTO cluster_media VALUES ('visit', 'video');
    INSERT INTO comments VALUES ('comment', 'owner', NULL, 'place', 'Keep this place discussion', 5);
    INSERT INTO media_upload_requests VALUES ('owner', 'upload', 'upload-fingerprint', 'video', 3);
    INSERT INTO media_upload_sessions VALUES ('owner', 'partial-upload', 'video/mp4', 4,
      '0000000000000000000000000000000000000000000000000000000000000000', 2, 3, 4);
    INSERT INTO media_upload_chunks VALUES ('owner', 'partial-upload', 0, X'090A');
    INSERT INTO sessions VALUES ('session-hash', 'owner', 9223372036854775806);
    INSERT INTO server_metadata VALUES ('deployment_mode', 'beta');
  `);
  db.close();
  await backupDatabase(sourcePath, targetPath);
  return { directory, sourcePath, targetPath };
}
function edit(path, sql) {
  const db = new DatabaseSync(path);
  try { db.exec(sql); } finally { db.close(); }
}
const script = fileURLToPath(new URL('../scripts/verify-same-schema.mjs', import.meta.url));

test('same-schema verifier preserves populated schema14 copies and only reports safe summaries', async t => {
  const paths = await fixture(t);
  const hash = async path => createHash('sha256').update(await readFile(path)).digest('hex');
  const sourceHash = await hash(paths.sourcePath), targetHash = await hash(paths.targetPath);
  const result = verifySameSchemaCopies(paths);
  assert.equal(result.ok, true);
  assert.equal(result.sourceSchema, 14);
  assert.equal(result.targetSchema, 14);
  assert.equal(result.tableCount, 27);
  assert.equal(result.tables.find(table => table.table === 'memory_clusters').count, 1);
  assert.equal(result.tables.find(table => table.table === 'cluster_media').count, 2);
  assert.equal(result.tables.find(table => table.table === 'media').count, 2);
  assert.match(result.schemaSha256, /^[a-f0-9]{64}$/);
  assert.equal(await hash(paths.sourcePath), sourceHash);
  assert.equal(await hash(paths.targetPath), targetHash);
  const cli = spawnSync(process.execPath, [script, paths.sourcePath, paths.targetPath], { encoding: 'utf8' });
  assert.equal(cli.status, 0, cli.stderr);
  assert.deepEqual(JSON.parse(cli.stdout), result);
  for (const privateValue of ['kept-secret-hash', 'Private Airport Café', 'original-hash', 'Private cluster title',
    'Private member caption', 'session-hash', 'upload-fingerprint', '9223372036854775806', paths.directory]) {
    assert.equal(JSON.stringify(result).includes(privateValue), false);
    assert.equal(cli.stdout.includes(privateValue), false);
  }
});

test('same-schema verifier detects old and populated-cluster row, timestamp, integer and BLOB changes', async t => {
  const cases = [
    ["UPDATE media SET bytes = X'05060709' WHERE id = 'video'", 'media'],
    ["UPDATE media_upload_chunks SET bytes = X'090B'", 'media_upload_chunks'],
    ["UPDATE memories SET request_hash = 'changed'", 'memories'],
    ['UPDATE memories SET published_at = published_at + 1', 'memories'],
    ['UPDATE memories SET created_at = created_at + 1', 'memories'],
    ['UPDATE memories SET latitude = 47.4502', 'memories'],
    ['UPDATE sessions SET expires_at = expires_at - 1', 'sessions'],
    ["UPDATE memory_clusters SET title = 'changed'", 'memory_clusters'],
    ["UPDATE memory_clusters SET members_json = '[{}]'", 'memory_clusters'],
    ["DELETE FROM cluster_media WHERE media_id = 'video'", 'cluster_media'],
    ["DELETE FROM comments", 'comments'],
  ];
  for (const [sql, table] of cases) await t.test(sql.split(' ').slice(0, 3).join(' '), async subtest => {
    const paths = await fixture(subtest);
    edit(paths.targetPath, sql);
    assert.throws(() => verifySameSchemaCopies(paths), new RegExp(`Stored rows changed: ${table}\\.`));
  });
});

test('same-schema verifier rejects changed objects, indexes, columns and SQL literal whitespace', async t => {
  const cases = [
    ['CREATE TABLE unexpected(id TEXT PRIMARY KEY)', /all 27/],
    ['DROP TABLE cluster_media', /all 27/],
    ['CREATE INDEX unexpected_caption ON memories(caption)', /Schema objects/],
    ['CREATE INDEX sqliteXunexpected ON memories(caption)', /Schema objects/],
    ['DROP INDEX cluster_media_asset; CREATE INDEX cluster_media_asset ON cluster_media(memory_id)', /Schema objects/],
    ['ALTER TABLE places ADD COLUMN unexpected TEXT', /Schema objects/],
    ["CREATE TRIGGER changed AFTER INSERT ON server_metadata BEGIN SELECT 'private  value'; END", /Schema objects/],
  ];
  for (const [sql, expected] of cases) await t.test(sql.split(';')[0], async subtest => {
    const paths = await fixture(subtest);
    edit(paths.targetPath, sql);
    assert.throws(() => verifySameSchemaCopies(paths), expected);
  });
  const paths = await fixture(t);
  edit(paths.sourcePath, "CREATE TRIGGER literal_check AFTER INSERT ON server_metadata BEGIN SELECT 'private  value'; END");
  edit(paths.targetPath, "CREATE TRIGGER literal_check AFTER INSERT ON server_metadata BEGIN SELECT 'private value'; END");
  assert.throws(() => verifySameSchemaCopies(paths), /Schema objects/);
});

test('same-schema verifier rejects non-independent files, symlinks, live paths and invalid versions', async t => {
  const paths = await fixture(t);
  assert.throws(() => verifySameSchemaCopies({ ...paths, targetPath: paths.sourcePath }), /independent/);
  const hardlink = join(paths.directory, 'hardlink.sqlite'), softlink = join(paths.directory, 'symlink.sqlite');
  await link(paths.sourcePath, hardlink);
  await symlink(paths.sourcePath, softlink);
  assert.throws(() => verifySameSchemaCopies({ ...paths, targetPath: hardlink }), /independent/);
  assert.throws(() => verifySameSchemaCopies({ ...paths, targetPath: softlink }), /symbolic links/);
  assert.throws(() => verifySameSchemaCopies({ ...paths, sourcePath: softlink }), /symbolic links/);
  assert.throws(() => verifySameSchemaCopies({ ...paths, targetPath: paths.directory }), /regular database files/);
  assert.throws(() => verifySameSchemaCopies({ ...paths, sourcePath: 'relative.sqlite' }), /absolute/);
  for (const path of ['/srv/maptalk/data/maptalk.sqlite', '/var/lib/maptalk/maptalk.sqlite']) {
    assert.throws(() => verifySameSchemaCopies({ ...paths, sourcePath: path }), /production database/);
    assert.throws(() => verifySameSchemaCopies({ ...paths, targetPath: path }), /production database/);
  }
  for (const key of ['sourcePath', 'targetPath']) {
    edit(paths[key], 'PRAGMA user_version = 12');
    assert.throws(() => verifySameSchemaCopies(paths), /Expected schema 14/);
    edit(paths[key], 'PRAGMA user_version = 14');
  }
});

test('same-schema verifier requires all27 tables even if both copies share the same unexpected table', async t => {
  const paths = await fixture(t);
  for (const path of [paths.sourcePath, paths.targetPath]) edit(path, 'CREATE TABLE unexpected(id TEXT PRIMARY KEY)');
  assert.throws(() => verifySameSchemaCopies(paths), /all 27/);
});

test('same-schema verifier checks FK and integrity and CLI suppresses native details and paths', async t => {
  const paths = await fixture(t);
  edit(paths.targetPath, "PRAGMA foreign_keys = OFF; UPDATE cluster_media SET media_id = 'missing' WHERE media_id = 'video'");
  assert.throws(() => verifySameSchemaCopies(paths), /foreign key check/);
  const corrupt = join(paths.directory, 'damaged.sqlite');
  await writeFile(corrupt, 'Private database content must never appear');
  const cli = spawnSync(process.execPath, [script, paths.sourcePath, corrupt], { encoding: 'utf8' });
  assert.equal(cli.status, 1);
  assert.equal(cli.stdout, '');
  assert.match(cli.stderr, /Unable to verify database copies/);
  assert.doesNotMatch(cli.stderr, /Private database|damaged.sqlite|SQLITE_ERROR|maptalk-same-schema-/);
  edit(paths.targetPath, "PRAGMA foreign_keys = OFF; UPDATE cluster_media SET media_id = 'video' WHERE media_id = 'missing'");
  // Corrupt only this closed fixture's one-entry index leaf. Do not use
  // writable_schema: newer SQLite defensive mode correctly prohibits it.
  // Clearing the leaf's cell count leaves the indexed row missing from the
  // index, which integrity_check detects even on a read-only connection.
  const db = new DatabaseSync(paths.targetPath, { readOnly: true });
  let rootPage;
  try { rootPage = db.prepare("SELECT rootpage FROM sqlite_schema WHERE name = 'sessions_expiration'").get().rootpage; }
  finally { db.close(); }
  const bytes = await readFile(paths.targetPath);
  const encodedPageSize = bytes.readUInt16BE(16), pageSize = encodedPageSize === 1 ? 65536 : encodedPageSize;
  const pageOffset = (rootPage - 1) * pageSize;
  assert.equal(bytes[pageOffset], 0x0a, 'fixture index must be a leaf page');
  assert.equal(bytes.readUInt16BE(pageOffset + 3), 1, 'fixture index must contain one row');
  bytes.writeUInt16BE(0, pageOffset + 3);
  await writeFile(paths.targetPath, bytes);
  assert.throws(() => verifySameSchemaCopies(paths), /integrity check/);
});
