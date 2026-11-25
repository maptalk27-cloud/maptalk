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
import { verifySchema17Copies } from '../scripts/verify-schema17.mjs';

const script = fileURLToPath(new URL('../scripts/verify-schema17.mjs', import.meta.url));
const hash = async path => createHash('sha256').update(await readFile(path)).digest('hex');
async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-schema17-verification-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const sourcePath = join(directory, 'frozen-v16.sqlite'), targetPath = join(directory, 'target.sqlite');
  const db = openDatabase(sourcePath);
  try {
    db.exec(`
      DROP TABLE IF EXISTS memory_custom_feelings; DROP TABLE direct_messages; DROP TABLE media_likes; DROP TABLE saved_places; DROP INDEX memories_place_owner_visits;
      DROP TABLE memory_feedback; PRAGMA user_version = 16;
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
      INSERT INTO memory_media VALUES ('post', 'photo', 0), ('post', 'video', 1);
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
  return { directory, sourcePath, targetPath };
}
function edit(path, sql) {
  const db = new DatabaseSync(path);
  try { db.exec(sql); } finally { db.close(); }
}
function migrate(path) {
  const db = openDatabase(path);
  // This fixture targets the historical 16 -> 17 release, not latest schema.
  db.exec('DROP TABLE IF EXISTS memory_custom_feelings; DROP TABLE direct_messages; DROP TABLE media_likes; DROP TABLE saved_places; DROP INDEX memories_place_owner_visits; PRAGMA user_version = 17;');
  db.close();
}
function rebuildFeedback(path, transform) {
  const db = new DatabaseSync(path);
  try {
    const { sql } = db.prepare("SELECT sql FROM sqlite_schema WHERE name = 'memory_feedback'").get();
    db.exec(`DROP TABLE memory_feedback; ${transform(sql)};`);
  } finally { db.close(); }
}
async function forMode(t, mode, withFeedback = false) {
  const paths = await fixture(t);
  if (mode === 'same-schema') migrate(paths.sourcePath);
  if (mode !== 'backup') migrate(paths.targetPath);
  if (withFeedback) for (const path of [paths.sourcePath, paths.targetPath]) {
    edit(path, "INSERT INTO memory_feedback VALUES ('visit', 'solid', 'Private feedback text')");
  }
  return paths;
}

for (const mode of ['backup', 'migration', 'same-schema']) {
  test(`schema17 ${mode} verifies all populated old tables without mutations or private output`, async t => {
    const paths = await forMode(t, mode, mode === 'same-schema');
    const before = [await hash(paths.sourcePath), await hash(paths.targetPath)];
    const result = verifySchema17Copies({ mode, ...paths });
    assert.equal(result.ok, true);
    assert.equal(result.sourceSchema, mode === 'same-schema' ? 17 : 16);
    assert.equal(result.targetSchema, mode === 'backup' ? 16 : 17);
    assert.equal(result.tableCount, mode === 'same-schema' ? 28 : 27);
    assert(result.tables.every(table => table.count > 0));
    assert.equal(result.comparedRowCount, result.tables.reduce((sum, table) => sum + table.count, 0));
    assert(result.comparedColumnCount > 100);
    assert.equal(result.targetSchemaObjectCount - result.sourceSchemaObjectCount, mode === 'migration' ? 2 : 0);
    assert.deepEqual(result.addedTables, mode === 'migration' ? ['memory_feedback'] : []);
    assert.equal(result.feedbackCount, mode === 'same-schema' ? 1 : 0);
    assert.match(result.sourceSchemaSha256, /^[a-f0-9]{64}$/);
    assert.match(result.targetSchemaSha256, /^[a-f0-9]{64}$/);
    assert.deepEqual([await hash(paths.sourcePath), await hash(paths.targetPath)], before);
    const cli = spawnSync(process.execPath, [script, mode, paths.sourcePath, paths.targetPath], { encoding: 'utf8' });
    assert.equal(cli.status, 0, cli.stderr);
    assert.deepEqual(JSON.parse(cli.stdout), result);
    for (const value of ['private-password-hash', 'Private Airport Café', 'Private cluster member',
      'private-session-hash', 'private-encrypted-token', 'original-hash', 'Private feedback text',
      'Private saved name', '11111111-1111-4111-8111-111111111111', '9223372036854775806', paths.directory]) {
      assert.equal(JSON.stringify(result).includes(value), false);
      assert.equal(cli.stdout.includes(value), false);
      assert.equal(cli.stderr.includes(value), false);
    }
  });

  test(`schema17 ${mode} rejects altered old rows, hashes, timestamps, snapshots and media`, async t => {
    const cases = [
      ["UPDATE media SET bytes = X'05060709' WHERE id = 'video'", 'media'],
      ["UPDATE media_upload_chunks SET bytes = X'090B'", 'media_upload_chunks'],
      ["UPDATE memories SET request_hash = 'changed'", 'memories'],
      ['UPDATE memories SET published_at = published_at + 1', 'memories'],
      ['UPDATE memories SET created_at = created_at + 1', 'memories'],
      ['UPDATE memories SET latitude = 47.4502', 'memories'],
      ["UPDATE memories SET location_name = 'Changed' WHERE kind = 'reel'", 'memories'],
      ["UPDATE memories SET post_location_id = '22222222-2222-4222-8222-222222222222' WHERE id = 'post'", 'memories'],
      ['UPDATE sessions SET expires_at = expires_at - 1', 'sessions'],
      ["UPDATE memory_clusters SET title = 'changed'", 'memory_clusters'],
      ["UPDATE memory_clusters SET members_json = '[{}]'", 'memory_clusters'],
      ["DELETE FROM cluster_media WHERE media_id = 'video'", 'cluster_media'],
      ['DELETE FROM comments', 'comments'],
      ["UPDATE apple_refresh_tokens SET encrypted_token = 'changed'", 'apple_refresh_tokens'],
    ];
    for (const [sql, table] of cases) await t.test(sql, async subtest => {
      const paths = await forMode(subtest, mode);
      edit(paths.targetPath, sql);
      assert.throws(() => verifySchema17Copies({ mode, ...paths }), new RegExp(`Stored rows changed: ${table}\\.`));
    });
  });

  test(`schema17 ${mode} rejects unexpected tables, altered old schema and new objects`, async t => {
    const cases = [
      ['CREATE TABLE unexpected(id TEXT PRIMARY KEY)', /application tables/],
      ['DROP TABLE cluster_media', /application tables/],
      ['CREATE INDEX unexpected_caption ON memories(caption)', /schema objects/],
      ['CREATE VIEW private_view AS SELECT caption FROM memories', /schema objects/],
      ['DROP INDEX cluster_media_asset; CREATE INDEX cluster_media_asset ON cluster_media(memory_id)', /schema objects/],
      ['ALTER TABLE places ADD COLUMN unexpected TEXT', /schema objects/],
      ["CREATE TRIGGER private_trigger AFTER INSERT ON server_metadata BEGIN SELECT 'private  value'; END", /schema objects/],
      ['PRAGMA application_id = 123', /application ID/],
    ];
    for (const [sql, expected] of cases) await t.test(sql.split(';')[0], async subtest => {
      const paths = await forMode(subtest, mode);
      edit(paths.targetPath, sql);
      assert.throws(() => verifySchema17Copies({ mode, ...paths }), expected);
    });
    const paths = await forMode(t, mode);
    edit(paths.sourcePath, "CREATE TRIGGER literal_check AFTER INSERT ON server_metadata BEGIN SELECT 'private  value'; END");
    edit(paths.targetPath, "CREATE TRIGGER literal_check AFTER INSERT ON server_metadata BEGIN SELECT 'private value'; END");
    assert.throws(() => verifySchema17Copies({ mode, ...paths }), /schema objects/);
  });
}

test('schema17 migration requires feedback empty; same-schema compares feedback contents exactly', async t => {
  const paths = await forMode(t, 'migration');
  edit(paths.targetPath, "INSERT INTO memory_feedback VALUES ('visit', 'solid', 'Private feedback text')");
  assert.throws(() => verifySchema17Copies({ mode: 'migration', ...paths }), /unexpectedly populated feedback/);
  for (const sql of ["UPDATE memory_feedback SET endorsement = 'hype'", "UPDATE memory_feedback SET comment = 'changed'",
    'DELETE FROM memory_feedback']) await t.test(sql, async subtest => {
    const equal = await forMode(subtest, 'same-schema', true);
    edit(equal.targetPath, sql);
    assert.throws(() => verifySchema17Copies({ mode: 'same-schema', ...equal }), /Stored rows changed: memory_feedback/);
  });
});

test('schema17 validates exact feedback constraints, columns and FK even if both schema17 copies share a defect', async t => {
  const transformations = [
    sql => sql.replace(' <= 1000', ' <= 1001'),
    sql => sql.replace("'questionable'", "'questionable '"),
    sql => sql.replace('ON DELETE CASCADE', 'ON DELETE NO ACTION'),
    sql => sql.replace('REFERENCES memories(id)', 'REFERENCES users(id)'),
    sql => sql.replace('comment TEXT NOT NULL', 'comment TEXT'),
    sql => sql.replace('length(comment) > 0', 'length(comment) >= 0'),
    sql => sql.replace(') STRICT', ')'),
    sql => sql.replace('endorsement TEXT', "endorsement TEXT DEFAULT 'solid'"),
    sql => sql.replace('comment TEXT NOT NULL', 'unexpected TEXT, comment TEXT NOT NULL'),
  ];
  for (const [index, transform] of transformations.entries()) for (const mode of ['migration', 'same-schema']) {
    await t.test(`${mode} altered feedback definition ${index}`, async subtest => {
      const paths = await forMode(subtest, mode);
      rebuildFeedback(paths.targetPath, transform);
      if (mode === 'same-schema') rebuildFeedback(paths.sourcePath, transform);
      assert.throws(() => verifySchema17Copies({ mode, ...paths }), /feedback table definition/);
    });
  }
  for (const sql of ['CREATE INDEX unexpected_feedback ON memory_feedback(endorsement)',
    "CREATE TRIGGER feedback_side_effect AFTER INSERT ON memory_feedback BEGIN SELECT 'private'; END"]) {
    await t.test(sql, async subtest => {
      const paths = await forMode(subtest, 'migration'); edit(paths.targetPath, sql);
      assert.throws(() => verifySchema17Copies({ mode: 'migration', ...paths }), /only the feedback table/);
    });
  }
});

test('schema17 rejects invalid modes, arguments, paths, hardlinks, symlinks and versions', async t => {
  const paths = await fixture(t), verify = overrides => verifySchema17Copies({ mode: 'backup', ...paths, ...overrides });
  assert.throws(() => verify({ mode: 'unknown' }), /Choose backup, migration or same-schema/);
  for (const sourcePath of [undefined, null, 123, 'relative.sqlite']) assert.throws(() => verify({ sourcePath }), /absolute/);
  assert.throws(() => verify({ targetPath: paths.sourcePath }), /independent/);
  const hardlink = join(paths.directory, 'hardlink.sqlite'), softlink = join(paths.directory, 'symlink.sqlite');
  await link(paths.sourcePath, hardlink);
  assert.throws(() => verify({ targetPath: hardlink }), /hard links/);
  assert.throws(() => verify({}), /hard links/, 'even an unpassed alias prevents treating a file as an isolated snapshot');
  await rm(hardlink);
  await symlink(paths.sourcePath, softlink);
  assert.throws(() => verify({ sourcePath: softlink }), /symbolic links/);
  assert.throws(() => verify({ targetPath: softlink }), /symbolic links/);
  assert.throws(() => verify({ targetPath: paths.directory }), /regular database files/);
  for (const path of ['/srv/maptalk/data/maptalk.sqlite', '/var/lib/maptalk/maptalk.sqlite']) {
    assert.throws(() => verify({ sourcePath: path }), /production database/);
    assert.throws(() => verify({ targetPath: path }), /production database/);
  }
  assert.throws(() => verify({ mode: 'migration' }), /Expected schema 17/);
  assert.throws(() => verify({ mode: 'same-schema' }), /Expected schema 17/);
  migrate(paths.targetPath);
  assert.throws(() => verify({}), /Expected schema 16/);
  migrate(paths.sourcePath);
  assert.throws(() => verify({ mode: 'migration' }), /Expected schema 16/);
  edit(paths.sourcePath, 'PRAGMA user_version = 18');
  assert.throws(() => verify({ mode: 'same-schema' }), /Expected schema 17/);
  const cli = spawnSync(process.execPath, [script, 'backup', paths.sourcePath, paths.targetPath, 'private-extra-argument'], { encoding: 'utf8' });
  assert.equal(cli.status, 1); assert.equal(cli.stdout, '');
  assert.match(cli.stderr, /Unexpected arguments/); assert.doesNotMatch(cli.stderr, /private-extra-argument/);
});

test('schema17 validates foreign keys, integrity and suppresses native errors and private schema names', async t => {
  const paths = await forMode(t, 'migration');
  edit(paths.targetPath, "PRAGMA foreign_keys = OFF; INSERT INTO memory_feedback VALUES ('missing', 'solid', 'private orphan')");
  assert.throws(() => verifySchema17Copies({ mode: 'migration', ...paths }), /foreign key check/);
  edit(paths.targetPath, 'DELETE FROM memory_feedback');
  edit(paths.targetPath, "PRAGMA foreign_keys = OFF; UPDATE cluster_media SET media_id = 'missing' WHERE media_id = 'video'");
  assert.throws(() => verifySchema17Copies({ mode: 'migration', ...paths }), /foreign key check/);
  edit(paths.targetPath, "UPDATE cluster_media SET media_id = 'video' WHERE media_id = 'missing'");
  const db = new DatabaseSync(paths.targetPath, { readOnly: true });
  let rootPage;
  try { rootPage = db.prepare("SELECT rootpage FROM sqlite_schema WHERE name = 'sessions_expiration'").get().rootpage; }
  finally { db.close(); }
  // Corrupt only a closed synthetic index leaf, leaving its table row present.
  const bytes = await readFile(paths.targetPath);
  const encodedPageSize = bytes.readUInt16BE(16), pageSize = encodedPageSize === 1 ? 65536 : encodedPageSize;
  const offset = (rootPage - 1) * pageSize;
  assert.equal(bytes[offset], 0x0a); assert.equal(bytes.readUInt16BE(offset + 3), 1);
  bytes.writeUInt16BE(0, offset + 3); await writeFile(paths.targetPath, bytes);
  assert.throws(() => verifySchema17Copies({ mode: 'migration', ...paths }), /integrity check/);
  const corrupt = join(paths.directory, 'private-damaged.sqlite');
  await writeFile(corrupt, 'Private database contents must never be printed');
  const cli = spawnSync(process.execPath, [script, 'migration', paths.sourcePath, corrupt], { encoding: 'utf8' });
  assert.equal(cli.status, 1); assert.equal(cli.stdout, '');
  assert.match(cli.stderr, /Unable to verify database copies/);
  assert.doesNotMatch(cli.stderr, /Private database|private-damaged|SQLITE_ERROR|maptalk-schema17-verification/);
  const named = await forMode(t, 'migration');
  edit(named.targetPath, 'CREATE INDEX private_schema_name ON memories(caption)');
  const schemaCli = spawnSync(process.execPath, [script, 'migration', named.sourcePath, named.targetPath], { encoding: 'utf8' });
  assert.equal(schemaCli.status, 1);
  assert.match(schemaCli.stderr, /schema objects/); assert.doesNotMatch(schemaCli.stderr, /private_schema_name/);
});
