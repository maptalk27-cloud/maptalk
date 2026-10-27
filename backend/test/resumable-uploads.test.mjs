import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { request as httpRequest } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openDatabase } from '../src/database.mjs';
import { createBackend } from '../src/server.mjs';
import { digest } from '../src/security.mjs';
import { createResumableUploads, UPLOAD_CHUNK_SIZE, UPLOAD_TTL } from '../src/resumable-uploads.mjs';
import { VideoProcessingError, videoProcessingFailure } from '../src/video-processing.mjs';

const code = expected => error => error.code === expected;
const meta = bytes => ({ mimeType: 'video/mp4', byteCount: bytes.length, sha256: digest(bytes) });
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1cAAAAASUVORK5CYII=', 'base64');

async function fixture(t, options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-resume-unit-'));
  const path = join(directory, 'db.sqlite');
  let db = openDatabase(path);
  let time = Date.now();
  for (const owner of ['owner', 'other']) db.prepare('INSERT INTO users(id, handle, password_hash, created_at) VALUES (?, ?, ?, ?)').run(owner, owner, 'unused', time);
  const configure = () => createResumableUploads({ db, now: () => time, storageLimit: options.limit ?? 50 * 1024 * 1024,
    assertOwner(owner) { if (!db.prepare('SELECT 1 FROM users WHERE id = ? AND deletion_started_at IS NULL').get(owner)) throw new Error('owner unavailable'); },
    normalize: options.normalize ?? (async bytes => ({ bytes, mimeType: 'video/mp4' })) });
  let uploads = configure();
  t.after(async () => { db.close(); await rm(directory, { recursive: true, force: true }); });
  return { get db() { return db; }, get uploads() { return uploads; },
    advance(ms) { time += ms; }, restart() { db.close(); db = openDatabase(path); uploads = configure(); },
    cancel(owner, key) {
      db.prepare('INSERT INTO media_upload_requests VALUES (?, ?, ?, NULL, ?)').run(owner, key, '', time);
      uploads.remove(owner, key);
    } };
}

test('accepted chunks survive restart and duplicate acknowledgements; completion recovers without re-upload', async t => {
  let normalizations = 0;
  const f = await fixture(t, { normalize: async bytes => { normalizations++; return { bytes, mimeType: 'video/mp4' }; } });
  const bytes = Buffer.alloc(UPLOAD_CHUNK_SIZE * 2 + 17, 7), key = randomUUID();
  assert.equal(f.uploads.begin('owner', key, meta(bytes)).receivedBytes, 0);
  assert.throws(() => f.uploads.append('owner', key, 0, Buffer.from([7])), code('invalid_request'), 'tiny nonfinal chunks cannot exhaust SQLite with row overhead');
  assert.equal(f.db.prepare('SELECT COUNT(*) AS n FROM media_upload_chunks').get().n, 0);
  const first = bytes.subarray(0, UPLOAD_CHUNK_SIZE);
  assert.equal(f.uploads.append('owner', key, 0, first).receivedBytes, first.length);
  assert.equal(f.uploads.append('owner', key, 0, first).receivedBytes, first.length, 'lost acknowledgement does not double append');
  assert.throws(() => f.uploads.append('owner', key, 0, Buffer.alloc(first.length, 9)), code('upload_chunk_conflict'));
  assert.throws(() => f.uploads.append('owner', key, first.length + 1, Buffer.from([1])), code('upload_offset_mismatch'));
  assert.throws(() => f.uploads.append('owner', key, first.length, Buffer.alloc(UPLOAD_CHUNK_SIZE + 1)), code('invalid_request'));
  assert.throws(() => f.uploads.append('owner', key, first.length, Buffer.alloc(0)), code('invalid_request'));
  await assert.rejects(f.uploads.complete('owner', key), code('upload_incomplete'));
  f.restart();
  assert.equal(f.uploads.begin('owner', key, meta(bytes)).receivedBytes, first.length);
  f.uploads.append('owner', key, first.length, bytes.subarray(first.length, first.length * 2));
  f.uploads.append('owner', key, first.length * 2, bytes.subarray(first.length * 2));
  const completed = await f.uploads.complete('owner', key);
  assert.equal(completed.receivedBytes, bytes.length);
  assert.equal(completed.media.byteCount, bytes.length);
  assert.equal(f.db.prepare('SELECT COUNT(*) AS n FROM media_upload_chunks').get().n, 0);
  f.restart();
  assert.deepEqual(f.uploads.status('owner', key), completed);
  assert.deepEqual(f.uploads.begin('owner', key, meta(bytes)), completed);
  assert.deepEqual(await f.uploads.complete('owner', key), completed);
  assert.equal(normalizations, 1);
  assert.equal(f.db.prepare('SELECT COUNT(*) AS n FROM media').get().n, 1);
  assert.deepEqual(Buffer.from(f.db.prepare('SELECT bytes FROM media').get().bytes), bytes);
});

test('pending upload quota is reserved once, includes legacy uploads, releases on cancellation and expires', async t => {
  const f = await fixture(t, { limit: 1024 * 1024 });
  const key = randomUUID(), bytes = Buffer.alloc(UPLOAD_CHUNK_SIZE);
  f.uploads.begin('owner', key, meta(bytes));
  f.uploads.begin('owner', key, meta(bytes));
  f.uploads.checkQuota('owner', UPLOAD_CHUNK_SIZE);
  assert.throws(() => f.uploads.checkQuota('owner', UPLOAD_CHUNK_SIZE + 1), code('media_quota'));
  const second = randomUUID();
  f.uploads.begin('owner', second, meta(bytes));
  assert.throws(() => f.uploads.begin('owner', randomUUID(), meta(Buffer.from([1]))), code('media_quota'));
  f.uploads.append('owner', key, 0, bytes);
  f.cancel('owner', key);
  assert.equal(f.db.prepare('SELECT COUNT(*) AS n FROM media_upload_chunks').get().n, 0);
  assert.throws(() => f.uploads.begin('owner', key, meta(bytes)), code('media_deleted'));
  f.uploads.checkQuota('owner', UPLOAD_CHUNK_SIZE);
  f.advance(UPLOAD_TTL + 1);
  f.uploads.expire();
  assert.throws(() => f.uploads.status('owner', second), code('not_found'));
  assert.equal(f.uploads.begin('owner', second, meta(bytes)).receivedBytes, 0, 'expired unfinished session can restart without a tombstone');
  assert.throws(() => f.uploads.status('owner', key), code('media_deleted'), 'explicit cancellation cannot expire into resurrection');
});

test('session cap, owner isolation, account cascade and completed receipts obey lifetime rules', async t => {
  const f = await fixture(t), bytes = Buffer.from('private staged video'), keys = [];
  for (let i = 0; i < 9; i++) { const key = randomUUID(); keys.push(key); f.uploads.begin('owner', key, meta(bytes)); }
  assert.throws(() => f.uploads.begin('owner', randomUUID(), meta(bytes)), code('upload_busy'));
  assert.throws(() => f.uploads.status('other', keys[0]), code('not_found'));
  assert.throws(() => f.uploads.append('other', keys[0], 0, bytes), code('not_found'));
  f.uploads.begin('other', keys[0], meta(bytes));
  f.uploads.append('owner', keys[0], 0, bytes);
  const completed = await f.uploads.complete('owner', keys[0]);
  assert.equal(f.uploads.status('other', keys[0]).receivedBytes, 0);
  f.uploads.begin('owner', randomUUID(), meta(bytes));
  f.advance(UPLOAD_TTL + 1); f.uploads.expire();
  assert.deepEqual(f.uploads.status('owner', keys[0]), completed, 'finished receipt does not expire');
  f.db.prepare('DELETE FROM media WHERE id = ?').run(completed.media.id);
  assert.throws(() => f.uploads.status('owner', keys[0]), code('media_deleted'));
  const fresh = randomUUID(); f.uploads.begin('owner', fresh, meta(bytes)); f.uploads.append('owner', fresh, 0, bytes);
  f.db.prepare('DELETE FROM users WHERE id = ?').run('owner');
  assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM media_upload_sessions WHERE owner_id = 'owner'").get().n, 0);
  assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM media_upload_chunks WHERE owner_id = 'owner'").get().n, 0);
});

test('busy or transient completion preserves staged bytes; cancellation wins over a late normalizer', async t => {
  let release, failNext = true;
  const f = await fixture(t, { normalize: async bytes => {
    if (failNext) { failNext = false; throw new VideoProcessingError(503, 'video_processing_timeout', 'retry'); }
    await new Promise(resolve => { release = resolve; }); return { bytes, mimeType: 'video/mp4' };
  } });
  const bytes = Buffer.from('retry saved bytes'), key = randomUUID();
  f.uploads.begin('owner', key, meta(bytes)); f.uploads.append('owner', key, 0, bytes);
  await assert.rejects(f.uploads.complete('owner', key), code('video_processing_timeout'));
  assert.equal(f.uploads.status('owner', key).receivedBytes, bytes.length);
  const completing = f.uploads.complete('owner', key);
  await assert.rejects(f.uploads.complete('owner', key), code('video_processing_busy'));
  f.cancel('owner', key); release();
  await assert.rejects(completing, code('media_deleted'));
  assert.equal(f.db.prepare('SELECT COUNT(*) AS n FROM media').get().n, 0);
  assert.equal(f.db.prepare('SELECT COUNT(*) AS n FROM media_upload_chunks').get().n, 0);
});

test('checksum/metadata conflicts cannot commit and a completed legacy upload is recovered without decoding', async t => {
  const f = await fixture(t), bytes = Buffer.from('original source bytes'), key = randomUUID();
  f.uploads.begin('owner', key, meta(bytes));
  assert.throws(() => f.uploads.begin('owner', key, meta(Buffer.from('different'))), code('idempotency_conflict'));
  assert.throws(() => f.uploads.checkLegacy('owner', key, 'video/mp4', Buffer.from('different')), code('idempotency_conflict'));
  f.uploads.append('owner', key, 0, Buffer.alloc(bytes.length));
  await assert.rejects(f.uploads.complete('owner', key), code('upload_checksum_mismatch'));
  assert.equal(f.db.prepare('SELECT COUNT(*) AS n FROM media').get().n, 0);
  const legacy = randomUUID(), mediaID = randomUUID();
  f.db.prepare('INSERT INTO media VALUES (?, ?, ?, ?, ?, ?)').run(mediaID, 'owner', 'video/mp4', 3, Buffer.from('MP4'), 1);
  f.db.prepare('INSERT INTO media_upload_requests VALUES (?, ?, ?, ?, ?)').run('owner', legacy, digest(`video/mp4:${digest(bytes)}`), mediaID, 1);
  const restored = f.uploads.begin('owner', legacy, meta(bytes));
  assert.equal(restored.media.id, mediaID);
  assert.equal(restored.byteCount, bytes.length);
  assert.equal(restored.receivedBytes, bytes.length);
  assert.equal(restored.media.byteCount, 3);
  assert.throws(() => f.uploads.begin('owner', legacy, meta(Buffer.from('different'))), code('idempotency_conflict'));
});

test('temporary decoder failures never tell the user a valid video is damaged', () => {
  for (const error of [{ killed: true }, { signal: 'SIGKILL' }, { code: 'ETIMEDOUT' }]) {
    assert.equal(videoProcessingFailure(error).status, 503);
    assert.equal(videoProcessingFailure(error).code, 'video_processing_timeout');
  }
  for (const reason of ['ENOENT', 'ENOSPC', 'ENOMEM', 'EAGAIN', 'EIO']) {
    assert.equal(videoProcessingFailure({ code: reason }).code, 'video_processing_unavailable');
  }
  assert.equal(videoProcessingFailure({ code: 1 }).code, 'invalid_video');
});

async function httpFixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-resume-http-'));
  const databasePath = join(directory, 'db.sqlite');
  let backend = createBackend({ databasePath, userMediaLimitBytes: 1024 * 1024 });
  let address = await backend.listen(0);
  t.after(async () => { await backend.close(); await rm(directory, { recursive: true, force: true }); });
  const api = {
    get url() { return address.url; },
    async restart() { await backend.close(); backend = createBackend({ databasePath, userMediaLimitBytes: 1024 * 1024 }); address = await backend.listen(0); },
    async call(path, { method = 'GET', token, json, body, headers = {} } = {}) {
      const response = await fetch(new URL(path, address.url), { method,
        headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(json !== undefined ? { 'content-type': 'application/json' } : {}), ...headers },
        body: json === undefined ? body : JSON.stringify(json) });
      const text = await response.text(); return { status: response.status, body: text ? JSON.parse(text) : null };
    },
    async owner(handle) {
      const registered = await api.call('/v1/auth/register', { method: 'POST', json: { handle, password: 'resumable-test-password-42' } });
      assert.equal(registered.status, 201); return registered.body;
    },
  };
  return api;
}

test('real HTTP half-chunk disconnect commits nothing; reconnect and server restart resume accepted offsets', async t => {
  const warnings = [];
  t.mock.method(console, 'warn', value => warnings.push(value));
  const api = await httpFixture(t), owner = await api.owner('reconnect'), other = await api.owner('unrelated');
  const key = randomUUID(), path = `/v1/media/uploads/${key}`, bytes = Buffer.alloc(UPLOAD_CHUNK_SIZE + 37, 5);
  const put = () => api.call(path, { method: 'PUT', token: owner.token, json: meta(bytes) });
  assert.equal((await api.call(path, { method: 'PUT', json: meta(bytes) })).status, 401);
  assert.equal((await put()).status, 200);
  assert.equal((await api.call(path, { token: other.token })).status, 404);
  await new Promise(resolve => {
    const request = httpRequest(`${api.url}${path}`, { method: 'PATCH', headers: {
      authorization: `Bearer ${owner.token}`, 'content-type': 'application/octet-stream', 'upload-offset': '0', 'content-length': UPLOAD_CHUNK_SIZE,
    } });
    request.on('error', () => resolve());
    request.write(bytes.subarray(0, UPLOAD_CHUNK_SIZE / 2), () => { setTimeout(() => request.destroy(new Error('intentional disconnect')), 30); });
  });
  assert.equal((await api.call(path, { token: owner.token })).body.receivedBytes, 0);
  assert.ok(warnings.some(value => JSON.parse(value).code === 'incomplete_body'), 'a disconnected response still emits safe diagnostics');
  for (const value of warnings) {
    assert.deepEqual(Object.keys(JSON.parse(value)).sort(), ['code', 'event', 'status']);
    assert.ok(!value.includes(owner.token) && !value.includes(owner.user.id) && !value.includes(key));
  }
  const first = await api.call(path, { method: 'PATCH', token: owner.token, body: bytes.subarray(0, UPLOAD_CHUNK_SIZE),
    headers: { 'content-type': 'application/octet-stream', 'upload-offset': '0' } });
  assert.equal(first.status, 200); assert.equal(first.body.receivedBytes, UPLOAD_CHUNK_SIZE);
  await api.restart();
  assert.equal((await put()).body.receivedBytes, UPLOAD_CHUNK_SIZE);
  const again = await api.call(path, { method: 'PATCH', token: owner.token, body: bytes.subarray(0, UPLOAD_CHUNK_SIZE),
    headers: { 'content-type': 'application/octet-stream', 'upload-offset': '0' } });
  assert.equal(again.body.receivedBytes, UPLOAD_CHUNK_SIZE);
  const final = await api.call(path, { method: 'PATCH', token: owner.token, body: bytes.subarray(UPLOAD_CHUNK_SIZE),
    headers: { 'content-type': 'application/octet-stream', 'upload-offset': String(UPLOAD_CHUNK_SIZE) } });
  assert.equal(final.body.receivedBytes, bytes.length);
  assert.equal((await api.call(`/v1/media/${key}`, { token: owner.token })).status, 404, 'pending data has no public media route');
  assert.equal((await api.call(`/v1/media/by-upload-key/${key}`, { method: 'DELETE', token: owner.token })).status, 204);
  assert.equal((await put()).body.error.code, 'media_deleted');
});

test('HTTP staged reservations protect quota from the old photo endpoint and cancellation frees it', async t => {
  const api = await httpFixture(t), owner = await api.owner('legacyquota'), key = randomUUID();
  const path = `/v1/media/uploads/${key}`;
  assert.equal((await api.call(path, { method: 'PUT', token: owner.token, json: meta(Buffer.alloc(1024 * 1024)) })).status, 200);
  const uploadPhoto = () => api.call('/v1/media', { method: 'POST', token: owner.token, body: PNG,
    headers: { 'content-type': 'image/png', 'idempotency-key': randomUUID() } });
  assert.equal((await uploadPhoto()).body.error.code, 'media_quota');
  await api.call(`/v1/media/by-upload-key/${key}`, { method: 'DELETE', token: owner.token });
  assert.equal((await uploadPhoto()).status, 201);
});
