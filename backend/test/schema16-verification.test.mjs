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
import { verifySchema16Copies } from '../scripts/verify-schema16.mjs';

const script = fileURLToPath(new URL('../scripts/verify-schema16.mjs', import.meta.url));
const repair = { ownerId: 'owner', postIds: ['post-1', 'post-2', 'post-3'],
  locationId: 'b01d6f93-a476-4456-a5af-e7527e59b559' };
const otherLocationId = '221fd62a-7786-4ea6-80bf-d7a4cb57214b';
const hash = async path => createHash('sha256').update(await readFile(path)).digest('hex');

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-schema16-verification-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const sourcePath = join(directory, 'frozen-v14.sqlite'), targetPath = join(directory, 'target.sqlite');
  const db = openDatabase(sourcePath);
  try {
    db.exec(`
      DROP TABLE IF EXISTS memory_custom_feelings; DROP TABLE direct_messages; DROP TABLE media_likes; DROP TABLE saved_places; DROP INDEX memories_place_owner_visits;
      DROP TABLE memory_feedback;
      ALTER TABLE memories DROP COLUMN post_location_id;
      ALTER TABLE memories DROP COLUMN location_name;
      PRAGMA user_version = 14;
      INSERT INTO users(id, handle, password_hash, created_at) VALUES
        ('owner', 'alice', 'private-password-hash', 1), ('other', 'bob', 'other-hash', 2);
      INSERT INTO places VALUES ('place', 'Private Airport Café', 'airport', 47.45, -122.31, 'airport');
      INSERT INTO media VALUES ('photo', 'owner', 'image/jpeg', 3, X'010203', 2);
      INSERT INTO media VALUES ('video', 'owner', 'video/mp4', 4, X'05060708', 2);
      INSERT INTO memories(id, owner_id, kind, visibility, latitude, longitude, caption, place_id,
        created_at, expires_at, request_hash, published_at) VALUES
        ('visit', 'owner', 'poi', 'public', 47.4501, -122.31, '', 'place', 3, 259200004, 'visit-hash', 4),
        ('post-1', 'owner', 'reel', 'public', 47.1, -122.1, 'Private  two-space caption', NULL, 11, 259200004, 'original-hash-1', 12),
        ('post-2', 'owner', 'reel', 'public', 47.2, -122.2, 'Second caption', NULL, 13, 259200004, 'original-hash-2', 14),
        ('post-3', 'owner', 'reel', 'public', 47.3, -122.3, 'Third caption', NULL, 15, 259200004, 'original-hash-3', 16),
        ('unlisted', 'owner', 'reel', 'private', 47.4, -122.4, 'Private unlisted caption', NULL, 17, 259200004, 'unlisted-hash', NULL),
        ('other-post', 'other', 'reel', 'public', 47.5, -122.5, 'Another owner', NULL, 19, 259200004, 'other-post-hash', 20);
      INSERT INTO memory_media VALUES ('post-1', 'photo', 0), ('post-1', 'video', 1);
      INSERT INTO memory_clusters VALUES ('post-2', 'Private cluster title', '[{"caption":"Private cluster member"}]');
      INSERT INTO cluster_media VALUES ('post-2', 'photo'), ('post-2', 'video');
      INSERT INTO comments VALUES ('comment', 'owner', NULL, 'place', 'Private comment', 5);
      INSERT INTO user_profiles VALUES ('owner', 'photo');
      INSERT INTO place_sources VALUES ('apple-place', 'place');
      INSERT INTO archive_hidden VALUES ('owner', 'reel', 'post-1', 8);
      INSERT INTO deleted_memories VALUES ('deleted-post', 'owner', 8);
      INSERT INTO media_upload_requests VALUES ('owner', 'original-upload', 'private-upload-hash', 'video', 3);
      INSERT INTO media_upload_sessions VALUES ('owner', 'partial-upload', 'video/mp4', 4,
        '0000000000000000000000000000000000000000000000000000000000000000', 2, 3, 4);
      INSERT INTO media_upload_chunks VALUES ('owner', 'partial-upload', 0, X'090A');
      INSERT INTO sessions VALUES ('private-session-hash', 'owner', 9223372036854775806);
      INSERT INTO server_metadata VALUES ('deployment_mode', 'beta');
      INSERT INTO auth_identities VALUES ('apple', 'private-subject', 'owner', 6);
      INSERT INTO apple_auth_challenges VALUES ('private-challenge', 'private-nonce-hash', 12);
      INSERT INTO apple_refresh_tokens VALUES ('owner', 'private-encrypted-token', 8, NULL);
      INSERT INTO apple_used_codes VALUES ('private-apple-code', 13);
      INSERT INTO oauth_auth_challenges VALUES ('private-oauth-challenge', 'google', 'private-state-hash', 12);
      INSERT INTO oauth_used_codes VALUES ('google', 'private-google-code', 13);
      INSERT INTO beta_members VALUES ('owner', 'active', 7);
      INSERT INTO beta_invites VALUES ('invite', 'private-invite-hash', 5, 13, NULL, 7, 'owner');
      INSERT INTO user_blocks VALUES ('owner', 'other', 6);
      INSERT INTO content_reports VALUES ('report', 'owner', 'other-post', 'private-reason', 7);
    `);
  } finally { db.close(); }
  await backupDatabase(sourcePath, targetPath);
  return { directory, sourcePath, targetPath };
}
function edit(path, sql) {
  const db = new DatabaseSync(path);
  try { db.exec(sql); } finally { db.close(); }
}
function migrate(path) {
  const db = openDatabase(path);
  // Keep this verifier scoped to the historical schema 14 -> 16 release.
  db.exec('DROP TABLE IF EXISTS memory_custom_feelings; DROP TABLE direct_messages; DROP TABLE media_likes; DROP TABLE saved_places; DROP INDEX memories_place_owner_visits; DROP TABLE memory_feedback; PRAGMA user_version = 16;');
  db.close();
}
function alteredMigration(path, transform) {
  edit(path, transform(`ALTER TABLE memories ADD COLUMN location_name TEXT
    CHECK(location_name IS NULL OR (kind = 'reel' AND length(location_name) BETWEEN 1 AND 80));
    ALTER TABLE memories ADD COLUMN post_location_id TEXT
    CHECK(post_location_id IS NULL OR (kind = 'reel' AND length(post_location_id) = 36));
    PRAGMA user_version = 16;`));
}
function applyRepair(path) {
  const db = new DatabaseSync(path);
  try {
    const update = db.prepare('UPDATE memories SET post_location_id = ? WHERE id = ?');
    for (const id of repair.postIds) update.run(repair.locationId, id);
  } finally { db.close(); }
}
async function repairedFixture(t) {
  const paths = await fixture(t);
  migrate(paths.sourcePath); migrate(paths.targetPath); applyRepair(paths.targetPath);
  return paths;
}
function rebuildMemories(path, transform) {
  const db = new DatabaseSync(path);
  try {
    const schema = db.prepare("SELECT type, sql FROM sqlite_schema WHERE tbl_name = 'memories' AND sql IS NOT NULL").all();
    const original = schema.find(object => object.type === 'table').sql;
    db.exec(`PRAGMA foreign_keys = OFF; BEGIN IMMEDIATE;
      ${transform(original).replace(/^CREATE TABLE memories/, 'CREATE TABLE memories_changed')};
      INSERT INTO memories_changed SELECT * FROM memories;
      DROP TABLE memories; ALTER TABLE memories_changed RENAME TO memories;
      ${schema.filter(object => object.type === 'index').map(object => object.sql + ';').join('\n')}
      COMMIT;`);
  } finally { db.close(); }
}

test('schema16 backup and migration verify all 27 populated tables without changing files or printing data', async t => {
  const paths = await fixture(t);
  const originalHash = await hash(paths.sourcePath), restoredHash = await hash(paths.targetPath);
  const backup = verifySchema16Copies({ mode: 'backup', ...paths });
  assert.equal(backup.tableCount, 27);
  assert(backup.tables.every(table => table.count > 0));
  assert.equal(backup.sourceSchema, 14); assert.equal(backup.targetSchema, 14);
  assert.equal(backup.comparedRowCount, backup.tables.reduce((sum, table) => sum + table.count, 0));
  assert(backup.comparedColumnCount > 100);
  assert.equal(await hash(paths.sourcePath), originalHash);
  assert.equal(await hash(paths.targetPath), restoredHash);
  migrate(paths.targetPath);
  const migratedHash = await hash(paths.targetPath);
  const result = verifySchema16Copies({ mode: 'migration', ...paths });
  assert.equal(result.sourceSchema, 14); assert.equal(result.targetSchema, 16);
  assert.deepEqual(result.tables, backup.tables);
  assert.deepEqual(result.addedColumns, ['location_name', 'post_location_id']);
  assert.equal(result.repairedPostCount, 0);
  assert.equal(result.schemaObjectCount, backup.schemaObjectCount);
  assert.equal(await hash(paths.sourcePath), originalHash);
  assert.equal(await hash(paths.targetPath), migratedHash);
  const cli = spawnSync(process.execPath, [script, 'migration', paths.sourcePath, paths.targetPath], { encoding: 'utf8' });
  assert.equal(cli.status, 0, cli.stderr);
  assert.deepEqual(JSON.parse(cli.stdout), result);
  for (const secret of ['private-password-hash', 'Private Airport Café', 'Private cluster member',
    'private-session-hash', 'private-encrypted-token', 'original-hash-1', paths.directory]) {
    assert.equal(JSON.stringify(result).includes(secret), false);
    assert.equal(cli.stdout.includes(secret), false);
  }
});

test('schema16 migration rejects any historical row, media BLOB, large integer or relationship change', async t => {
  const cases = [
    ["UPDATE media SET bytes = X'05060709' WHERE id = 'video'", 'media'],
    ["UPDATE media_upload_chunks SET bytes = X'090B'", 'media_upload_chunks'],
    ['UPDATE media_upload_sessions SET received_bytes = 3', 'media_upload_sessions'],
    ["UPDATE media_upload_requests SET request_hash = 'different'", 'media_upload_requests'],
    ["UPDATE memories SET caption = 'Changed' WHERE id = 'post-1'", 'memories'],
    ["UPDATE memories SET request_hash = 'different'", 'memories'],
    ['UPDATE memories SET published_at = published_at + 1', 'memories'],
    ['UPDATE memories SET created_at = created_at + 1', 'memories'],
    ['UPDATE memories SET expires_at = expires_at + 1', 'memories'],
    ['UPDATE memories SET latitude = 47.45', 'memories'],
    ['UPDATE memories SET longitude = -122.45', 'memories'],
    ["UPDATE memories SET visibility = 'private'", 'memories'],
    ['UPDATE sessions SET expires_at = expires_at - 1', 'sessions'],
    ["UPDATE places SET directory_kind = NULL", 'places'],
    ["UPDATE memory_clusters SET members_json = '[{}]'", 'memory_clusters'],
    ["DELETE FROM cluster_media WHERE media_id = 'video'", 'cluster_media'],
    ['DELETE FROM memory_media WHERE position = 1', 'memory_media'],
    ["UPDATE comments SET text = 'Changed'", 'comments'],
    ["UPDATE apple_refresh_tokens SET encrypted_token = 'Changed'", 'apple_refresh_tokens'],
    ["INSERT INTO server_metadata VALUES ('unexpected', 'value')", 'server_metadata'],
  ];
  for (const [sql, table] of cases) await t.test(sql, async subtest => {
    const paths = await fixture(subtest); migrate(paths.targetPath); edit(paths.targetPath, sql);
    assert.throws(() => verifySchema16Copies({ mode: 'migration', ...paths }), new RegExp(`Stored rows changed: ${table}\\.`));
  });
});

test('schema16 permits exactly the two nullable columns, precise CHECKs, and no migration backfill', async t => {
  const cases = [
    ['CREATE TABLE unexpected(id TEXT PRIMARY KEY)', /all 27/],
    ['CREATE INDEX unexpected_caption ON memories(caption)', /Schema object count/],
    ['CREATE INDEX sqliteXunexpected ON memories(caption)', /Schema object count/],
    ['DROP TABLE cluster_media', /all 27/],
    ['ALTER TABLE memories ADD COLUMN unexpected TEXT', /Schema definition/],
    ['ALTER TABLE users ADD COLUMN unexpected TEXT', /Schema definition/],
    ['DROP INDEX cluster_media_asset; CREATE INDEX cluster_media_asset ON cluster_media(memory_id)', /Schema definition/],
    ["CREATE TRIGGER hidden_change AFTER INSERT ON server_metadata BEGIN SELECT 'private'; END", /Schema object count/],
    ["UPDATE memories SET location_name = 'Inferred name' WHERE id = 'post-1'", /unexpectedly populated/],
    [`UPDATE memories SET post_location_id = '${repair.locationId}' WHERE id = 'post-1'`, /unexpectedly populated/],
    ['PRAGMA application_id = 42', /application ID changed/],
  ];
  for (const [sql, expected] of cases) await t.test(sql, async subtest => {
    const paths = await fixture(subtest); migrate(paths.targetPath); edit(paths.targetPath, sql);
    assert.throws(() => verifySchema16Copies({ mode: 'migration', ...paths }), expected);
  });
  const transforms = [
    sql => sql.replace('BETWEEN 1 AND 80', 'BETWEEN 1 AND 81'),
    sql => sql.replace('length(post_location_id) = 36', 'length(post_location_id) >= 36'),
    sql => sql.replace('location_name TEXT', 'location_name TEXT DEFAULT NULL'),
    sql => sql.replace("'reel' AND length(location_name)", "'poi' AND length(location_name)"),
    sql => sql.replace('location_name TEXT', 'location_name TEXT REFERENCES places(id)'),
  ];
  for (const [index, transform] of transforms.entries()) await t.test(`constraint mutation ${index}`, async subtest => {
    const paths = await fixture(subtest); alteredMigration(paths.targetPath, transform);
    assert.throws(() => verifySchema16Copies({ mode: 'migration', ...paths }), /Schema definition/);
  });
  const paths = await fixture(t); migrate(paths.targetPath);
  rebuildMemories(paths.targetPath, sql => sql.replace('latitude BETWEEN -90 AND 90', 'latitude BETWEEN -180 AND 180'));
  assert.throws(() => verifySchema16Copies({ mode: 'migration', ...paths }), /Schema definition/);
});

test('schema16 repair verifies exact owner and Post allowlist while preserving every other value', async t => {
  const paths = await repairedFixture(t);
  const sourceHash = await hash(paths.sourcePath), targetHash = await hash(paths.targetPath);
  const result = verifySchema16Copies({ mode: 'repair', ...paths, repair });
  assert.equal(result.sourceSchema, 16); assert.equal(result.targetSchema, 16);
  assert.equal(result.repairedPostCount, 3); assert.equal(result.tableCount, 27);
  assert.deepEqual(result.addedColumns, []);
  assert.equal(result.sourceSchemaSha256, result.targetSchemaSha256);
  assert.equal(await hash(paths.sourcePath), sourceHash); assert.equal(await hash(paths.targetPath), targetHash);
  const cli = spawnSync(process.execPath, [script, 'repair', paths.sourcePath, paths.targetPath,
    repair.ownerId, repair.locationId, ...repair.postIds], { encoding: 'utf8' });
  assert.equal(cli.status, 0, cli.stderr); assert.deepEqual(JSON.parse(cli.stdout), result);
  assert.equal(cli.stdout.includes(repair.locationId), false);
  assert.equal(cli.stdout.includes('post-1'), false);
});

test('schema16 repair rejects extra modifications, missing repairs, wrong IDs and preexisting assignments', async t => {
  const cases = [
    [`UPDATE memories SET post_location_id = '${repair.locationId}' WHERE id = 'unlisted'`, /Stored rows changed: memories/],
    [`UPDATE memories SET post_location_id = '${repair.locationId}' WHERE id = 'other-post'`, /Stored rows changed: memories/],
    [`UPDATE memories SET post_location_id = '${otherLocationId}' WHERE id = 'post-1'`, /exact allowlisted location ID/],
    ["UPDATE memories SET post_location_id = NULL WHERE id = 'post-1'", /exact allowlisted location ID/],
    ["UPDATE memories SET owner_id = 'other' WHERE id = 'post-1'", /exact allowlisted location ID/],
    ["DELETE FROM memories WHERE id = 'post-3'", /exact allowlisted location ID/],
    ["UPDATE memories SET caption = 'Changed' WHERE id = 'post-1'", /Stored rows changed: memories/],
    ["UPDATE memories SET location_name = 'Newcastle' WHERE id = 'post-1'", /Stored rows changed: memories/],
    ["UPDATE memories SET latitude = 47.99 WHERE id = 'post-1'", /Stored rows changed: memories/],
    ["UPDATE memories SET published_at = published_at + 1 WHERE id = 'post-1'", /Stored rows changed: memories/],
    ["UPDATE memories SET request_hash = 'Changed' WHERE id = 'post-1'", /Stored rows changed: memories/],
    ["UPDATE media SET bytes = X'010204' WHERE id = 'photo'", /Stored rows changed: media/],
    ["UPDATE memory_clusters SET title = 'Changed'", /Stored rows changed: memory_clusters/],
  ];
  for (const [sql, expected] of cases) await t.test(sql, async subtest => {
    const paths = await repairedFixture(subtest); edit(paths.targetPath, sql);
    assert.throws(() => verifySchema16Copies({ mode: 'repair', ...paths, repair }), expected);
  });
  for (const postIds of [['visit'], ['other-post'], ['missing']]) await t.test(`invalid source ${postIds[0]}`, async subtest => {
    const paths = await repairedFixture(subtest);
    assert.throws(() => verifySchema16Copies({ mode: 'repair', ...paths, repair: { ...repair, postIds } }), /Repair source allowlist/);
  });
  const paths = await repairedFixture(t);
  for (const id of [repair.locationId, otherLocationId]) {
    edit(paths.sourcePath, `UPDATE memories SET post_location_id = '${id}' WHERE id = 'post-1'`);
    assert.throws(() => verifySchema16Copies({ mode: 'repair', ...paths, repair }), /Repair source allowlist/);
  }
});

test('schema16 rejects implicit or malformed repair allowances, non-independent files and wrong schemas', async t => {
  const paths = await fixture(t);
  assert.throws(() => verifySchema16Copies({ mode: 'unknown', ...paths }), /Choose backup, migration or repair/);
  assert.throws(() => verifySchema16Copies({ mode: 'migration', ...paths, repair }), /only accepted in repair/);
  for (const invalid of [undefined, {}, { ...repair, ownerId: '' }, { ...repair, locationId: 'invalid' },
    { ...repair, postIds: [] }, { ...repair, postIds: ['post-1', 'post-1'] }, { ...repair, postIds: [''] },
    { ...repair, caption: 'also change this' }]) {
    assert.throws(() => verifySchema16Copies({ mode: 'repair', ...paths, repair: invalid }), /Repair requires/);
  }
  assert.throws(() => verifySchema16Copies({ mode: 'backup', ...paths, targetPath: paths.sourcePath }), /independent/);
  const hardlink = join(paths.directory, 'hardlink.sqlite'), softlink = join(paths.directory, 'symlink.sqlite');
  await link(paths.sourcePath, hardlink); await symlink(paths.sourcePath, softlink);
  assert.throws(() => verifySchema16Copies({ mode: 'backup', ...paths, targetPath: hardlink }), /independent/);
  assert.throws(() => verifySchema16Copies({ mode: 'backup', ...paths, targetPath: softlink }), /symbolic links/);
  assert.throws(() => verifySchema16Copies({ mode: 'backup', ...paths, sourcePath: softlink }), /symbolic links/);
  assert.throws(() => verifySchema16Copies({ mode: 'backup', ...paths, targetPath: paths.directory }), /regular database files/);
  assert.throws(() => verifySchema16Copies({ mode: 'backup', ...paths, sourcePath: 'relative.sqlite' }), /absolute/);
  for (const path of ['/srv/maptalk/data/maptalk.sqlite', '/var/lib/maptalk/maptalk.sqlite']) {
    assert.throws(() => verifySchema16Copies({ mode: 'backup', ...paths, sourcePath: path }), /production database/);
    assert.throws(() => verifySchema16Copies({ mode: 'backup', ...paths, targetPath: path }), /production database/);
  }
  assert.throws(() => verifySchema16Copies({ mode: 'migration', ...paths }), /Expected schema 16/);
  migrate(paths.targetPath);
  assert.throws(() => verifySchema16Copies({ mode: 'backup', ...paths }), /Expected schema 14/);
  assert.throws(() => verifySchema16Copies({ mode: 'repair', ...paths, repair }), /Expected schema 16/);
  migrate(paths.sourcePath);
  assert.throws(() => verifySchema16Copies({ mode: 'migration', ...paths }), /Expected schema 14/);
});

test('schema16 rejects schema literal changes, foreign key damage and suppresses unsafe native errors', async t => {
  const paths = await fixture(t);
  edit(paths.sourcePath, "CREATE TRIGGER literal_check AFTER INSERT ON server_metadata BEGIN SELECT 'private  value'; END");
  edit(paths.targetPath, "CREATE TRIGGER literal_check AFTER INSERT ON server_metadata BEGIN SELECT 'private value'; END");
  migrate(paths.targetPath);
  assert.throws(() => verifySchema16Copies({ mode: 'migration', ...paths }), /Schema definition/);
  edit(paths.targetPath, "PRAGMA foreign_keys = OFF; UPDATE cluster_media SET media_id = 'missing' WHERE media_id = 'video'");
  assert.throws(() => verifySchema16Copies({ mode: 'migration', ...paths }), /foreign key check/);
  const corrupt = join(paths.directory, 'private-damaged.sqlite');
  await writeFile(corrupt, 'Private database contents must never be printed');
  const cli = spawnSync(process.execPath, [script, 'migration', paths.sourcePath, corrupt], { encoding: 'utf8' });
  assert.equal(cli.status, 1); assert.equal(cli.stdout, '');
  assert.match(cli.stderr, /Unable to verify database copies/);
  assert.doesNotMatch(cli.stderr, /Private database|private-damaged|SQLITE_ERROR|maptalk-schema16-verification/);
});

test('schema16 detects integrity failures and rejects weakened location constraints even on both repair copies', async t => {
  const paths = await fixture(t); migrate(paths.targetPath);
  const db = new DatabaseSync(paths.targetPath, { readOnly: true });
  let rootPage;
  try { rootPage = db.prepare("SELECT rootpage FROM sqlite_schema WHERE name = 'sessions_expiration'").get().rootpage; }
  finally { db.close(); }
  // Corrupt this closed synthetic index, never a production file. The row is
  // still present in the table but absent from its index leaf.
  const bytes = await readFile(paths.targetPath);
  const encodedPageSize = bytes.readUInt16BE(16), pageSize = encodedPageSize === 1 ? 65536 : encodedPageSize;
  const offset = (rootPage - 1) * pageSize;
  assert.equal(bytes[offset], 0x0a); assert.equal(bytes.readUInt16BE(offset + 3), 1);
  bytes.writeUInt16BE(0, offset + 3); await writeFile(paths.targetPath, bytes);
  assert.throws(() => verifySchema16Copies({ mode: 'migration', ...paths }), /integrity check/);
  const weak = await fixture(t);
  for (const path of [weak.sourcePath, weak.targetPath]) alteredMigration(path,
    sql => sql.replace('length(post_location_id) = 36', 'length(post_location_id) >= 36'));
  applyRepair(weak.targetPath);
  assert.throws(() => verifySchema16Copies({ mode: 'repair', ...weak, repair }), /Schema definition/);
});
