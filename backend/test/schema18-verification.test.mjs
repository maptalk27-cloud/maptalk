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
import { verifySchema18Copies } from '../scripts/verify-schema18.mjs';

const script = fileURLToPath(new URL('../scripts/verify-schema18.mjs', import.meta.url));
const hash = async path => createHash('sha256').update(await readFile(path)).digest('hex');
const additions = ['direct_messages', 'media_likes', 'saved_places'];
function edit(path, sql) {
  const db = new DatabaseSync(path);
  try { db.exec(sql); } finally { db.close(); }
}
function migrate(path) {
  const db = openDatabase(path);
  // This verifier remains scoped to the historical schema 17 -> 18 release.
  db.exec('DROP TABLE memory_custom_feelings; PRAGMA user_version = 18;');
  db.close();
}
async function fixture(t, mode = 'backup', withSocial = false) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-schema18-verification-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const sourcePath = join(directory, 'frozen-v17.sqlite'), targetPath = join(directory, 'target.sqlite');
  const db = openDatabase(sourcePath);
  try {
    db.exec(`
      DROP TABLE IF EXISTS memory_custom_feelings; DROP TABLE direct_messages; DROP TABLE media_likes; DROP TABLE saved_places;
      DROP INDEX memories_place_owner_visits; PRAGMA user_version = 17;
      INSERT INTO users(id, handle, password_hash, created_at) VALUES
        ('owner', 'alice', 'private-password-hash', 1), ('other', 'bob', 'other-hash', 2);
      INSERT INTO places VALUES ('place', 'Private Airport Café', 'airport', 47.45, -122.31, 'airport');
      INSERT INTO media VALUES ('photo', 'owner', 'image/jpeg', 3, X'010203', 2);
      INSERT INTO media VALUES ('video', 'owner', 'video/mp4', 4, X'05060708', 2);
      INSERT INTO memories(id, owner_id, kind, visibility, latitude, longitude, caption, place_id,
        created_at, expires_at, request_hash, published_at, location_name, post_location_id) VALUES
        ('visit', 'owner', 'poi', 'public', 47.4501, -122.31, '', 'place', 3, 259200004, 'visit-hash', 4, NULL, NULL),
        ('post', 'owner', 'reel', 'public', 47.1, -122.1, 'Private  two-space caption', NULL,
          11, 259200004, 'original-hash', 12, 'Private saved name', '11111111-1111-4111-8111-111111111111'),
        ('other-post', 'other', 'reel', 'public', 47.5, -122.5, 'Another owner', NULL,
          19, 259200004, 'other-post-hash', 20, NULL, NULL);
      INSERT INTO memory_media VALUES ('post', 'photo', 0), ('post', 'video', 1), ('visit', 'photo', 0);
      INSERT INTO memory_feedback VALUES ('visit', 'solid', 'Private feedback text');
      INSERT INTO memory_clusters VALUES ('post', 'Private cluster title', '[{"caption":"Private cluster member"}]');
      INSERT INTO cluster_media VALUES ('post', 'photo'), ('post', 'video');
      INSERT INTO comments VALUES ('comment', 'owner', NULL, 'place', 'Private comment', 5);
      INSERT INTO user_profiles VALUES ('owner', 'photo');
      INSERT INTO place_sources VALUES ('apple-place', 'place');
      INSERT INTO archive_hidden VALUES ('owner', 'reel', 'post', 8);
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
  if (mode === 'same-schema') migrate(sourcePath);
  if (mode !== 'backup') migrate(targetPath);
  if (withSocial) for (const path of [sourcePath, targetPath]) edit(path, `
    INSERT INTO media_likes VALUES ('visit', 'photo', 'other', 40);
    INSERT INTO saved_places VALUES ('other', 'place', 41);
    INSERT INTO direct_messages VALUES ('message', 'other', 'owner', 'Private message text', 'visit', 'photo', 'private-message-retry', 42);
  `);
  return { directory, sourcePath, targetPath };
}

for (const mode of ['backup', 'migration', 'same-schema']) {
  test(`schema18 ${mode} preserves every populated table and canonical day without mutating copies or printing private data`, async t => {
    const paths = await fixture(t, mode, mode === 'same-schema');
    const before = [await hash(paths.sourcePath), await hash(paths.targetPath)];
    const result = verifySchema18Copies({ mode, ...paths });
    assert.equal(result.ok, true);
    assert.equal(result.sourceSchema, mode === 'same-schema' ? 18 : 17);
    assert.equal(result.targetSchema, mode === 'backup' ? 17 : 18);
    assert.equal(result.tableCount, mode === 'same-schema' ? 31 : 28);
    assert(result.tables.every(table => table.count > 0));
    assert.equal(result.comparedRowCount, result.tables.reduce((sum, table) => sum + table.count, 0));
    assert(result.comparedColumnCount > 100);
    assert.equal(result.targetSchemaObjectCount - result.sourceSchemaObjectCount, mode === 'migration' ? 10 : 0);
    assert.deepEqual(result.addedTables, mode === 'migration' ? additions : []);
    assert.equal(result.visitDays.policy, 'place-iana-v1'); assert.equal(result.visitDays.count, 1);
    assert.match(result.visitDays.sha256, /^[a-f0-9]{64}$/);
    assert.deepEqual([await hash(paths.sourcePath), await hash(paths.targetPath)], before);
    const cli = spawnSync(process.execPath, [script, mode, paths.sourcePath, paths.targetPath], { encoding: 'utf8' });
    assert.equal(cli.status, 0, cli.stderr); assert.deepEqual(JSON.parse(cli.stdout), result);
    for (const value of ['private-password-hash', 'Private Airport Café', 'Private cluster member',
      'private-session-hash', 'private-encrypted-token', 'original-hash', 'Private feedback text',
      'Private message text', 'private-message-retry', '9223372036854775806', paths.directory]) {
      assert.equal(JSON.stringify(result).includes(value), false);
      assert.equal(cli.stdout.includes(value), false); assert.equal(cli.stderr.includes(value), false);
    }
  });
}

test('schema18 rejects changed old bytes, incomplete uploads, all time fields, retry hashes, identities, feedback and snapshots', async t => {
  for (const [sql, table] of [
    ["UPDATE media SET bytes = X'05060709' WHERE id = 'video'", 'media'],
    ["UPDATE media_upload_chunks SET bytes = X'090B'", 'media_upload_chunks'],
    ["UPDATE memories SET request_hash = 'changed'", 'memories'],
    ['UPDATE memories SET published_at = published_at + 1', 'memories'],
    ['UPDATE memories SET created_at = created_at + 1', 'memories'],
    ['UPDATE memories SET expires_at = expires_at + 1', 'memories'],
    ['UPDATE memories SET latitude = 47.4502', 'memories'],
    ["UPDATE memories SET post_location_id = '22222222-2222-4222-8222-222222222222' WHERE id = 'post'", 'memories'],
    ["UPDATE places SET longitude = -122.3", 'places'],
    ['UPDATE sessions SET expires_at = expires_at - 1', 'sessions'],
    ["UPDATE memory_clusters SET members_json = '[{}]'", 'memory_clusters'],
    ["UPDATE memory_feedback SET comment = 'changed'", 'memory_feedback'],
    ["DELETE FROM cluster_media WHERE media_id = 'video'", 'cluster_media'],
  ]) await t.test(table + ' ' + sql.slice(0, 32), async subtest => {
    const paths = await fixture(subtest, 'migration'); edit(paths.targetPath, sql);
    assert.throws(() => verifySchema18Copies({ mode: 'migration', ...paths }), new RegExp(`Stored rows changed: ${table}\\.`));
  });
});

test('schema18 only allows the precise new tables/indexes and rejects identical defects in both schema18 copies', async t => {
  for (const sql of [
    'CREATE TABLE unexpected(id TEXT PRIMARY KEY)',
    'CREATE INDEX unexpected_caption ON memories(caption)',
    'DROP INDEX memories_place_owner_visits; CREATE INDEX memories_place_owner_visits ON memories(owner_id,place_id)',
    'DROP INDEX saved_places_page',
    'CREATE INDEX unexpected_message ON direct_messages(text)',
    "CREATE TRIGGER unexpected_trigger AFTER INSERT ON direct_messages BEGIN SELECT 'private'; END",
    'ALTER TABLE saved_places ADD COLUMN unexpected TEXT',
    'ALTER TABLE places ADD COLUMN unexpected TEXT',
    'PRAGMA application_id = 123',
  ]) await t.test(sql.slice(0, 60), async subtest => {
    const paths = await fixture(subtest, 'migration'); edit(paths.targetPath, sql);
    assert.throws(() => verifySchema18Copies({ mode: 'migration', ...paths }), /application tables|schema18|schema objects|application ID/);
  });
  for (const transform of [
    sql => sql.replace(' <= 1000', ' <= 1001'),
    sql => sql.replaceAll('ON DELETE CASCADE', 'ON DELETE NO ACTION'),
    sql => sql.replace('CHECK(sender_id != recipient_id),', ''),
    sql => sql.replace(') STRICT', ')'),
    sql => sql.replace('context_memory_id TEXT', 'context_memory_id TEXT REFERENCES memories(id)'),
  ]) await t.test('same defect in both copies', async subtest => {
    const paths = await fixture(subtest, 'same-schema');
    for (const path of [paths.sourcePath, paths.targetPath]) {
      const db = new DatabaseSync(path);
      try {
        const schema = db.prepare("SELECT sql FROM sqlite_schema WHERE tbl_name = 'direct_messages' AND sql IS NOT NULL ORDER BY type DESC").all();
        db.exec('DROP TABLE direct_messages');
        for (const row of schema) db.exec(transform(row.sql));
      } finally { db.close(); }
    }
    assert.throws(() => verifySchema18Copies({ mode: 'same-schema', ...paths }), /schema18 table\/index definition/);
  });
});

test('schema18 migration requires empty additions and same-schema preserves every interaction/message byte', async t => {
  for (const sql of [
    "INSERT INTO media_likes VALUES ('visit','photo','other',40)",
    "INSERT INTO saved_places VALUES ('other','place',41)",
    "INSERT INTO direct_messages VALUES ('message','other','owner','Private message',NULL,NULL,'retry',42)",
  ]) await t.test('populated addition', async subtest => {
    const paths = await fixture(subtest, 'migration'); edit(paths.targetPath, sql);
    assert.throws(() => verifySchema18Copies({ mode: 'migration', ...paths }), /unexpectedly populated new tables/);
  });
  for (const [sql, table] of [
    ['DELETE FROM media_likes', 'media_likes'], ['UPDATE saved_places SET created_at = 42', 'saved_places'],
    ["UPDATE direct_messages SET text = 'changed'", 'direct_messages'],
    ["UPDATE direct_messages SET request_hash = 'changed'", 'direct_messages'],
    ['UPDATE direct_messages SET context_memory_id = NULL, context_media_id = NULL', 'direct_messages'],
  ]) await t.test(table, async subtest => {
    const paths = await fixture(subtest, 'same-schema', true); edit(paths.targetPath, sql);
    assert.throws(() => verifySchema18Copies({ mode: 'same-schema', ...paths }), new RegExp(`Stored rows changed: ${table}`));
  });
});

test('schema18 refuses live paths, aliases, wrong versions and extra CLI arguments', async t => {
  const paths = await fixture(t), verify = overrides => verifySchema18Copies({ mode: 'backup', ...paths, ...overrides });
  assert.throws(() => verify({ mode: 'unknown' }), /Choose backup/);
  for (const path of [undefined, null, 1, 'relative.sqlite']) assert.throws(() => verify({ sourcePath: path }), /absolute/);
  assert.throws(() => verify({ targetPath: paths.sourcePath }), /independent/);
  for (const path of ['/srv/maptalk/data/maptalk.sqlite', '/var/lib/maptalk/maptalk.sqlite']) {
    assert.throws(() => verify({ sourcePath: path }), /production database/);
    assert.throws(() => verify({ targetPath: path }), /production database/);
  }
  const hardlink = join(paths.directory, 'hardlink.sqlite'), softlink = join(paths.directory, 'symlink.sqlite');
  await link(paths.sourcePath, hardlink); assert.throws(() => verify({ targetPath: hardlink }), /hard links/);
  assert.throws(() => verify({}), /hard links/); await rm(hardlink);
  await symlink(paths.sourcePath, softlink); assert.throws(() => verify({ sourcePath: softlink }), /symbolic links/);
  assert.throws(() => verify({ targetPath: paths.directory }), /regular database files/);
  assert.throws(() => verify({ mode: 'migration' }), /Expected schema 18/);
  migrate(paths.targetPath); assert.throws(() => verify({}), /Expected schema 17/);
  const cli = spawnSync(process.execPath, [script, 'backup', paths.sourcePath, paths.targetPath, 'private-extra'], { encoding: 'utf8' });
  assert.equal(cli.status, 1); assert.match(cli.stderr, /Unexpected arguments/); assert.doesNotMatch(cli.stderr, /private-extra/);
});

test('schema18 checks FK/integrity and suppresses raw database errors, file paths and arbitrary schema names', async t => {
  const paths = await fixture(t, 'migration');
  edit(paths.targetPath, "PRAGMA foreign_keys=OFF; INSERT INTO media_likes VALUES ('missing','photo','owner',1)");
  assert.throws(() => verifySchema18Copies({ mode: 'migration', ...paths }), /foreign key check/);
  edit(paths.targetPath, 'DELETE FROM media_likes');
  const db = new DatabaseSync(paths.targetPath, { readOnly: true });
  let rootPage;
  try { rootPage = db.prepare("SELECT rootpage FROM sqlite_schema WHERE name='sessions_expiration'").get().rootpage; }
  finally { db.close(); }
  const bytes = await readFile(paths.targetPath), encodedPageSize = bytes.readUInt16BE(16);
  const offset = (rootPage - 1) * (encodedPageSize === 1 ? 65536 : encodedPageSize);
  assert.equal(bytes[offset], 0x0a); assert.equal(bytes.readUInt16BE(offset + 3), 1);
  bytes.writeUInt16BE(0, offset + 3); await writeFile(paths.targetPath, bytes);
  assert.throws(() => verifySchema18Copies({ mode: 'migration', ...paths }), /integrity check/);
  const corrupt = join(paths.directory, 'private-damaged.sqlite');
  await writeFile(corrupt, 'Private database contents must never be printed');
  const cli = spawnSync(process.execPath, [script, 'migration', paths.sourcePath, corrupt], { encoding: 'utf8' });
  assert.equal(cli.status, 1); assert.equal(cli.stdout, '');
  assert.match(cli.stderr, /Unable to verify database copies/);
  assert.doesNotMatch(cli.stderr, /Private database|private-damaged|SQLITE_ERROR|maptalk-schema18-verification/);
  const named = await fixture(t, 'migration'); edit(named.targetPath, 'CREATE INDEX private_schema_name ON memories(caption)');
  const schemaCli = spawnSync(process.execPath, [script, 'migration', named.sourcePath, named.targetPath], { encoding: 'utf8' });
  assert.equal(schemaCli.status, 1); assert.doesNotMatch(schemaCli.stderr, /private_schema_name/);
});
