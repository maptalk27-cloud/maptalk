import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { openDatabase } from '../src/database.mjs';
import { backupDatabase } from '../src/backup.mjs';
import { verifySchema11Copies } from '../scripts/verify-schema11.mjs';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-schema11-verification-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const sourcePath = join(directory, 'source-v10.sqlite');
  const targetPath = join(directory, 'restored.sqlite');
  const db = openDatabase(sourcePath);
  db.exec(`
    DROP TABLE cluster_media;
    DROP TABLE memory_clusters;
    DROP TABLE comments;
    ALTER TABLE places DROP COLUMN directory_kind;
    PRAGMA user_version = 10;
    INSERT INTO users(id, handle, password_hash, created_at) VALUES ('owner', 'alice', 'kept-secret-hash', 1);
    INSERT INTO places(id, name, category, latitude, longitude) VALUES ('place', 'Private Airport Café', 'coffee', 47.45, -122.31);
    INSERT INTO media VALUES ('photo', 'owner', 'image/jpeg', 3, X'010203', 2);
    INSERT INTO memories(id, owner_id, kind, visibility, latitude, longitude, caption, place_id, created_at, expires_at, request_hash)
      VALUES ('visit', 'owner', 'poi', 'private', 47.4501, -122.31, '', 'place', 3, 4, 'original-hash');
    INSERT INTO memory_media VALUES ('visit', 'photo', 0);
  `);
  db.close();
  await backupDatabase(sourcePath, targetPath);
  return { sourcePath, targetPath };
}

// This verifier belongs to the historical 10 -> 11 release. Apply only that
// release's ALTER, not later category-table rebuilds or cluster migrations.
function upgradeFixtureToSchema11(path) {
  const db = new DatabaseSync(path);
  db.exec(`
    PRAGMA foreign_keys = ON;
    ALTER TABLE places ADD COLUMN directory_kind TEXT CHECK(directory_kind IS NULL OR directory_kind = 'airport');
    PRAGMA user_version = 11;
  `);
  return db;
}

test('read-only verifier compares restored schema10 and allows only the schema11 nullable metadata addition', async t => {
  const paths = await fixture(t);
  const hash = async path => createHash('sha256').update(await readFile(path)).digest('hex');
  const sourceHash = await hash(paths.sourcePath), targetHash = await hash(paths.targetPath);
  const backup = verifySchema11Copies({ mode: 'backup', ...paths });
  assert.equal(backup.tableCount, 24);
  assert.equal(backup.tables.find(table => table.table === 'media').count, 1);
  assert.equal(await hash(paths.sourcePath), sourceHash);
  assert.equal(await hash(paths.targetPath), targetHash, 'verification does not modify either input');
  assert.equal(JSON.stringify(backup).includes('kept-secret-hash'), false);
  assert.equal(JSON.stringify(backup).includes('Private Airport Café'), false);
  upgradeFixtureToSchema11(paths.targetPath).close();
  const migratedHash = await hash(paths.targetPath);
  const migration = verifySchema11Copies({ mode: 'migration', ...paths });
  assert.equal(migration.targetSchema, 11);
  assert.deepEqual(migration.tables, backup.tables);
  assert.equal(await hash(paths.sourcePath), sourceHash);
  assert.equal(await hash(paths.targetPath), migratedHash);
});

test('verifier refuses changed media bytes, existing-place reclassification, extra schema or the same file', async t => {
  const paths = await fixture(t);
  assert.throws(() => verifySchema11Copies({ mode: 'backup', sourcePath: paths.sourcePath, targetPath: paths.sourcePath }), /independent/);
  let target = new DatabaseSync(paths.targetPath);
  target.exec("UPDATE media SET bytes = X'010204'"); target.close();
  assert.throws(() => verifySchema11Copies({ mode: 'backup', ...paths }), /Stored rows changed: media/);
  target = new DatabaseSync(paths.targetPath);
  target.exec("UPDATE media SET bytes = X'010203'"); target.close();
  target = upgradeFixtureToSchema11(paths.targetPath);
  target.exec("UPDATE places SET directory_kind = 'airport'"); target.close();
  assert.throws(() => verifySchema11Copies({ mode: 'migration', ...paths }), /unexpectedly classified/);
  target = new DatabaseSync(paths.targetPath);
  target.exec('UPDATE places SET directory_kind = NULL; CREATE INDEX unexpected_caption_index ON memories(caption)'); target.close();
  assert.throws(() => verifySchema11Copies({ mode: 'migration', ...paths }), /Schema object count/);
});

test('verifier rejects wrong versions and changed old fields even when schema11 itself is valid', async t => {
  const paths = await fixture(t);
  assert.throws(() => verifySchema11Copies({ mode: 'migration', ...paths }), /Expected schema 11/);
  const target = upgradeFixtureToSchema11(paths.targetPath);
  target.exec('UPDATE memories SET expires_at = expires_at + 1'); target.close();
  assert.throws(() => verifySchema11Copies({ mode: 'migration', ...paths }), /Stored rows changed: memories/);
});
