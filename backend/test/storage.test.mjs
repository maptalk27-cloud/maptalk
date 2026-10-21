import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { DatabaseSync } from 'node:sqlite';
import { openDatabase } from '../src/database.mjs';
import { backupDatabase } from '../src/backup.mjs';
import { hashPassword, verifyPassword, issueSession, digest } from '../src/security.mjs';

test('passwords are salted and tokens are not stored in plaintext', async () => {
  const password = 'not-a-real-password-42';
  const first = await hashPassword(password);
  const second = await hashPassword(password);
  assert.notEqual(first, second);
  assert.match(first, /^scrypt\$32768\$8\$3\$/);
  assert.ok(!first.includes(password));
  assert.equal(await verifyPassword(password, first), true);
  assert.equal(await verifyPassword('wrong-password', first), false);
  assert.equal(await verifyPassword(password), false);
  assert.equal(await verifyPassword(password, 'corrupt'), false);

  const directory = await mkdtemp(join(tmpdir(), 'maptalk-security-'));
  const db = openDatabase(join(directory, 'test.sqlite'));
  try {
    db.prepare('INSERT INTO users(id, handle, password_hash, created_at) VALUES (?, ?, ?, ?)').run('user-a', 'alice', first, 1);
    const session = issueSession(db, 'user-a', 1);
    const stored = db.prepare('SELECT * FROM sessions').get();
    assert.equal(stored.token_hash, digest(session.token));
    assert.ok(!JSON.stringify(stored).includes(session.token));
    assert.equal((await stat(join(directory, 'test.sqlite'))).mode & 0o777, 0o600);
  } finally {
    db.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test('a live backup includes WAL writes, restores, and never overwrites an existing backup', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-backup-test-'));
  const source = join(directory, 'source.sqlite');
  const target = join(directory, 'backup.sqlite');
  const db = openDatabase(source);
  let restored;
  try {
    db.prepare('INSERT INTO users(id, handle, password_hash, created_at) VALUES (?, ?, ?, ?)').run('user-a', 'alice', 'test-hash', 1);
    await backupDatabase(source, target);
    restored = openDatabase(target);
    assert.equal(restored.prepare('SELECT handle FROM users').get().handle, 'alice');
    assert.equal(restored.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
    assert.equal((await stat(target)).mode & 0o777, 0o600);
    await assert.rejects(backupDatabase(source, target), { code: 'EEXIST' });
    await assert.rejects(backupDatabase(source, source), /must not replace/);
    assert.equal(restored.prepare('SELECT COUNT(*) AS count FROM users').get().count, 1);
  } finally {
    restored?.close();
    db.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test('schema upgrades preserve existing private and public records', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-migration-'));
  const path = join(directory, 'v1.sqlite');
  let db = new DatabaseSync(path);
  try {
    db.exec(await readFile(new URL('../src/schema.sql', import.meta.url), 'utf8'));
    db.exec('PRAGMA user_version = 1;');
    db.prepare('INSERT INTO users(id, handle, password_hash, created_at) VALUES (?, ?, ?, ?)').run('user-a', 'alice', 'test-hash', 1);
    const insert = db.prepare(`INSERT INTO memories(id, owner_id, kind, visibility,
      latitude, longitude, caption, created_at, expires_at, request_hash)
      VALUES (?, 'user-a', 'reel', ?, 37, -122, 'Saved before upgrade', 1000, 86401000, 'test')`);
    insert.run('private-id', 'private');
    insert.run('public-id', 'public');
    db.close();
    db = openDatabase(path);
    assert.equal(db.prepare('PRAGMA user_version').get().user_version, 9);
    const rows = db.prepare('SELECT * FROM memories ORDER BY id').all();
    assert.equal(rows.length, 2);
    assert.equal(rows[0].visibility, 'private');
    assert.equal(rows[0].published_at, null);
    assert.equal(rows[1].published_at, 1000);
    assert.equal(rows[1].created_at, 1000);
    assert.equal(rows[1].expires_at, 86401000);
    assert.equal(db.prepare('SELECT COUNT(*) AS count FROM deleted_memories').get().count, 0);
    assert.equal(db.prepare('SELECT COUNT(*) AS count FROM place_sources').get().count, 0);
    assert.equal(db.prepare('SELECT COUNT(*) AS count FROM archive_hidden').get().count, 0);
    assert.equal(db.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
  } finally {
    db.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test('version two databases acquire archive/source tables without changing records', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-v2-migration-'));
  const path = join(directory, 'v2.sqlite');
  let db = openDatabase(path);
  try {
    db.prepare('INSERT INTO users(id, handle, password_hash, created_at) VALUES (?, ?, ?, ?)').run('user-a', 'alice', 'test-hash', 1);
    db.prepare(`INSERT INTO memories(id, owner_id, kind, visibility, latitude, longitude,
      caption, created_at, expires_at, request_hash, published_at)
      VALUES ('memory-a', 'user-a', 'reel', 'private', 37, -122, 'Kept', 1000, 86401000, 'test', NULL)`).run();
    db.exec('DROP TABLE place_sources; DROP TABLE archive_hidden; PRAGMA user_version = 2;');
    db.close();
    db = openDatabase(path);
    assert.equal(db.prepare('PRAGMA user_version').get().user_version, 9);
    assert.equal(db.prepare('SELECT caption FROM memories').get().caption, 'Kept');
    assert.equal(db.prepare('SELECT COUNT(*) AS count FROM archive_hidden').get().count, 0);
    assert.equal(db.prepare('SELECT COUNT(*) AS count FROM place_sources').get().count, 0);
    assert.equal(db.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
  } finally {
    db.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test('version three upgrade adds Apple identities without changing existing accounts or sessions', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-v3-migration-'));
  const path = join(directory, 'v3.sqlite');
  let db = openDatabase(path);
  try {
    db.prepare('INSERT INTO users(id, handle, password_hash, created_at) VALUES (?, ?, ?, ?)').run('user-a', 'alice', 'existing-password-hash', 1);
    const session = issueSession(db, 'user-a', 1);
    db.exec('DROP TABLE auth_identities; DROP TABLE apple_auth_challenges; PRAGMA user_version = 3;');
    db.close();
    db = openDatabase(path);
    assert.equal(db.prepare('PRAGMA user_version').get().user_version, 9);
    assert.equal(db.prepare('SELECT password_hash FROM users').get().password_hash, 'existing-password-hash');
    assert.equal(db.prepare('SELECT token_hash FROM sessions').get().token_hash, digest(session.token));
    assert.equal(db.prepare('SELECT COUNT(*) AS count FROM auth_identities').get().count, 0);
    assert.equal(db.prepare('SELECT COUNT(*) AS count FROM apple_auth_challenges').get().count, 0);
    assert.equal(db.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
  } finally {
    db.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test('version four upgrade preserves Apple identities, sessions and content while adding other providers', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-v4-migration-'));
  const path = join(directory, 'v4.sqlite');
  let db = openDatabase(path);
  try {
    db.prepare('INSERT INTO users(id, handle, password_hash, created_at) VALUES (?, ?, ?, ?)').run('apple-user', 'existing_apple', '', 1);
    db.prepare('INSERT INTO users(id, handle, password_hash, created_at) VALUES (?, ?, ?, ?)').run('password-user', 'existing_local', 'kept-hash', 1);
    const session = issueSession(db, 'apple-user', 1);
    db.prepare(`INSERT INTO memories(id, owner_id, kind, visibility, latitude, longitude,
      caption, created_at, expires_at, request_hash, published_at)
      VALUES ('memory-a', 'apple-user', 'reel', 'private', 37, -122, 'Kept', 1000, 86401000, 'test', NULL)`).run();
    db.exec(`
      DROP TABLE auth_identities;
      CREATE TABLE auth_identities (
        provider TEXT NOT NULL CHECK(provider = 'apple'), provider_subject TEXT NOT NULL,
        user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, created_at INTEGER NOT NULL,
        PRIMARY KEY(provider, provider_subject), UNIQUE(provider, user_id)
      ) STRICT;
      INSERT INTO auth_identities VALUES ('apple', 'stable-apple-sub', 'apple-user', 1);
      DROP TABLE oauth_auth_challenges; DROP TABLE oauth_used_codes;
      PRAGMA user_version = 4;
    `);
    db.close();
    db = openDatabase(path);
    assert.equal(db.prepare('PRAGMA user_version').get().user_version, 9);
    assert.equal(db.prepare('SELECT provider_subject FROM auth_identities').get().provider_subject, 'stable-apple-sub');
    assert.equal(db.prepare('SELECT token_hash FROM sessions').get().token_hash, digest(session.token));
    assert.equal(db.prepare('SELECT caption FROM memories').get().caption, 'Kept');
    assert.equal(db.prepare("SELECT password_hash FROM users WHERE id = 'password-user'").get().password_hash, 'kept-hash');
    db.prepare('INSERT INTO auth_identities VALUES (?, ?, ?, ?)').run('google', 'google-sub', 'password-user', 2);
    db.prepare('INSERT INTO auth_identities VALUES (?, ?, ?, ?)').run('wechat', 'wx-id:openid', 'password-user', 2);
    assert.throws(() => db.prepare('INSERT INTO auth_identities VALUES (?, ?, ?, ?)').run('fake', 'bad', 'password-user', 2));
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
    assert.equal(db.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
  } finally {
    db.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test('version six migration approves only pending records and preserves privacy, rejection, expiry and safety data', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-v6-profile-migration-'));
  const path = join(directory, 'v6.sqlite');
  let db = openDatabase(path);
  try {
    const user = db.prepare('INSERT INTO users(id, handle, password_hash, created_at) VALUES (?, ?, ?, 1)');
    user.run('owner', 'alice', 'kept-hash'); user.run('viewer', 'bob', 'other-hash');
    const insert = db.prepare(`INSERT INTO memories(id, owner_id, kind, visibility, latitude, longitude,
      caption, created_at, expires_at, request_hash, published_at, moderation_status)
      VALUES (?, 'owner', 'reel', ?, 37, -122, 'Original caption', 1000, 2000, 'original-hash', ?, ?)`);
    for (const audience of ['private', 'public']) for (const status of ['pending', 'approved', 'rejected']) {
      insert.run(`${audience}-${status}`, audience, audience === 'public' ? 1000 : null, status);
    }
    db.exec(`
      INSERT INTO user_blocks VALUES ('viewer', 'owner', 11);
      INSERT INTO beta_members VALUES ('owner', 'revoked', 12);
      INSERT INTO archive_hidden VALUES ('owner', 'reel', 'public-pending', 13);
      INSERT INTO deleted_memories VALUES ('deleted-record', 'owner', 14);
      INSERT INTO content_reports VALUES ('report', 'viewer', 'public-rejected', 'Keep rejection', 15);
      DROP TABLE user_profiles;
      PRAGMA user_version = 6;
    `);
    const before = db.prepare('SELECT * FROM memories ORDER BY id').all();
    const safetyTables = ['users', 'user_blocks', 'beta_members', 'archive_hidden', 'deleted_memories', 'content_reports'];
    const safety = Object.fromEntries(safetyTables.map(table => [table, db.prepare(`SELECT * FROM ${table}`).all()]));
    db.close();
    db = openDatabase(path);
    assert.equal(db.prepare('PRAGMA user_version').get().user_version, 9);
    assert.deepEqual(db.prepare('SELECT * FROM memories ORDER BY id').all().map(row => ({ ...row })), before.map(row => ({ ...row,
      moderation_status: row.moderation_status === 'pending' ? 'approved' : row.moderation_status })));
    for (const table of safetyTables) assert.deepEqual(db.prepare(`SELECT * FROM ${table}`).all(), safety[table], table);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM user_profiles').get().n, 0);
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
    assert.equal(db.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
    const migrated = db.prepare('SELECT * FROM memories ORDER BY id').all();
    db.close();
    db = openDatabase(path);
    assert.deepEqual(db.prepare('SELECT * FROM memories ORDER BY id').all(), migrated, 'reopening does not revive rejected or extend expired posts');
  } finally {
    db.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test('version seven adds retry mappings without changing media, records, avatars or deletion tombstones', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-v7-upload-migration-'));
  const path = join(directory, 'v7.sqlite');
  let db = openDatabase(path);
  try {
    db.exec(`
      INSERT INTO users(id, handle, password_hash, created_at) VALUES ('owner', 'alice', 'kept-hash', 1);
      INSERT INTO media VALUES ('photo', 'owner', 'image/jpeg', 1, X'01', 2);
      INSERT INTO user_profiles VALUES ('owner', 'photo');
      INSERT INTO memories(id, owner_id, kind, visibility, latitude, longitude, caption, created_at, expires_at, request_hash)
        VALUES ('post', 'owner', 'reel', 'private', 37, -122, 'Kept', 3, 4, 'original-hash');
      INSERT INTO memory_media VALUES ('post', 'photo', 0);
      INSERT INTO deleted_memories VALUES ('deleted', 'owner', 5);
      DROP TABLE media_upload_requests;
      PRAGMA user_version = 7;
    `);
    const tables = ['users', 'media', 'user_profiles', 'memories', 'memory_media', 'deleted_memories'];
    const before = Object.fromEntries(tables.map(table => [table, db.prepare(`SELECT * FROM ${table}`).all()]));
    db.close(); db = openDatabase(path);
    assert.equal(db.prepare('PRAGMA user_version').get().user_version, 9);
    for (const table of tables) assert.deepEqual(db.prepare(`SELECT * FROM ${table}`).all(), before[table]);
    db.prepare('INSERT INTO media_upload_requests VALUES (?, ?, ?, ?, ?)').run('owner', 'key', 'hash', 'photo', 6);
    db.exec("DELETE FROM memories; UPDATE user_profiles SET avatar_media_id = NULL; DELETE FROM media;");
    assert.equal(db.prepare('SELECT media_id FROM media_upload_requests').get().media_id, null, 'deleted bytes leave a retry tombstone');
    db.exec('DELETE FROM users;');
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM media_upload_requests').get().n, 0, 'account deletion also erases retry history');
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
    assert.equal(db.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
  } finally { db.close(); await rm(directory, { recursive: true, force: true }); }
});

test('version eight media rebuild preserves exact bytes, avatars, links and retry tombstones; videos survive backup restore', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-v8-video-migration-'));
  const path = join(directory, 'v8.sqlite');
  let db = openDatabase(path);
  let restored;
  try {
    db.exec(`
      INSERT INTO users(id, handle, password_hash, created_at) VALUES ('owner', 'alice', 'kept-hash', 1);
      INSERT INTO media VALUES ('photo', 'owner', 'image/jpeg', 3, X'010203', 2);
      INSERT INTO user_profiles VALUES ('owner', 'photo');
      INSERT INTO memories(id, owner_id, kind, visibility, latitude, longitude, caption, created_at, expires_at, request_hash)
        VALUES ('post', 'owner', 'reel', 'private', 37, -122, 'Kept', 3, 4, 'original-hash');
      INSERT INTO memory_media VALUES ('post', 'photo', 0);
      INSERT INTO media_upload_requests VALUES ('owner', 'live-key', 'kept-upload-hash', 'photo', 5);
      INSERT INTO media_upload_requests VALUES ('owner', 'deleted-key', 'deleted-hash', NULL, 6);
      PRAGMA foreign_keys = OFF;
      CREATE TABLE media_v8 (
        id TEXT PRIMARY KEY, owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        mime_type TEXT NOT NULL CHECK(mime_type IN ('image/jpeg', 'image/png', 'image/webp')),
        byte_count INTEGER NOT NULL CHECK(byte_count > 0), bytes BLOB NOT NULL, created_at INTEGER NOT NULL
      ) STRICT;
      INSERT INTO media_v8 SELECT * FROM media;
      DROP TABLE media;
      ALTER TABLE media_v8 RENAME TO media;
      CREATE INDEX media_owner ON media(owner_id);
      PRAGMA foreign_keys = ON;
      PRAGMA user_version = 8;
    `);
    assert.throws(() => db.exec("INSERT INTO media VALUES ('movie', 'owner', 'video/mp4', 1, X'00', 7)"), /CHECK/);
    const tables = ['users', 'media', 'user_profiles', 'memories', 'memory_media', 'media_upload_requests'];
    const before = Object.fromEntries(tables.map(table => [table, db.prepare(`SELECT * FROM ${table}`).all()]));
    db.close(); db = openDatabase(path);
    assert.equal(db.prepare('PRAGMA user_version').get().user_version, 9);
    assert.equal(db.prepare('PRAGMA foreign_keys').get().foreign_keys, 1);
    for (const table of tables) assert.deepEqual(db.prepare(`SELECT * FROM ${table}`).all(), before[table], table);
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
    assert.equal(db.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
    db.exec("INSERT INTO media VALUES ('movie', 'owner', 'video/mp4', 4, X'00112233', 7)");
    db.exec("INSERT INTO memory_media VALUES ('post', 'movie', 1)");
    const backup = join(directory, 'restored.sqlite');
    await backupDatabase(path, backup);
    restored = openDatabase(backup);
    assert.deepEqual(restored.prepare("SELECT * FROM media WHERE id = 'movie'").get(), db.prepare("SELECT * FROM media WHERE id = 'movie'").get());
    assert.deepEqual(restored.prepare('PRAGMA foreign_key_check').all(), []);
    db.exec("DELETE FROM memories; UPDATE user_profiles SET avatar_media_id = NULL; DELETE FROM media WHERE id = 'photo';");
    assert.equal(db.prepare("SELECT media_id FROM media_upload_requests WHERE request_id = 'live-key'").get().media_id, null);
    db.exec("DELETE FROM users WHERE id = 'owner';");
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM media').get().n, 0, 'owner cascade still deletes movie bytes');
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM media_upload_requests').get().n, 0);
  } finally { restored?.close(); db.close(); await rm(directory, { recursive: true, force: true }); }
});
