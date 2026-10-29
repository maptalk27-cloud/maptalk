import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openDatabase } from '../src/database.mjs';
import { backupDatabase } from '../src/backup.mjs';

test('schema 14 preserves every place reference and old row while allowing hotel and airport categories', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-category-migration-'));
  const path = join(directory, 'v13.sqlite');
  let db = openDatabase(path);
  let restored;
  try {
    // Recreate the exact prior CHECK, not merely a downgraded version number.
    db.exec(`
      PRAGMA foreign_keys = OFF;
      BEGIN IMMEDIATE;
      CREATE TABLE places_old (
        id TEXT PRIMARY KEY, name TEXT NOT NULL,
        category TEXT NOT NULL CHECK(category IN ('viewpoint', 'restaurant', 'coffee', 'nightlife', 'art', 'market', 'other')),
        latitude REAL NOT NULL CHECK(latitude BETWEEN -90 AND 90),
        longitude REAL NOT NULL CHECK(longitude BETWEEN -180 AND 180),
        directory_kind TEXT CHECK(directory_kind IS NULL OR directory_kind = 'airport')
      ) STRICT;
      DROP TABLE places;
      ALTER TABLE places_old RENAME TO places;
      PRAGMA user_version = 13;
      COMMIT;
      PRAGMA foreign_keys = ON;
      INSERT INTO users VALUES ('owner', 'alice', 'unchanged-hash', 1, NULL);
      INSERT INTO places VALUES ('place', 'Airport hotel', 'other', 47.45, -122.31, NULL);
      INSERT INTO place_sources VALUES ('apple-source', 'place');
      INSERT INTO memories(id, owner_id, kind, visibility, latitude, longitude, caption, place_id,
        created_at, expires_at, request_hash, published_at)
        VALUES ('visit', 'owner', 'poi', 'private', 47.45, -122.31, '', 'place', 2, 3, 'keep-idempotency', NULL);
      INSERT INTO comments VALUES ('comment', 'owner', NULL, 'place', 'Keep discussion', 4);
      INSERT INTO media VALUES ('video', 'owner', 'video/mp4', 3, X'010203', 5);
      INSERT INTO memory_media VALUES ('visit', 'video', 0);
      INSERT INTO media_upload_sessions VALUES ('owner', 'pending', 'video/mp4', 5, '${'0'.repeat(64)}', 2, 6, 7);
      INSERT INTO media_upload_chunks VALUES ('owner', 'pending', 0, X'0102');
    `);
    const tables = db.prepare("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .all().map(({ name }) => name);
    const before = Object.fromEntries(tables.map(name => [name, db.prepare(`SELECT * FROM ${name}`).all()]));
    const backupPath = join(directory, 'restore.sqlite');
    await backupDatabase(path, backupPath);
    db.close();
    db = openDatabase(path);
    restored = openDatabase(backupPath);
    for (const migrated of [db, restored]) {
      assert.equal(migrated.prepare('PRAGMA user_version').get().user_version, 14);
      for (const [table, rows] of Object.entries(before)) {
        assert.deepEqual(migrated.prepare(`SELECT * FROM ${table}`).all(), rows, table);
      }
      const insert = migrated.prepare('INSERT INTO places VALUES (?, ?, ?, 47, -122, NULL)');
      insert.run('hotel', 'New hotel', 'hotel');
      insert.run('airport', 'New airport', 'airport');
      assert.throws(() => insert.run('unknown', 'Unknown', 'future-type'), /CHECK/);
      assert.throws(() => migrated.exec("UPDATE places SET directory_kind = 'hotel' WHERE id = 'hotel'"), /CHECK/);
      assert.deepEqual(migrated.prepare('PRAGMA foreign_key_check').all(), []);
      assert.equal(migrated.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
      assert.equal(migrated.prepare('PRAGMA foreign_keys').get().foreign_keys, 1);
    }
    db.close();
    db = openDatabase(path);
    assert.equal(db.prepare("SELECT category FROM places WHERE id = 'hotel'").get().category, 'hotel');
    assert.equal(db.prepare("SELECT category FROM places WHERE id = 'place'").get().category, 'other', 'no inferred rewrites');
  } finally {
    restored?.close();
    db.close();
    await rm(directory, { recursive: true, force: true });
  }
});
