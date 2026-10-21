CREATE TABLE users (
    id TEXT PRIMARY KEY,
    handle TEXT NOT NULL UNIQUE COLLATE NOCASE,
    password_hash TEXT NOT NULL,
    created_at INTEGER NOT NULL
) STRICT;

CREATE TABLE sessions (
    token_hash TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at INTEGER NOT NULL
) STRICT;
CREATE INDEX sessions_expiration ON sessions(expires_at);

-- Photos stay in this local database so metadata and bytes have one backup.
-- A deployed service should move bytes to private object storage behind the
-- same authorization boundary, not expose these IDs as public static files.
CREATE TABLE media (
    id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    mime_type TEXT NOT NULL CHECK(mime_type IN ('image/jpeg', 'image/png', 'image/webp')),
    byte_count INTEGER NOT NULL CHECK(byte_count > 0),
    bytes BLOB NOT NULL,
    created_at INTEGER NOT NULL
) STRICT;
CREATE INDEX media_owner ON media(owner_id);

-- A shared landmark has no audience. Each person's individual check-in does.
CREATE TABLE places (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    category TEXT NOT NULL CHECK(category IN
        ('viewpoint', 'restaurant', 'coffee', 'nightlife', 'art', 'market', 'other')),
    latitude REAL NOT NULL CHECK(latitude BETWEEN -90 AND 90),
    longitude REAL NOT NULL CHECK(longitude BETWEEN -180 AND 180)
) STRICT;

CREATE TABLE memories (
    id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK(kind IN ('poi', 'reel')),
    visibility TEXT NOT NULL CHECK(visibility IN ('public', 'private')),
    latitude REAL NOT NULL CHECK(latitude BETWEEN -90 AND 90),
    longitude REAL NOT NULL CHECK(longitude BETWEEN -180 AND 180),
    caption TEXT NOT NULL,
    place_id TEXT REFERENCES places(id),
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    request_hash TEXT NOT NULL,
    CHECK((kind = 'poi' AND place_id IS NOT NULL AND caption = '') OR
          (kind = 'reel' AND place_id IS NULL))
) STRICT;
CREATE INDEX memories_owner_time ON memories(owner_id, created_at DESC, id DESC);
CREATE INDEX memories_public_time ON memories(visibility, created_at DESC, id DESC);
CREATE INDEX memories_place ON memories(place_id);

CREATE TABLE memory_media (
    memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
    media_id TEXT NOT NULL REFERENCES media(id),
    position INTEGER NOT NULL CHECK(position BETWEEN 0 AND 8),
    PRIMARY KEY(memory_id, position),
    UNIQUE(memory_id, media_id)
) STRICT;
CREATE INDEX memory_media_asset ON memory_media(media_id);
