import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { link, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { openDatabase } from '../src/database.mjs';
import { backupDatabase } from '../src/backup.mjs';
import { verifySchema14Copies } from '../scripts/verify-schema14.mjs';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-schema14-verification-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const sourcePath = join(directory, 'snapshot-v12.sqlite');
  const targetPath = join(directory, 'restored-copy.sqlite');
  const db = openDatabase(sourcePath);
  // Recreate the historical places CHECK and the separate schema11 ALTER, not
  // just user_version. This covers actual SQL spacing left by ALTER ADD COLUMN.
  db.exec(`
    PRAGMA foreign_keys = OFF;
    BEGIN IMMEDIATE;
    DROP TABLE cluster_media;
    DROP TABLE memory_clusters;
    DROP TABLE places;
    CREATE TABLE places (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      category TEXT NOT NULL CHECK(category IN
        ('viewpoint', 'restaurant', 'coffee', 'nightlife', 'art', 'market', 'other')),
      latitude REAL NOT NULL CHECK(latitude BETWEEN -90 AND 90),
      longitude REAL NOT NULL CHECK(longitude BETWEEN -180 AND 180)
    ) STRICT;
    ALTER TABLE places ADD COLUMN directory_kind TEXT CHECK(directory_kind IS NULL OR directory_kind = 'airport');
    PRAGMA user_version = 12;
    COMMIT;
    PRAGMA foreign_keys = ON;
    INSERT INTO users(id, handle, password_hash, created_at) VALUES ('owner', 'alice', 'kept-secret-hash', 1);
    INSERT INTO places VALUES ('place', 'Private Airport Café', 'coffee', 47.45, -122.31, 'airport');
    INSERT INTO media VALUES ('photo', 'owner', 'image/jpeg', 3, X'010203', 2);
    INSERT INTO media VALUES ('video', 'owner', 'video/mp4', 4, X'05060708', 2);
    INSERT INTO memories(id, owner_id, kind, visibility, latitude, longitude, caption, place_id,
      created_at, expires_at, request_hash, published_at)
      VALUES ('visit', 'owner', 'poi', 'public', 47.4501, -122.31, '', 'place', 3, 259200004, 'original-hash', 4);
    INSERT INTO memory_media VALUES ('visit', 'photo', 0);
    INSERT INTO memory_media VALUES ('visit', 'video', 1);
    INSERT INTO comments VALUES ('comment', 'owner', NULL, 'place', 'Keep this place discussion', 5);
    INSERT INTO user_profiles VALUES ('owner', 'photo');
    INSERT INTO place_sources VALUES ('apple-place', 'place');
    INSERT INTO media_upload_requests VALUES ('owner', 'original-upload', 'request-fingerprint', 'video', 3);
    INSERT INTO media_upload_sessions VALUES ('owner', 'partial-upload', 'video/mp4', 4,
      '0000000000000000000000000000000000000000000000000000000000000000', 2, 3, 4);
    INSERT INTO media_upload_chunks VALUES ('owner', 'partial-upload', 0, X'090A');
    INSERT INTO sessions VALUES ('session-hash', 'owner', 9223372036854775806);
    INSERT INTO server_metadata VALUES ('deployment_mode', 'beta');
  `);
  db.close();
  await backupDatabase(sourcePath, targetPath);
  return { sourcePath, targetPath };
}
function edit(path, sql) {
  const db = new DatabaseSync(path);
  try { db.exec(sql); } finally { db.close(); }
}
function migrate(path) { openDatabase(path).close(); }
function changePlaceDefinition(path, transform) {
  const db = new DatabaseSync(path);
  try {
    const sql = db.prepare("SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = 'places'").get().sql;
    db.exec(`PRAGMA foreign_keys = OFF; BEGIN IMMEDIATE;
      ${transform(sql).replace(/^CREATE TABLE "?places"?/, 'CREATE TABLE places_changed')};
      INSERT INTO places_changed SELECT * FROM places;
      DROP TABLE places; ALTER TABLE places_changed RENAME TO places; COMMIT;`);
  } finally { db.close(); }
}

test('schema14 copy verifier checks all 25 old tables, leaves files unchanged and only reports digests', async t => {
  const paths = await fixture(t);
  const hash = async path => createHash('sha256').update(await readFile(path)).digest('hex');
  const sourceHash = await hash(paths.sourcePath), targetHash = await hash(paths.targetPath);
  const restored = verifySchema14Copies({ mode: 'backup', ...paths });
  assert.equal(restored.tableCount, 25);
  assert.equal(restored.sourceSchema, 12);
  assert.equal(restored.targetSchema, 12);
  assert.equal(restored.tables.find(row => row.table === 'media').count, 2);
  assert.equal(restored.tables.find(row => row.table === 'media_upload_chunks').count, 1);
  assert.equal(await hash(paths.sourcePath), sourceHash);
  assert.equal(await hash(paths.targetPath), targetHash);
  migrate(paths.targetPath);
  const migratedHash = await hash(paths.targetPath);
  const migrated = verifySchema14Copies({ mode: 'migration', ...paths });
  assert.equal(migrated.targetSchema, 14);
  assert.deepEqual(migrated.tables, restored.tables);
  assert.deepEqual(migrated.addedTables, ['memory_clusters', 'cluster_media']);
  assert.equal(migrated.addedIndexCount, 1);
  assert.deepEqual(migrated.widenedPlaceCategories, ['hotel', 'airport']);
  assert.equal(await hash(paths.sourcePath), sourceHash);
  assert.equal(await hash(paths.targetPath), migratedHash);
  for (const value of ['kept-secret-hash', 'Private Airport Café', 'original-hash', 'session-hash', '090A']) {
    assert.equal(JSON.stringify(migrated).includes(value), false);
  }
});

test('schema14 verifier rejects same files, hardlinks, wrong versions, live paths and invalid inputs', async t => {
  const paths = await fixture(t);
  assert.throws(() => verifySchema14Copies({ mode: 'backup', sourcePath: paths.sourcePath, targetPath: paths.sourcePath }), /independent/);
  const alias = paths.sourcePath + '.hardlink';
  await link(paths.sourcePath, alias);
  assert.throws(() => verifySchema14Copies({ mode: 'backup', sourcePath: paths.sourcePath, targetPath: alias }), /independent/);
  assert.throws(() => verifySchema14Copies({ mode: 'unknown', ...paths }), /Choose backup or migration/);
  assert.throws(() => verifySchema14Copies({ mode: 'backup', sourcePath: 'relative.sqlite', targetPath: paths.targetPath }), /absolute/);
  assert.throws(() => verifySchema14Copies({ mode: 'backup', sourcePath: '/srv/maptalk/data/maptalk.sqlite', targetPath: paths.targetPath }), /production database/);
  assert.throws(() => verifySchema14Copies({ mode: 'migration', ...paths }), /Expected schema 14/);
  migrate(paths.targetPath);
  assert.throws(() => verifySchema14Copies({ mode: 'backup', ...paths }), /Expected schema 12/);
  migrate(paths.sourcePath);
  assert.throws(() => verifySchema14Copies({ mode: 'migration', ...paths }), /Expected schema 12/);
});

test('schema14 verifier detects changes to old bytes, retry identities, coordinates, dates and relationships', async t => {
  const cases = [
    ["UPDATE media SET bytes = X'05060709' WHERE id = 'video'", /Stored rows changed: media/],
    ["UPDATE media_upload_chunks SET bytes = X'090B'", /Stored rows changed: media_upload_chunks/],
    ['UPDATE media_upload_sessions SET received_bytes = 3', /Stored rows changed: media_upload_sessions/],
    ["UPDATE media_upload_requests SET request_hash = 'different'", /Stored rows changed: media_upload_requests/],
    ["UPDATE memories SET request_hash = 'different'", /Stored rows changed: memories/],
    ['UPDATE memories SET published_at = published_at + 1', /Stored rows changed: memories/],
    ['UPDATE memories SET latitude = 47.4502', /Stored rows changed: memories/],
    ["UPDATE places SET category = 'airport'", /Stored rows changed: places/],
    ["UPDATE places SET directory_kind = NULL", /Stored rows changed: places/],
    ["UPDATE comments SET text = 'changed'", /Stored rows changed: comments/],
    ["UPDATE users SET handle = 'someone_else'", /Stored rows changed: users/],
    ['UPDATE sessions SET expires_at = expires_at - 1', /Stored rows changed: sessions/],
    ['DELETE FROM memory_media WHERE position = 1', /Stored rows changed: memory_media/],
  ];
  for (const [sql, expected] of cases) await t.test(sql.split(' ').slice(0, 2).join(' '), async subtest => {
    const paths = await fixture(subtest);
    migrate(paths.targetPath);
    edit(paths.targetPath, sql);
    assert.throws(() => verifySchema14Copies({ mode: 'migration', ...paths }), expected);
  });
});

test('schema14 backup mode refuses changed rows and historical source schema violations', async t => {
  const paths = await fixture(t);
  edit(paths.targetPath, "UPDATE media SET bytes = X'010204' WHERE id = 'photo'");
  assert.throws(() => verifySchema14Copies({ mode: 'backup', ...paths }), /Stored rows changed: media/);
  changePlaceDefinition(paths.sourcePath, sql => sql.replace("'market', 'other'", "'market', 'hotel', 'other'"));
  assert.throws(() => verifySchema14Copies({ mode: 'backup', ...paths }), /historical category constraint/);
});

test('schema14 verifier permits only the exact widened places CHECK and unchanged directory and GPS constraints', async t => {
  const transforms = [
    sql => sql.replace("'hotel', 'airport', ", ''),
    sql => sql.replace("'hotel', 'airport', ", "'hotel', 'airport', 'future-type', "),
    sql => sql.replace('latitude BETWEEN -90 AND 90', 'latitude BETWEEN -180 AND 180'),
    sql => sql.replace("directory_kind IS NULL OR directory_kind = 'airport'", "directory_kind IS NULL OR directory_kind IN ('airport', 'hotel')"),
    sql => sql.replace('name TEXT NOT NULL', 'name TEXT'),
  ];
  for (const [index, transform] of transforms.entries()) await t.test(`constraint mutation ${index}`, async subtest => {
    const paths = await fixture(subtest);
    migrate(paths.targetPath);
    changePlaceDefinition(paths.targetPath, transform);
    assert.throws(() => verifySchema14Copies({ mode: 'migration', ...paths }), /Schema definition changed unexpectedly: places/);
  });
});

test('schema14 verifier rejects extra objects, altered columns or changed new and old indexes', async t => {
  const cases = [
    ['CREATE TABLE unexpected(id TEXT PRIMARY KEY)', /Schema object count/],
    ['CREATE INDEX unexpected_caption ON memories(caption)', /Schema object count/],
    ['ALTER TABLE places ADD COLUMN unexpected TEXT', /Schema definition changed unexpectedly: places/],
    ['ALTER TABLE media ADD COLUMN unexpected TEXT', /Schema definition changed unexpectedly: media/],
    ['DROP INDEX cluster_media_asset', /Schema object count/],
    ['DROP INDEX cluster_media_asset; CREATE INDEX cluster_media_asset ON cluster_media(memory_id)', /Schema definition changed unexpectedly: cluster_media_asset/],
    ['DROP INDEX comments_author_time; CREATE INDEX comments_author_time ON comments(user_id, id)', /Schema definition changed unexpectedly: comments_author_time/],
    ['DROP TABLE cluster_media', /Schema object count/],
  ];
  for (const [sql, expected] of cases) await t.test(sql.split(';')[0], async subtest => {
    const paths = await fixture(subtest);
    migrate(paths.targetPath);
    edit(paths.targetPath, sql);
    assert.throws(() => verifySchema14Copies({ mode: 'migration', ...paths }), expected);
  });
});

test('schema14 verifier rejects weakened cluster constraints and populated cluster storage', async t => {
  const paths = await fixture(t);
  migrate(paths.targetPath);
  edit(paths.targetPath, `INSERT INTO memory_clusters VALUES ('visit', 'Unexpected cluster', '[{}]');
    INSERT INTO cluster_media VALUES ('visit', 'photo');`);
  assert.throws(() => verifySchema14Copies({ mode: 'migration', ...paths }), /unexpectedly populated memory_clusters/);
  edit(paths.targetPath, `DROP TABLE cluster_media; DROP TABLE memory_clusters;
    CREATE TABLE memory_clusters (
      memory_id TEXT PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,
      title TEXT NOT NULL,
      members_json TEXT NOT NULL
    ) STRICT;
    CREATE TABLE cluster_media (
      memory_id TEXT NOT NULL REFERENCES memory_clusters(memory_id) ON DELETE CASCADE,
      media_id TEXT NOT NULL REFERENCES media(id), PRIMARY KEY(memory_id, media_id)
    ) STRICT;
    CREATE INDEX cluster_media_asset ON cluster_media(media_id);`);
  assert.throws(() => verifySchema14Copies({ mode: 'migration', ...paths }), /Schema definition changed unexpectedly: memory_clusters/);
});

test('schema14 verifier checks foreign keys and its CLI suppresses native diagnostic details', async t => {
  const paths = await fixture(t);
  migrate(paths.targetPath);
  edit(paths.targetPath, "PRAGMA foreign_keys = OFF; UPDATE comments SET place_id = 'absent'");
  assert.throws(() => verifySchema14Copies({ mode: 'migration', ...paths }), /foreign key check/);
  const corrupt = paths.targetPath + '.damaged';
  await writeFile(corrupt, 'Private database contents must not appear in diagnostics');
  const script = fileURLToPath(new URL('../scripts/verify-schema14.mjs', import.meta.url));
  const result = spawnSync(process.execPath, [script, 'backup', paths.sourcePath, corrupt], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
  assert.match(result.stderr, /Unable to verify database copies/);
  assert.doesNotMatch(result.stderr, /Private database contents|snapshot-v12|SQLITE_ERROR/);
});
