import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { request as httpRequest } from 'node:http';
import { DatabaseSync } from 'node:sqlite';
import { createBackend } from '../src/server.mjs';
import { issueSession } from '../src/security.mjs';
import { poiVisitDay } from '../src/poi-visit-day.mjs';

const LA = { latitude: 34.0522, longitude: -118.2437 };
const DAY = 86_400_000;
const socialTables = ['media_likes', 'saved_places', 'direct_messages'];
const status = (result, expected = 200) => {
  assert.equal(result.status, expected, JSON.stringify(result.data));
  return result.data;
};

async function fixture(t, beta = false) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-poi-social-'));
  const databasePath = join(directory, 'test.sqlite');
  let time = Date.UTC(2026, 10, 24, 12);
  const configuration = { databasePath, now: () => time, ...(beta ? {
    deployment: { mode: 'beta', publicOrigin: 'https://beta.maptalk.example' },
    google: { iosClientID: '100000-ios.apps.googleusercontent.com',
      serverClientID: '100000-server.apps.googleusercontent.com', clientSecret: 'fixture-only',
      fetch: async () => { throw new Error('No external authentication requests in this fixture.'); } },
  } : {}) };
  let backend = createBackend(configuration), address = await backend.listen(0);
  t.after(async () => { await backend.close(); await rm(directory, { recursive: true, force: true }); });
  const api = {
    advance(ms) { time += ms; },
    db(work) {
      const db = new DatabaseSync(databasePath);
      try { db.exec('PRAGMA foreign_keys = ON;'); return work(db); } finally { db.close(); }
    },
    async restart() { await backend.close(); backend = createBackend(configuration); address = await backend.listen(0); },
    account(handle) {
      return api.db(db => {
        const id = randomUUID();
        db.prepare('INSERT INTO users(id, handle, password_hash, created_at) VALUES (?, ?, ?, ?)')
          .run(id, handle, 'fixture-only', time);
        if (beta) db.prepare("INSERT INTO beta_members(user_id, status, updated_at) VALUES (?, 'active', ?)").run(id, time);
        return { id, ...issueSession(db, id, time) };
      });
    },
    place(coordinate = LA) {
      const id = randomUUID();
      api.db(db => db.prepare('INSERT INTO places(id, name, category, latitude, longitude) VALUES (?, ?, ?, ?, ?)')
        .run(id, 'Fixture place', 'coffee', coordinate.latitude, coordinate.longitude));
      return { id, ...coordinate };
    },
    memory(owner, place, { at = time, visibility = 'public', moderation = 'approved', publishedAt = at, media = [] } = {}) {
      const id = randomUUID();
      api.db(db => {
        db.prepare(`INSERT INTO memories(id, owner_id, kind, visibility, latitude, longitude, caption, place_id,
          created_at, published_at, expires_at, request_hash, moderation_status)
          VALUES (?, ?, 'poi', ?, ?, ?, '', ?, ?, ?, ?, ?, ?)`)
          .run(id, owner.id, visibility, place.latitude, place.longitude, place.id, at, publishedAt, at + DAY, `fixture:${id}`, moderation);
        for (let i = 0; i < media.length; i++) db.prepare('INSERT INTO memory_media(memory_id, media_id, position) VALUES (?, ?, ?)').run(id, media[i], i);
      });
      return { id, placeId: place.id, ownerId: owner.id };
    },
    media(owner, mime = 'image/jpeg') {
      const id = randomUUID(), bytes = Buffer.from('fixture-media-bytes-not-for-decoding');
      api.db(db => db.prepare('INSERT INTO media(id, owner_id, mime_type, byte_count, bytes, created_at) VALUES (?, ?, ?, ?, ?, ?)')
        .run(id, owner.id, mime, bytes.length, bytes, time));
      return id;
    },
    call(path, account, method = 'GET', body) {
      return new Promise((resolve, reject) => {
        const req = httpRequest(new URL(path, address.url), { method, headers: {
          ...(beta ? { host: 'beta.maptalk.example' } : {}),
          ...(account ? { authorization: `Bearer ${account.token}` } : {}),
          ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
        } }, response => {
          let text = '';
          response.on('data', chunk => { text += chunk; });
          response.on('end', () => resolve({ status: response.statusCode, data: text ? JSON.parse(text) : null }));
          response.on('error', reject);
        });
        req.on('error', reject);
        req.end(body === undefined ? undefined : JSON.stringify(body));
      });
    },
    async counts(viewer, pairs) {
      return status(await api.call('/v1/places/visit-counts', viewer, 'POST', { items: pairs }));
    },
  };
  return api;
}

test('canonical visit day follows place civil timezone, including China, Hawaii and DST rather than viewer/solar offset', () => {
  const cases = [
    ['2026-11-24T08:30:00Z', 21.3099, -157.8581, '2026-11-23'],
    ['2026-11-24T16:30:00Z', 30.5728, 104.0668, '2026-11-25'],
    ['2026-07-01T07:30:00Z', LA.latitude, LA.longitude, '2026-07-01'],
    ['2026-01-01T07:30:00Z', LA.latitude, LA.longitude, '2025-12-31'],
    ['2026-03-08T09:59:00Z', LA.latitude, LA.longitude, '2026-03-08'],
    ['2026-03-08T10:01:00Z', LA.latitude, LA.longitude, '2026-03-08'],
  ];
  for (const [time, latitude, longitude, expected] of cases) {
    assert.equal(poiVisitDay(Date.parse(time), latitude, longitude), expected);
  }
});

test('batch counts cover durable history and distinct canonical days, not pages, media or duplicate records', async t => {
  const api = await fixture(t), owner = api.account('owner'), viewer = api.account('viewer'), place = api.place();
  const photo = api.media(owner), video = api.media(owner, 'video/mp4');
  const early = Date.parse('2025-01-01T07:59:00Z'), later = Date.parse('2025-01-01T08:00:00Z');
  const first = api.memory(owner, place, { at: early, media: [photo, video] });
  api.memory(owner, place, { at: later });
  for (let i = 0; i < 125; i++) api.memory(owner, place, { at: later + i * 1000 });
  api.memory(owner, place, { at: later + DAY, visibility: 'private', publishedAt: null });
  api.db(db => db.prepare("INSERT INTO archive_hidden(owner_id, kind, target_id, hidden_at) VALUES (?, 'poi', ?, ?)")
    .run(owner.id, place.id, early));
  const pair = { placeId: place.id, ownerId: owner.id };
  assert.deepEqual(await api.counts(owner, [pair, pair]), { items: [{ ...pair, count: 3 }], dayPolicy: 'place-iana-v1' });
  assert.equal((await api.counts(viewer, [pair])).items[0].count, 2);
  const memory = status(await api.call(`/v1/memories/${first.id}`, viewer));
  assert.equal(memory.visitDay, '2024-12-31');
  assert.equal(memory.createdAt, new Date(early).toISOString());
  assert.equal(memory.publishedAt, new Date(early).toISOString());
  assert.equal(status(await api.call('/v1/feed', viewer)).items.length, 0, 'expired feed does not remove historical days');
  assert.equal(status(await api.call('/health')).features.poiVisitCounts, true);
});

test('counts recompute permissions, moderation, deletion and bilateral blocks without exposing nonexistent pairs', async t => {
  const api = await fixture(t), owner = api.account('owner'), viewer = api.account('viewer'), place = api.place();
  const pair = { placeId: place.id, ownerId: owner.id }, start = Date.UTC(2025, 1, 1, 12);
  const shared = api.memory(owner, place, { at: start });
  api.memory(owner, place, { at: start + DAY, visibility: 'private' });
  api.memory(owner, place, { at: start + DAY * 2, moderation: 'rejected' });
  api.memory(owner, place, { at: start + DAY * 3, moderation: 'pending' });
  assert.equal((await api.counts(viewer, [pair])).items[0].count, 1);
  assert.equal((await api.counts(owner, [pair])).items[0].count, 4, 'same owner-visible policy as the existing private archive');
  for (const [blocker, blocked] of [[owner, viewer], [viewer, owner]]) {
    api.db(db => db.prepare('INSERT INTO user_blocks(blocker_id, blocked_id, created_at) VALUES (?, ?, 1)').run(blocker.id, blocked.id));
    assert.equal((await api.counts(viewer, [pair])).items[0].count, 0);
    api.db(db => db.exec('DELETE FROM user_blocks'));
  }
  api.db(db => db.prepare('UPDATE users SET deletion_started_at = 1 WHERE id = ?').run(owner.id));
  assert.equal((await api.counts(viewer, [pair])).items[0].count, 0);
  api.db(db => db.prepare('UPDATE users SET deletion_started_at = NULL WHERE id = ?').run(owner.id));
  status(await api.call(`/v1/memories/${shared.id}`, owner, 'DELETE'), 204);
  assert.equal((await api.counts(viewer, [pair])).items[0].count, 0);
  const unknown = { placeId: randomUUID(), ownerId: randomUUID() };
  assert.deepEqual((await api.counts(viewer, [unknown])).items, [{ ...unknown, count: 0 }]);
});

test('counts authenticate and strictly bound/validate batches and identifiers', async t => {
  const api = await fixture(t), user = api.account('viewer'), item = { placeId: randomUUID(), ownerId: randomUUID() };
  status(await api.call('/v1/places/visit-counts', null, 'POST', { items: [item] }), 401);
  for (const body of [{}, { items: [] }, { items: Array(101).fill(item) }, { items: [null] },
    { items: [{ ...item, ownerId: 'bad' }] }, { items: [{ ...item, count: 9 }] }, { items: [item], admin: true }]) {
    status(await api.call('/v1/places/visit-counts', user, 'POST', body), 422);
  }
  status(await api.call('/v1/places/visit-counts?limit=1', user, 'POST', { items: [item] }), 422);
  assert.equal((await api.counts(user, Array(100).fill(item))).items.length, 1);
});

test('likes target one exact authorized photo/video attachment and persist idempotently without changing posts', async t => {
  const api = await fixture(t), owner = api.account('owner'), viewer = api.account('viewer'), third = api.account('third');
  const place = api.place(), photo = api.media(owner), video = api.media(owner, 'video/mp4'), unrelated = api.media(owner);
  const memory = api.memory(owner, place, { media: [photo, video] });
  const path = media => `/v1/memories/${memory.id}/media/${media}/like`;
  const before = api.db(db => db.prepare('SELECT * FROM memories WHERE id = ?').get(memory.id));
  status(await api.call(path(photo), null), 401);
  status(await api.call(path(unrelated), viewer, 'PUT', { liked: true }), 404);
  status(await api.call(path(photo), viewer, 'PUT', { liked: 1 }), 422);
  assert.deepEqual(status(await api.call(path(photo), viewer, 'PUT', { liked: true })), { liked: true, count: 1 });
  assert.deepEqual(status(await api.call(path(photo), viewer, 'PUT', { liked: true })), { liked: true, count: 1 });
  assert.deepEqual(status(await api.call(path(video), viewer)), { liked: false, count: 0 });
  status(await api.call(path(photo), third, 'PUT', { liked: true }));
  await api.restart();
  assert.deepEqual(status(await api.call(path(photo), viewer)), { liked: true, count: 2 });
  api.db(db => db.prepare('INSERT INTO user_blocks(blocker_id, blocked_id, created_at) VALUES (?, ?, 1)').run(viewer.id, third.id));
  assert.equal(status(await api.call(path(photo), viewer)).count, 1, 'blocked liker is not counted to this viewer');
  assert.deepEqual(status(await api.call(path(photo), viewer, 'PUT', { liked: false })), { liked: false, count: 0 });
  assert.deepEqual(api.db(db => db.prepare('SELECT * FROM memories WHERE id = ?').get(memory.id)), before);
  api.db(db => db.prepare("UPDATE memories SET visibility = 'private' WHERE id = ?").run(memory.id));
  status(await api.call(path(photo), viewer), 404);
  status(await api.call(path(photo), viewer, 'PUT', { liked: true }), 404);
  status(await api.call(path(photo), owner));
  status(await api.call(`/v1/memories/${memory.id}`, owner, 'DELETE'), 204);
  assert.equal(api.db(db => db.prepare('SELECT COUNT(*) n FROM media_likes').get().n), 0);
});

test('saved places are private, paginated, place-specific and withdraw inaccessible sources without leaking visits', async t => {
  const api = await fixture(t), owner = api.account('owner'), viewer = api.account('viewer'), places = [api.place(), api.place()];
  const memories = places.map(place => api.memory(owner, place));
  for (const place of places) {
    assert.deepEqual(status(await api.call(`/v1/places/${place.id}/saved`, viewer, 'PUT', { saved: true })), { saved: true });
  }
  assert.deepEqual(status(await api.call(`/v1/places/${places[0].id}/saved`, owner)), { saved: false });
  await api.restart();
  const first = status(await api.call('/v1/me/saved-places?limit=1', viewer));
  assert.equal(first.items.length, 1); assert.ok(first.nextCursor);
  const second = status(await api.call(`/v1/me/saved-places?limit=1&cursor=${first.nextCursor}`, viewer));
  assert.equal(new Set([first.items[0].place.id, second.items[0].place.id]).size, 2);
  assert.equal(second.nextCursor, null);
  api.db(db => db.prepare("UPDATE memories SET visibility = 'private' WHERE id = ?").run(memories[0].id));
  assert.equal(status(await api.call('/v1/me/saved-places', viewer)).items.length, 1);
  status(await api.call(`/v1/places/${places[0].id}/saved`, viewer), 404);
  assert.deepEqual(status(await api.call(`/v1/places/${places[0].id}/saved`, viewer, 'PUT', { saved: false })), { saved: false });
  status(await api.call(`/v1/places/${places[0].id}/saved`, owner, 'PUT', { saved: true }));
  status(await api.call(`/v1/places/${randomUUID()}/saved`, viewer, 'PUT', { saved: true }), 404);
  status(await api.call('/v1/me/saved-places?limit=0', viewer), 422);
});

test('direct messages are participant-only, idempotent, newest-first and thread lists expose only the current viewer', async t => {
  const api = await fixture(t), sender = api.account('sender'), peer = api.account('peer'), stranger = api.account('stranger');
  const path = `/v1/messages/${peer.id}`, body = { id: randomUUID(), text: '  Hello  ' };
  status(await api.call(path, null, 'POST', body), 401);
  const message = status(await api.call(path, sender, 'POST', body), 201);
  assert.deepEqual(message, { id: body.id, senderId: sender.id, recipientId: peer.id, text: 'Hello',
    createdAt: message.createdAt, context: null });
  assert.deepEqual(status(await api.call(path, sender, 'POST', body)), message);
  status(await api.call(path, sender, 'POST', { ...body, text: 'different' }), 409);
  status(await api.call(path, stranger, 'POST', body), 409);
  api.advance(1000);
  const reply = status(await api.call(`/v1/messages/${sender.id}`, peer, 'POST', { id: randomUUID(), text: 'Hi back' }), 201);
  await api.restart();
  const first = status(await api.call(`${path}?limit=1`, sender));
  assert.equal(first.items[0].id, reply.id); assert.ok(first.nextCursor);
  assert.equal(status(await api.call(`${path}?limit=1&cursor=${first.nextCursor}`, sender)).items[0].id, message.id);
  assert.equal(status(await api.call(path, stranger)).items.length, 0);
  assert.equal(status(await api.call('/v1/messages', stranger)).items.length, 0);
  const threads = status(await api.call('/v1/messages', sender)).items;
  assert.equal(threads.length, 1); assert.equal(threads[0].peer.id, peer.id); assert.equal(threads[0].lastMessage.id, reply.id);
  assert.equal(threads[0].updatedAt, reply.createdAt);
});

test('message media context requires the recipient exact attachment and is hidden when permission/source is revoked while text remains', async t => {
  const api = await fixture(t), sender = api.account('sender'), peer = api.account('peer'), other = api.account('other'), place = api.place();
  const photo = api.media(peer), unrelated = api.media(peer), memory = api.memory(peer, place, { media: [photo] });
  const context = { memoryId: memory.id, mediaId: photo }, path = `/v1/messages/${peer.id}`;
  status(await api.call(path, sender, 'POST', { id: randomUUID(), text: 'wrong attachment', context: { ...context, mediaId: unrelated } }), 404);
  status(await api.call(`/v1/messages/${other.id}`, sender, 'POST', { id: randomUUID(), text: 'wrong recipient', context }), 404);
  const body = { id: randomUUID(), text: 'About this photo', context };
  assert.deepEqual(status(await api.call(path, sender, 'POST', body), 201).context, context);
  api.db(db => db.prepare("UPDATE memories SET visibility = 'private' WHERE id = ?").run(memory.id));
  assert.equal(status(await api.call(path, sender)).items[0].context, null);
  assert.equal(status(await api.call(path, sender, 'POST', body)).context, null, 'retry remains safe after source revocation');
  status(await api.call(path, sender, 'POST', { ...body, id: randomUUID() }), 404);
  status(await api.call(`/v1/memories/${memory.id}`, peer, 'DELETE'), 204);
  const kept = status(await api.call(`/v1/messages/${sender.id}`, peer)).items[0];
  assert.equal(kept.text, body.text); assert.equal(kept.context, null);
  assert.equal(status(await api.call('/v1/messages', sender)).items[0].lastMessage.context, null);
});

test('message bounds, self/unknown peers, bilateral blocks and deleting peers are enforced on reads and writes', async t => {
  const api = await fixture(t), sender = api.account('sender'), peer = api.account('peer'), path = `/v1/messages/${peer.id}`;
  for (const body of [{ id: randomUUID(), text: '' }, { id: randomUUID(), text: 'x'.repeat(1001) },
    { id: randomUUID(), text: '\u0000' }, { id: randomUUID(), text: 'x', senderId: peer.id },
    { id: randomUUID(), text: 'x', context: { memoryId: 'bad', mediaId: randomUUID() } }]) {
    status(await api.call(path, sender, 'POST', body), 422);
  }
  status(await api.call(`/v1/messages/${sender.id}`, sender), 404);
  status(await api.call(`/v1/messages/${randomUUID()}`, sender), 404);
  status(await api.call(path, sender, 'POST', { id: randomUUID(), text: 'Before block' }), 201);
  for (const [blocker, blocked] of [[peer, sender], [sender, peer]]) {
    api.db(db => db.prepare('INSERT INTO user_blocks(blocker_id, blocked_id, created_at) VALUES (?, ?, 1)').run(blocker.id, blocked.id));
    status(await api.call(path, sender), 404);
    status(await api.call(path, sender, 'POST', { id: randomUUID(), text: 'Blocked' }), 404);
    assert.equal(status(await api.call('/v1/messages', sender)).items.length, 0);
    api.db(db => db.exec('DELETE FROM user_blocks'));
  }
  api.db(db => db.prepare('UPDATE users SET deletion_started_at = 1 WHERE id = ?').run(peer.id));
  status(await api.call(path, sender), 404);
  assert.equal(status(await api.call('/v1/messages', sender)).items.length, 0);
});

test('beta membership revocation removes counts, likes, saved sources and conversations and denies revoked viewer', async t => {
  const api = await fixture(t, true), owner = api.account('owner'), viewer = api.account('viewer'), place = api.place();
  const photo = api.media(owner), memory = api.memory(owner, place, { media: [photo] });
  const pair = { placeId: place.id, ownerId: owner.id };
  status(await api.call(`/v1/places/${place.id}/saved`, viewer, 'PUT', { saved: true }));
  status(await api.call(`/v1/messages/${owner.id}`, viewer, 'POST', { id: randomUUID(), text: 'hello' }), 201);
  assert.equal((await api.counts(viewer, [pair])).items[0].count, 1);
  api.db(db => db.prepare("UPDATE beta_members SET status = 'revoked' WHERE user_id = ?").run(owner.id));
  assert.equal((await api.counts(viewer, [pair])).items[0].count, 0);
  status(await api.call(`/v1/memories/${memory.id}/media/${photo}/like`, viewer), 404);
  assert.equal(status(await api.call('/v1/me/saved-places', viewer)).items.length, 0);
  assert.equal(status(await api.call('/v1/messages', viewer)).items.length, 0);
  status(await api.call(`/v1/messages/${owner.id}`, viewer), 404);
  status(await api.call('/v1/places/visit-counts', owner, 'POST', { items: [pair] }), 403);
});

test('schema17 to18 only adds social tables/indexes and preserves every existing record/media/timestamp/hash', async t => {
  const api = await fixture(t), owner = api.account('owner'), place = api.place(), photo = api.media(owner);
  const memory = api.memory(owner, place, { visibility: 'private', media: [photo] });
  api.db(db => {
    db.prepare('INSERT INTO memory_feedback(memory_id, endorsement, comment) VALUES (?, ?, ?)').run(memory.id, 'solid', 'Old note');
    for (const table of socialTables) db.exec(`DROP TABLE ${table}`);
    db.exec('DROP INDEX memories_place_owner_visits; PRAGMA user_version = 17;');
  });
  const snapshot = () => api.db(db => Object.fromEntries(db.prepare("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
    .all().filter(row => !socialTables.includes(row.name)).map(({ name }) => [name, db.prepare(`SELECT * FROM "${name}" ORDER BY rowid`).all()])));
  const before = snapshot();
  await api.restart();
  assert.deepEqual(snapshot(), before);
  api.db(db => {
    assert.equal(db.prepare('PRAGMA user_version').get().user_version, 19);
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
    assert.equal(db.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
    for (const table of socialTables) assert.equal(db.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n, 0);
  });
  await api.restart();
  assert.deepEqual(snapshot(), before, 'migration is idempotent');
});
