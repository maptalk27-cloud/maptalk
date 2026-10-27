import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { link, mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { openDatabase } from '../src/database.mjs';
import { backupDatabase } from '../src/backup.mjs';
import { verifySchema12Copies } from '../scripts/verify-schema12.mjs';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-schema12-verification-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const sourcePath = join(directory, 'source-v11.sqlite');
  const targetPath = join(directory, 'restored.sqlite');
  const db = openDatabase(sourcePath);
  db.exec(`
    DROP TABLE comments;
    PRAGMA user_version = 11;
    INSERT INTO users(id, handle, password_hash, created_at) VALUES ('owner', 'alice', 'kept-secret-hash', 1);
    INSERT INTO places(id, name, category, latitude, longitude, directory_kind)
      VALUES ('place', 'Private Airport Café', 'coffee', 47.45, -122.31, 'airport');
    INSERT INTO media VALUES ('photo', 'owner', 'image/jpeg', 3, X'010203', 2);
    INSERT INTO media VALUES ('video', 'owner', 'video/mp4', 4, X'05060708', 2);
    INSERT INTO memories(id, owner_id, kind, visibility, latitude, longitude, caption, place_id,
      created_at, expires_at, request_hash, published_at)
      VALUES ('visit', 'owner', 'poi', 'public', 47.4501, -122.31, '', 'place', 3, 259200004, 'original-hash', 4);
    INSERT INTO memory_media VALUES ('visit', 'photo', 0);
    INSERT INTO memory_media VALUES ('visit', 'video', 1);
    INSERT INTO user_profiles VALUES ('owner', 'photo');
    INSERT INTO place_sources VALUES ('apple-place', 'place');
    INSERT INTO media_upload_requests VALUES ('owner', 'original-upload', 'request-fingerprint', 'video', 3);
    INSERT INTO media_upload_sessions VALUES ('owner', 'partial-upload', 'video/mp4', 4,
      '0000000000000000000000000000000000000000000000000000000000000000', 2, 3, 4);
    INSERT INTO media_upload_chunks VALUES ('owner', 'partial-upload', 0, X'090A');
  `);
  db.close();
  await backupDatabase(sourcePath, targetPath);
  return { sourcePath, targetPath };
}

function edit(path, sql) {
  const db = new DatabaseSync(path);
  try { db.exec(sql); } finally { db.close(); }
}

test('read-only verifier preserves every schema11 table and media across restore and the comments-only migration', async t => {
  const paths = await fixture(t);
  const hash = async path => createHash('sha256').update(await readFile(path)).digest('hex');
  const sourceHash = await hash(paths.sourcePath), targetHash = await hash(paths.targetPath);
  const backup = verifySchema12Copies({ mode: 'backup', ...paths });
  assert.equal(backup.tableCount, 24);
  assert.equal(backup.sourceSchema, 11);
  assert.equal(backup.targetSchema, 11);
  assert.equal(backup.tables.find(table => table.table === 'media').count, 2);
  assert.equal(backup.tables.find(table => table.table === 'media_upload_chunks').count, 1);
  assert.equal(await hash(paths.sourcePath), sourceHash);
  assert.equal(await hash(paths.targetPath), targetHash, 'verification does not modify either input');
  assert.equal(JSON.stringify(backup).includes('kept-secret-hash'), false);
  assert.equal(JSON.stringify(backup).includes('Private Airport Café'), false);
  openDatabase(paths.targetPath).close();
  const migratedHash = await hash(paths.targetPath);
  const migration = verifySchema12Copies({ mode: 'migration', ...paths });
  assert.equal(migration.targetSchema, 12);
  assert.deepEqual(migration.tables, backup.tables);
  assert.deepEqual(migration.addedTables, ['comments']);
  assert.equal(migration.addedIndexCount, 3);
  assert.equal(await hash(paths.sourcePath), sourceHash);
  assert.equal(await hash(paths.targetPath), migratedHash);
});

test('verifier rejects same files, hardlinks, wrong versions and non-absolute inputs', async t => {
  const paths = await fixture(t);
  assert.throws(() => verifySchema12Copies({ mode: 'backup', sourcePath: paths.sourcePath, targetPath: paths.sourcePath }), /independent/);
  const aliasPath = paths.sourcePath + '.hardlink';
  await link(paths.sourcePath, aliasPath);
  assert.throws(() => verifySchema12Copies({ mode: 'backup', sourcePath: paths.sourcePath, targetPath: aliasPath }), /independent/);
  assert.throws(() => verifySchema12Copies({ mode: 'backup', sourcePath: 'relative.sqlite', targetPath: paths.targetPath }), /absolute/);
  assert.throws(() => verifySchema12Copies({ mode: 'migration', ...paths }), /Expected schema 12/);
  openDatabase(paths.targetPath).close();
  assert.throws(() => verifySchema12Copies({ mode: 'backup', ...paths }), /Expected schema 11/);
});

test('migration verification rejects changes to media bytes, pending video chunks, dates or original place metadata', async t => {
  const cases = [
    ["UPDATE media SET bytes = X'05060709' WHERE id = 'video'", /Stored rows changed: media/],
    ["UPDATE media_upload_chunks SET bytes = X'090B'", /Stored rows changed: media_upload_chunks/],
    ['UPDATE memories SET published_at = published_at + 1', /Stored rows changed: memories/],
    ["UPDATE places SET directory_kind = NULL", /Stored rows changed: places/],
    ["UPDATE users SET handle = 'someone_else'", /Stored rows changed: users/],
    ['DELETE FROM memory_media WHERE position = 1', /Stored rows changed: memory_media/],
  ];
  for (const [sql, expected] of cases) {
    await t.test(sql.split(' ')[0] + ' ' + expected.source, async subtest => {
      const paths = await fixture(subtest);
      openDatabase(paths.targetPath).close();
      edit(paths.targetPath, sql);
      assert.throws(() => verifySchema12Copies({ mode: 'migration', ...paths }), expected);
    });
  }
});

test('backup verification refuses any changed stored rows even before migration', async t => {
  const paths = await fixture(t);
  edit(paths.targetPath, "UPDATE media SET bytes = X'010204' WHERE id = 'photo'");
  assert.throws(() => verifySchema12Copies({ mode: 'backup', ...paths }), /Stored rows changed: media/);
});

test('migration verification rejects extra schema, altered old columns and missing or changed comment indexes', async t => {
  const cases = [
    ['CREATE INDEX unexpected_caption_index ON memories(caption)', /Schema object count/],
    ['ALTER TABLE places ADD COLUMN unexpected TEXT', /Schema definition changed unexpectedly: places/],
    ['DROP INDEX comments_author_time', /Schema object count/],
    ['DROP INDEX comments_place_time; CREATE INDEX comments_place_time ON comments(place_id, id)', /Schema definition changed unexpectedly: comments_place_time/],
    ['CREATE TABLE extra_table(id TEXT PRIMARY KEY)', /Schema object count/],
  ];
  for (const [sql, expected] of cases) {
    await t.test(sql, async subtest => {
      const paths = await fixture(subtest);
      openDatabase(paths.targetPath).close();
      edit(paths.targetPath, sql);
      assert.throws(() => verifySchema12Copies({ mode: 'migration', ...paths }), expected);
    });
  }
});

test('migration verification rejects a comments table with relaxed constraints or prefilled content', async t => {
  const paths = await fixture(t);
  openDatabase(paths.targetPath).close();
  edit(paths.targetPath, `INSERT INTO comments VALUES ('comment', 'owner', 'visit', NULL, 'Unexpected content', 5)`);
  assert.throws(() => verifySchema12Copies({ mode: 'migration', ...paths }), /unexpectedly created comments/);
  edit(paths.targetPath, `
    DROP TABLE comments;
    CREATE TABLE comments (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      memory_id TEXT REFERENCES memories(id) ON DELETE CASCADE,
      place_id TEXT REFERENCES places(id) ON DELETE CASCADE,
      text TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      CHECK((memory_id IS NOT NULL) != (place_id IS NOT NULL))
    ) STRICT;
    CREATE INDEX comments_memory_time ON comments(memory_id, created_at DESC, id DESC);
    CREATE INDEX comments_place_time ON comments(place_id, created_at DESC, id DESC);
    CREATE INDEX comments_author_time ON comments(user_id, created_at DESC);
  `);
  assert.throws(() => verifySchema12Copies({ mode: 'migration', ...paths }), /Schema definition changed unexpectedly: comments/);
});
