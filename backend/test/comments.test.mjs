import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { createBackend } from '../src/server.mjs';

const LOCATION = { latitude: 37.3688, longitude: -122.0363 };

async function fixture(t, options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-comments-test-'));
  const databasePath = join(directory, 'comments.sqlite');
  let backend = createBackend({ databasePath, ...options });
  t.after(async () => {
    try { await backend.close(); } finally { await rm(directory, { recursive: true, force: true }); }
  });
  let address = await backend.listen(0);
  return {
    databasePath,
    async restart() {
      await backend.close();
      backend = createBackend({ databasePath, ...options });
      address = await backend.listen(0);
    },
    sql(work) {
      const db = new DatabaseSync(databasePath);
      try { return work(db); } finally { db.close(); }
    },
    async call(path, { method = 'GET', token, json } = {}) {
      const response = await fetch(new URL(path, address.url), {
        method, headers: {
          ...(token ? { authorization: `Bearer ${token}` } : {}),
          ...(json !== undefined ? { 'content-type': 'application/json' } : {}),
        },
        body: json === undefined ? undefined : JSON.stringify(json),
      });
      const text = await response.text();
      return { status: response.status, data: text ? JSON.parse(text) : null, headers: response.headers };
    },
  };
}

function status(result, expected) {
  assert.equal(result.status, expected, JSON.stringify(result.data));
  return result.data;
}

async function register(api, handle) {
  return status(await api.call('/v1/auth/register', { method: 'POST',
    json: { handle, password: 'comments-local-test-password-42' } }), 201);
}

async function publish(api, owner, overrides = {}) {
  return status(await api.call('/v1/memories', { method: 'POST', token: owner.token,
    json: { id: randomUUID(), kind: 'reel', visibility: 'public', location: LOCATION,
      caption: 'Original post', ...overrides } }), 201);
}

async function comment(api, author, path, text = 'A useful reply', id = randomUUID(), expected = 201) {
  return status(await api.call(path, { method: 'POST', token: author.token, json: { id, text } }), expected);
}

async function list(api, viewer, path) {
  return status(await api.call(path, { token: viewer.token }), 200);
}

test('comments need only text, use the authenticated author and never create a visit or media', async t => {
  const api = await fixture(t);
  const owner = await register(api, 'owner'), viewer = await register(api, 'viewer');
  const post = await publish(api, owner);
  const path = `/v1/memories/${post.id}/comments`;
  const snapshot = () => api.sql(db => Object.fromEntries(['memories', 'places', 'media'].map(table =>
    [table, db.prepare(`SELECT * FROM ${table} ORDER BY id`).all()])));
  const before = snapshot();
  const saved = await comment(api, viewer, path, '  Can you recommend a quiet time?  ');
  assert.equal(saved.text, 'Can you recommend a quiet time?');
  assert.equal(saved.userId, viewer.user.id);
  assert.deepEqual(saved.author, viewer.user);
  assert.equal(Object.hasOwn(saved, 'location'), false);
  assert.equal(Object.hasOwn(saved, 'media'), false);
  assert.deepEqual(snapshot(), before);
  assert.deepEqual((await list(api, owner, path)).items, [saved]);
  assert.deepEqual((await list(api, viewer, '/v1/me/memories')).items, []);
  status(await api.call(path), 401);
  status(await api.call(path, { method: 'POST', json: { id: randomUUID(), text: 'anonymous' } }), 401);
});

test('a place has one discussion across repeated public visits and different visitors', async t => {
  const api = await fixture(t);
  const owner = await register(api, 'owner'), visitor = await register(api, 'visitor');
  const first = await publish(api, owner, { kind: 'poi', caption: '', place: { name: 'Shared café', category: 'coffee' } });
  const second = await publish(api, visitor, { kind: 'poi', caption: '', placeId: first.place.id });
  assert.equal(first.place.id, second.place.id);
  const path = `/v1/places/${first.place.id}/comments`;
  const firstReply = await comment(api, visitor, path, 'Good place to work?');
  const secondReply = await comment(api, owner, path, 'Yes, before lunch.');
  assert.deepEqual(new Set((await list(api, visitor, `/v1/places/${second.place.id}/comments`)).items.map(c => c.id)),
    new Set([firstReply.id, secondReply.id]));
  status(await api.call(`/v1/memories/${first.id}`, { method: 'DELETE', token: owner.token }), 204);
  assert.equal((await list(api, visitor, path)).items.length, 2, 'another public visit keeps the place discussion available');
});

test('private, rejected, deleted and inaccessible targets never expose discussion', async t => {
  const api = await fixture(t);
  const owner = await register(api, 'owner'), viewer = await register(api, 'viewer');
  const privatePost = await publish(api, owner, { visibility: 'private' });
  const privateVisit = await publish(api, owner, { kind: 'poi', visibility: 'private', caption: '',
    place: { name: 'Private place', category: 'other' } });
  const rejected = await publish(api, owner);
  const rejectedPlace = await publish(api, owner, { kind: 'poi', caption: '', place: { name: 'Rejected place', category: 'other' } });
  api.sql(db => db.prepare("UPDATE memories SET moderation_status = 'rejected' WHERE id IN (?, ?)").run(rejected.id, rejectedPlace.id));
  for (const path of [`/v1/memories/${privatePost.id}/comments`, `/v1/places/${privateVisit.place.id}/comments`,
    `/v1/memories/${rejected.id}/comments`, `/v1/places/${rejectedPlace.place.id}/comments`,
    `/v1/memories/${randomUUID()}/comments`, `/v1/places/${randomUUID()}/comments`]) {
    for (const person of [owner, viewer]) {
      status(await api.call(path, { token: person.token }), 404);
      status(await api.call(path, { method: 'POST', token: person.token, json: { id: randomUUID(), text: 'Not allowed' } }), 404);
    }
  }
  const post = await publish(api, owner);
  const path = `/v1/memories/${post.id}/comments`;
  const saved = await comment(api, viewer, path);
  status(await api.call(`/v1/memories/${post.id}`, { method: 'DELETE', token: owner.token }), 204);
  status(await api.call(path, { token: viewer.token }), 404);
  status(await api.call(path, { method: 'POST', token: viewer.token, json: { id: saved.id, text: saved.text } }), 404);
  assert.equal(api.sql(db => db.prepare('SELECT COUNT(*) AS n FROM comments WHERE memory_id = ?').get(post.id).n), 0);
});

test('blocking hides comments in both directions and prevents access to blocked authors posts', async t => {
  const api = await fixture(t);
  const owner = await register(api, 'owner'), alice = await register(api, 'alice'), bob = await register(api, 'bob');
  const post = await publish(api, owner), path = `/v1/memories/${post.id}/comments`;
  const a = await comment(api, alice, path), b = await comment(api, bob, path);
  status(await api.call('/v1/blocks', { method: 'POST', token: alice.token, json: { userId: bob.user.id } }), 204);
  assert.deepEqual((await list(api, alice, path)).items.map(c => c.id), [a.id]);
  assert.deepEqual((await list(api, bob, path)).items.map(c => c.id), [b.id]);
  assert.equal((await list(api, owner, path)).items.length, 2);
  status(await api.call('/v1/blocks', { method: 'POST', token: owner.token, json: { userId: alice.user.id } }), 204);
  status(await api.call(path, { token: alice.token }), 404);
  status(await api.call(path, { method: 'POST', token: alice.token, json: { id: a.id, text: a.text } }), 404);
});

test('deleting accounts are hidden and cannot read or write comments while deletion is pending', async t => {
  const api = await fixture(t);
  const owner = await register(api, 'owner'), author = await register(api, 'author'), viewer = await register(api, 'viewer');
  const post = await publish(api, owner), path = `/v1/memories/${post.id}/comments`;
  await comment(api, author, path);
  api.sql(db => db.prepare('UPDATE users SET deletion_started_at = ? WHERE id = ?').run(Date.now(), author.user.id));
  assert.equal((await list(api, viewer, path)).items.length, 0);
  status(await api.call(path, { token: author.token }), 409);
  status(await api.call(path, { method: 'POST', token: author.token, json: { id: randomUUID(), text: 'No' } }), 409);
  api.sql(db => db.prepare('UPDATE users SET deletion_started_at = ? WHERE id = ?').run(Date.now(), owner.user.id));
  status(await api.call(path, { token: viewer.token }), 404);
});

test('comment input validates UTF-16 size, identity and only the small text payload', async t => {
  const api = await fixture(t);
  const user = await register(api, 'user'), post = await publish(api, user);
  const path = `/v1/memories/${post.id}/comments`;
  for (const json of [null, [], {}, { id: 'bad', text: 'Hello' }, { id: randomUUID() },
    ...['', ' \n ', null, false, 42, 'x'.repeat(1001), '🙂'.repeat(501)].map(text => ({ id: randomUUID(), text })),
    { id: randomUUID(), text: 'Hi', userId: randomUUID() }, { id: randomUUID(), text: 'Hi', location: LOCATION },
    { id: randomUUID(), text: 'Hi', mediaIds: [] }]) {
    status(await api.call(path, { method: 'POST', token: user.token, json }), 422);
  }
  assert.equal((await list(api, user, path)).items.length, 0);
  assert.equal((await comment(api, user, path, 'x'.repeat(1000))).text.length, 1000);
  assert.equal((await comment(api, user, path, '🙂'.repeat(500))).text.length, 1000);
  status(await api.call('/v1/memories/not-a-uuid/comments', { token: user.token }), 422);
});

test('comment retries persist once, but cannot reuse an ID for different text, author or target', async t => {
  const api = await fixture(t);
  const user = await register(api, 'user'), other = await register(api, 'other');
  const post = await publish(api, user), second = await publish(api, user);
  const path = `/v1/memories/${post.id}/comments`, id = randomUUID();
  const results = await Promise.all([1, 2].map(() => api.call(path, {
    method: 'POST', token: user.token, json: { id, text: 'Same text' },
  })));
  assert.deepEqual(results.map(r => r.status).sort(), [200, 201]);
  assert.deepEqual(results[0].data, results[1].data);
  await api.restart();
  assert.deepEqual(await comment(api, user, path, '  Same text  ', id, 200), results[0].data);
  for (const [person, target, text] of [[other, path, 'Same text'], [user, path, 'Changed'],
    [user, `/v1/memories/${second.id}/comments`, 'Same text']]) {
    const result = await api.call(target, { method: 'POST', token: person.token, json: { id, text } });
    assert.equal(status(result, 409).error.code, 'id_conflict');
  }
  assert.equal((await list(api, user, path)).items.length, 1);
  assert.equal((await list(api, user, `/v1/memories/${second.id}/comments`)).items.length, 0);
});

test('pagination is deterministic at identical timestamps and survives inserts between pages', async t => {
  let time = Date.UTC(2026, 9, 23);
  const api = await fixture(t, { now: () => time });
  const user = await register(api, 'user'), post = await publish(api, user), path = `/v1/memories/${post.id}/comments`;
  const ids = [];
  for (let index = 0; index < 5; index++) ids.push((await comment(api, user, path, `Reply ${index}`)).id);
  const first = await list(api, user, `${path}?limit=2`);
  assert.equal(first.items.length, 2);
  assert.ok(first.nextCursor);
  time += 1;
  const inserted = await comment(api, user, path, 'Newer reply');
  const seen = [...first.items];
  let cursor = first.nextCursor;
  for (let page = 0; cursor && page < 5; page++) {
    const next = await list(api, user, `${path}?limit=2&cursor=${encodeURIComponent(cursor)}`);
    seen.push(...next.items); cursor = next.nextCursor;
  }
  assert.equal(cursor, null);
  assert.deepEqual(seen.map(c => c.id), [...ids].sort().reverse());
  assert.equal(seen.some(c => c.id === inserted.id), false);
  assert.equal((await list(api, user, path)).items[0].id, inserted.id);
  for (const suffix of ['?limit=0', '?limit=101', '?cursor=bad', '?unknown=true']) {
    status(await api.call(path + suffix, { token: user.token }), 422);
  }
});

test('per-user spam limit covers all threads, survives restart and allows exact retries', async t => {
  let time = Date.UTC(2026, 9, 23);
  const api = await fixture(t, { now: () => time });
  const user = await register(api, 'user'), other = await register(api, 'other');
  const post = await publish(api, user), second = await publish(api, user);
  const path = `/v1/memories/${post.id}/comments`, secondPath = `/v1/memories/${second.id}/comments`;
  let saved;
  for (let index = 0; index < 12; index++) saved = await comment(api, user, index % 2 ? path : secondPath, `Reply ${index}`);
  await api.restart();
  const limited = await api.call(path, { method: 'POST', token: user.token, json: { id: randomUUID(), text: 'Too many' } });
  assert.equal(status(limited, 429).error.code, 'rate_limited');
  assert.equal(limited.headers.get('retry-after'), '60');
  assert.deepEqual(await comment(api, user, path, saved.text, saved.id, 200), saved);
  await comment(api, other, path, 'Different author still allowed');
  time += 60_001;
  await comment(api, user, path, 'Allowed after cooldown');
});

test('comments survive restart, cascade with authors and posts, and do not revive expired activity', async t => {
  let time = Date.UTC(2026, 9, 23);
  const api = await fixture(t, { now: () => time });
  const owner = await register(api, 'owner'), author = await register(api, 'author');
  const post = await publish(api, owner), path = `/v1/memories/${post.id}/comments`;
  const visit = await publish(api, owner, { kind: 'poi', caption: '', place: { name: 'Historic café', category: 'coffee' } });
  const placePath = `/v1/places/${visit.place.id}/comments`;
  time += 72 * 60 * 60 * 1000 + 1;
  const saved = await comment(api, author, path, 'Revisiting this old post');
  await comment(api, author, placePath, 'Still useful advice');
  await api.restart();
  assert.deepEqual((await list(api, owner, path)).items, [saved]);
  assert.equal((await list(api, author, '/v1/feed')).items.length, 0);
  const map = await list(api, author, '/v1/map/memories?west=-123&east=-121&south=37&north=38');
  assert.deepEqual(map.items.map(m => m.id), [visit.id], 'expired POI history remains; expired Reel does not');
  assert.equal(status(await api.call(`/v1/memories/${post.id}`, { token: author.token }), 200).publishedAt, post.publishedAt);
  status(await api.call('/v1/me', { method: 'DELETE', token: author.token }), 204);
  assert.equal((await list(api, owner, path)).items.length, 0);
  assert.equal((await list(api, owner, placePath)).items.length, 0);
  await comment(api, owner, path);
  await comment(api, owner, placePath);
  status(await api.call('/v1/me', { method: 'DELETE', token: owner.token }), 204);
  api.sql(db => {
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM comments').get().n, 0);
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
  });
});
