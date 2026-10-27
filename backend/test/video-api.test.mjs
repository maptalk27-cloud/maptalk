import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createBackend } from '../src/server.mjs';
import { DEFAULT_USER_MEDIA_LIMIT_BYTES } from '../src/media-storage.mjs';
import { videoFixture } from './helpers/video.mjs';
import { digest } from '../src/security.mjs';
import { UPLOAD_CHUNK_SIZE } from '../src/resumable-uploads.mjs';

const location = { latitude: 37.3688, longitude: -122.0363 };
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1cAAAAASUVORK5CYII=', 'base64');

async function fixture(t, options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-video-api-'));
  const databasePath = join(directory, 'test.sqlite');
  let server = createBackend({ databasePath, ...options });
  let address = await server.listen(0);
  t.after(async () => { await server.close(); await rm(directory, { recursive: true, force: true }); });
  const api = {
    async restart() { await server.close(); server = createBackend({ databasePath, ...options }); address = await server.listen(0); },
    async call(path, { method = 'GET', token, json, body, headers = {} } = {}) {
      const result = await fetch(new URL(path, address.url), { method,
        headers: { ...(token ? { authorization: `Bearer ${token}` } : {}),
          ...(json === undefined ? {} : { 'content-type': 'application/json' }), ...headers },
        body: json === undefined ? body : JSON.stringify(json) });
      const bytes = Buffer.from(await result.arrayBuffer());
      return { status: result.status, headers: result.headers, bytes,
        data: result.headers.get('content-type')?.includes('application/json') && bytes.length ? JSON.parse(bytes) : null };
    },
    async register(handle) {
      return expected(await api.call('/v1/auth/register', { method: 'POST', json: { handle, password: 'test-video-password-42' } }), 201);
    },
    async upload(token, bytes, key = randomUUID(), mimeType = 'video/mp4') {
      return api.call('/v1/media', { method: 'POST', token, body: bytes,
        headers: { 'content-type': mimeType, 'idempotency-key': key } });
    },
    async publish(token, mediaIds, overrides = {}) {
      return api.call('/v1/memories', { method: 'POST', token, json: {
        id: randomUUID(), kind: 'reel', visibility: 'public', caption: 'A video', location, mediaIds, ...overrides,
      } });
    },
  };
  return api;
}

function expected(result, status) {
  assert.equal(result.status, status, JSON.stringify(result.data));
  return result.data;
}

test('video upload is idempotent across restart and playback ranges retain private/public authorization', async t => {
  const api = await fixture(t);
  const owner = await api.register('videoowner');
  const viewer = await api.register('videoviewer');
  const input = await videoFixture({ duration: 10 });
  const key = randomUUID();
  expected(await api.upload(undefined, input, key), 401);
  const media = expected(await api.upload(owner.token, input, key), 201);
  assert.equal(media.mimeType, 'video/mp4');
  assert.ok(media.byteCount > 0);
  expected(await api.call(media.path, { token: viewer.token }), 404);
  expected(await api.call(media.path, { method: 'HEAD', token: viewer.token }), 404);
  expected(await api.call(media.path, { token: viewer.token, headers: { range: 'bytes=0-1' } }), 404);
  const full = await api.call(media.path, { token: owner.token });
  expected(full, 200);
  assert.equal(full.bytes.length, media.byteCount);
  assert.equal(full.headers.get('accept-ranges'), 'bytes');
  const prefix = await api.call(media.path, { token: owner.token, headers: { range: 'bytes=0-1' } });
  expected(prefix, 206);
  assert.deepEqual(prefix.bytes, full.bytes.subarray(0, 2));
  assert.equal(prefix.headers.get('content-range'), `bytes 0-1/${media.byteCount}`);
  const tail = await api.call(media.path, { token: owner.token, headers: { range: 'bytes=-20' } });
  expected(tail, 206); assert.deepEqual(tail.bytes, full.bytes.subarray(-20));
  assert.ok(media.byteCount > 64 * 1024, 'fixture must exercise multiple bounded SQLite reads');
  const boundary = await api.call(media.path, { token: owner.token, headers: { range: 'bytes=65530-65550' } });
  expected(boundary, 206); assert.deepEqual(boundary.bytes, full.bytes.subarray(65530, 65551));
  const head = await api.call(media.path, { method: 'HEAD', token: owner.token });
  expected(head, 200); assert.equal(head.bytes.length, 0); assert.equal(Number(head.headers.get('content-length')), media.byteCount);
  const invalidRange = await api.call(media.path, { token: owner.token, headers: { range: `bytes=${media.byteCount}-` } });
  expected(invalidRange, 416); assert.equal(invalidRange.headers.get('content-range'), `bytes */${media.byteCount}`);
  expected(await api.call(media.path, { token: owner.token, headers: { range: 'bytes=0-1,4-5' } }), 416);
  const post = expected(await api.publish(owner.token, [media.id]), 201);
  assert.equal(post.media[0].mimeType, 'video/mp4');
  expected(await api.call(media.path, { token: viewer.token, headers: { range: 'bytes=0-1' } }), 206);
  expected(await api.call('/v1/me', { method: 'PATCH', token: owner.token,
    json: { handle: owner.user.handle, avatarMediaId: media.id } }), 404, 'videos never become avatars');
  await api.restart();
  assert.deepEqual(expected(await api.upload(owner.token, input, key), 200), media);
  expected(await api.upload(owner.token, await videoFixture({ audio: false }), key), 409);
  expected(await api.call(`/v1/memories/${post.id}`, { method: 'PATCH', token: owner.token, json: { visibility: 'private' } }), 200);
  expected(await api.call(media.path, { token: viewer.token, headers: { range: 'bytes=0-1' } }), 404);
  expected(await api.call(`/v1/memories/${post.id}`, { method: 'DELETE', token: owner.token }), 204);
  expected(await api.call(media.path, { token: owner.token }), 404);
  expected(await api.upload(owner.token, input, key), 410, 'a stale queued upload cannot resurrect deleted video bytes');
});

test('POI accepts one video, Reel accepts nine mixed attachments in order, and videos obey the unchanged storage quota', async t => {
  const api = await fixture(t, { userMediaLimitBytes: 1024 * 1024 });
  assert.equal(DEFAULT_USER_MEDIA_LIMIT_BYTES, 50 * 1024 * 1024);
  const owner = await api.register('videomixed');
  const input = await videoFixture({ audio: false });
  const video = expected(await api.upload(owner.token, input), 201);
  const photo = expected(await api.upload(owner.token, PNG, randomUUID(), 'image/png'), 201);
  const poi = { kind: 'poi', caption: '', place: { name: 'Test coffee', category: 'coffee' } };
  const checkin = expected(await api.publish(owner.token, [video.id], poi), 201);
  assert.equal(checkin.media[0].mimeType, 'video/mp4');
  expected(await api.publish(owner.token, [video.id, photo.id], poi), 422);
  const ids = [photo.id, video.id];
  while (ids.length < 10) ids.push(expected(await api.upload(owner.token, PNG, randomUUID(), 'image/png'), 201).id);
  const mixed = expected(await api.publish(owner.token, ids.slice(0, 9)), 201);
  assert.deepEqual(mixed.media.map(media => media.id), ids.slice(0, 9));
  expected(await api.publish(owner.token, ids), 422);
  const filler = Buffer.alloc(1024 * 1024 - 20_000); PNG.copy(filler);
  const filling = expected(await api.upload(owner.token, filler, randomUUID(), 'image/png'), 201);
  const largerVideo = await videoFixture({ duration: 3 });
  const quota = expected(await api.upload(owner.token, largerVideo), 413);
  assert.equal(quota.error.code, 'media_quota');
  expected(await api.call(filling.path, { method: 'DELETE', token: owner.token }), 204);
  expected(await api.upload(owner.token, largerVideo), 201);
});

test('video cancellation retains tombstones before arrival and after an unlinked upload', async t => {
  const api = await fixture(t);
  const owner = await api.register('videocancel');
  const viewer = await api.register('videoother');
  const input = await videoFixture();
  const cancelled = randomUUID();
  expected(await api.call(`/v1/media/by-upload-key/${cancelled}`, { method: 'DELETE', token: owner.token }), 204);
  expected(await api.upload(owner.token, input, cancelled), 410);
  const live = randomUUID();
  const media = expected(await api.upload(owner.token, input, live), 201);
  expected(await api.call(media.path, { method: 'DELETE', token: viewer.token }), 404);
  expected(await api.call(`/v1/media/by-upload-key/${live}`, { method: 'DELETE', token: owner.token }), 204);
  await api.restart();
  expected(await api.upload(owner.token, input, live), 410);
  expected(await api.call(media.path, { token: owner.token }), 404);
  expected(await api.upload(viewer.token, input, live), 201, 'upload IDs are scoped to each owner');
});

test('HTTP video rejects unsupported input and oversized bodies before persisting media', async t => {
  const api = await fixture(t);
  const owner = await api.register('videoinvalid');
  const valid = await videoFixture();
  expected(await api.upload(owner.token, valid, randomUUID(), 'video/quicktime'), 415);
  expected(await api.upload(owner.token, PNG), 422);
  expected(await api.upload(owner.token, valid.subarray(0, valid.length - 100)), 422);
  expected(await api.upload(owner.token, Buffer.alloc(20 * 1024 * 1024 + 1)), 413);
  expected(await api.upload(owner.token, valid), 201, 'a rejected upload must not poison later uploads');
});

test('resumable video completes through the real decoder, survives restart, and remains compatible with legacy retry and private playback', async t => {
  const api = await fixture(t), owner = await api.register('resumereal'), viewer = await api.register('resumeviewer');
  const video = await videoFixture({ duration: 2, rotation: 90 });
  // A legal free box makes this a multi-chunk transfer without a huge/slow fixture.
  const padding = Buffer.alloc(UPLOAD_CHUNK_SIZE + 8); padding.writeUInt32BE(padding.length); padding.write('free', 4);
  const input = Buffer.concat([video, padding]), key = randomUUID(), path = `/v1/media/uploads/${key}`;
  const metadata = { mimeType: 'video/mp4', byteCount: input.length, sha256: digest(input) };
  expected(await api.call(path, { method: 'PUT', token: owner.token, json: metadata }), 200);
  for (let offset = 0; offset < input.length; offset += UPLOAD_CHUNK_SIZE) {
    const part = input.subarray(offset, offset + UPLOAD_CHUNK_SIZE);
    const status = expected(await api.call(path, { method: 'PATCH', token: owner.token, body: part,
      headers: { 'content-type': 'application/octet-stream', 'upload-offset': String(offset) } }), 200);
    assert.equal(status.receivedBytes, offset + part.length);
  }
  await api.restart();
  const completed = expected(await api.call(`${path}/complete`, { method: 'POST', token: owner.token, json: {} }), 200);
  assert.equal(completed.receivedBytes, input.length);
  assert.equal(completed.media.mimeType, 'video/mp4');
  assert.ok(completed.media.byteCount < input.length, 'normalization removes free metadata padding');
  assert.deepEqual(expected(await api.upload(owner.token, input, key), 200), completed.media);
  assert.deepEqual(expected(await api.call(path, { method: 'PUT', token: owner.token, json: metadata }), 200), completed);
  assert.deepEqual(expected(await api.call(`${path}/complete`, { method: 'POST', token: owner.token, json: {} }), 200), completed);
  expected(await api.call(path, { token: viewer.token }), 404);
  expected(await api.call(completed.media.path, { token: viewer.token }), 404);
  const post = expected(await api.publish(owner.token, [completed.media.id]), 201);
  expected(await api.call(completed.media.path, { token: viewer.token, headers: { range: 'bytes=0-1' } }), 206);
  expected(await api.call(`/v1/memories/${post.id}`, { method: 'DELETE', token: owner.token }), 204);
  assert.equal(expected(await api.call(path, { method: 'PUT', token: owner.token, json: metadata }), 410).error.code, 'media_deleted');
  // A completed upload from the old protocol can be adopted without another body.
  const oldKey = randomUUID(), oldMedia = expected(await api.upload(owner.token, video, oldKey), 201);
  const adopted = expected(await api.call(`/v1/media/uploads/${oldKey}`, { method: 'PUT', token: owner.token,
    json: { mimeType: 'video/mp4', byteCount: video.length, sha256: digest(video) } }), 200);
  assert.deepEqual(adopted.media, oldMedia); assert.equal(adopted.receivedBytes, video.length);
});
