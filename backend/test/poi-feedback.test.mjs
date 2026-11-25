import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { createBackend } from '../src/server.mjs';
import { issueSession } from '../src/security.mjs';

const LOCATION = { latitude: 37.37, longitude: -122.04 };
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1cAAAAASUVORK5CYII=', 'base64');

function status(result, expected) {
  assert.equal(result.status, expected, JSON.stringify(result.data));
  return result.data;
}

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-poi-feedback-'));
  const databasePath = join(directory, 'test.sqlite');
  let time = Date.UTC(2026, 10, 15);
  let backend = createBackend({ databasePath, now: () => time });
  t.after(async () => { await backend.close(); await rm(directory, { recursive: true, force: true }); });
  let address = await backend.listen(0);
  const api = {
    advance(ms) { time += ms; },
    db(work) {
      const db = new DatabaseSync(databasePath);
      try { db.exec('PRAGMA foreign_keys = ON;'); return work(db); } finally { db.close(); }
    },
    account(handle) {
      return api.db(db => {
        const id = randomUUID();
        db.prepare('INSERT INTO users(id, handle, password_hash, created_at) VALUES (?, ?, ?, ?)')
          .run(id, handle, 'fixture-only-not-a-password', time);
        return { id, ...issueSession(db, id, time) };
      });
    },
    async restart() {
      await backend.close(); backend = createBackend({ databasePath, now: () => time });
      address = await backend.listen(0);
    },
    async call(path, account, method = 'GET', json, headers = {}, bytes) {
      const response = await fetch(new URL(path, address.url), { method,
        headers: { ...(account ? { authorization: `Bearer ${account.token}` } : {}),
          ...(json !== undefined ? { 'content-type': 'application/json' } : {}), ...headers },
        body: json === undefined ? bytes : JSON.stringify(json) });
      const text = await response.text();
      return { status: response.status, data: text ? JSON.parse(text) : null };
    },
    async publish(account, overrides = {}) {
      const input = { id: randomUUID(), kind: 'poi', visibility: 'public', location: LOCATION,
        caption: '', place: { name: 'A quiet café', category: 'coffee' }, ...overrides };
      const memory = status(await api.call('/v1/memories', account, 'POST', input), 201);
      return { memory, input };
    },
    async feedback(account, memory, body) {
      return status(await api.call(`/v1/memories/${memory.id}/feedback`, account, 'PUT', body), 200);
    },
    async memory(account, memory) {
      return status(await api.call(`/v1/memories/${memory.id}`, account), 200);
    },
  };
  return api;
}

function snapshot(api) {
  return api.db(db => Object.fromEntries(db.prepare(`SELECT name FROM sqlite_schema WHERE type = 'table'
    AND name NOT LIKE 'sqlite_%' AND name NOT IN ('memory_feedback', 'memory_custom_feelings') ORDER BY name`).all().map(({ name }) =>
    [name, db.prepare(`SELECT * FROM "${name}" ORDER BY rowid`).all()])));
}

test('POI feedback capability is explicit and skipping leaves no feedback or changed publish contract', async t => {
  const api = await fixture(t), owner = api.account('owner');
  const health = status(await api.call('/health'), 200);
  assert.equal(health.features.poiFeedback, true);
  assert.equal(health.features.poiCustomFeelings, true);
  const { memory, input } = await api.publish(owner);
  assert.equal(Object.hasOwn(memory, 'feedback'), false);
  assert.equal(api.db(db => db.prepare('SELECT COUNT(*) AS n FROM memory_feedback').get().n), 0);
  assert.deepEqual(status(await api.call('/v1/memories', owner, 'POST', input), 200), memory);
  status(await api.call('/v1/memories', owner, 'POST', { ...input, id: randomUUID(),
    feedback: { endorsement: 'hype', comment: '' } }), 422);
  status(await api.call(`/v1/memories/${memory.id}`, owner, 'PATCH', { caption: 'Not a new POI caption' }), 422);
});

test('all four feelings and comment-only feedback replace idempotently without changing parent records or retry hashes', async t => {
  const api = await fixture(t), owner = api.account('owner');
  const upload = status(await api.call('/v1/media', owner, 'POST', undefined,
    { 'content-type': 'image/png', 'idempotency-key': randomUUID() }, PNG), 201);
  const { memory, input } = await api.publish(owner, { mediaIds: [upload.id], capturedAt: '2026-11-14T22:00:00.000Z' });
  const before = snapshot(api);
  api.advance(4 * 24 * 60 * 60 * 1000);
  for (const endorsement of ['hype', 'solid', 'meh', 'questionable']) {
    const saved = await api.feedback(owner, memory, { endorsement, comment: '  This visit was memorable. \n' });
    assert.deepEqual(saved.feedback, { endorsement, comment: 'This visit was memorable.' });
    assert.deepEqual({ ...saved, feedback: undefined }, { ...memory, feedback: undefined });
    assert.deepEqual(await api.feedback(owner, memory, { endorsement, comment: 'This visit was memorable.' }), saved);
    assert.equal(api.db(db => db.prepare('SELECT COUNT(*) AS n FROM memory_feedback').get().n), 1);
    assert.deepEqual(snapshot(api), before);
  }
  assert.deepEqual((await api.feedback(owner, memory, { comment: 'Just a note' })).feedback,
    { endorsement: null, comment: 'Just a note' });
  assert.deepEqual((await api.feedback(owner, memory, { endorsement: 'solid' })).feedback,
    { endorsement: 'solid', comment: '' });
  await api.restart();
  const reloaded = await api.memory(owner, memory);
  assert.deepEqual(reloaded.feedback, { endorsement: 'solid', comment: '' });
  assert.deepEqual(status(await api.call('/v1/memories', owner, 'POST', input), 200), reloaded,
    'old initial publish payload remains retryable and does not overwrite later feedback');
  assert.deepEqual(status(await api.call('/v1/feed', owner), 200).items, [], 'feedback does not revive expired activity');
  assert.deepEqual(snapshot(api), before);
});

test('feedback accepts only the bounded optional feeling and trimmed text fields', async t => {
  const api = await fixture(t), owner = api.account('owner');
  const { memory } = await api.publish(owner), path = `/v1/memories/${memory.id}/feedback`;
  for (const body of [null, [], 7, 'bad', { endorsement: false }, { endorsement: 0 },
    { endorsement: 'excellent' }, { endorsement: {} }, { endorsement: ['hype'] },
    { comment: null }, { comment: 4 }, { comment: false }, { comment: [] },
    { comment: 'x'.repeat(1001) }, { comment: '🙂'.repeat(501) }, { comment: '\u0000' }, { comment: 'a\u0000b' },
    { comment: 'note', ownerId: owner.id }, { comment: 'note', visibility: 'public' },
    { comment: 'note', caption: 'different' }, { comment: 'note', mediaIds: [] }]) {
    status(await api.call(path, owner, 'PUT', body), 422);
  }
  assert.equal(api.db(db => db.prepare('SELECT COUNT(*) AS n FROM memory_feedback').get().n), 0);
  assert.equal((await api.feedback(owner, memory, { comment: `  ${'🙂'.repeat(500)}  ` })).feedback.comment.length, 1000);
  assert.equal((await api.feedback(owner, memory, { comment: 'x'.repeat(1000) })).feedback.comment.length, 1000);
  for (const body of [{ endorsement: null, comment: ' \n ' }, {}]) {
    const cleared = await api.feedback(owner, memory, body);
    assert.equal(Object.hasOwn(cleared, 'feedback'), false);
    assert.deepEqual(await api.feedback(owner, memory, body), cleared);
  }
  status(await api.call('/v1/memories/not-a-uuid/feedback', owner, 'PUT', { endorsement: 'hype' }), 422);
});

test('only the owner of an existing POI can mutate feedback; no anonymous, other-owner or Post writes', async t => {
  const api = await fixture(t), owner = api.account('owner'), viewer = api.account('viewer');
  const { memory } = await api.publish(owner), path = `/v1/memories/${memory.id}/feedback`;
  status(await api.call(path, undefined, 'PUT', { endorsement: 'hype' }), 401);
  status(await api.call(path, viewer, 'PUT', { endorsement: 'hype' }), 404);
  status(await api.call(`/v1/memories/${randomUUID()}/feedback`, owner, 'PUT', { comment: 'note' }), 404);
  const { memory: post } = await api.publish(owner, { kind: 'reel', place: undefined, caption: 'Original Post' });
  status(await api.call(`/v1/memories/${post.id}/feedback`, owner, 'PUT', { endorsement: 'hype' }), 422);
  await api.feedback(owner, memory, { endorsement: 'hype' });
  status(await api.call(path, viewer, 'PUT', {}), 404);
  assert.deepEqual((await api.memory(viewer, memory)).feedback, { endorsement: 'hype', comment: '' });
  assert.equal(api.db(db => db.prepare('SELECT COUNT(*) AS n FROM comments').get().n), 0);
});

test('feedback follows private/public parent access without leaking into independent place comments', async t => {
  const api = await fixture(t), owner = api.account('owner'), viewer = api.account('viewer');
  const { memory: shared } = await api.publish(owner);
  const { memory: privateVisit } = await api.publish(owner, { visibility: 'private', place: undefined, placeId: shared.place.id });
  await api.feedback(owner, privateVisit, { endorsement: 'questionable', comment: 'Private details' });
  status(await api.call(`/v1/memories/${privateVisit.id}`, viewer), 404);
  status(await api.call(`/v1/memories/${privateVisit.id}/feedback`, viewer, 'PUT', { comment: 'No' }), 404);
  for (const path of ['/v1/feed', '/v1/map/memories?west=-123&east=-121&south=37&north=38',
    `/v1/users/${owner.id}/memories`, `/v1/places/${shared.place.id}/memories`]) {
    const list = status(await api.call(path, viewer), 200);
    assert.deepEqual(list.items.map(item => item.id), [shared.id]);
    assert.equal(JSON.stringify(list).includes('Private details'), false);
  }
  assert.deepEqual(status(await api.call(`/v1/places/${shared.place.id}/comments`, viewer), 200).items, []);
  const own = status(await api.call('/v1/me/memories', owner), 200);
  assert.equal(own.items.find(item => item.id === privateVisit.id).feedback.comment, 'Private details');
  status(await api.call(`/v1/memories/${privateVisit.id}`, owner, 'PATCH', { visibility: 'public' }), 200);
  assert.equal((await api.memory(viewer, privateVisit)).feedback.comment, 'Private details');
  status(await api.call(`/v1/memories/${privateVisit.id}`, owner, 'PATCH', { visibility: 'private' }), 200);
  status(await api.call(`/v1/memories/${privateVisit.id}`, viewer), 404);
});

test('moderation, blocks in either direction and account deletion state hide feedback with its visit', async t => {
  const api = await fixture(t), owner = api.account('owner'), viewer = api.account('viewer');
  const { memory } = await api.publish(owner);
  await api.feedback(owner, memory, { endorsement: 'meh', comment: 'Moderated details' });
  const assertHidden = async () => {
    status(await api.call(`/v1/memories/${memory.id}`, viewer), 404);
    assert.deepEqual(status(await api.call('/v1/feed', viewer), 200).items, []);
    status(await api.call(`/v1/places/${memory.place.id}/memories`, viewer), 404);
  };
  api.db(db => db.prepare("UPDATE memories SET moderation_status = 'rejected' WHERE id = ?").run(memory.id));
  await assertHidden();
  assert.equal((await api.memory(owner, memory)).feedback.comment, 'Moderated details');
  await api.feedback(owner, memory, { comment: 'Still rejected after edit' });
  await assertHidden();
  api.db(db => db.prepare("UPDATE memories SET moderation_status = 'approved' WHERE id = ?").run(memory.id));
  for (const [blocker, blocked] of [[owner, viewer], [viewer, owner]]) {
    status(await api.call('/v1/blocks', blocker, 'POST', { userId: blocked.id }), 204);
    await assertHidden();
    api.db(db => db.prepare('DELETE FROM user_blocks').run());
  }
  api.db(db => db.prepare('UPDATE users SET deletion_started_at = 1 WHERE id = ?').run(owner.id));
  await assertHidden();
  status(await api.call(`/v1/memories/${memory.id}/feedback`, owner, 'PUT', { endorsement: 'solid' }), 409);
});

test('deleted visits and accounts cascade feedback; retries cannot resurrect a deleted visit', async t => {
  const api = await fixture(t), owner = api.account('owner'), viewer = api.account('viewer');
  const { memory, input } = await api.publish(owner);
  await api.feedback(owner, memory, { comment: 'Deleted with my visit' });
  status(await api.call(`/v1/memories/${memory.id}`, owner, 'DELETE'), 204);
  status(await api.call(`/v1/memories/${memory.id}/feedback`, owner, 'PUT', { endorsement: 'hype' }), 404);
  status(await api.call('/v1/memories', owner, 'POST', input), 410);
  status(await api.call(`/v1/memories/${memory.id}`, viewer), 404);
  assert.equal(api.db(db => db.prepare('SELECT COUNT(*) AS n FROM memory_feedback').get().n), 0);
  const { memory: another } = await api.publish(owner);
  await api.feedback(owner, another, { endorsement: 'solid' });
  status(await api.call('/v1/me', owner, 'DELETE'), 204);
  api.db(db => {
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM memory_feedback').get().n, 0);
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
  });
});

test('new Bubble snapshots include selected feedback while existing snapshots remain immutable', async t => {
  const api = await fixture(t), owner = api.account('owner'), viewer = api.account('viewer');
  const { memory } = await api.publish(owner, { visibility: 'private' });
  const bubble = () => api.publish(owner, { kind: 'reel', place: undefined,
    cluster: { title: 'Selected visit', memoryIds: [memory.id] } });
  const { memory: oldBubble } = await bubble();
  await api.feedback(owner, memory, { endorsement: 'hype', comment: 'A note intentionally shared in the next Bubble' });
  const { memory: newBubble } = await bubble();
  assert.equal(Object.hasOwn(oldBubble.cluster.members[0], 'feedback'), false);
  assert.deepEqual(newBubble.cluster.members[0].feedback,
    { endorsement: 'hype', comment: 'A note intentionally shared in the next Bubble' });
  const frozen = api.db(db => db.prepare('SELECT * FROM memory_clusters ORDER BY memory_id').all());
  await api.feedback(owner, memory, { comment: 'Later private edit' });
  assert.deepEqual((await api.memory(viewer, oldBubble)).cluster, oldBubble.cluster);
  assert.deepEqual((await api.memory(viewer, newBubble)).cluster, newBubble.cluster);
  status(await api.call(`/v1/memories/${memory.id}`, viewer), 404);
  status(await api.call(`/v1/memories/${memory.id}`, owner, 'DELETE'), 204);
  await api.restart();
  assert.deepEqual((await api.memory(viewer, newBubble)).cluster, newBubble.cluster);
  assert.deepEqual(api.db(db => db.prepare('SELECT * FROM memory_clusters ORDER BY memory_id').all()), frozen);
});

test('schema16 feedback migration through current schema19 preserves every existing table row, media byte, timestamp and immutable snapshot', async t => {
  const api = await fixture(t), owner = api.account('owner');
  const photo = status(await api.call('/v1/media', owner, 'POST', undefined,
    { 'content-type': 'image/png', 'idempotency-key': randomUUID() }, PNG), 201);
  const { memory, input } = await api.publish(owner, { visibility: 'private', mediaIds: [photo.id],
    capturedAt: '2026-11-14T22:00:00.000Z' });
  const { memory: bubble } = await api.publish(owner, { kind: 'reel', place: undefined,
    cluster: { title: 'Before feedback existed', memoryIds: [memory.id] } });
  api.db(db => db.exec('DROP TABLE memory_feedback; PRAGMA user_version = 16;'));
  const before = snapshot(api);
  const schemaBefore = api.db(db => db.prepare('SELECT * FROM sqlite_schema ORDER BY name').all());
  await api.restart();
  assert.deepEqual(snapshot(api), before);
  api.db(db => {
    assert.equal(db.prepare('PRAGMA user_version').get().user_version, 19);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM memory_feedback').get().n, 0);
    assert.deepEqual(db.prepare('SELECT * FROM sqlite_schema WHERE tbl_name != ? ORDER BY name').all('memory_feedback'), schemaBefore);
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
    assert.equal(db.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
  });
  assert.deepEqual(await api.memory(owner, memory), memory);
  assert.deepEqual((await api.memory(owner, bubble)).cluster, bubble.cluster);
  assert.deepEqual(status(await api.call('/v1/memories', owner, 'POST', input), 200), memory);
  await api.feedback(owner, memory, { endorsement: 'solid' });
  await api.restart();
  assert.equal((await api.memory(owner, memory)).feedback.endorsement, 'solid');
  assert.deepEqual(snapshot(api), before);
});

test('all curated custom feelings persist without becoming ratings or comments, changing time or breaking publish retries', async t => {
  const api = await fixture(t), owner = api.account('owner');
  const { memory, input } = await api.publish(owner), before = snapshot(api);
  api.advance(4 * 24 * 60 * 60 * 1000);
  for (const customEmoji of ['🫠', '🥹', '😂', '😎', '🥱', '🤯', '🤤', '🤩', '🥲', '😌', '🙃', '🫶', '☕️', '🍜', '🌧️', '🌅', '✨', '💀']) {
    const saved = await api.feedback(owner, memory, { endorsement: null, customEmoji, comment: '' });
    assert.deepEqual(saved.feedback, { endorsement: null, comment: '', customEmoji });
    assert.deepEqual({ ...saved, feedback: undefined }, { ...memory, feedback: undefined });
    assert.deepEqual(await api.feedback(owner, memory, { customEmoji }), saved);
    assert.equal(api.db(db => db.prepare('SELECT COUNT(*) AS n FROM memory_feedback').get().n), 0);
    assert.equal(api.db(db => db.prepare('SELECT COUNT(*) AS n FROM memory_custom_feelings').get().n), 1);
    assert.deepEqual(snapshot(api), before);
  }
  await api.restart();
  const reloaded = await api.memory(owner, memory);
  assert.deepEqual(reloaded.feedback, { endorsement: null, comment: '', customEmoji: '💀' });
  assert.deepEqual(status(await api.call('/v1/memories', owner, 'POST', input), 200), reloaded);
  assert.deepEqual(status(await api.call('/v1/feed', owner), 200).items, [], 'editing does not revive activity');
  assert.deepEqual(snapshot(api), before);
});

test('custom feeling and optional note are atomic, and switching/clearing never retains a stale rating', async t => {
  const api = await fixture(t), owner = api.account('owner'), { memory } = await api.publish(owner);
  await api.feedback(owner, memory, { endorsement: 'hype', comment: 'Original' });
  assert.deepEqual((await api.feedback(owner, memory, { customEmoji: '☕️', comment: '  Slow morning  ' })).feedback,
    { endorsement: null, comment: 'Slow morning', customEmoji: '☕️' });
  api.db(db => assert.equal(db.prepare('SELECT endorsement FROM memory_feedback WHERE memory_id = ?').get(memory.id).endorsement, null));
  assert.deepEqual((await api.feedback(owner, memory, { endorsement: 'solid', customEmoji: null, comment: 'Still here' })).feedback,
    { endorsement: 'solid', comment: 'Still here' });
  assert.equal(api.db(db => db.prepare('SELECT COUNT(*) AS n FROM memory_custom_feelings').get().n), 0);
  await api.feedback(owner, memory, { customEmoji: '✨', comment: 'A little note' });
  assert.deepEqual((await api.feedback(owner, memory, { customEmoji: null, comment: 'Only the note' })).feedback,
    { endorsement: null, comment: 'Only the note' });
  const cleared = await api.feedback(owner, memory, { endorsement: null, customEmoji: null, comment: '' });
  assert.equal(Object.hasOwn(cleared, 'feedback'), false);
  assert.deepEqual(await api.feedback(owner, memory, { customEmoji: null }), cleared);
  api.db(db => {
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM memory_feedback').get().n, 0);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM memory_custom_feelings').get().n, 0);
  });
});

test('older clients preserve an unknown custom feeling on comment edits/clears, while an explicit rating replaces it', async t => {
  const api = await fixture(t), owner = api.account('owner'), { memory } = await api.publish(owner);
  await api.feedback(owner, memory, { customEmoji: '🥹', comment: 'New client' });
  assert.deepEqual((await api.feedback(owner, memory, { endorsement: null, comment: 'Old-client note' })).feedback,
    { endorsement: null, comment: 'Old-client note', customEmoji: '🥹' });
  assert.deepEqual((await api.feedback(owner, memory, {})).feedback,
    { endorsement: null, comment: '', customEmoji: '🥹' });
  assert.deepEqual((await api.feedback(owner, memory, { endorsement: 'meh', comment: '' })).feedback,
    { endorsement: 'meh', comment: '' });
  assert.equal(api.db(db => db.prepare('SELECT COUNT(*) AS n FROM memory_custom_feelings').get().n), 0);
});

test('custom feeling inputs are curated, bounded and mutually exclusive without partial writes', async t => {
  const api = await fixture(t), owner = api.account('owner'), { memory } = await api.publish(owner);
  const original = await api.feedback(owner, memory, { endorsement: 'solid', comment: 'Keep me' });
  for (const customEmoji of ['', ' ', 'not emoji', '🔥', '☕', '✨✨', 'x'.repeat(10000), '✨\u0000', 1, false, [], {}, ['✨']]) {
    status(await api.call(`/v1/memories/${memory.id}/feedback`, owner, 'PUT', { customEmoji, comment: 'Invalid' }), 422);
    assert.deepEqual(await api.memory(owner, memory), original);
  }
  status(await api.call(`/v1/memories/${memory.id}/feedback`, owner, 'PUT', { endorsement: 'hype', customEmoji: '✨' }), 422);
  assert.deepEqual(await api.memory(owner, memory), original);
  assert.equal(api.db(db => db.prepare('SELECT COUNT(*) AS n FROM memory_custom_feelings').get().n), 0);
});

test('custom feelings inherit owner-only writes, visibility, blocks, moderation and deletion', async t => {
  const api = await fixture(t), owner = api.account('owner'), viewer = api.account('viewer');
  const { memory, input } = await api.publish(owner, { visibility: 'private' });
  const path = `/v1/memories/${memory.id}/feedback`, body = { customEmoji: '🫶', comment: 'Private custom note' };
  status(await api.call(path, undefined, 'PUT', body), 401);
  status(await api.call(path, viewer, 'PUT', body), 404);
  const { memory: post } = await api.publish(owner, { kind: 'reel', place: undefined, caption: 'A Post is not a POI' });
  status(await api.call(`/v1/memories/${post.id}/feedback`, owner, 'PUT', body), 422);
  await api.feedback(owner, memory, body);
  status(await api.call(`/v1/memories/${memory.id}`, viewer), 404);
  assert.equal(JSON.stringify(status(await api.call('/v1/feed', viewer), 200)).includes('Private custom note'), false);
  status(await api.call(`/v1/memories/${memory.id}`, owner, 'PATCH', { visibility: 'public' }), 200);
  assert.equal((await api.memory(viewer, memory)).feedback.customEmoji, '🫶');
  for (const [blocker, blocked] of [[owner, viewer], [viewer, owner]]) {
    status(await api.call('/v1/blocks', blocker, 'POST', { userId: blocked.id }), 204);
    status(await api.call(`/v1/memories/${memory.id}`, viewer), 404);
    api.db(db => db.prepare('DELETE FROM user_blocks').run());
  }
  api.db(db => db.prepare("UPDATE memories SET moderation_status = 'rejected' WHERE id = ?").run(memory.id));
  status(await api.call(`/v1/memories/${memory.id}`, viewer), 404);
  assert.equal((await api.memory(owner, memory)).feedback.customEmoji, '🫶');
  status(await api.call(`/v1/memories/${memory.id}`, owner, 'DELETE'), 204);
  status(await api.call(path, owner, 'PUT', body), 404);
  status(await api.call('/v1/memories', owner, 'POST', input), 410);
  assert.equal(api.db(db => db.prepare('SELECT COUNT(*) AS n FROM memory_custom_feelings').get().n), 0);
  const { memory: another } = await api.publish(owner);
  await api.feedback(owner, another, { customEmoji: '🌅' });
  status(await api.call('/v1/me', owner, 'DELETE'), 204);
  api.db(db => {
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM memory_custom_feelings').get().n, 0);
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
  });
});

test('custom feelings flow through archive/feed/place responses and new immutable Bubble snapshots only', async t => {
  const api = await fixture(t), owner = api.account('owner'), viewer = api.account('viewer');
  const { memory } = await api.publish(owner);
  const bubble = () => api.publish(owner, { kind: 'reel', place: undefined,
    cluster: { title: 'Custom mood visit', memoryIds: [memory.id] } });
  const { memory: oldBubble } = await bubble();
  const feedback = { endorsement: null, comment: '', customEmoji: '🫠' };
  await api.feedback(owner, memory, feedback);
  const { memory: newBubble } = await bubble();
  for (const path of ['/v1/feed', '/v1/me/memories', `/v1/users/${owner.id}/memories`,
    `/v1/places/${memory.place.id}/memories`, '/v1/map/memories?west=-123&east=-121&south=37&north=38']) {
    assert.deepEqual(status(await api.call(path, owner), 200).items.find(item => item.id === memory.id).feedback, feedback);
  }
  assert.equal(Object.hasOwn(oldBubble.cluster.members[0], 'feedback'), false);
  assert.deepEqual(newBubble.cluster.members[0].feedback, feedback);
  const frozen = api.db(db => db.prepare('SELECT * FROM memory_clusters ORDER BY memory_id').all());
  await api.feedback(owner, memory, { endorsement: 'solid', customEmoji: null });
  assert.deepEqual((await api.memory(viewer, oldBubble)).cluster, oldBubble.cluster);
  assert.deepEqual((await api.memory(viewer, newBubble)).cluster, newBubble.cluster);
  assert.deepEqual(api.db(db => db.prepare('SELECT * FROM memory_clusters ORDER BY memory_id').all()), frozen);
});
