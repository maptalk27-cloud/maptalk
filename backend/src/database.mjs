import { DatabaseSync } from 'node:sqlite';
import { chmodSync, mkdirSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

export function openDatabase(databasePath) {
  if (!databasePath || databasePath === ':memory:') {
    throw new Error('A persistent databasePath is required.');
  }
  const path = resolve(databasePath);
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const db = new DatabaseSync(path, { timeout: 5000 });
  try {
    chmodSync(path, 0o600);
    db.exec('PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL;');
    const version = db.prepare('PRAGMA user_version').get().user_version;
    if (version > 13) throw new Error('Database is newer than this server; refusing to open it.');
    if (version === 0) {
      transaction(db, () => {
        db.exec(readFileSync(new URL('./schema.sql', import.meta.url), 'utf8'));
        db.exec('PRAGMA user_version = 1;');
      });
    }
    if (version < 2) {
      transaction(db, () => {
        db.exec(`
          ALTER TABLE memories ADD COLUMN published_at INTEGER;
          UPDATE memories SET published_at = created_at WHERE visibility = 'public';
          CREATE INDEX memories_feed_time ON memories(visibility, published_at DESC, id DESC);
          CREATE TABLE deleted_memories (
            id TEXT PRIMARY KEY,
            owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            deleted_at INTEGER NOT NULL
          ) STRICT;
          PRAGMA user_version = 2;
        `);
      });
    }
    if (version < 3) {
      transaction(db, () => {
        db.exec(`
          -- Apple place identity is shared; individual check-ins remain private/public.
          CREATE TABLE place_sources (
            source_id TEXT PRIMARY KEY,
            place_id TEXT NOT NULL UNIQUE REFERENCES places(id) ON DELETE CASCADE
          ) STRICT;
          -- Hiding an archive item never deletes or changes its published record.
          CREATE TABLE archive_hidden (
            owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            kind TEXT NOT NULL CHECK(kind IN ('poi', 'reel')),
            target_id TEXT NOT NULL,
            hidden_at INTEGER NOT NULL,
            PRIMARY KEY(owner_id, kind, target_id)
          ) STRICT;
          PRAGMA user_version = 3;
        `);
      });
    }
    if (version < 4) {
      transaction(db, () => {
        db.exec(`
          CREATE TABLE IF NOT EXISTS auth_identities (
            provider TEXT NOT NULL CHECK(provider = 'apple'),
            provider_subject TEXT NOT NULL,
            user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            created_at INTEGER NOT NULL,
            PRIMARY KEY(provider, provider_subject),
            UNIQUE(provider, user_id)
          ) STRICT;
          CREATE TABLE IF NOT EXISTS apple_auth_challenges (
            id TEXT PRIMARY KEY,
            nonce_hash TEXT NOT NULL,
            expires_at INTEGER NOT NULL
          ) STRICT;
          CREATE INDEX IF NOT EXISTS apple_auth_challenges_expiration ON apple_auth_challenges(expires_at);
          PRAGMA user_version = 4;
        `);
      });
    }
    if (version < 5) {
      transaction(db, () => {
        db.exec(`
          CREATE TABLE auth_identities_v5 (
            provider TEXT NOT NULL CHECK(provider IN ('apple', 'google', 'wechat')),
            provider_subject TEXT NOT NULL,
            user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            created_at INTEGER NOT NULL,
            PRIMARY KEY(provider, provider_subject),
            UNIQUE(provider, user_id)
          ) STRICT;
          INSERT INTO auth_identities_v5 SELECT * FROM auth_identities;
          DROP TABLE auth_identities;
          ALTER TABLE auth_identities_v5 RENAME TO auth_identities;
          CREATE TABLE IF NOT EXISTS oauth_auth_challenges (
            id TEXT PRIMARY KEY,
            provider TEXT NOT NULL CHECK(provider IN ('google', 'wechat')),
            state_hash TEXT,
            expires_at INTEGER NOT NULL
          ) STRICT;
          CREATE INDEX IF NOT EXISTS oauth_auth_challenges_expiration ON oauth_auth_challenges(expires_at);
          CREATE TABLE IF NOT EXISTS oauth_used_codes (
            provider TEXT NOT NULL CHECK(provider IN ('google', 'wechat')),
            code_hash TEXT NOT NULL,
            expires_at INTEGER NOT NULL,
            PRIMARY KEY(provider, code_hash)
          ) STRICT;
          CREATE INDEX IF NOT EXISTS oauth_used_codes_expiration ON oauth_used_codes(expires_at);
          PRAGMA user_version = 5;
        `);
      });
    }
    if (version < 6) {
      transaction(db, () => {
        if (!db.prepare('PRAGMA table_info(users)').all().some(column => column.name === 'deletion_started_at')) {
          db.exec('ALTER TABLE users ADD COLUMN deletion_started_at INTEGER;');
        }
        if (!db.prepare('PRAGMA table_info(memories)').all().some(column => column.name === 'moderation_status')) {
          db.exec("ALTER TABLE memories ADD COLUMN moderation_status TEXT NOT NULL DEFAULT 'approved' CHECK(moderation_status IN ('pending', 'approved', 'rejected')); ");
        }
        db.exec(`
          CREATE TABLE IF NOT EXISTS server_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
          CREATE TABLE IF NOT EXISTS beta_members (
            user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
            status TEXT NOT NULL CHECK(status IN ('active', 'revoked')),
            updated_at INTEGER NOT NULL
          ) STRICT;
          CREATE TABLE IF NOT EXISTS beta_invites (
            id TEXT PRIMARY KEY, code_hash TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL, revoked_at INTEGER, redeemed_at INTEGER,
            redeemed_by TEXT REFERENCES users(id) ON DELETE SET NULL
          ) STRICT;
          CREATE TABLE IF NOT EXISTS user_blocks (
            blocker_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            blocked_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            created_at INTEGER NOT NULL, PRIMARY KEY(blocker_id, blocked_id), CHECK(blocker_id != blocked_id)
          ) STRICT;
          CREATE INDEX IF NOT EXISTS user_blocks_reverse ON user_blocks(blocked_id, blocker_id);
          CREATE TABLE IF NOT EXISTS content_reports (
            id TEXT PRIMARY KEY,
            reporter_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            reason TEXT NOT NULL, created_at INTEGER NOT NULL, UNIQUE(reporter_id, memory_id)
          ) STRICT;
          CREATE TABLE IF NOT EXISTS apple_refresh_tokens (
            user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
            encrypted_token TEXT NOT NULL, updated_at INTEGER NOT NULL, revoked_at INTEGER
          ) STRICT;
          CREATE TABLE IF NOT EXISTS apple_used_codes (
            code_hash TEXT PRIMARY KEY, expires_at INTEGER NOT NULL
          ) STRICT;
          PRAGMA user_version = 6;
        `);
      });
    }
    if (version < 7) {
      transaction(db, () => {
        db.exec(`
          CREATE TABLE IF NOT EXISTS user_profiles (
            user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
            avatar_media_id TEXT REFERENCES media(id) ON DELETE SET NULL
          ) STRICT;
          CREATE INDEX IF NOT EXISTS user_profiles_avatar ON user_profiles(avatar_media_id);
          -- Pre-publication review is retired. Do not revive rejected records
          -- or alter audience, publication time, expiry, blocks or deletions.
          UPDATE memories SET moderation_status = 'approved' WHERE moderation_status = 'pending';
          PRAGMA user_version = 7;
        `);
      });
    }
    if (version < 8) {
      transaction(db, () => {
        db.exec(`
          CREATE TABLE IF NOT EXISTS media_upload_requests (
            owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            request_id TEXT NOT NULL,
            request_hash TEXT NOT NULL,
            media_id TEXT REFERENCES media(id) ON DELETE SET NULL,
            created_at INTEGER NOT NULL,
            PRIMARY KEY(owner_id, request_id)
          ) STRICT;
          CREATE INDEX IF NOT EXISTS media_upload_requests_asset ON media_upload_requests(media_id);
          PRAGMA user_version = 8;
        `);
      });
    }
    if (version < 9) {
      // Rebuild only the media CHECK constraint. Disable FK actions outside the
      // transaction so DROP does not null avatars/retry maps or delete links.
      // Referencing tables continue to reference the unchanged name "media".
      db.exec('PRAGMA foreign_keys = OFF;');
      try {
        transaction(db, () => {
          db.exec(`
            CREATE TABLE media_v9 (
              id TEXT PRIMARY KEY,
              owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
              mime_type TEXT NOT NULL CHECK(mime_type IN ('image/jpeg', 'image/png', 'image/webp', 'video/mp4')),
              byte_count INTEGER NOT NULL CHECK(byte_count > 0),
              bytes BLOB NOT NULL,
              created_at INTEGER NOT NULL
            ) STRICT;
            INSERT INTO media_v9 SELECT * FROM media;
            DROP TABLE media;
            ALTER TABLE media_v9 RENAME TO media;
            CREATE INDEX media_owner ON media(owner_id);
            PRAGMA user_version = 9;
          `);
          if (db.prepare('PRAGMA foreign_key_check').all().length) throw new Error('Video migration violated a foreign key.');
        });
      } finally { db.exec('PRAGMA foreign_keys = ON;'); }
    }
    if (version < 10) {
      transaction(db, () => {
        db.exec(`
          CREATE TABLE IF NOT EXISTS media_upload_sessions (
            owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            request_id TEXT NOT NULL,
            mime_type TEXT NOT NULL CHECK(mime_type = 'video/mp4'),
            byte_count INTEGER NOT NULL CHECK(byte_count > 0 AND byte_count <= 20971520),
            sha256 TEXT NOT NULL CHECK(length(sha256) = 64),
            received_bytes INTEGER NOT NULL DEFAULT 0 CHECK(received_bytes >= 0 AND received_bytes <= byte_count),
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY(owner_id, request_id)
          ) STRICT;
          CREATE INDEX IF NOT EXISTS media_upload_sessions_expiry ON media_upload_sessions(updated_at);
          CREATE TABLE IF NOT EXISTS media_upload_chunks (
            owner_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            byte_offset INTEGER NOT NULL CHECK(byte_offset >= 0),
            bytes BLOB NOT NULL CHECK(length(bytes) > 0 AND length(bytes) <= 524288),
            PRIMARY KEY(owner_id, request_id, byte_offset),
            FOREIGN KEY(owner_id, request_id) REFERENCES media_upload_sessions(owner_id, request_id) ON DELETE CASCADE
          ) STRICT;
          PRAGMA user_version = 10;
        `);
      });
    }
    if (version < 11) {
      transaction(db, () => {
        // Directory metadata is distinct from the app's visual POI category.
        // Existing places stay ordinary; never infer an airport from its name.
        if (!db.prepare('PRAGMA table_info(places)').all().some(column => column.name === 'directory_kind')) {
          db.exec("ALTER TABLE places ADD COLUMN directory_kind TEXT CHECK(directory_kind IS NULL OR directory_kind = 'airport');");
        }
        db.exec('PRAGMA user_version = 11;');
      });
    }
    if (version < 12) {
      transaction(db, () => {
        db.exec(`
          CREATE TABLE comments (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            memory_id TEXT REFERENCES memories(id) ON DELETE CASCADE,
            place_id TEXT REFERENCES places(id) ON DELETE CASCADE,
            text TEXT NOT NULL CHECK(length(text) BETWEEN 1 AND 1000),
            created_at INTEGER NOT NULL,
            CHECK((memory_id IS NOT NULL) != (place_id IS NOT NULL))
          ) STRICT;
          CREATE INDEX comments_memory_time ON comments(memory_id, created_at DESC, id DESC);
          CREATE INDEX comments_place_time ON comments(place_id, created_at DESC, id DESC);
          CREATE INDEX comments_author_time ON comments(user_id, created_at DESC);
          PRAGMA user_version = 12;
        `);
      });
    }
    if (version < 13) {
      transaction(db, () => {
        db.exec(`
          -- A cluster is an immutable authored attachment, not a live folder or
          -- a foreign key to its source records. Deleting a source keeps it intact.
          CREATE TABLE IF NOT EXISTS memory_clusters (
            memory_id TEXT PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,
            title TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 160),
            members_json TEXT NOT NULL CHECK(json_valid(members_json)
              AND json_type(members_json) = 'array' AND json_array_length(members_json) BETWEEN 1 AND 50)
          ) STRICT;
          CREATE TABLE IF NOT EXISTS cluster_media (
            memory_id TEXT NOT NULL REFERENCES memory_clusters(memory_id) ON DELETE CASCADE,
            media_id TEXT NOT NULL REFERENCES media(id),
            PRIMARY KEY(memory_id, media_id)
          ) STRICT;
          CREATE INDEX IF NOT EXISTS cluster_media_asset ON cluster_media(media_id);
          PRAGMA user_version = 13;
        `);
      });
    }
    return db;
  } catch (error) {
    db.close();
    throw error;
  }
}

// Callbacks must be synchronous: never leave a transaction open across await.
export function transaction(db, work) {
  db.exec('BEGIN IMMEDIATE');
  try {
    const result = work();
    db.exec('COMMIT');
    return result;
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  }
}
