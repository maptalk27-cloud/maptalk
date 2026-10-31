import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { openDatabase, transaction } from './database.mjs';
import { digest, hashPassword, issueSession, verifyPassword } from './security.mjs';
import { AppleAuthError, createAppleAuthentication } from './apple-auth.mjs';
import { SocialAuthError, createSocialAuthentication } from './social-auth.mjs';
import { AppleLifecycleError } from './apple-lifecycle.mjs';
import { BetaError, betaAccess, createConcurrentGate, deploymentConfiguration, redeemInvite, requireBetaAccess } from './beta.mjs';
import { normalizePhoto, PhotoProcessingError } from './photo-processing.mjs';
import { normalizeVideo, VIDEO_LIMITS, VideoProcessingError } from './video-processing.mjs';
import { mediaByteRange, sendMediaBytes } from './media-range.mjs';
import { mediaJSON, userJSON } from './user-profile.mjs';
import { reclaimUnreferencedMedia, userMediaLimitBytes as validateMediaLimit } from './media-storage.mjs';
import { createResumableUploads, ResumableUploadError, UPLOAD_CHUNK_SIZE } from './resumable-uploads.mjs';

const ACTIVE_FEED_WINDOW = 72 * 60 * 60 * 1000;
// Derive activity from first publication so existing 24-hour rows follow the
// current policy without rewriting history. Legacy/private rows fall back to
// their original local publication/save time.
const PUBLICATION_TIME_SQL = 'COALESCE(published_at, created_at)';
const PHOTO_LIMIT = 10 * 1024 * 1024;
const CATEGORIES = ['viewpoint', 'restaurant', 'coffee', 'nightlife', 'art', 'market', 'hotel', 'airport', 'other'];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

class APIError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function requireValue(condition, message = 'Invalid request.') {
  if (!condition) throw new APIError(422, 'invalid_request', message);
}

function notFound() {
  return new APIError(404, 'not_found', 'Not found.');
}

function object(value, allowed) {
  requireValue(value !== null && typeof value === 'object' && !Array.isArray(value));
  requireValue(Object.keys(value).every(key => allowed.includes(key)), 'Unexpected field.');
  return value;
}

function id(value) {
  requireValue(typeof value === 'string' && UUID.test(value), 'Expected a UUID.');
  return value.toLowerCase();
}

function visibility(value) {
  requireValue(value === 'public' || value === 'private', 'Choose public or private.');
  return value;
}

function coordinate(value) {
  object(value, ['latitude', 'longitude']);
  const { latitude, longitude } = value;
  requireValue(typeof latitude === 'number' && Number.isFinite(latitude) && Math.abs(latitude) <= 90,
    'Latitude must be between -90 and 90.');
  requireValue(typeof longitude === 'number' && Number.isFinite(longitude) && Math.abs(longitude) <= 180,
    'Longitude must be between -180 and 180.');
  return { latitude, longitude };
}

function distanceInMeters(a, b) {
  const radians = degrees => degrees * Math.PI / 180;
  const latitude = radians(b.latitude - a.latitude);
  const longitude = radians(b.longitude - a.longitude);
  const haversine = Math.sin(latitude / 2) ** 2
    + Math.cos(radians(a.latitude)) * Math.cos(radians(b.latitude)) * Math.sin(longitude / 2) ** 2;
  return 6_371_000 * 2 * Math.asin(Math.sqrt(Math.min(1, haversine)));
}

function requireNearbyPlace(location, place, directoryKind) {
  const radius = directoryKind === 'airport' ? 2000 : 150;
  requireValue(distanceInMeters(location, place) <= radius,
    `Choose a place within ${radius} meters of the supplied location.`);
}

function handle(value) {
  requireValue(typeof value === 'string' && value.length >= 3 && value.length <= 32 && !/[^a-zA-Z0-9_]/.test(value),
    'Handle must be 3–32 letters, digits or underscores.');
  return value.toLowerCase();
}

function credentials(body) {
  object(body, ['handle', 'password']);
  const name = handle(body.handle);
  requireValue(typeof body.password === 'string' && body.password.length >= 12 && body.password.length <= 128,
    'Password must be 12–128 characters.');
  return { handle: name, password: body.password };
}

function memoryInput(body, time) {
  object(body, ['id', 'kind', 'visibility', 'location', 'caption', 'mediaIds', 'place', 'placeId', 'capturedAt', 'cluster']);
  const result = {
    id: id(body.id), kind: body.kind, visibility: visibility(body.visibility),
    location: coordinate(body.location), caption: body.caption ?? '',
    mediaIds: body.mediaIds ?? [], place: null, placeId: null,
  };
  if (body.capturedAt !== undefined) {
    requireValue(typeof body.capturedAt === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/.test(body.capturedAt),
      'Capture time must be an ISO 8601 UTC timestamp.');
    const captured = Date.parse(body.capturedAt);
    requireValue(Number.isSafeInteger(captured) && captured >= Date.UTC(2000, 0, 1) && captured <= time + 5 * 60_000,
      'Capture time must be a valid past time (up to five minutes of clock skew).');
    requireValue(new Date(captured).toISOString().slice(0, 19) === body.capturedAt.slice(0, 19),
      'Capture time must be a valid calendar date.');
    // This legacy wire name is the first local publish/save tap, not the media's
    // camera timestamp. Keep it stable for retries; clamp minor clock skew only
    // when storing it. Omitting this field preserves old request hashes.
    result.capturedAt = new Date(captured).toISOString();
  }
  requireValue(result.kind === 'poi' || result.kind === 'reel', 'Kind must be poi or reel.');
  requireValue(typeof result.caption === 'string' && result.caption.length <= 2200, 'Caption is too long.');
  result.caption = result.caption.trim();
  requireValue(Array.isArray(result.mediaIds) && result.mediaIds.length <= (result.kind === 'poi' ? 1 : 9),
    'POI allows at most one photo; Reel allows at most nine.');
  result.mediaIds = result.mediaIds.map(id);
  requireValue(new Set(result.mediaIds).size === result.mediaIds.length, 'Duplicate media.');
  if (body.cluster !== undefined) {
    requireValue(result.kind === 'reel', 'Only a Reel can contain a cluster.');
    object(body.cluster, ['title', 'memoryIds']);
    requireValue(typeof body.cluster.title === 'string' && body.cluster.title.trim().length > 0
      && body.cluster.title.length <= 160, 'A cluster needs a title of at most 160 characters.');
    requireValue(Array.isArray(body.cluster.memoryIds) && body.cluster.memoryIds.length >= 1
      && body.cluster.memoryIds.length <= 50, 'Choose between 1 and 50 records.');
    const memoryIds = body.cluster.memoryIds.map(id);
    requireValue(new Set(memoryIds).size === memoryIds.length, 'Duplicate cluster record.');
    requireValue(!memoryIds.includes(result.id), 'A Reel cannot contain itself.');
    // Do not add a default field: old persisted retry hashes must stay identical.
    result.cluster = { title: body.cluster.title.trim(), memoryIds };
  }
  if (result.kind === 'poi') {
    requireValue(result.caption === '', 'POI check-ins do not have captions.');
    requireValue((body.place !== undefined) !== (body.placeId !== undefined), 'Choose one place or placeId.');
    if (body.place !== undefined) {
      object(body.place, ['name', 'category', 'coordinate', 'sourceId', 'directoryKind']);
      requireValue(typeof body.place.name === 'string' && body.place.name.trim().length > 0
        && body.place.name.length <= 160, 'A place needs a name of at most 160 characters.');
      requireValue(CATEGORIES.includes(body.place.category), 'Invalid place category.');
      result.place = { name: body.place.name.trim(), category: body.place.category };
      if (body.place.coordinate !== undefined) result.place.coordinate = coordinate(body.place.coordinate);
      if (body.place.sourceId !== undefined) result.place.sourceId = id(body.place.sourceId);
      if (body.place.directoryKind !== undefined) {
        requireValue(body.place.directoryKind === 'airport', 'Unsupported directory place type.');
        requireValue(result.place.sourceId !== undefined && result.place.coordinate !== undefined,
          'An airport needs its directory identity and center coordinate.');
        // Omit when absent so queued pre-airport request hashes remain valid.
        result.place.directoryKind = body.place.directoryKind;
      }
    } else {
      result.placeId = id(body.placeId);
    }
  } else {
    requireValue(body.place === undefined && body.placeId === undefined, 'Reels are not POI check-ins.');
    requireValue(result.caption.length > 0 || result.mediaIds.length > 0 || result.cluster, 'Add a caption, media or cluster.');
  }
  return result;
}

function readBytes(request, limit, timeoutMs = 15_000) {
  if (request.headers['content-encoding'] && request.headers['content-encoding'] !== 'identity') {
    request.resume();
    throw new APIError(415, 'unsupported_encoding', 'Compressed request bodies are not supported.');
  }
  if (Number(request.headers['content-length']) > limit) {
    request.resume();
    throw new APIError(413, 'body_too_large', 'Upload is too large.');
  }
  return new Promise((resolve, reject) => {
    let chunks = [];
    let size = 0;
    let failed = false;
    const timer = setTimeout(() => {
      failed = true; chunks = [];
      reject(new APIError(408, 'upload_timeout', 'The upload took too long. Please try again.'));
    }, timeoutMs);
    timer.unref();
    request.on('data', chunk => {
      if (failed) return;
      size += chunk.length;
      if (size > limit) {
        failed = true;
        clearTimeout(timer);
        chunks = [];
        reject(new APIError(413, 'body_too_large', 'Upload is too large.'));
      } else {
        chunks.push(chunk);
      }
    });
    request.on('end', () => { clearTimeout(timer); if (!failed) resolve(Buffer.concat(chunks)); });
    request.on('error', error => { clearTimeout(timer); reject(error); });
    request.on('aborted', () => { clearTimeout(timer); reject(new APIError(400, 'incomplete_body', 'Incomplete request.')); });
  });
}

async function readJSON(request) {
  if (request.headers['content-type']?.split(';')[0].trim().toLowerCase() !== 'application/json') {
    throw new APIError(415, 'unsupported_type', 'Use application/json.');
  }
  const bytes = await readBytes(request, 64 * 1024);
  try {
    return JSON.parse(bytes.toString('utf8'));
  } catch {
    throw new APIError(400, 'invalid_json', 'Invalid JSON.');
  }
}

function imageType(bytes) {
  if (bytes.length >= 8 && bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
    return 'image/png';
  }
  if (bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg';
  if (bytes.length >= 12 && bytes.toString('ascii', 0, 4) === 'RIFF'
    && bytes.toString('ascii', 8, 12) === 'WEBP') return 'image/webp';
  return null;
}

function pageInput(params, extraKeys = []) {
  requireValue([...params.keys()].every(key => ['limit', 'cursor', ...extraKeys].includes(key)), 'Unknown query parameter.');
  requireValue([...new Set(params.keys())].every(key => params.getAll(key).length === 1), 'Duplicate query parameter.');
  const limit = params.has('limit') ? Number(params.get('limit')) : 50;
  requireValue(Number.isInteger(limit) && limit >= 1 && limit <= 100, 'Limit must be 1–100.');
  let cursor = null;
  if (params.has('cursor')) {
    const raw = params.get('cursor');
    requireValue(raw.length <= 256 && /^[a-zA-Z0-9_-]+$/.test(raw), 'Invalid cursor.');
    try {
      cursor = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8'));
    } catch {
      throw new APIError(422, 'invalid_request', 'Invalid cursor.');
    }
    object(cursor, ['createdAt', 'id']);
    requireValue(Number.isSafeInteger(cursor.createdAt) && cursor.createdAt >= 0, 'Invalid cursor.');
    cursor.id = id(cursor.id);
  }
  return { limit, cursor };
}

function bounds(params) {
  const values = ['west', 'east', 'south', 'north'].map(key => {
    requireValue(params.has(key) && params.get(key).trim() !== '', 'Map requires west, east, south and north.');
    const number = Number(params.get(key));
    requireValue(Number.isFinite(number), 'Invalid map bounds.');
    return number;
  });
  const [west, east, south, north] = values;
  requireValue(Math.abs(west) <= 180 && Math.abs(east) <= 180
    && Math.abs(south) <= 90 && Math.abs(north) <= 90 && south <= north, 'Invalid map bounds.');
  return { west, east, south, north };
}

/** Local by default; beta requires explicit HTTPS proxy origin and opt-in. */
export function createBackend({ databasePath, now = () => Date.now(), authLimit = 30, apple = {}, google = {}, wechat = {}, deployment = {}, userMediaLimitBytes }) {
  const storageLimit = validateMediaLimit(userMediaLimitBytes);
  const hosting = deploymentConfiguration(deployment);
  const isBeta = hosting.mode === 'beta';
  const db = openDatabase(databasePath);
  let appleAuth;
  let socialAuth;
  try {
    const storedMode = db.prepare("SELECT value FROM server_metadata WHERE key = 'deployment_mode'").get()?.value;
    if (storedMode === 'beta' && !isBeta) throw new Error('A beta database cannot be opened by the local/password server.');
    if (isBeta && storedMode !== 'beta') {
      const occupied = ['users', 'memories', 'media'].some(table => db.prepare(`SELECT 1 FROM ${table} LIMIT 1`).get());
      if (occupied) throw new Error('Start beta with a new empty database. Local test media and accounts cannot be promoted to hosted beta.');
    }
    appleAuth = createAppleAuthentication({ db, now, ...apple, requireLifecycle: isBeta });
    socialAuth = createSocialAuthentication({ db, now, google, wechat });
    if (isBeta && !apple.clientID && !socialAuth.providers().some(provider => provider.available)) {
      throw new Error('Beta requires at least one configured real identity provider.');
    }
    if (isBeta) db.prepare("INSERT OR IGNORE INTO server_metadata(key, value) VALUES ('deployment_mode', 'beta')").run();
  } catch (error) { db.close(); throw error; }
  let closed = false;
  let authInFlight = 0;
  let authWindow = { since: now(), count: 0 };
  const acquireUpload = createConcurrentGate(2);
  const acquireDownload = createConcurrentGate(8);
  const mutationWindows = new Map();
  const transferWindows = new Map();
  const deletionTasks = new Map();
  let mediaErrorWindow = { since: now(), count: 0 };
  function assertUploadOwner(ownerID) {
    requireBetaAccess(db, ownerID, isBeta);
    const current = db.prepare('SELECT deletion_started_at FROM users WHERE id = ?').get(ownerID);
    if (!current || current.deletion_started_at !== null) throw new APIError(409, 'account_deleting', 'This account is being deleted.');
  }
  const resumable = createResumableUploads({ db, now, storageLimit, assertOwner: assertUploadOwner });
  resumable.expire();
  const uploadCleanup = setInterval(() => resumable.expire(), 60 * 60 * 1000);
  uploadCleanup.unref();

  function deleteAccount(userID) {
    if (deletionTasks.has(userID)) return deletionTasks.get(userID);
    const task = (async () => {
      appleAuth.preflightDeletion(userID);
      db.prepare('UPDATE users SET deletion_started_at = COALESCE(deletion_started_at, ?) WHERE id = ?').run(now(), userID);
      try { await appleAuth.revokeUser(userID); }
      catch (error) {
        // A failed remote revoke remains retryable without locking out the user.
        db.prepare('UPDATE users SET deletion_started_at = NULL WHERE id = ?').run(userID);
        throw error;
      }
      transaction(db, () => {
        // Explicit order avoids memory_media's non-cascading media FK.
        db.prepare('DELETE FROM memories WHERE owner_id = ?').run(userID);
        db.prepare('DELETE FROM users WHERE id = ?').run(userID);
        db.prepare('DELETE FROM places WHERE NOT EXISTS (SELECT 1 FROM memories WHERE place_id = places.id)').run();
      });
    })().finally(() => deletionTasks.delete(userID));
    deletionTasks.set(userID, task);
    return task;
  }

  function mutationLimit(userID, response) {
    if (!isBeta) return;
    const time = now();
    for (const [key, value] of mutationWindows) if (time - value.since >= 60_000) mutationWindows.delete(key);
    const window = mutationWindows.get(userID) ?? { since: time, count: 0 };
    mutationWindows.set(userID, window);
    if (++window.count > 60) {
      response.setHeader('Retry-After', '60');
      throw new APIError(429, 'rate_limited', 'Too many changes; try again shortly.');
    }
  }

  function transferLimit(userID, response) {
    if (!isBeta) return;
    const time = now();
    for (const [key, value] of transferWindows) if (time - value.since >= 60_000) transferWindows.delete(key);
    const window = transferWindows.get(userID) ?? { since: time, count: 0 };
    transferWindows.set(userID, window);
    // A maximum-size video has 40 chunks. Transfer traffic must not consume
    // the separate budget for cancel/delete/profile changes. This still bounds
    // accepted payload to <=60 MiB/min/user, in addition to storage/concurrency caps.
    if (++window.count > 120) {
      response.setHeader('Retry-After', String(Math.max(1, Math.ceil((60_000 - (time - window.since)) / 1000))));
      throw new APIError(429, 'upload_rate_limited', 'Upload paused briefly. Continue after the indicated delay.');
    }
  }

  function userFor(request) {
    const header = request.headers.authorization;
    if (typeof header !== 'string' || !/^Bearer [a-zA-Z0-9_-]{43}$/.test(header)) {
      throw new APIError(401, 'unauthorized', 'Sign in to continue.');
    }
    const user = db.prepare(`SELECT users.id, users.handle, users.deletion_started_at FROM sessions
      JOIN users ON users.id = sessions.user_id WHERE token_hash = ? AND expires_at > ?`)
      .get(digest(header.slice(7)), now());
    if (!user) throw new APIError(401, 'unauthorized', 'Session expired or invalid.');
    return { id: user.id, handle: user.handle, deletionStartedAt: user.deletion_started_at };
  }

  function blocked(viewerID, ownerID) {
    return Boolean(db.prepare(`SELECT 1 FROM user_blocks WHERE
      (blocker_id = ? AND blocked_id = ?) OR (blocker_id = ? AND blocked_id = ?)`).get(viewerID, ownerID, ownerID, viewerID));
  }
  function visibleOwner(viewerID, ownerID) {
    if (viewerID === ownerID) return true;
    const owner = db.prepare('SELECT deletion_started_at FROM users WHERE id = ?').get(ownerID);
    return owner && owner.deletion_started_at === null && !blocked(viewerID, ownerID)
      && (!isBeta || betaAccess(db, ownerID, true).status === 'active');
  }
  function checkCurrentUser(userID) {
    const current = db.prepare('SELECT deletion_started_at FROM users WHERE id = ?').get(userID);
    if (!current || current.deletion_started_at !== null) throw new APIError(409, 'account_deleting', 'This account is being deleted.');
    requireBetaAccess(db, userID, isBeta);
  }
  async function authorizedJSON(request, userID) {
    const result = await readJSON(request);
    checkCurrentUser(userID);
    return result;
  }
  function visibilitySQL(column = 'memories.owner_id') {
    return `NOT EXISTS (SELECT 1 FROM user_blocks b WHERE (b.blocker_id = ? AND b.blocked_id = ${column})
      OR (b.blocked_id = ? AND b.blocker_id = ${column}))
      AND EXISTS (SELECT 1 FROM users visible_owner WHERE visible_owner.id = ${column} AND visible_owner.deletion_started_at IS NULL)
      ${isBeta ? `AND EXISTS (SELECT 1 FROM beta_members bm WHERE bm.user_id = ${column} AND bm.status = 'active')` : ''}`;
  }

  function memoryFor(memoryID, userID, ownerOnly = false) {
    const row = db.prepare('SELECT * FROM memories WHERE id = ?').get(memoryID);
    if (!row || (row.owner_id !== userID && (ownerOnly || row.visibility !== 'public'
      || row.moderation_status !== 'approved' || !visibleOwner(userID, row.owner_id)))) throw notFound();
    return row;
  }

  function serializeMemory(row, includeCluster = true) {
    const owner = db.prepare('SELECT id, handle FROM users WHERE id = ?').get(row.owner_id);
    const place = row.place_id ? db.prepare(`SELECT places.*, place_sources.source_id FROM places
      LEFT JOIN place_sources ON place_sources.place_id = places.id WHERE places.id = ?`).get(row.place_id) : null;
    const media = db.prepare(`SELECT media.id, media.mime_type, media.byte_count FROM memory_media
      JOIN media ON media.id = memory_media.media_id WHERE memory_id = ? ORDER BY position`).all(row.id);
    const cluster = includeCluster
      ? db.prepare('SELECT title, members_json FROM memory_clusters WHERE memory_id = ?').get(row.id) : null;
    return {
      id: row.id, ownerId: row.owner_id, owner: userJSON(db, owner),
      kind: row.kind, visibility: row.visibility,
      moderationStatus: row.moderation_status,
      location: { latitude: row.latitude, longitude: row.longitude }, caption: row.caption,
      place: place ? { id: place.id, name: place.name, category: place.category, sourceId: place.source_id,
        ...(place.directory_kind ? { directoryKind: place.directory_kind } : {}),
        coordinate: { latitude: place.latitude, longitude: place.longitude } } : null,
      media: media.map(mediaJSON), createdAt: new Date(row.created_at).toISOString(),
      publishedAt: row.published_at === null ? null : new Date(row.published_at).toISOString(),
      expiresAt: new Date((row.published_at ?? row.created_at) + ACTIVE_FEED_WINDOW).toISOString(),
      ...(cluster ? { cluster: { id: row.id, title: cluster.title, members: JSON.parse(cluster.members_json) } } : {}),
    };
  }

  function publicCommentTarget(kind, targetID, viewerID) {
    if (kind === 'memories') {
      const memory = memoryFor(targetID, viewerID);
      // A private archive is not a public discussion, even for its owner.
      if (memory.visibility !== 'public' || memory.moderation_status !== 'approved'
        || !visibleOwner(viewerID, memory.owner_id)) throw notFound();
    } else {
      // A directory ID alone never grants access to private check-ins.
      const visible = db.prepare(`SELECT 1 FROM memories WHERE place_id = ?
        AND visibility = 'public' AND moderation_status = 'approved' AND ${visibilitySQL()} LIMIT 1`)
        .get(targetID, viewerID, viewerID);
      if (!visible) throw notFound();
    }
  }

  function serializeComment(row) {
    const author = db.prepare('SELECT id, handle FROM users WHERE id = ?').get(row.user_id);
    return { id: row.id, userId: row.user_id, text: row.text,
      createdAt: new Date(row.created_at).toISOString(), author: userJSON(db, author) };
  }

  function listMemories(where, args, { limit, cursor }, orderBy = PUBLICATION_TIME_SQL) {
    // Column names come only from these internal callers, never client input.
    if (cursor) {
      where += ` AND (${orderBy} < ? OR (${orderBy} = ? AND id < ?))`;
      args.push(cursor.createdAt, cursor.createdAt, cursor.id);
    }
    const rows = db.prepare(`SELECT *, ${orderBy} AS list_order FROM memories WHERE ${where} ORDER BY ${orderBy} DESC, id DESC LIMIT ?`)
      .all(...args, limit + 1);
    const items = rows.slice(0, limit);
    const last = items.at(-1);
    return {
      items: items.map(row => serializeMemory(row)),
      nextCursor: rows.length > limit ? Buffer.from(JSON.stringify({ createdAt: last.list_order, id: last.id })).toString('base64url') : null,
    };
  }

  function json(response, status, body) {
    response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
    response.end(body === undefined ? undefined : JSON.stringify(body));
  }

  async function route(request, response) {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Content-Security-Policy', "default-src 'none'; frame-ancestors 'none'");
    // Refuse DNS rebinding and browser requests from unrelated origins.
    const port = server.address()?.port;
    const allowedHosts = isBeta ? [hosting.publicHost] : [`127.0.0.1:${port}`, `localhost:${port}`];
    const allowedOrigins = isBeta ? [hosting.publicOrigin] : allowedHosts.map(host => `http://${host}`);
    if (!allowedHosts.includes(request.headers.host)
      || (request.headers.origin && !allowedOrigins.includes(request.headers.origin))
      || !request.url.startsWith('/') || request.url.startsWith('//')) {
      throw new APIError(403, isBeta ? 'untrusted_origin' : 'local_only', 'This request origin is not allowed.');
    }
    if (isBeta) response.setHeader('Strict-Transport-Security', 'max-age=31536000');
    const url = new URL(request.url, 'http://127.0.0.1');
    const path = url.pathname;
    const method = request.method;
    if (method === 'GET' && path === '/health') {
      return json(response, 200, { status: 'ok', mode: isBeta ? 'private-beta' : 'local-development', apiVersion: 1 });
    }
    if (method === 'GET' && path === '/v1/auth/providers') {
      return json(response, 200, { providers: [
        { id: 'apple', available: Boolean(apple.clientID), ...(!apple.clientID ? {
          reason: 'Apple sign-in is not configured on this development server yet.',
        } : {}) }, ...socialAuth.providers(),
      ] });
    }

    if (method === 'POST' && ['/v1/auth/register', '/v1/auth/login',
      '/v1/auth/apple/challenge', '/v1/auth/apple', '/v1/auth/google/challenge', '/v1/auth/google',
      '/v1/auth/wechat/challenge', '/v1/auth/wechat'].includes(path)) {
      const time = now();
      if (time - authWindow.since >= 60_000) authWindow = { since: time, count: 0 };
      if (++authWindow.count > authLimit || authInFlight >= 4) {
        response.setHeader('Retry-After', '60');
        throw new APIError(429, 'rate_limited', 'Too many attempts; try again later.');
      }
      authInFlight++;
      try {
        if (isBeta && ['/v1/auth/register', '/v1/auth/login'].includes(path)) {
          throw new APIError(403, 'password_auth_disabled', 'Use Apple, Google or WeChat to join this private beta.');
        }
        if (path === '/v1/auth/apple/challenge') {
          object(await readJSON(request), []);
          return json(response, 200, appleAuth.challenge());
        }
        if (path === '/v1/auth/apple') {
          const input = object(await readJSON(request), ['challengeId', 'identityToken', 'authorizationCode']);
          input.challengeId = id(input.challengeId);
          requireValue(typeof input.identityToken === 'string' && input.identityToken.length <= 16_384,
            'Provide the Apple identity token.');
          if (input.authorizationCode !== undefined) requireValue(typeof input.authorizationCode === 'string'
            && /^[\x21-\x7e]{1,4096}$/.test(input.authorizationCode), 'Provide the Apple authorization code.');
          return json(response, 200, await appleAuth.exchange(input));
        }
        const social = /^\/v1\/auth\/(google|wechat)(\/challenge)?$/.exec(path);
        if (social) {
          const provider = social[1];
          if (social[2]) {
            object(await readJSON(request), []);
            return json(response, 200, socialAuth.challenge(provider));
          }
          const input = object(await readJSON(request), ['challengeId', 'code', ...(provider === 'wechat' ? ['state'] : [])]);
          input.challengeId = id(input.challengeId);
          requireValue(typeof input.code === 'string' && /^[\x21-\x7e]{1,4096}$/.test(input.code),
            'Provide the sign-in authorization code.');
          if (provider === 'wechat') {
            requireValue(typeof input.state === 'string' && /^[A-Za-z0-9_-]{43}$/.test(input.state),
              'Provide the sign-in request state.');
          }
          return json(response, 200, await socialAuth.exchange(provider, input));
        }
        const input = credentials(await readJSON(request));
        if (path.endsWith('/register')) {
          const passwordHash = await hashPassword(input.password);
          const result = transaction(db, () => {
            if (db.prepare('SELECT id FROM users WHERE handle = ?').get(input.handle)) {
              throw new APIError(409, 'handle_taken', 'Handle is already registered.');
            }
            const user = { id: randomUUID(), handle: input.handle };
            db.prepare('INSERT INTO users(id, handle, password_hash, created_at) VALUES (?, ?, ?, ?)')
              .run(user.id, user.handle, passwordHash, now());
            return { user: userJSON(db, user), ...issueSession(db, user.id, now()) };
          });
          return json(response, 201, result);
        }
        const stored = db.prepare('SELECT * FROM users WHERE handle = ?').get(input.handle);
        const matches = await verifyPassword(input.password, stored?.password_hash || undefined);
        // Password verification awaits: a concurrent rename/deletion must not
        // return stale profile data or issue a session for a vanished account.
        const current = stored && db.prepare('SELECT id, handle, deletion_started_at FROM users WHERE id = ?').get(stored.id);
        if (!current || !matches || current.handle !== input.handle || current.deletion_started_at !== null) {
          throw new APIError(401, 'invalid_credentials', 'Invalid handle or password.');
        }
        return json(response, 200, { user: userJSON(db, current), ...issueSession(db, current.id, now()) });
      } finally {
        authInFlight--;
      }
    }

    const user = userFor(request);
    const resumableMatch = /^\/v1\/media\/uploads\/([^/]+)(\/complete)?$/.exec(path);
    const isTransfer = resumableMatch && ((!resumableMatch[2] && ['PUT', 'PATCH'].includes(method))
      || (resumableMatch[2] && method === 'POST'));
    if (isTransfer) transferLimit(user.id, response);
    else if (method !== 'GET') mutationLimit(user.id, response);
    if (method === 'DELETE' && path === '/v1/me') {
      await deleteAccount(user.id);
      return json(response, 204);
    }
    if (method === 'POST' && path === '/v1/auth/logout') {
      db.prepare('DELETE FROM sessions WHERE token_hash = ?').run(digest(request.headers.authorization.slice(7)));
      return json(response, 204);
    }
    if (user.deletionStartedAt !== null) throw new APIError(409, 'account_deleting', 'Account deletion is in progress. Please retry deletion.');
    if (method === 'GET' && path === '/v1/me') return json(response, 200, { user: userJSON(db, user) });
    if (method === 'GET' && path === '/v1/beta/access') return json(response, 200, betaAccess(db, user.id, isBeta));
    if (method === 'POST' && path === '/v1/beta/redeem') {
      const body = object(await readJSON(request), ['code']);
      const current = db.prepare('SELECT deletion_started_at FROM users WHERE id = ?').get(user.id);
      if (!current || current.deletion_started_at !== null) throw new APIError(409, 'account_deleting', 'This account is being deleted.');
      redeemInvite(db, user.id, body.code, now());
      return json(response, 204);
    }
    requireBetaAccess(db, user.id, isBeta);

    const commentMatch = /^\/v1\/(memories|places)\/([^/]+)\/comments$/.exec(path);
    if (commentMatch && (method === 'GET' || method === 'POST')) {
      const kind = commentMatch[1];
      const targetID = id(commentMatch[2]);
      const column = kind === 'memories' ? 'memory_id' : 'place_id';
      const body = method === 'POST' ? await authorizedJSON(request, user.id) : null;
      publicCommentTarget(kind, targetID, user.id);
      if (method === 'GET') {
        const { limit, cursor } = pageInput(url.searchParams);
        const after = cursor ? 'AND (created_at < ? OR (created_at = ? AND id < ?))' : '';
        const args = [targetID, user.id, user.id];
        if (cursor) args.push(cursor.createdAt, cursor.createdAt, cursor.id);
        const rows = db.prepare(`SELECT * FROM comments WHERE ${column} = ?
          AND ${visibilitySQL('comments.user_id')} ${after}
          ORDER BY created_at DESC, id DESC LIMIT ?`).all(...args, limit + 1);
        const items = rows.slice(0, limit);
        const last = items.at(-1);
        return json(response, 200, { items: items.map(serializeComment),
          nextCursor: rows.length > limit ? Buffer.from(JSON.stringify({
            createdAt: last.created_at, id: last.id,
          })).toString('base64url') : null });
      }
      object(body, ['id', 'text']);
      const commentID = id(body.id);
      requireValue(typeof body.text === 'string' && body.text.trim().length > 0 && body.text.length <= 1000,
        'Write a comment of up to 1000 characters.');
      const text = body.text.trim();
      const existing = db.prepare('SELECT * FROM comments WHERE id = ?').get(commentID);
      if (existing) {
        if (existing.user_id !== user.id || existing[column] !== targetID || existing.text !== text) {
          throw new APIError(409, 'id_conflict', 'Use a new ID for a different comment.');
        }
        return json(response, 200, serializeComment(existing));
      }
      const recent = db.prepare('SELECT COUNT(*) AS count FROM comments WHERE user_id = ? AND created_at > ?')
        .get(user.id, now() - 60_000).count;
      if (recent >= 12) {
        response.setHeader('Retry-After', '60');
        throw new APIError(429, 'rate_limited', 'Please wait a moment before commenting again.');
      }
      db.prepare('INSERT INTO comments(id, user_id, memory_id, place_id, text, created_at) VALUES (?, ?, ?, ?, ?, ?)')
        .run(commentID, user.id, kind === 'memories' ? targetID : null, kind === 'places' ? targetID : null, text, now());
      // Discussion is not a new visit/publication: do not mutate memory time,
      // feed membership, media, or the user's current location.
      return json(response, 201, serializeComment(db.prepare('SELECT * FROM comments WHERE id = ?').get(commentID)));
    }

    if (method === 'PATCH' && path === '/v1/me') {
      const body = object(await authorizedJSON(request, user.id), ['handle', 'avatarMediaId']);
      const name = handle(body.handle);
      const changingAvatar = Object.hasOwn(body, 'avatarMediaId');
      const avatarID = changingAvatar && body.avatarMediaId !== null ? id(body.avatarMediaId) : null;
      const updated = transaction(db, () => {
        if (db.prepare('SELECT 1 FROM users WHERE handle = ? AND id != ?').get(name, user.id)) {
          throw new APIError(409, 'handle_taken', 'Handle is already registered.');
        }
        if (avatarID && !db.prepare(`SELECT 1 FROM media WHERE id = ? AND owner_id = ?
          AND mime_type IN ('image/jpeg', 'image/png', 'image/webp')`).get(avatarID, user.id)) throw notFound();
        const previous = db.prepare('SELECT avatar_media_id FROM user_profiles WHERE user_id = ?').get(user.id)?.avatar_media_id;
        db.prepare('UPDATE users SET handle = ? WHERE id = ?').run(name, user.id);
        if (changingAvatar) {
          db.prepare(`INSERT INTO user_profiles(user_id, avatar_media_id) VALUES (?, ?)
            ON CONFLICT(user_id) DO UPDATE SET avatar_media_id = excluded.avatar_media_id`).run(user.id, avatarID);
          // Reclaim only this user's replaced avatar if no memory or profile
          // still references it. Handle and avatar changes commit atomically.
          if (previous && previous !== avatarID) reclaimUnreferencedMedia(db, user.id, [previous]);
        }
        return userJSON(db, { id: user.id, handle: name });
      });
      return json(response, 200, { user: updated });
    }

    if (method === 'POST' && path === '/v1/reports') {
      const body = object(await authorizedJSON(request, user.id), ['memoryId', 'reason']);
      const memory = memoryFor(id(body.memoryId), user.id);
      requireValue(memory.owner_id !== user.id, 'You cannot report your own post.');
      requireValue(typeof body.reason === 'string' && body.reason.trim().length > 0 && body.reason.length <= 500,
        'Provide a reason of at most 500 characters.');
      db.prepare('INSERT OR IGNORE INTO content_reports(id, reporter_id, memory_id, reason, created_at) VALUES (?, ?, ?, ?, ?)')
        .run(randomUUID(), user.id, memory.id, body.reason.trim(), now());
      return json(response, 204);
    }
    if (method === 'POST' && path === '/v1/blocks') {
      const body = object(await authorizedJSON(request, user.id), ['userId']);
      const target = id(body.userId);
      requireValue(target !== user.id, 'You cannot block yourself.');
      if (!db.prepare('SELECT id FROM users WHERE id = ?').get(target)) throw notFound();
      db.prepare('INSERT OR IGNORE INTO user_blocks(blocker_id, blocked_id, created_at) VALUES (?, ?, ?)').run(user.id, target, now());
      return json(response, 204);
    }
    const unblock = /^\/v1\/blocks\/([^/]+)$/.exec(path);
    if (method === 'DELETE' && unblock) {
      db.prepare('DELETE FROM user_blocks WHERE blocker_id = ? AND blocked_id = ?').run(user.id, id(unblock[1]));
      return json(response, 204);
    }

    const userMatch = /^\/v1\/users\/([^/]+)(\/memories)?$/.exec(path);
    if (method === 'GET' && userMatch) {
      const profile = db.prepare('SELECT id, handle FROM users WHERE id = ?').get(id(userMatch[1]));
      if (!profile || !visibleOwner(user.id, profile.id)) throw notFound();
      if (!userMatch[2]) return json(response, 200, { user: userJSON(db, profile) });
      return json(response, 200, listMemories("owner_id = ? AND visibility = 'public' AND moderation_status = 'approved'",
        [profile.id], pageInput(url.searchParams)));
    }

    if (method === 'POST' && path === '/v1/me/archive/hide') {
      const body = object(await authorizedJSON(request, user.id), ['kind', 'id']);
      requireValue(body.kind === 'poi' || body.kind === 'reel', 'Kind must be poi or reel.');
      const targetID = id(body.id);
      const targetColumn = body.kind === 'poi' ? 'place_id' : 'id';
      const owned = db.prepare(`SELECT 1 FROM memories WHERE owner_id = ? AND kind = ? AND ${targetColumn} = ? LIMIT 1`)
        .get(user.id, body.kind, targetID);
      if (!owned) throw notFound();
      db.prepare('INSERT OR IGNORE INTO archive_hidden(owner_id, kind, target_id, hidden_at) VALUES (?, ?, ?, ?)')
        .run(user.id, body.kind, targetID, now());
      return json(response, 204);
    }

    if (resumableMatch) {
      const requestID = id(resumableMatch[1]);
      if (resumableMatch[2]) {
        if (method !== 'POST') throw notFound();
        object(await authorizedJSON(request, user.id), []);
        return json(response, 200, await resumable.complete(user.id, requestID));
      }
      if (method === 'PUT') {
        const input = object(await authorizedJSON(request, user.id), ['mimeType', 'byteCount', 'sha256']);
        return json(response, 200, resumable.begin(user.id, requestID, input));
      }
      if (method === 'GET') return json(response, 200, resumable.status(user.id, requestID));
      if (method === 'PATCH') {
        if (request.headers['content-type']?.split(';')[0].trim().toLowerCase() !== 'application/octet-stream') {
          throw new APIError(415, 'unsupported_type', 'Send an application/octet-stream video chunk.');
        }
        const rawOffset = request.headers['upload-offset'];
        requireValue(typeof rawOffset === 'string' && /^(0|[1-9][0-9]{0,9})$/.test(rawOffset), 'Provide a decimal Upload-Offset.');
        // Reject missing/cancelled sessions before reading an expensive body.
        resumable.status(user.id, requestID);
        const release = acquireUpload();
        if (!release) throw new APIError(429, 'upload_busy', 'Another upload is in progress. Try again shortly.');
        try {
          const bytes = await readBytes(request, UPLOAD_CHUNK_SIZE, 60_000);
          return json(response, 200, resumable.append(user.id, requestID, Number(rawOffset), bytes));
        } finally { release(); }
      }
      throw notFound();
    }

    if (method === 'POST' && path === '/v1/media') {
      const requestID = request.headers['idempotency-key'] === undefined ? null : id(request.headers['idempotency-key']);
      const releaseUpload = isBeta ? acquireUpload() : () => {};
      if (!releaseUpload) throw new APIError(429, 'upload_busy', 'Another upload is in progress. Try again shortly.');
      try {
        let mimeType = request.headers['content-type']?.split(';')[0].trim().toLowerCase();
        const isVideo = mimeType === 'video/mp4';
        if (!['image/jpeg', 'image/png', 'image/webp', 'video/mp4'].includes(mimeType)) {
          throw new APIError(415, 'unsupported_media', 'Use JPEG, PNG, WebP or an H.264 MP4 video.');
        }
        let bytes = await readBytes(request, isVideo ? VIDEO_LIMITS.inputBytes : PHOTO_LIMIT, isVideo ? 180_000 : 15_000);
        resumable.expire();
        resumable.checkLegacy(user.id, requestID, mimeType, bytes);
        if (!isVideo && imageType(bytes) !== mimeType) throw new APIError(415, 'invalid_photo', 'Photo signature does not match its type.');
        const requestHash = requestID ? digest(`${mimeType}:${digest(bytes)}`) : null;
        const currentUpload = () => {
          requireBetaAccess(db, user.id, isBeta);
          const currentUser = db.prepare('SELECT deletion_started_at FROM users WHERE id = ?').get(user.id);
          if (!currentUser || currentUser.deletion_started_at !== null) throw new APIError(409, 'account_deleting', 'This account is being deleted.');
          if (!requestID) return null;
          const previous = db.prepare('SELECT * FROM media_upload_requests WHERE owner_id = ? AND request_id = ?').get(user.id, requestID);
          if (!previous) return null;
          if (!previous.media_id) throw new APIError(410, 'media_deleted', 'This upload was removed. Select the media again to upload a new copy.');
          if (previous.request_hash !== requestHash) throw new APIError(409, 'idempotency_conflict', 'Use a new upload ID for different media.');
          return db.prepare('SELECT id, mime_type, byte_count FROM media WHERE id = ? AND owner_id = ?').get(previous.media_id, user.id);
        };
        const previous = currentUpload();
        if (previous) return json(response, 200, mediaJSON(previous));
        if (isVideo) ({ bytes, mimeType } = await normalizeVideo(bytes, mimeType));
        else if (isBeta) ({ bytes, mimeType } = await normalizePhoto(bytes, mimeType));
        // Decoding awaited. Recheck identity and duplicate requests, then commit
        // quota, bytes and retry mapping atomically without another await.
        const saved = transaction(db, () => {
          const existing = currentUpload();
          if (existing) return { status: 200, media: existing };
          resumable.checkQuota(user.id, bytes.length, requestID ?? '');
          const mediaID = randomUUID();
          db.prepare('INSERT INTO media(id, owner_id, mime_type, byte_count, bytes, created_at) VALUES (?, ?, ?, ?, ?, ?)')
            .run(mediaID, user.id, mimeType, bytes.length, bytes, now());
          if (requestID) db.prepare('INSERT INTO media_upload_requests(owner_id, request_id, request_hash, media_id, created_at) VALUES (?, ?, ?, ?, ?)')
            .run(user.id, requestID, requestHash, mediaID, now());
          if (requestID) resumable.clearChunks(user.id, requestID);
          return { status: 201, media: { id: mediaID, mime_type: mimeType, byte_count: bytes.length } };
        });
        return json(response, saved.status, mediaJSON(saved.media));
      } finally { releaseUpload(); }
    }

    const uploadKeyMatch = /^\/v1\/media\/by-upload-key\/([^/]+)$/.exec(path);
    if (method === 'DELETE' && uploadKeyMatch) {
      const requestID = id(uploadKeyMatch[1]);
      transaction(db, () => {
        const previous = db.prepare('SELECT media_id FROM media_upload_requests WHERE owner_id = ? AND request_id = ?').get(user.id, requestID);
        if (!previous) {
          // Cancellation may beat both the request body and its image decode.
          // An empty hash denotes no accepted payload; a NULL media_id always
          // wins over hash comparison, so late uploads cannot recreate bytes.
          db.prepare('INSERT INTO media_upload_requests(owner_id, request_id, request_hash, media_id, created_at) VALUES (?, ?, ?, NULL, ?)')
            .run(user.id, requestID, '', now());
        } else if (previous.media_id) {
          if (db.prepare('SELECT 1 FROM memory_media WHERE media_id = ? LIMIT 1').get(previous.media_id)
            || db.prepare('SELECT 1 FROM cluster_media WHERE media_id = ? LIMIT 1').get(previous.media_id)
            || db.prepare('SELECT 1 FROM user_profiles WHERE avatar_media_id = ? LIMIT 1').get(previous.media_id)) {
            throw new APIError(409, 'media_in_use', 'Remove associated records or replace the avatar before deleting this photo.');
          }
          // Ownership of the lookup and bytes must agree. FK SET NULL retains
          // the original accepted hash while making cancellation irreversible.
          db.prepare('DELETE FROM media WHERE id = ? AND owner_id = ?').run(previous.media_id, user.id);
        }
        resumable.remove(user.id, requestID);
      });
      return json(response, 204);
    }

    const mediaMatch = /^\/v1\/media\/([^/]+)$/.exec(path);
    if (mediaMatch && ['GET', 'HEAD', 'DELETE'].includes(method)) {
      const mediaID = id(mediaMatch[1]);
      const media = db.prepare('SELECT id, owner_id, mime_type, byte_count FROM media WHERE id = ?').get(mediaID);
      if (!media || !visibleOwner(user.id, media.owner_id)) throw notFound();
      if (method === 'DELETE') {
        if (media.owner_id !== user.id) throw notFound();
        if (db.prepare('SELECT 1 FROM memory_media WHERE media_id = ? LIMIT 1').get(mediaID)
          || db.prepare('SELECT 1 FROM cluster_media WHERE media_id = ? LIMIT 1').get(mediaID)
          || db.prepare('SELECT 1 FROM user_profiles WHERE avatar_media_id = ? LIMIT 1').get(mediaID)) {
          throw new APIError(409, 'media_in_use', 'Remove associated records or replace the avatar before deleting this photo.');
        }
        db.prepare('DELETE FROM media WHERE id = ?').run(mediaID);
        return json(response, 204);
      }
      const isAvatar = db.prepare('SELECT 1 FROM user_profiles WHERE user_id = ? AND avatar_media_id = ?')
        .get(media.owner_id, mediaID);
      if (media.owner_id !== user.id && !isAvatar && !db.prepare(`SELECT 1 FROM memories
        WHERE owner_id = ? AND visibility = 'public' AND moderation_status = 'approved'
          AND (EXISTS (SELECT 1 FROM memory_media WHERE memory_id = memories.id AND media_id = ?)
            OR EXISTS (SELECT 1 FROM cluster_media WHERE memory_id = memories.id AND media_id = ?)) LIMIT 1`)
        .get(media.owner_id, mediaID, mediaID)) throw notFound();
      const range = mediaByteRange(request.headers.range, media.byte_count);
      if (!range) {
        response.writeHead(416, { 'Content-Range': `bytes */${media.byte_count}`, 'Accept-Ranges': 'bytes' });
        return response.end();
      }
      const headers = { 'Content-Type': media.mime_type, 'Content-Length': range.end - range.start + 1,
        'Accept-Ranges': 'bytes', ...(range.partial ? { 'Content-Range': `bytes ${range.start}-${range.end}/${media.byte_count}` } : {}) };
      if (method === 'HEAD') { response.writeHead(range.partial ? 206 : 200, headers); return response.end(); }
      const releaseDownload = isBeta ? acquireDownload() : () => {};
      if (!releaseDownload) throw new APIError(429, 'media_busy', 'Media is busy. Try again shortly.');
      response.once('finish', releaseDownload);
      response.once('close', releaseDownload);
      try {
        response.writeHead(range.partial ? 206 : 200, headers);
        return await sendMediaBytes(db, response, mediaID, range);
      } catch (error) { releaseDownload(); throw error; }
    }

    if (method === 'POST' && path === '/v1/memories') {
      const input = memoryInput(await authorizedJSON(request, user.id), now());
      const requestHash = digest(JSON.stringify(input));
      const saved = transaction(db, () => {
        const deleted = db.prepare('SELECT owner_id FROM deleted_memories WHERE id = ?').get(input.id);
        if (deleted) {
          if (deleted.owner_id !== user.id) throw new APIError(409, 'id_conflict', 'Use a new record ID.');
          throw new APIError(410, 'record_deleted', 'This record was deleted; use a new ID for a new record.');
        }
        const existing = db.prepare('SELECT * FROM memories WHERE id = ?').get(input.id);
        if (existing) {
          if (existing.owner_id !== user.id || existing.request_hash !== requestHash) {
            throw new APIError(409, 'id_conflict', 'Use a new record ID for different content.');
          }
          return { status: 200, row: existing };
        }
        const members = input.cluster?.memoryIds.map(memoryID => {
          const source = memoryFor(memoryID, user.id, true);
          // A rejected source cannot be republished through a new attachment.
          if (source.moderation_status !== 'approved') throw notFound();
          const member = serializeMemory(source, false);
          // A snapshot retains only explicitly selected record media, not an
          // unrelated avatar whose lifecycle belongs to the current profile.
          member.owner = { id: member.owner.id, handle: member.owner.handle };
          return member;
        });
        for (const mediaID of input.mediaIds) {
          if (!db.prepare('SELECT id FROM media WHERE id = ? AND owner_id = ?').get(mediaID, user.id)) throw notFound();
        }
        let placeID = input.placeId;
        if (placeID) {
          // Knowing the ID of somebody else's private place is not permission.
          const visible = db.prepare(`SELECT 1 FROM memories WHERE place_id = ?
            AND (owner_id = ? OR (visibility = 'public' AND moderation_status = 'approved' AND ${visibilitySQL()})) LIMIT 1`)
            .get(placeID, user.id, user.id, user.id);
          // Source landmarks deliberately outlive their last check-in. A queued
          // visit can still name that canonical ID after its last visible visit
          // was deleted. Reuse only the bare landmark: any surviving memory,
          // including a private, blocked or rejected one, keeps the usual access
          // check above. This never grants access to past visits or their media.
          const orphanedSource = !visible && db.prepare(`SELECT 1 FROM place_sources
            WHERE place_id = ? AND NOT EXISTS (SELECT 1 FROM memories WHERE place_id = ?)`).get(placeID, placeID);
          if (!visible && !orphanedSource) throw notFound();
          const place = db.prepare('SELECT latitude, longitude, directory_kind FROM places WHERE id = ?').get(placeID);
          requireNearbyPlace(input.location, place, place.directory_kind);
        }
        if (input.place) {
          const source = input.place.sourceId
            ? db.prepare(`SELECT places.* FROM place_sources JOIN places ON places.id = place_sources.place_id
                WHERE source_id = ?`).get(input.place.sourceId)
            : null;
          if (source) {
            // A recognized source identifies only the landmark, never another user's check-ins.
            // Later clients cannot relocate or rename this canonical place by publishing to it.
            requireValue(input.place.directoryKind === undefined || input.place.directoryKind === source.directory_kind,
              'A check-in cannot change this place type.');
            requireNearbyPlace(input.location, source, source.directory_kind);
            placeID = source.id;
          } else {
            placeID = randomUUID();
            const location = input.place.coordinate ?? input.location;
            requireNearbyPlace(input.location, location, input.place.directoryKind);
            db.prepare('INSERT INTO places(id, name, category, latitude, longitude, directory_kind) VALUES (?, ?, ?, ?, ?, ?)')
              .run(placeID, input.place.name, input.place.category, location.latitude, location.longitude, input.place.directoryKind ?? null);
            if (input.place.sourceId) {
              db.prepare('INSERT INTO place_sources(source_id, place_id) VALUES (?, ?)').run(input.place.sourceId, placeID);
            }
          }
        }
        // Upload completion is not a new publication. Offline posts retain the
        // first tap's position and active lifetime on both Feed and MyMap.
        const received = now();
        const created = input.capturedAt ? Math.min(Date.parse(input.capturedAt), received) : received;
        db.prepare(`INSERT INTO memories(id, owner_id, kind, visibility, latitude, longitude,
          caption, place_id, created_at, expires_at, request_hash, published_at, moderation_status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
          .run(input.id, user.id, input.kind, input.visibility, input.location.latitude, input.location.longitude,
            input.caption, placeID, created,
            created + ACTIVE_FEED_WINDOW, requestHash, input.visibility === 'public' ? created : null,
            'approved');
        const attach = db.prepare('INSERT INTO memory_media(memory_id, media_id, position) VALUES (?, ?, ?)');
        input.mediaIds.forEach((mediaID, position) => attach.run(input.id, mediaID, position));
        if (members) {
          db.prepare('INSERT INTO memory_clusters(memory_id, title, members_json) VALUES (?, ?, ?)')
            .run(input.id, input.cluster.title, JSON.stringify(members));
          const retain = db.prepare('INSERT INTO cluster_media(memory_id, media_id) VALUES (?, ?)');
          for (const mediaID of new Set(members.flatMap(member => member.media.map(media => media.id)))) {
            retain.run(input.id, mediaID);
          }
        }
        // Only a genuinely new memory restores an archive item. Retrying an old POST does not
        // undo a later intentional hide, even if the original network response was lost.
        db.prepare('DELETE FROM archive_hidden WHERE owner_id = ? AND kind = ? AND target_id = ?')
          .run(user.id, input.kind, input.kind === 'poi' ? placeID : input.id);
        return { status: 201, row: db.prepare('SELECT * FROM memories WHERE id = ?').get(input.id) };
      });
      return json(response, saved.status, serializeMemory(saved.row));
    }

    if (method === 'GET' && path === '/v1/me/memories') {
      return json(response, 200, listMemories(`owner_id = ? AND NOT EXISTS (
        SELECT 1 FROM archive_hidden hidden WHERE hidden.owner_id = memories.owner_id
          AND hidden.kind = memories.kind AND hidden.target_id =
            CASE WHEN memories.kind = 'poi' THEN memories.place_id ELSE memories.id END
      )`, [user.id], pageInput(url.searchParams)));
    }
    if (method === 'GET' && path === '/v1/feed') {
      return json(response, 200, listMemories(`visibility = 'public' AND moderation_status = 'approved' AND ${PUBLICATION_TIME_SQL} > ? AND ${visibilitySQL()}`,
        [now() - ACTIVE_FEED_WINDOW, user.id, user.id], pageInput(url.searchParams), PUBLICATION_TIME_SQL));
    }
    if (method === 'GET' && path === '/v1/map/memories') {
      const page = pageInput(url.searchParams, ['west', 'east', 'south', 'north']);
      const { west, east, south, north } = bounds(url.searchParams);
      const longitudeClause = west <= east ? 'longitude BETWEEN ? AND ?' : '(longitude >= ? OR longitude <= ?)';
      return json(response, 200, listMemories(`visibility = 'public' AND moderation_status = 'approved'
        AND (kind = 'poi' OR ${PUBLICATION_TIME_SQL} > ?)
        AND latitude BETWEEN ? AND ? AND ${longitudeClause} AND ${visibilitySQL()}`,
        [now() - ACTIVE_FEED_WINDOW, south, north, west, east, user.id, user.id], page));
    }

    const placeMemoriesMatch = /^\/v1\/places\/([^/]+)\/memories$/.exec(path);
    if (method === 'GET' && placeMemoriesMatch) {
      const placeID = id(placeMemoriesMatch[1]);
      const page = pageInput(url.searchParams);
      // A place is a durable public history, not the viewer's current viewport
      // or the 72-hour active Feed. Its ID never grants access to private visits.
      // Match comments' non-enumerating 404 for unknown/inaccessible places.
      try {
        publicCommentTarget('places', placeID, user.id);
      } catch (error) {
        if (error instanceof APIError && error.status === 404) {
          // All missing/private/withdrawn places share this code. Unlike an
          // older server's unknown-route 404, it forbids a cached fallback.
          throw new APIError(404, 'place_unavailable', 'This place is not available.');
        }
        throw error;
      }
      return json(response, 200, listMemories(`kind = 'poi' AND place_id = ?
        AND visibility = 'public' AND moderation_status = 'approved' AND ${visibilitySQL()}`,
        [placeID, user.id, user.id], page, PUBLICATION_TIME_SQL));
    }

    const memoryMatch = /^\/v1\/memories\/([^/]+)$/.exec(path);
    if (memoryMatch && ['GET', 'PATCH', 'DELETE'].includes(method)) {
      const memoryID = id(memoryMatch[1]);
      if (method === 'DELETE') {
        requireValue([...url.searchParams.keys()].every(key => key === 'cancelPending')
          && (!url.searchParams.has('cancelPending') || (url.searchParams.getAll('cancelPending').length === 1
            && url.searchParams.get('cancelPending') === 'true')), 'Use cancelPending=true to cancel an unpublished record.');
        const deleted = db.prepare('SELECT owner_id FROM deleted_memories WHERE id = ?').get(memoryID);
        if (deleted) {
          if (deleted.owner_id !== user.id) throw notFound();
          return json(response, 204);
        }
        if (url.searchParams.has('cancelPending') && !db.prepare('SELECT 1 FROM memories WHERE id = ?').get(memoryID)) {
          // A publish request may still be reading its body or waiting for
          // connectivity. Persist cancellation before acknowledging it; its
          // later POST must see this tombstone rather than resurrect the item.
          db.prepare('INSERT INTO deleted_memories(id, owner_id, deleted_at) VALUES (?, ?, ?)').run(memoryID, user.id, now());
          return json(response, 204);
        }
      }
      memoryFor(memoryID, user.id, method !== 'GET');
      if (method === 'GET') return json(response, 200, serializeMemory(memoryFor(memoryID, user.id)));
      if (method === 'PATCH') {
        const body = object(await authorizedJSON(request, user.id), ['visibility', 'caption']);
        requireValue(Object.keys(body).length > 0, 'Choose what to update.');
        const current = memoryFor(memoryID, user.id, true);
        const audience = body.visibility === undefined ? current.visibility : visibility(body.visibility);
        let caption = current.caption;
        if (body.caption !== undefined) {
          requireValue(current.kind === 'reel', 'POI check-ins do not have captions.');
          requireValue(typeof body.caption === 'string' && body.caption.length <= 2200, 'Caption is too long.');
          caption = body.caption.trim();
          const hasMedia = db.prepare('SELECT 1 FROM memory_media WHERE memory_id = ? LIMIT 1').get(memoryID);
          const hasCluster = db.prepare('SELECT 1 FROM memory_clusters WHERE memory_id = ?').get(memoryID);
          requireValue(caption.length > 0 || hasMedia || hasCluster, 'Add a caption, media or cluster.');
        }
        const firstPublication = body.visibility === 'public' && current.published_at === null;
        const published = firstPublication ? now() : current.published_at;
        db.prepare('UPDATE memories SET visibility = ?, caption = ?, published_at = ?, expires_at = ? WHERE id = ? AND owner_id = ?')
          .run(audience, caption, published, firstPublication ? published + ACTIVE_FEED_WINDOW : current.expires_at, memoryID, user.id);
        return json(response, 200, serializeMemory(memoryFor(memoryID, user.id)));
      }
      // Permanent deletion withdraws the same record from every public surface.
      transaction(db, () => {
        const mediaIDs = db.prepare(`SELECT media_id FROM memory_media WHERE memory_id = ?
          UNION SELECT media_id FROM cluster_media WHERE memory_id = ?`).all(memoryID, memoryID).map(row => row.media_id);
        db.prepare('INSERT INTO deleted_memories(id, owner_id, deleted_at) VALUES (?, ?, ?)')
          .run(memoryID, user.id, now());
        db.prepare('DELETE FROM memories WHERE id = ? AND owner_id = ?').run(memoryID, user.id);
        reclaimUnreferencedMedia(db, user.id, mediaIDs);
        db.prepare(`DELETE FROM places WHERE NOT EXISTS (SELECT 1 FROM memories WHERE place_id = places.id)
          AND NOT EXISTS (SELECT 1 FROM place_sources WHERE place_id = places.id)`).run();
      });
      return json(response, 204);
    }
    throw notFound();
  }

  const server = createServer({ requestTimeout: 180_000, headersTimeout: 10_000, maxHeaderSize: 8192 }, (request, response) => {
    route(request, response).catch(error => {
      request.resume();
      const knownError = error instanceof APIError || error instanceof AppleAuthError || error instanceof SocialAuthError
        || error instanceof AppleLifecycleError || error instanceof BetaError || error instanceof PhotoProcessingError || error instanceof VideoProcessingError
        || error instanceof ResumableUploadError;
      if (knownError && ['POST', 'PUT', 'PATCH', 'DELETE'].includes(request.method)
        && /^\/v1\/media(?:\/|$)/.test(request.url?.split('?')[0] ?? '')) {
        if (now() - mediaErrorWindow.since >= 60_000) mediaErrorWindow = { since: now(), count: 0 };
        // Diagnose upload failures without recording identities, URLs, content,
        // tokens or decoder output. Bound logs even during abusive retry storms.
        if (mediaErrorWindow.count++ < 20) console.warn(JSON.stringify({
          event: 'media_request_failed', code: error.code, status: error.status,
        }));
        else if (mediaErrorWindow.count === 21) console.warn(JSON.stringify({ event: 'media_errors_rate_limited' }));
      }
      if (response.destroyed || response.writableEnded) return;
      if (response.headersSent) return response.destroy();
      if (knownError && error.status === 429 && !response.hasHeader('Retry-After')) response.setHeader('Retry-After', '2');
      if (!knownError) {
        // Never log passwords, bearer tokens, request bodies, coordinates or DB paths.
        console.error('Backend request failed:', error.code ?? error.name ?? 'InternalError');
      }
      json(response, knownError ? error.status : 500, {
        error: { code: knownError ? error.code : 'internal_error',
          message: knownError ? error.message : 'The request could not be completed.' },
      });
    });
  });

  return {
    async listen(port = 0) {
      if (closed || server.listening) throw new Error('Server already started or closed.');
      requireValue(Number.isInteger(port) && port >= 0 && port <= 65535, 'Invalid port.');
      // A crash after the user's explicit delete request must not strand the
      // account in an un-sign-in-able state. Revoke is safe to repeat remotely.
      for (const pending of db.prepare('SELECT id FROM users WHERE deletion_started_at IS NOT NULL').all()) {
        try { await deleteAccount(pending.id); }
        catch { console.error('Pending account deletion could not finish; operator follow-up is required.'); }
      }
      await new Promise((resolve, reject) => {
        const onError = error => { server.off('listening', onListen); reject(error); };
        const onListen = () => { server.off('error', onError); resolve(); };
        server.once('error', onError);
        server.once('listening', onListen);
        server.listen(port, hosting.bind);
      });
      return { url: `http://127.0.0.1:${server.address().port}` };
    },
    async close() {
      if (closed) return;
      clearInterval(uploadCleanup);
      // Wait for in-flight requests before closing SQLite.
      if (server.listening) await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
      db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
      db.close();
      closed = true;
    },
  };
}
