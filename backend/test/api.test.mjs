import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { request as httpRequest } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createBackend } from '../src/server.mjs';

const PASSWORD = 'a-private-test-password-42';
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1cAAAAASUVORK5CYII=',
  'base64',
);
const LOCATION = { latitude: 37.3688, longitude: -122.0363 };

async function fixture(t, options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-api-test-'));
  const databasePath = join(directory, 'test.sqlite');
  let backend = createBackend({ databasePath, ...options });
  t.after(async () => {
    try {
      await backend.close();
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });
  let address = await backend.listen(0);

  return {
    get url() { return address.url; },
    async restart() {
      await backend.close();
      backend = createBackend({ databasePath, ...options });
      address = await backend.listen(0);
    },
    async call(path, { method = 'GET', token, json, body, headers = {} } = {}) {
      const response = await fetch(new URL(path, address.url), {
        method,
        headers: {
          ...(token ? { authorization: `Bearer ${token}` } : {}),
          ...(json !== undefined ? { 'content-type': 'application/json' } : {}),
          ...headers,
        },
        body: json !== undefined ? JSON.stringify(json) : body,
      });
      const text = await response.text();
      let data = null;
      if (text) {
        try { data = JSON.parse(text); } catch { data = text; }
      }
      return { status: response.status, data, headers: response.headers };
    },
  };
}

function expectStatus(result, expected) {
  assert.equal(result.status, expected, JSON.stringify(result.data));
  return result.data;
}

async function register(api, handle) {
  const result = await api.call('/v1/auth/register', {
    method: 'POST', json: { handle, password: PASSWORD },
  });
  const account = expectStatus(result, 201);
  assert.ok(account.user.id);
  assert.ok(account.token);
  assert.ok(account.expiresAt);
  return account;
}

async function upload(api, account) {
  const media = expectStatus(await api.call('/v1/media', {
    method: 'POST', token: account.token, body: PNG,
    headers: { 'content-type': 'image/png' },
  }), 201);
  assert.equal(media.mimeType, 'image/png');
  assert.equal(media.byteCount, PNG.length);
  assert.ok(media.id);
  assert.ok(media.path);
  return media;
}

function reel(overrides = {}) {
  return {
    id: randomUUID(), kind: 'reel', visibility: 'public',
    location: LOCATION, caption: 'An afternoon worth remembering.', ...overrides,
  };
}

async function publish(api, account, draft = reel()) {
  return expectStatus(await api.call('/v1/memories', {
    method: 'POST', token: account.token, json: draft,
  }), 201);
}

async function listAll(api, account, path, limit = 2) {
  const items = [];
  let cursor;
  const seenCursors = new Set();
  for (let page = 0; page < 20; page += 1) {
    const url = new URL(path, api.url);
    url.searchParams.set('limit', String(limit));
    if (cursor) url.searchParams.set('cursor', cursor);
    const data = expectStatus(await api.call(`${url.pathname}${url.search}`, {
      token: account.token,
    }), 200);
    assert.ok(Array.isArray(data.items));
    assert.ok(data.items.length <= limit);
    items.push(...data.items);
    if (!data.nextCursor) return items;
    assert.ok(!seenCursors.has(data.nextCursor), 'pagination must advance');
    seenCursors.add(data.nextCursor);
    cursor = data.nextCursor;
  }
  assert.fail('pagination did not terminate');
}

test('independent identities, case-insensitive login, and session logout', async (t) => {
  const api = await fixture(t);
  const alice = await register(api, 'Alice');
  const bob = await register(api, 'bob');
  assert.notEqual(alice.user.id, bob.user.id);
  assert.notEqual(alice.token, bob.token);

  expectStatus(await api.call('/v1/me'), 401);
  expectStatus(await api.call('/v1/me', { token: 'not-a-session' }), 401);
  const me = expectStatus(await api.call('/v1/me', { token: alice.token }), 200);
  assert.equal(me.user.id, alice.user.id);
  assert.equal(me.user.password, undefined);
  assert.equal(me.user.passwordHash, undefined);

  expectStatus(await api.call('/v1/auth/register', {
    method: 'POST', json: { handle: 'aLiCe', password: PASSWORD },
  }), 409);
  expectStatus(await api.call('/v1/auth/login', {
    method: 'POST', json: { handle: 'alice', password: 'incorrect-password' },
  }), 401);
  const login = expectStatus(await api.call('/v1/auth/login', {
    method: 'POST', json: { handle: 'ALICE', password: PASSWORD },
  }), 200);
  assert.equal(login.user.id, alice.user.id);

  expectStatus(await api.call('/v1/auth/logout', {
    method: 'POST', token: login.token,
  }), 204);
  expectStatus(await api.call('/v1/me', { token: login.token }), 401);
  expectStatus(await api.call('/v1/me', { token: bob.token }), 200);
});

test('profile edits persist in sessions, login, profiles and feed owners without changing user identity', async t => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const bob = await register(api, 'bob');
  const avatar = await upload(api, alice);
  const saved = expectStatus(await api.call('/v1/me', { method: 'PATCH', token: alice.token,
    json: { handle: 'Alice_New', avatarMediaId: avatar.id } }), 200).user;
  assert.deepEqual(saved, { id: alice.user.id, handle: 'alice_new', avatar });
  assert.deepEqual(expectStatus(await api.call('/v1/me', { token: alice.token }), 200).user, saved);
  assert.deepEqual(expectStatus(await api.call(`/v1/users/${alice.user.id}`, { token: bob.token }), 200).user, saved);
  expectStatus(await api.call(avatar.path, { token: bob.token }), 200);
  const post = await publish(api, alice);
  assert.deepEqual(post.owner, saved);
  assert.deepEqual(expectStatus(await api.call('/v1/feed', { token: bob.token }), 200).items[0].owner, saved);
  await api.restart();
  assert.deepEqual(expectStatus(await api.call('/v1/me', { token: alice.token }), 200).user, saved);
  const login = expectStatus(await api.call('/v1/auth/login', { method: 'POST', json: { handle: 'ALICE_NEW', password: PASSWORD } }), 200);
  assert.deepEqual(login.user, saved);
  expectStatus(await api.call('/v1/auth/login', { method: 'POST', json: { handle: 'alice', password: PASSWORD } }), 401);
  const renameOnly = expectStatus(await api.call('/v1/me', { method: 'PATCH', token: alice.token,
    json: { handle: 'alice_final' } }), 200).user;
  assert.deepEqual(renameOnly.avatar, avatar, 'omitting avatarMediaId preserves the avatar');
});

test('profile validation and ownership failures are atomic, and case-insensitive handle races have one winner', async t => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const bob = await register(api, 'bob');
  const avatar = await upload(api, alice);
  const replacement = await upload(api, alice);
  const foreign = await upload(api, bob);
  const original = expectStatus(await api.call('/v1/me', { method: 'PATCH', token: alice.token,
    json: { handle: 'alice', avatarMediaId: avatar.id } }), 200).user;
  expectStatus(await api.call('/v1/me', { method: 'PATCH', json: { handle: 'anonymous' } }), 401);
  for (const [json, status] of [
    [{ handle: 'BoB', avatarMediaId: replacement.id }, 409],
    [{ handle: 'valid_name', avatarMediaId: foreign.id }, 404],
    [{ handle: 'valid_name', avatarMediaId: randomUUID() }, 404],
    [{ handle: 'valid_name', avatarMediaId: 'bad-id' }, 422],
    [{ handle: 'valid_name', avatarMediaId: false }, 422],
    [{ handle: 'bad name', avatarMediaId: replacement.id }, 422],
    [{ handle: 'ab' }, 422], [{ handle: 'a'.repeat(33) }, 422], [{ handle: ' alice' }, 422], [{ handle: 'alice\n' }, 422],
    [{ handle: '中文名称' }, 422], [{ handle: 'safe', role: 'admin' }, 422],
    [{ avatarMediaId: replacement.id }, 422],
  ]) {
    const result = await api.call('/v1/me', { method: 'PATCH', token: alice.token, json });
    expectStatus(result, status);
    if (status === 409) assert.equal(result.data.error.code, 'handle_taken');
    assert.deepEqual(expectStatus(await api.call('/v1/me', { token: alice.token }), 200).user, original);
    expectStatus(await api.call(avatar.path, { token: alice.token }), 200);
  }
  const results = await Promise.all([alice, bob].map(account => api.call('/v1/me', {
    method: 'PATCH', token: account.token, json: { handle: 'Same_Name' },
  })));
  assert.deepEqual(results.map(result => result.status).sort(), [200, 409]);
  assert.equal(results.find(result => result.status === 409).data.error.code, 'handle_taken');
});

test('only explicitly selected avatars become shared, and avatar replacement preserves other media references', async t => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const bob = await register(api, 'bob');
  const avatar = await upload(api, alice);
  const privatePhoto = await upload(api, alice);
  const privatePost = await publish(api, alice, reel({ visibility: 'private', mediaIds: [privatePhoto.id] }));
  expectStatus(await api.call(avatar.path, { token: bob.token }), 404);
  expectStatus(await api.call(avatar.path), 401);
  await api.call('/v1/me', { method: 'PATCH', token: alice.token, json: { handle: 'alice', avatarMediaId: avatar.id } });
  expectStatus(await api.call(avatar.path, { token: bob.token }), 200);
  expectStatus(await api.call(privatePhoto.path, { token: bob.token }), 404);
  expectStatus(await api.call(`/v1/memories/${privatePost.id}`, { token: bob.token }), 404);
  assert.equal(expectStatus(await api.call(avatar.path, { method: 'DELETE', token: alice.token }), 409).error.code, 'media_in_use');
  expectStatus(await api.call(avatar.path, { method: 'DELETE', token: bob.token }), 404);
  expectStatus(await api.call('/v1/me', { method: 'PATCH', token: alice.token,
    json: { handle: 'alice', avatarMediaId: privatePhoto.id } }), 200);
  expectStatus(await api.call(avatar.path, { token: alice.token }), 404, 'unreferenced old avatar is reclaimed');
  expectStatus(await api.call(privatePhoto.path, { token: bob.token }), 200, 'selecting this photo explicitly shares the photo, not its private post');
  expectStatus(await api.call(`/v1/memories/${privatePost.id}`, { token: bob.token }), 404);
  const cleared = expectStatus(await api.call('/v1/me', { method: 'PATCH', token: alice.token,
    json: { handle: 'alice', avatarMediaId: null } }), 200).user;
  assert.equal(cleared.avatar, undefined);
  expectStatus(await api.call(privatePhoto.path, { token: alice.token }), 200, 'private memory reference keeps bytes');
  expectStatus(await api.call(privatePhoto.path, { token: bob.token }), 404, 'old avatar-only sharing is revoked immediately');
  expectStatus(await api.call(`/v1/memories/${privatePost.id}`, { method: 'PATCH', token: alice.token, json: { visibility: 'public' } }), 200);
  expectStatus(await api.call('/v1/me', { method: 'PATCH', token: alice.token,
    json: { handle: 'alice', avatarMediaId: privatePhoto.id } }), 200);
  expectStatus(await api.call('/v1/me', { method: 'PATCH', token: alice.token,
    json: { handle: 'alice', avatarMediaId: null } }), 200);
  expectStatus(await api.call(privatePhoto.path, { token: bob.token }), 200, 'an existing public post still grants media access');
});

test('private records and media cannot leak through direct URLs or lists', async (t) => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const bob = await register(api, 'bob');
  const photo = await upload(api, alice);

  expectStatus(await api.call(photo.path), 401);
  expectStatus(await api.call(photo.path, { token: bob.token }), 404);
  const image = await fetch(new URL(photo.path, api.url), {
    headers: { authorization: `Bearer ${alice.token}` },
  });
  assert.equal(image.status, 200);
  assert.match(image.headers.get('content-type'), /^image\/png/);
  assert.deepEqual(Buffer.from(await image.arrayBuffer()), PNG);

  const memory = await publish(api, alice, reel({
    visibility: 'private', mediaIds: [photo.id],
  }));
  assert.equal(memory.ownerId, alice.user.id);
  assert.equal(memory.media[0].id, photo.id);
  expectStatus(await api.call(`/v1/memories/${memory.id}`), 401);
  expectStatus(await api.call(`/v1/memories/${memory.id}`, { token: bob.token }), 404);
  expectStatus(await api.call(photo.path, { token: bob.token }), 404);
  assert.equal(expectStatus(await api.call('/v1/feed', { token: bob.token }), 200).items.length, 0);
  assert.equal(expectStatus(await api.call('/v1/me/memories', { token: bob.token }), 200).items.length, 0);
  assert.equal(expectStatus(await api.call('/v1/me/memories', { token: alice.token }), 200).items.length, 1);

  expectStatus(await api.call(`/v1/media/${photo.id}`, {
    method: 'DELETE', token: alice.token,
  }), 409);
  expectStatus(await api.call(`/v1/memories/${memory.id}`, {
    method: 'PATCH', token: alice.token, json: { visibility: 'public' },
  }), 200);
  expectStatus(await api.call(`/v1/memories/${memory.id}`, { token: bob.token }), 200);
  assert.equal((await fetch(new URL(photo.path, api.url), {
    headers: { authorization: `Bearer ${bob.token}` },
  })).status, 200);

  expectStatus(await api.call(`/v1/memories/${memory.id}`, {
    method: 'PATCH', token: alice.token, json: { visibility: 'private' },
  }), 200);
  expectStatus(await api.call(photo.path, { token: bob.token }), 404);
  expectStatus(await api.call(`/v1/memories/${memory.id}`, {
    method: 'DELETE', token: alice.token,
  }), 204);
  expectStatus(await api.call(`/v1/memories/${memory.id}`, { token: alice.token }), 404);
  expectStatus(await api.call(`/v1/media/${photo.id}`, {
    method: 'DELETE', token: alice.token,
  }), 404); // Already reclaimed when its last post was deleted.
  expectStatus(await api.call(photo.path, { token: alice.token }), 404);
});

test('public and private check-ins can share a place without sharing visibility', async (t) => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const bob = await register(api, 'bob');
  const visible = await publish(api, alice, {
    id: randomUUID(), kind: 'poi', visibility: 'public', location: LOCATION,
    place: { name: 'Neighborhood café', category: 'coffee' }, mediaIds: [],
  });
  assert.ok(visible.place.id);
  assert.equal(visible.place.sourceId, null, 'a custom landmark has no external directory source');
  const hidden = await publish(api, alice, {
    id: randomUUID(), kind: 'poi', visibility: 'private', location: LOCATION,
    placeId: visible.place.id,
  });
  assert.equal(hidden.place.id, visible.place.id);
  expectStatus(await api.call(`/v1/memories/${hidden.id}`, { token: bob.token }), 404);
  const feed = expectStatus(await api.call('/v1/feed', { token: bob.token }), 200);
  assert.deepEqual(feed.items.map((item) => item.id), [visible.id]);
  const map = expectStatus(await api.call(
    '/v1/map/memories?west=-123&east=-121&south=37&north=38', { token: bob.token },
  ), 200);
  assert.deepEqual(map.items.map((item) => item.id), [visible.id]);

  const bobsVisit = await publish(api, bob, {
    id: randomUUID(), kind: 'poi', visibility: 'private', location: LOCATION,
    placeId: visible.place.id,
  });
  assert.equal(bobsVisit.place.id, visible.place.id);
  assert.equal(bobsVisit.ownerId, bob.user.id);
  expectStatus(await api.call(`/v1/memories/${bobsVisit.id}`, { token: alice.token }), 404);
  const privatePlace = await publish(api, alice, {
    id: randomUUID(), kind: 'poi', visibility: 'private', location: LOCATION,
    place: { name: 'A private place', category: 'other' },
  });
  expectStatus(await api.call('/v1/memories', {
    method: 'POST', token: bob.token,
    json: {
      id: randomUUID(), kind: 'poi', visibility: 'public', location: LOCATION,
      placeId: privatePlace.place.id,
    },
  }), 404);
});

test('media preserves attachment order and loses public access with its last public reference', async (t) => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const bob = await register(api, 'bob');
  const first = await upload(api, alice);
  const second = await upload(api, alice);
  const ordered = await publish(api, alice, reel({ mediaIds: [second.id, first.id] }));
  assert.deepEqual(ordered.media.map((item) => item.id), [second.id, first.id]);
  const privateCopy = await publish(api, alice, reel({
    visibility: 'private', mediaIds: [first.id],
  }));
  assert.equal((await fetch(new URL(first.path, api.url), {
    headers: { authorization: `Bearer ${bob.token}` },
  })).status, 200);
  expectStatus(await api.call(`/v1/memories/${ordered.id}`, {
    method: 'DELETE', token: alice.token,
  }), 204);
  expectStatus(await api.call(first.path, { token: bob.token }), 404);
  expectStatus(await api.call(`/v1/media/${first.id}`, {
    method: 'DELETE', token: alice.token,
  }), 409);
  expectStatus(await api.call(`/v1/memories/${privateCopy.id}`, {
    method: 'DELETE', token: alice.token,
  }), 204);
  expectStatus(await api.call(`/v1/media/${first.id}`, {
    method: 'DELETE', token: alice.token,
  }), 404); // Last reference removal reclaims the bytes automatically.
});

test('publishing a previously private place does not expose its earlier private photo', async (t) => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const bob = await register(api, 'bob');
  const privatePhoto = await upload(api, alice);
  const publicPhoto = await upload(api, alice);
  const privateVisit = await publish(api, alice, {
    id: randomUUID(), kind: 'poi', visibility: 'private', location: LOCATION,
    place: { name: 'A café I found', category: 'coffee' },
    mediaIds: [privatePhoto.id],
  });
  const publicVisit = await publish(api, alice, {
    id: randomUUID(), kind: 'poi', visibility: 'public', location: LOCATION,
    placeId: privateVisit.place.id, mediaIds: [publicPhoto.id],
  });
  assert.equal(privateVisit.place.id, publicVisit.place.id);
  expectStatus(await api.call(`/v1/memories/${privateVisit.id}`, { token: bob.token }), 404);
  expectStatus(await api.call(privatePhoto.path, { token: bob.token }), 404);
  const visible = expectStatus(await api.call(`/v1/memories/${publicVisit.id}`, {
    token: bob.token,
  }), 200);
  assert.deepEqual(visible.media.map((item) => item.id), [publicPhoto.id]);
  const image = await fetch(new URL(publicPhoto.path, api.url), {
    headers: { authorization: `Bearer ${bob.token}` },
  });
  assert.equal(image.status, 200);
  assert.deepEqual(Buffer.from(await image.arrayBuffer()), PNG);
  for (const path of ['/v1/feed', '/v1/map/memories?west=-123&east=-121&south=37&north=38']) {
    const list = expectStatus(await api.call(path, { token: bob.token }), 200);
    assert.deepEqual(list.items.map((item) => item.id), [publicVisit.id]);
    assert.deepEqual(list.items.flatMap((item) => item.media.map((media) => media.id)), [publicPhoto.id]);
  }
});

test('ownership is derived from the session, including media and mutation rights', async (t) => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  for (const path of ['/v1/feed', '/v1/me/memories', '/v1/map/memories?west=-180&east=180&south=-90&north=90']) {
    expectStatus(await api.call(path), 401);
  }
  const bob = await register(api, 'bob');
  const media = await upload(api, alice);
  const memory = await publish(api, alice);

  expectStatus(await api.call('/v1/memories', {
    method: 'POST', token: bob.token, json: reel({ ownerId: alice.user.id }),
  }), 422);
  expectStatus(await api.call('/v1/memories', {
    method: 'POST', token: bob.token, json: reel({ mediaIds: [media.id] }),
  }), 404);
  for (const method of ['PATCH', 'DELETE']) {
    expectStatus(await api.call(`/v1/memories/${memory.id}`, {
      method, token: bob.token,
      ...(method === 'PATCH' ? { json: { visibility: 'private' } } : {}),
    }), 404);
  }
  expectStatus(await api.call(`/v1/media/${media.id}`, {
    method: 'DELETE', token: bob.token,
  }), 404);
  expectStatus(await api.call(`/v1/memories/${memory.id}`, {
    method: 'PATCH', token: alice.token, json: { visibility: 'private', ownerId: bob.user.id },
  }), 422);
  assert.equal(expectStatus(await api.call(`/v1/memories/${memory.id}`, {
    token: alice.token,
  }), 200).ownerId, alice.user.id);
});

test('publishing retries are idempotent but cannot silently overwrite a post', async (t) => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const draft = reel();
  const original = await publish(api, alice, draft);
  const retry = expectStatus(await api.call('/v1/memories', {
    method: 'POST', token: alice.token, json: draft,
  }), 200);
  assert.deepEqual(retry, original);
  expectStatus(await api.call('/v1/memories', {
    method: 'POST', token: alice.token, json: { ...draft, caption: 'A changed story.' },
  }), 409);
  const mine = expectStatus(await api.call('/v1/me/memories', { token: alice.token }), 200);
  assert.deepEqual(mine.items.map((item) => item.id), [original.id]);
});

test('photo upload retries survive a lost response and restart without duplicating storage', async t => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const bob = await register(api, 'bob');
  const key = randomUUID();
  const options = { method: 'POST', token: alice.token, body: PNG,
    headers: { 'content-type': 'image/png', 'idempotency-key': key } };
  const first = expectStatus(await api.call('/v1/media', options), 201);
  assert.deepEqual(expectStatus(await api.call('/v1/media', options), 200), first);
  await api.restart();
  assert.deepEqual(expectStatus(await api.call('/v1/media', options), 200), first);
  const parallel = await Promise.all([api.call('/v1/media', options), api.call('/v1/media', options)]);
  for (const result of parallel) assert.deepEqual(expectStatus(result, 200), first);
  const changed = expectStatus(await api.call('/v1/media', { ...options, body: Buffer.concat([PNG, Buffer.from([1])]) }), 409);
  assert.equal(changed.error.code, 'idempotency_conflict');
  const otherOwner = expectStatus(await api.call('/v1/media', { ...options, token: bob.token }), 201);
  assert.notEqual(otherOwner.id, first.id, 'upload keys are scoped to an owner');
  expectStatus(await api.call('/v1/media', { ...options, headers: { ...options.headers, 'idempotency-key': 'invalid' } }), 422);
  const draft = reel({ mediaIds: [first.id] });
  await publish(api, alice, draft);
  expectStatus(await api.call(`/v1/memories/${draft.id}`, { method: 'DELETE', token: alice.token }), 204);
  expectStatus(await api.call(`/v1/memories/${draft.id}`, { method: 'DELETE', token: alice.token }), 204);
  expectStatus(await api.call(`/v1/memories/${draft.id}`, { method: 'DELETE', token: bob.token }), 404);
  await api.restart();
  assert.equal(expectStatus(await api.call('/v1/media', options), 410).error.code, 'media_deleted');
  assert.equal(expectStatus(await api.call('/v1/memories', { method: 'POST', token: alice.token, json: draft }), 410).error.code, 'record_deleted');
  expectStatus(await api.call(first.path, { token: alice.token }), 404);
  expectStatus(await api.call(otherOwner.path, { token: bob.token }), 200);
});

test('upload-key cancellation reclaims lost-response photos and quota, is owner scoped, and survives restart', async t => {
  const limit = 1024 * 1024;
  const api = await fixture(t, { userMediaLimitBytes: limit });
  const alice = await register(api, 'alice');
  const bob = await register(api, 'bob');
  const key = randomUUID();
  const bytes = Buffer.alloc(limit); PNG.copy(bytes);
  const uploadOptions = { method: 'POST', token: alice.token, body: bytes,
    headers: { 'content-type': 'image/png', 'idempotency-key': key } };
  const photo = expectStatus(await api.call('/v1/media', uploadOptions), 201);
  const cleanup = `/v1/media/by-upload-key/${key}`;
  // A different owner may cancel their own use of a key, never our bytes.
  expectStatus(await api.call(cleanup, { method: 'DELETE', token: bob.token }), 204);
  expectStatus(await api.call(photo.path, { token: alice.token }), 200);
  expectStatus(await api.call('/v1/media', { ...uploadOptions, token: bob.token }), 410);
  expectStatus(await api.call('/v1/media', { ...uploadOptions,
    headers: { ...uploadOptions.headers, 'idempotency-key': randomUUID() } }), 413);
  // The canceled client only knows its upload key, not this response's ID.
  expectStatus(await api.call(cleanup, { method: 'DELETE', token: alice.token }), 204);
  expectStatus(await api.call(cleanup, { method: 'DELETE', token: alice.token }), 204);
  expectStatus(await api.call(photo.path, { token: alice.token }), 404);
  await api.restart();
  expectStatus(await api.call(cleanup, { method: 'DELETE', token: alice.token }), 204);
  assert.equal(expectStatus(await api.call('/v1/media', uploadOptions), 410).error.code, 'media_deleted');
  assert.equal(expectStatus(await api.call('/v1/media', { ...uploadOptions, body: PNG }), 410).error.code, 'media_deleted',
    'a cancellation tombstone wins over a different payload hash');
  expectStatus(await api.call('/v1/media', { ...uploadOptions,
    headers: { ...uploadOptions.headers, 'idempotency-key': randomUUID() } }), 201);
  expectStatus(await api.call('/v1/media/by-upload-key/not-a-uuid', { method: 'DELETE', token: alice.token }), 422);
});

test('upload-key cancellation preserves referenced photos and can finish after their last reference is removed', async t => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const key = randomUUID();
  const options = { method: 'POST', token: alice.token, body: PNG,
    headers: { 'content-type': 'image/png', 'idempotency-key': key } };
  const photo = expectStatus(await api.call('/v1/media', options), 201);
  const post = await publish(api, alice, reel({ mediaIds: [photo.id] }));
  const path = `/v1/media/by-upload-key/${key}`;
  const cleanup = () => api.call(path, { method: 'DELETE', token: alice.token });
  assert.equal(expectStatus(await cleanup(), 409).error.code, 'media_in_use');
  assert.deepEqual(expectStatus(await api.call('/v1/media', options), 200), photo);
  expectStatus(await api.call('/v1/me', { method: 'PATCH', token: alice.token,
    json: { handle: 'alice', avatarMediaId: photo.id } }), 200);
  expectStatus(await api.call(`/v1/memories/${post.id}`, { method: 'DELETE', token: alice.token }), 204);
  expectStatus(await cleanup(), 409, 'avatar references remain protected');
  expectStatus(await api.call('/v1/me', { method: 'PATCH', token: alice.token,
    json: { handle: 'alice', avatarMediaId: null } }), 200);
  expectStatus(await cleanup(), 204);
  expectStatus(await api.call('/v1/media', options), 410);
});

test('canceling an upload key before a partial image body completes prevents orphan photo creation', async t => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const key = randomUUID();
  let request;
  const response = new Promise((resolve, reject) => {
    request = httpRequest(new URL('/v1/media', api.url), { method: 'POST', headers: {
      authorization: `Bearer ${alice.token}`, 'content-type': 'image/png', 'content-length': PNG.length,
      'idempotency-key': key,
    } }, res => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, data: JSON.parse(Buffer.concat(chunks).toString('utf8')) }));
      res.on('error', reject);
    });
    request.on('error', reject);
    request.write(PNG.subarray(0, 8));
  });
  t.after(() => request.destroy());
  expectStatus(await api.call(`/v1/media/by-upload-key/${key}`, { method: 'DELETE', token: alice.token }), 204);
  request.end(PNG.subarray(8));
  assert.equal(expectStatus(await response, 410).error.code, 'media_deleted');
  await api.restart();
  expectStatus(await api.call('/v1/media', { method: 'POST', token: alice.token, body: PNG,
    headers: { 'content-type': 'image/png', 'idempotency-key': key } }), 410);
});

test('queued posts keep capture time while the feed lifetime begins on actual publication', async t => {
  let time = Date.parse('2026-10-20T12:00:00Z');
  const api = await fixture(t, { now: () => time });
  const alice = await register(api, 'alice');
  const draft = reel({ capturedAt: '2026-10-17T12:00:00.000Z' });
  const saved = await publish(api, alice, draft);
  assert.equal(saved.createdAt, draft.capturedAt);
  assert.equal(saved.publishedAt, '2026-10-20T12:00:00.000Z');
  assert.equal(saved.expiresAt, '2026-10-21T12:00:00.000Z');
  assert.deepEqual((await listAll(api, alice, '/v1/feed')).map(item => item.id), [saved.id]);
  await api.restart();
  time += 600_000;
  assert.deepEqual(expectStatus(await api.call('/v1/memories', { method: 'POST', token: alice.token, json: draft }), 200), saved);
  expectStatus(await api.call('/v1/memories', { method: 'POST', token: alice.token,
    json: { ...draft, capturedAt: '2026-10-16T12:00:00Z' } }), 409);
  for (const capturedAt of [null, 1, '', 'not-a-date', '2026-10-20', '2026-99-01T00:00:00Z',
    '1999-01-01T00:00:00Z', '2027-01-01T00:00:00Z', '2026-02-30T00:00:00Z']) {
    expectStatus(await api.call('/v1/memories', { method: 'POST', token: alice.token, json: reel({ capturedAt }) }), 422);
  }
  const slightlyFast = await publish(api, alice, reel({ capturedAt: new Date(time + 60_000).toISOString() }));
  assert.equal(slightlyFast.createdAt, new Date(time).toISOString(), 'clock skew cannot push a post into the future');
  const privateDraft = reel({ visibility: 'private', capturedAt: '2026-10-17T12:00:00Z' });
  const privatePost = await publish(api, alice, privateDraft);
  assert.equal(privatePost.publishedAt, null);
  time += 3600_000;
  const published = expectStatus(await api.call(`/v1/memories/${privatePost.id}`, { method: 'PATCH', token: alice.token,
    json: { visibility: 'public' } }), 200);
  assert.equal(published.createdAt, privatePost.createdAt);
  assert.equal(published.publishedAt, new Date(time).toISOString());
  assert.equal(published.expiresAt, new Date(time + 86400_000).toISOString());
});

test('pending cancellation is durable before a late post arrives and cannot cancel another owner records', async t => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const bob = await register(api, 'bob');
  const draft = reel();
  const plainPath = `/v1/memories/${draft.id}`;
  const cancelPath = `${plainPath}?cancelPending=true`;
  expectStatus(await api.call(plainPath, { method: 'DELETE', token: alice.token }), 404);
  expectStatus(await api.call(cancelPath, { method: 'DELETE', token: alice.token }), 204);
  expectStatus(await api.call(cancelPath, { method: 'DELETE', token: alice.token }), 204);
  expectStatus(await api.call(plainPath, { method: 'DELETE', token: alice.token }), 204);
  expectStatus(await api.call(cancelPath, { method: 'DELETE', token: bob.token }), 404);
  const late = await api.call('/v1/memories', { method: 'POST', token: alice.token, json: draft });
  assert.equal(expectStatus(late, 410).error.code, 'record_deleted');
  expectStatus(await api.call('/v1/memories', { method: 'POST', token: bob.token, json: draft }), 409);
  await api.restart();
  expectStatus(await api.call(cancelPath, { method: 'DELETE', token: alice.token }), 204);
  expectStatus(await api.call('/v1/memories', { method: 'POST', token: alice.token, json: draft }), 410);
  assert.deepEqual((await listAll(api, alice, '/v1/me/memories')), []);
  assert.deepEqual((await listAll(api, bob, '/v1/feed')), []);

  const bobsPost = await publish(api, bob);
  expectStatus(await api.call(`/v1/memories/${bobsPost.id}?cancelPending=true`, { method: 'DELETE', token: alice.token }), 404);
  expectStatus(await api.call(`/v1/memories/${bobsPost.id}`, { token: bob.token }), 200);
  const arrived = await publish(api, alice);
  expectStatus(await api.call(`/v1/memories/${arrived.id}?cancelPending=true`, { method: 'DELETE', token: alice.token }), 204);
  expectStatus(await api.call(`/v1/memories/${arrived.id}`, { token: alice.token }), 404);
  for (const query of ['cancelPending=false', 'cancelPending=1', 'cancelPending=true&cancelPending=true', 'unknown=true']) {
    expectStatus(await api.call(`/v1/memories/${randomUUID()}?${query}`, { method: 'DELETE', token: alice.token }), 422);
  }
});

test('cancelling while a publish body is still arriving prevents any feed publication', async t => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const draft = reel();
  const body = JSON.stringify(draft);
  let request;
  const response = new Promise((resolve, reject) => {
    request = httpRequest(new URL('/v1/memories', api.url), { method: 'POST', headers: {
      authorization: `Bearer ${alice.token}`, 'content-type': 'application/json', 'content-length': Buffer.byteLength(body),
    } }, res => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, data: JSON.parse(Buffer.concat(chunks).toString('utf8')) }));
      res.on('error', reject);
    });
    request.on('error', reject);
    request.write(body.slice(0, 1));
  });
  t.after(() => request.destroy());
  expectStatus(await api.call(`/v1/memories/${draft.id}?cancelPending=true`, { method: 'DELETE', token: alice.token }), 204);
  request.end(body.slice(1));
  assert.equal(expectStatus(await response, 410).error.code, 'record_deleted');
  assert.deepEqual(await listAll(api, alice, '/v1/feed'), []);
});

test('deleting a post reclaims only its unreferenced photos, preserves shared and queued uploads, and restores quota', async t => {
  const limit = 1024 * 1024;
  const api = await fixture(t, { userMediaLimitBytes: limit });
  const alice = await register(api, 'alice');
  // Local mode keeps bytes verbatim; no large native image allocations needed.
  const bytes = Buffer.alloc(limit / 2); PNG.copy(bytes);
  const uploadPhoto = () => api.call('/v1/media', { method: 'POST', token: alice.token, body: bytes,
    headers: { 'content-type': 'image/png', 'idempotency-key': randomUUID() } });
  const shared = expectStatus(await uploadPhoto(), 201);
  const queued = expectStatus(await uploadPhoto(), 201);
  const first = await publish(api, alice, reel({ mediaIds: [shared.id] }));
  const second = await publish(api, alice, reel({ mediaIds: [shared.id] }));
  const full = expectStatus(await uploadPhoto(), 413);
  assert.equal(full.error.code, 'media_quota');
  assert.match(full.error.message, /Delete photos, videos or posts/);
  expectStatus(await api.call(`/v1/memories/${first.id}`, { method: 'DELETE', token: alice.token }), 204);
  expectStatus(await api.call(shared.path, { token: alice.token }), 200);
  expectStatus(await uploadPhoto(), 413);
  expectStatus(await api.call(`/v1/memories/${second.id}`, { method: 'DELETE', token: alice.token }), 204);
  expectStatus(await api.call(shared.path, { token: alice.token }), 404);
  expectStatus(await api.call(queued.path, { token: alice.token }), 200, 'unlinked upload is still waiting for an offline post');
  expectStatus(await uploadPhoto(), 201, 'deletion frees the stored byte budget');
  const eventuallyPublished = await publish(api, alice, reel({ mediaIds: [queued.id] }));
  assert.equal(eventuallyPublished.media[0].id, queued.id);
});

test('post deletion keeps avatar media until replacement, and deleted upload keys never resurrect', async t => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const key = randomUUID();
  const uploadOptions = { method: 'POST', token: alice.token, body: PNG,
    headers: { 'content-type': 'image/png', 'idempotency-key': key } };
  const shared = expectStatus(await api.call('/v1/media', uploadOptions), 201);
  const replacement = await upload(api, alice);
  expectStatus(await api.call('/v1/me', { method: 'PATCH', token: alice.token,
    json: { handle: 'alice', avatarMediaId: shared.id } }), 200);
  const post = await publish(api, alice, reel({ mediaIds: [shared.id] }));
  expectStatus(await api.call(`/v1/memories/${post.id}`, { method: 'DELETE', token: alice.token }), 204);
  expectStatus(await api.call(shared.path, { token: alice.token }), 200);
  expectStatus(await api.call('/v1/me', { method: 'PATCH', token: alice.token,
    json: { handle: 'alice', avatarMediaId: replacement.id } }), 200);
  expectStatus(await api.call(shared.path, { token: alice.token }), 404);
  assert.equal(expectStatus(await api.call('/v1/media', uploadOptions), 410).error.code, 'media_deleted');
  expectStatus(await api.call('/v1/me', { method: 'DELETE', token: alice.token }), 204);
  const recreated = await register(api, 'alice');
  assert.notEqual(recreated.user.id, alice.user.id);
  expectStatus(await api.call('/v1/media', { ...uploadOptions, token: recreated.token }), 201);
});

test('deleted memories cannot be replayed or republish their media, even after restart', async (t) => {
  const api = await fixture(t);
  let alice = await register(api, 'alice');
  let bob = await register(api, 'bob');
  const media = await upload(api, alice);
  const draft = reel({ mediaIds: [media.id] });
  const memory = await publish(api, alice, draft);
  expectStatus(await api.call(`/v1/memories/${memory.id}`, {
    method: 'DELETE', token: alice.token,
  }), 204);

  for (const restart of [false, true]) {
    if (restart) {
      await api.restart();
      alice = expectStatus(await api.call('/v1/auth/login', {
        method: 'POST', json: { handle: 'alice', password: PASSWORD },
      }), 200);
      bob = expectStatus(await api.call('/v1/auth/login', {
        method: 'POST', json: { handle: 'bob', password: PASSWORD },
      }), 200);
    }
    const replay = expectStatus(await api.call('/v1/memories', {
      method: 'POST', token: alice.token, json: draft,
    }), 410);
    assert.equal(replay.error.code, 'record_deleted');
    expectStatus(await api.call('/v1/memories', {
      method: 'POST', token: bob.token, json: draft,
    }), 409);
    expectStatus(await api.call(`/v1/memories/${memory.id}`, { token: alice.token }), 404);
    expectStatus(await api.call(media.path, { token: bob.token }), 404);
    assert.equal(expectStatus(await api.call('/v1/feed', { token: bob.token }), 200).items.length, 0);
    assert.equal(expectStatus(await api.call('/v1/me/memories', { token: alice.token }), 200).items.length, 0);
  }
});

test('a check-in may reuse a nearby place but not a remote canonical location', async (t) => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const bob = await register(api, 'bob');
  const original = await publish(api, alice, {
    id: randomUUID(), kind: 'poi', visibility: 'public', location: LOCATION,
    place: { name: 'Neighborhood café', category: 'coffee' },
  });
  expectStatus(await api.call('/v1/memories', {
    method: 'POST', token: bob.token,
    json: {
      id: randomUUID(), kind: 'poi', visibility: 'public',
      location: { latitude: LOCATION.latitude + 0.01, longitude: LOCATION.longitude },
      placeId: original.place.id,
    },
  }), 422);
  const nearby = await publish(api, bob, {
    id: randomUUID(), kind: 'poi', visibility: 'public',
    location: { latitude: LOCATION.latitude + 0.0006, longitude: LOCATION.longitude },
    placeId: original.place.id,
  });
  assert.equal(nearby.place.id, original.place.id);
  assert.deepEqual(nearby.place.coordinate, original.place.coordinate);
  const bobsRecords = expectStatus(await api.call('/v1/me/memories', { token: bob.token }), 200);
  assert.deepEqual(bobsRecords.items.map((item) => item.id), [nearby.id]);
});

test('first publication starts feed time without changing capture time or refreshing on visibility toggles', async (t) => {
  let time = Date.UTC(2026, 9, 17, 12);
  const api = await fixture(t, { now: () => time });
  const alice = await register(api, 'alice');
  const bob = await register(api, 'bob');
  const saved = await publish(api, alice, reel({ visibility: 'private' }));
  assert.equal(saved.publishedAt, null);
  const captureTime = saved.createdAt;

  time += 2 * 24 * 60 * 60 * 1000;
  const laterCapture = await publish(api, alice);
  time += 1000;
  const publicationTime = time;
  const published = expectStatus(await api.call(`/v1/memories/${saved.id}`, {
    method: 'PATCH', token: alice.token, json: { visibility: 'public' },
  }), 200);
  assert.equal(published.createdAt, captureTime);
  assert.equal(published.publishedAt, new Date(publicationTime).toISOString());
  assert.equal(published.expiresAt, new Date(publicationTime + 24 * 60 * 60 * 1000).toISOString());
  const feed = await listAll(api, bob, '/v1/feed', 1);
  assert.deepEqual(feed.map((item) => item.id), [saved.id, laterCapture.id]);
  const archive = await listAll(api, alice, '/v1/me/memories', 1);
  assert.deepEqual(archive.map((item) => item.id), [laterCapture.id, saved.id]);

  time += 60 * 60 * 1000;
  const hidden = expectStatus(await api.call(`/v1/memories/${saved.id}`, {
    method: 'PATCH', token: alice.token, json: { visibility: 'private' },
  }), 200);
  assert.equal(hidden.publishedAt, published.publishedAt);
  assert.equal(hidden.expiresAt, published.expiresAt);
  assert.deepEqual((await listAll(api, bob, '/v1/feed', 1)).map((item) => item.id), [laterCapture.id]);
  time += 60 * 60 * 1000;
  const reshared = expectStatus(await api.call(`/v1/memories/${saved.id}`, {
    method: 'PATCH', token: alice.token, json: { visibility: 'public' },
  }), 200);
  assert.equal(reshared.createdAt, captureTime);
  assert.equal(reshared.publishedAt, published.publishedAt);
  assert.equal(reshared.expiresAt, published.expiresAt);

  time = publicationTime + 24 * 60 * 60 * 1000 + 1;
  assert.equal(expectStatus(await api.call('/v1/feed', { token: bob.token }), 200).items.length, 0);
  expectStatus(await api.call(`/v1/memories/${saved.id}`, { token: bob.token }), 200);
});

test('active feed expires after 24 hours while archives and viewport history remain', async (t) => {
  let time = Date.UTC(2026, 9, 17, 12);
  const api = await fixture(t, { now: () => time });
  const alice = await register(api, 'alice');
  const bob = await register(api, 'bob');
  const old = await publish(api, alice, reel({ location: { latitude: 10, longitude: 179.8 } }));
  await publish(api, alice, reel({
    visibility: 'private', location: { latitude: 10, longitude: -179.7 },
  }));
  time += 25 * 60 * 60 * 1000;
  const recent = await publish(api, alice, reel({ location: { latitude: 10, longitude: -179.8 } }));
  const feed = expectStatus(await api.call('/v1/feed', { token: bob.token }), 200);
  assert.deepEqual(feed.items.map((item) => item.id), [recent.id]);
  expectStatus(await api.call(`/v1/memories/${old.id}`, { token: bob.token }), 200);
  assert.equal(expectStatus(await api.call('/v1/me/memories', { token: alice.token }), 200).items.length, 3);

  const crossing = expectStatus(await api.call(
    '/v1/map/memories?west=179&east=-179&south=9&north=11', { token: bob.token },
  ), 200);
  assert.deepEqual(new Set(crossing.items.map((item) => item.id)), new Set([old.id, recent.id]));
  const outside = expectStatus(await api.call(
    '/v1/map/memories?west=-123&east=-121&south=37&north=38', { token: bob.token },
  ), 200);
  assert.equal(outside.items.length, 0);
});

test('cursor pagination is stable even when records have the same timestamp', async (t) => {
  const api = await fixture(t, { now: () => Date.UTC(2026, 9, 17) });
  const alice = await register(api, 'alice');
  const expected = new Set();
  for (let index = 0; index < 5; index += 1) {
    expected.add((await publish(api, alice)).id);
  }
  for (const path of [
    '/v1/me/memories', '/v1/feed',
    '/v1/map/memories?west=-123&east=-121&south=37&north=38',
  ]) {
    const items = await listAll(api, alice, path);
    assert.equal(items.length, expected.size);
    assert.deepEqual(new Set(items.map((item) => item.id)), expected);
  }
  expectStatus(await api.call('/v1/feed?cursor=not-a-valid-cursor', { token: alice.token }), 422);
  expectStatus(await api.call('/v1/feed?limit=0', { token: alice.token }), 422);
});

test('accounts, private records, and media survive a server restart', async (t) => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  await register(api, 'bob');
  const media = await upload(api, alice);
  const memory = await publish(api, alice, reel({ visibility: 'private', mediaIds: [media.id] }));
  await api.restart();

  const login = expectStatus(await api.call('/v1/auth/login', {
    method: 'POST', json: { handle: 'alice', password: PASSWORD },
  }), 200);
  assert.equal(login.user.id, alice.user.id);
  const restored = expectStatus(await api.call(`/v1/memories/${memory.id}`, { token: login.token }), 200);
  assert.equal(restored.visibility, 'private');
  assert.equal(restored.media[0].id, media.id);
  assert.equal(expectStatus(await api.call('/v1/me/memories', { token: login.token }), 200).items.length, 1);
  const image = await fetch(new URL(media.path, api.url), {
    headers: { authorization: `Bearer ${login.token}` },
  });
  assert.equal(image.status, 200);
  assert.deepEqual(Buffer.from(await image.arrayBuffer()), PNG);
  const bob = expectStatus(await api.call('/v1/auth/login', {
    method: 'POST', json: { handle: 'bob', password: PASSWORD },
  }), 200);
  expectStatus(await api.call(`/v1/memories/${memory.id}`, { token: bob.token }), 404);
  expectStatus(await api.call(media.path, { token: bob.token }), 404);
});

test('sessions expire after seven days', async (t) => {
  let time = Date.UTC(2026, 9, 17);
  const api = await fixture(t, { now: () => time });
  const alice = await register(api, 'alice');
  time += 7 * 24 * 60 * 60 * 1000 + 1;
  expectStatus(await api.call('/v1/me', { token: alice.token }), 401);
  const login = expectStatus(await api.call('/v1/auth/login', {
    method: 'POST', json: { handle: 'alice', password: PASSWORD },
  }), 200);
  expectStatus(await api.call('/v1/me', { token: login.token }), 200);
});

test('authentication rate limiting recovers after its one-minute window', async (t) => {
  let time = Date.UTC(2026, 9, 17);
  const api = await fixture(t, { now: () => time, authLimit: 2 });
  const alice = await register(api, 'alice');
  expectStatus(await api.call('/v1/auth/login', {
    method: 'POST', json: { handle: 'alice', password: 'incorrect-password' },
  }), 401);
  const limited = await api.call('/v1/auth/login', {
    method: 'POST', json: { handle: 'alice', password: PASSWORD },
  });
  expectStatus(limited, 429);
  assert.ok(Number(limited.headers.get('retry-after')) > 0);
  expectStatus(await api.call('/v1/me', { token: alice.token }), 200);
  time += 60_000;
  const login = expectStatus(await api.call('/v1/auth/login', {
    method: 'POST', json: { handle: 'alice', password: PASSWORD },
  }), 200);
  assert.equal(login.user.id, alice.user.id);
  expectStatus(await api.call('/v1/me', { token: login.token }), 200);
});

test('local HTTP endpoints reject unrelated browser origins and forged hosts', async (t) => {
  const api = await fixture(t);
  expectStatus(await api.call('/health'), 200);
  expectStatus(await api.call('/health', {
    headers: { origin: 'https://unrelated.example' },
  }), 403);
  // fetch replaces Host with the URL host; use HTTP directly to exercise rebinding protection.
  const forgedHostStatus = await new Promise((resolve, reject) => {
    const request = httpRequest(new URL('/health', api.url), {
      headers: { host: 'unrelated.example' },
    }, (response) => {
      response.resume();
      response.on('end', () => resolve(response.statusCode));
      response.on('error', reject);
    });
    request.on('error', reject);
    request.end();
  });
  assert.equal(forgedHostStatus, 403);
  expectStatus(await api.call('/health', {
    headers: { origin: api.url },
  }), 200);
});

test('malformed input is rejected without writing records', async (t) => {
  const api = await fixture(t);
  for (const json of [
    { handle: 'ab', password: PASSWORD },
    { handle: 'a'.repeat(33), password: PASSWORD },
    { handle: 'not a handle', password: PASSWORD },
    { handle: 'alice', password: 'too-short' },
    { handle: 'alice', password: 'a'.repeat(129) },
    { handle: 'alice', password: PASSWORD, role: 'admin' },
  ]) {
    expectStatus(await api.call('/v1/auth/register', { method: 'POST', json }), 422);
  }
  const alice = await register(api, 'alice');
  expectStatus(await api.call('/v1/memories', {
    method: 'POST', token: alice.token, body: '{not json',
    headers: { 'content-type': 'application/json' },
  }), 400);
  expectStatus(await api.call('/v1/memories', {
    method: 'POST', token: alice.token, body: '{}',
    headers: { 'content-type': 'text/plain' },
  }), 415);

  const invalid = [
    reel({ id: 'not-a-uuid' }),
    reel({ kind: 'folder' }),
    reel({ visibility: 'friends' }),
    reel({ location: { latitude: 91, longitude: 0 } }),
    reel({ location: { latitude: 0, longitude: -181 } }),
    reel({ location: { latitude: '37', longitude: 0 } }),
    reel({ caption: '', mediaIds: [] }),
    reel({ unexpectedProperty: true }),
    reel({ place: { name: 'Not a reel field', category: 'coffee' } }),
    reel({ mediaIds: Array.from({ length: 10 }, () => randomUUID()) }),
    { id: randomUUID(), kind: 'poi', visibility: 'public', location: LOCATION },
    {
      id: randomUUID(), kind: 'poi', visibility: 'public', location: LOCATION,
      place: { name: 'A place', category: 'coffee' }, caption: 'No POI captions',
    },
    {
      id: randomUUID(), kind: 'poi', visibility: 'public', location: LOCATION,
      place: { name: 'A place', category: 'coffee' }, placeId: randomUUID(),
    },
    {
      id: randomUUID(), kind: 'poi', visibility: 'public', location: LOCATION,
      place: { name: 'A place', category: 'coffee' }, mediaIds: [randomUUID(), randomUUID()],
    },
    {
      id: randomUUID(), kind: 'poi', visibility: 'public', location: LOCATION,
      place: { name: 'A place', category: 'not-a-category' },
    },
  ];
  for (const json of invalid) {
    expectStatus(await api.call('/v1/memories', { method: 'POST', token: alice.token, json }), 422);
  }
  for (const query of [
    '', '?west=-123&east=-121&south=37',
    '?west=-181&east=180&south=-90&north=90',
    '?west=-123&east=-121&south=38&north=37',
    '?west=no&east=-121&south=37&north=38',
  ]) {
    expectStatus(await api.call(`/v1/map/memories${query}`, { token: alice.token }), 422);
  }
  assert.equal(expectStatus(await api.call('/v1/me/memories', { token: alice.token }), 200).items.length, 0);
});

test('media uploads enforce authentication, signatures, supported types, and size', async (t) => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const uploadOptions = { method: 'POST', body: PNG, headers: { 'content-type': 'image/png' } };
  expectStatus(await api.call('/v1/media', uploadOptions), 401);
  expectStatus(await api.call('/v1/media', {
    ...uploadOptions, token: alice.token, headers: { 'content-type': 'image/gif' },
  }), 415);
  expectStatus(await api.call('/v1/media', {
    ...uploadOptions, token: alice.token, headers: { 'content-type': 'image/jpeg' },
  }), 415);
  expectStatus(await api.call('/v1/media', {
    ...uploadOptions, token: alice.token, body: Buffer.from('not an image'),
  }), 415);
  const oversized = Buffer.alloc(10 * 1024 * 1024 + 1);
  PNG.copy(oversized);
  expectStatus(await api.call('/v1/media', {
    ...uploadOptions, token: alice.token, body: oversized,
  }), 413);
  await upload(api, alice);
});

test('Apple source identity deduplicates landmarks without leaking private visits or allowing edits', async (t) => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const bob = await register(api, 'bob');
  const photo = await upload(api, alice);
  const sourceId = randomUUID();
  const place = {
    name: 'Apple neighborhood café', category: 'coffee', sourceId,
    coordinate: { latitude: LOCATION.latitude + 0.0002, longitude: LOCATION.longitude },
  };
  const hidden = await publish(api, alice, {
    id: randomUUID(), kind: 'poi', visibility: 'private', location: LOCATION,
    place, mediaIds: [photo.id],
  });
  assert.deepEqual(hidden.place.coordinate, place.coordinate);
  assert.equal(hidden.place.sourceId, sourceId);
  assert.deepEqual(hidden.owner, alice.user);
  assert.notDeepEqual(hidden.location, hidden.place.coordinate);

  // A server ID alone cannot be used to discover a private place/check-in.
  expectStatus(await api.call('/v1/memories', {
    method: 'POST', token: bob.token, json: {
      id: randomUUID(), kind: 'poi', visibility: 'public', location: LOCATION,
      placeId: hidden.place.id,
    },
  }), 404);
  const visible = await publish(api, bob, {
    id: randomUUID(), kind: 'poi', visibility: 'public', location: LOCATION,
    place: { ...place, name: 'Cannot rename the place', category: 'market', coordinate: LOCATION },
  });
  assert.deepEqual(visible.place, hidden.place);
  const publicPlaces = await listAll(api, bob, `/v1/users/${bob.user.id}/memories`);
  assert.equal(publicPlaces[0].place.sourceId, sourceId);
  const privatePlaces = await listAll(api, alice, '/v1/me/memories');
  assert.equal(privatePlaces[0].place.sourceId, sourceId);
  assert.deepEqual(visible.owner, bob.user);
  assert.deepEqual(visible.media, []);
  expectStatus(await api.call(`/v1/memories/${hidden.id}`, { token: bob.token }), 404);
  expectStatus(await api.call(photo.path, { token: bob.token }), 404);
  assert.deepEqual((await listAll(api, bob, '/v1/feed')).map(item => item.id), [visible.id]);

  await api.restart();
  const repeated = await publish(api, alice, {
    id: randomUUID(), kind: 'poi', visibility: 'private', location: LOCATION, place,
  });
  assert.equal(repeated.place.id, hidden.place.id);
  assert.equal(repeated.place.sourceId, sourceId, 'source aliases survive a server restart');
  for (const [account, memory] of [[alice, hidden], [bob, visible], [alice, repeated]]) {
    expectStatus(await api.call(`/v1/memories/${memory.id}`, {
      method: 'DELETE', token: account.token,
    }), 204);
  }
  await api.restart();
  const recreated = await publish(api, bob, {
    id: randomUUID(), kind: 'poi', visibility: 'public', location: LOCATION, place,
  });
  assert.deepEqual(recreated.place, hidden.place, 'deleting all visits must not change external place identity');
  expectStatus(await api.call(photo.path, { token: bob.token }), 404);
});

test('new and reused Apple places must remain near the submitted location', async (t) => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const sourceId = randomUUID();
  const base = { id: randomUUID(), kind: 'poi', visibility: 'private', location: LOCATION };
  for (const place of [
    { name: 'Far away', category: 'coffee', coordinate: { latitude: 47.6, longitude: -122.3 } },
    { name: 'Bad coordinate', category: 'coffee', coordinate: { latitude: 91, longitude: 0 } },
    { name: 'Bad source', category: 'coffee', sourceId: 'not-a-uuid' },
    { name: 'Unsupported field', category: 'coffee', provider: 'apple' },
  ]) {
    expectStatus(await api.call('/v1/memories', {
      method: 'POST', token: alice.token, json: { ...base, place },
    }), 422);
  }
  const original = await publish(api, alice, {
    ...base, place: { name: 'Canonical café', category: 'coffee', sourceId, coordinate: LOCATION },
  });
  const far = { latitude: 47.6, longitude: -122.3 };
  expectStatus(await api.call('/v1/memories', {
    method: 'POST', token: alice.token, json: {
      ...base, id: randomUUID(), location: far,
      place: { name: 'Spoofed local café', category: 'coffee', sourceId, coordinate: far },
    },
  }), 422);
  const details = expectStatus(await api.call(`/v1/memories/${original.id}`, { token: alice.token }), 200);
  assert.equal(details.place.name, 'Canonical café');
  assert.deepEqual(details.place.coordinate, LOCATION);
  assert.equal((await listAll(api, alice, '/v1/me/memories')).length, 1);
});

test('archive hiding is private, persistent, and separate from public record deletion', async (t) => {
  const api = await fixture(t);
  const alice = await register(api, 'alice');
  const bob = await register(api, 'bob');
  const photo = await upload(api, alice);
  const firstDraft = {
    id: randomUUID(), kind: 'poi', visibility: 'public', location: LOCATION,
    place: { name: 'Shared café', category: 'coffee' }, mediaIds: [photo.id],
  };
  const first = await publish(api, alice, firstDraft);
  const privateVisit = await publish(api, alice, {
    id: randomUUID(), kind: 'poi', visibility: 'private', location: LOCATION, placeId: first.place.id,
  });
  const bobsVisit = await publish(api, bob, {
    id: randomUUID(), kind: 'poi', visibility: 'private', location: LOCATION, placeId: first.place.id,
  });
  const post = await publish(api, alice);
  const hide = (account, kind, id) => api.call('/v1/me/archive/hide', {
    method: 'POST', token: account.token, json: { kind, id },
  });
  expectStatus(await hide(bob, 'reel', post.id), 404);
  expectStatus(await hide(alice, 'poi', first.id), 404);
  expectStatus(await hide(alice, 'reel', first.id), 404);
  expectStatus(await hide(alice, 'poi', first.place.id), 204);
  expectStatus(await hide(alice, 'poi', first.place.id), 204);
  expectStatus(await hide(alice, 'reel', post.id), 204);
  assert.equal((await listAll(api, alice, '/v1/me/memories')).length, 0);
  assert.deepEqual((await listAll(api, bob, '/v1/me/memories')).map(item => item.id), [bobsVisit.id]);
  assert.deepEqual(new Set((await listAll(api, bob, '/v1/feed')).map(item => item.id)), new Set([first.id, post.id]));
  expectStatus(await api.call(`/v1/memories/${first.id}`, { token: bob.token }), 200);
  expectStatus(await api.call(`/v1/memories/${privateVisit.id}`, { token: alice.token }), 200);
  expectStatus(await api.call(`/v1/memories/${privateVisit.id}`, { token: bob.token }), 404);
  expectStatus(await api.call(photo.path, { token: bob.token }), 200);
  assert.deepEqual(new Set((await listAll(api, bob,
    '/v1/map/memories?west=-123&east=-121&south=37&north=38')).map(item => item.id)), new Set([first.id, post.id]));

  await api.restart();
  assert.equal((await listAll(api, alice, '/v1/me/memories')).length, 0);
  expectStatus(await api.call('/v1/memories', { method: 'POST', token: alice.token, json: firstDraft }), 200);
  assert.equal((await listAll(api, alice, '/v1/me/memories')).length, 0, 'retry must not undo a later hide');
  const newVisit = await publish(api, alice, {
    id: randomUUID(), kind: 'poi', visibility: 'private', location: LOCATION, placeId: first.place.id,
  });
  assert.deepEqual(new Set((await listAll(api, alice, '/v1/me/memories')).map(item => item.id)),
    new Set([first.id, privateVisit.id, newVisit.id]));
  const newReel = await publish(api, alice);
  assert.ok((await listAll(api, alice, '/v1/me/memories')).some(item => item.id === newReel.id));
  assert.ok(!(await listAll(api, alice, '/v1/me/memories')).some(item => item.id === post.id));
  for (const json of [{ kind: 'folder', id: post.id }, { kind: 'reel', id: 'invalid' },
    { kind: 'reel', id: post.id, ownerId: bob.user.id }]) {
    expectStatus(await api.call('/v1/me/archive/hide', { method: 'POST', token: alice.token, json }), 422);
  }
});

test('public profiles expose only public historical memories with stable owner identities', async (t) => {
  let time = Date.parse('2026-10-17T12:00:00Z');
  const api = await fixture(t, { now: () => time });
  const alice = await register(api, 'alice');
  const bob = await register(api, 'bob');
  const profilePath = `/v1/users/${alice.user.id}`;
  expectStatus(await api.call(profilePath), 401);
  const profile = expectStatus(await api.call(profilePath, { token: bob.token }), 200);
  assert.deepEqual(profile, { user: alice.user });
  expectStatus(await api.call(`/v1/users/${randomUUID()}`, { token: bob.token }), 404);
  expectStatus(await api.call(`/v1/users/${randomUUID()}/memories`, { token: bob.token }), 404);
  const first = await publish(api, alice);
  const second = await publish(api, alice);
  const hidden = await publish(api, alice, reel({ visibility: 'private' }));
  await publish(api, bob);
  expectStatus(await api.call('/v1/me/archive/hide', {
    method: 'POST', token: alice.token, json: { kind: 'reel', id: first.id },
  }), 204);
  time += 2 * 24 * 60 * 60 * 1000;
  assert.equal((await listAll(api, bob, '/v1/feed')).length, 0);
  const memories = await listAll(api, bob, `${profilePath}/memories`, 1);
  assert.deepEqual(new Set(memories.map(item => item.id)), new Set([first.id, second.id]));
  assert.ok(memories.every(item => item.visibility === 'public' && item.ownerId === alice.user.id));
  for (const memory of memories) assert.deepEqual(memory.owner, alice.user);
  const ownPublicProfile = await listAll(api, alice, `${profilePath}/memories`);
  assert.ok(!ownPublicProfile.some(item => item.id === hidden.id), 'profile endpoint stays public even for its owner');
});
