import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { createBackend } from '../src/server.mjs';
import { openDatabase } from '../src/database.mjs';
import { backupDatabase } from '../src/backup.mjs';
import { digest, issueSession } from '../src/security.mjs';

const LOCATION = { latitude: 37.37, longitude: -122.04 };
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1cAAAAASUVORK5CYII=', 'base64');

function status(result, expected) {
  assert.equal(result.status, expected, JSON.stringify(result.data));
  return result.data;
}

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-cluster-test-'));
  const databasePath = join(directory, 'test.sqlite');
  let backend = createBackend({ databasePath });
  t.after(async () => { await backend.close(); await rm(directory, { recursive: true, force: true }); });
  let address = await backend.listen(0);
  const api = {
    databasePath,
    db(work) {
      const db = new DatabaseSync(databasePath);
      try { db.exec('PRAGMA foreign_keys = ON;'); return work(db); } finally { db.close(); }
    },
    account(handle) {
      return api.db(db => {
        const id = randomUUID();
        db.prepare('INSERT INTO users(id, handle, password_hash, created_at) VALUES (?, ?, ?, ?)')
          .run(id, handle, 'test-only-not-a-password', Date.now());
        return { id, ...issueSession(db, id, Date.now()) };
      });
    },
    async restart() {
      await backend.close(); backend = createBackend({ databasePath }); address = await backend.listen(0);
    },
    async call(path, account, method = 'GET', json, headers = {}, body) {
      const response = await fetch(new URL(path, address.url), { method,
        headers: { ...(account ? { authorization: `Bearer ${account.token}` } : {}),
          ...(json !== undefined ? { 'content-type': 'application/json' } : {}), ...headers },
        body: json === undefined ? body : JSON.stringify(json) });
      const text = await response.text();
      let data; try { data = text ? JSON.parse(text) : null; } catch { data = text; }
      return { status: response.status, data, headers: response.headers };
    },
    async upload(account, key = randomUUID()) {
      const media = status(await api.call('/v1/media', account, 'POST', undefined,
        { 'content-type': 'image/png', 'idempotency-key': key }, PNG), 201);
      return { ...media, key };
    },
    async publish(account, overrides = {}) {
      const input = { id: randomUUID(), kind: 'reel', visibility: 'private', location: LOCATION,
        caption: 'Original snapshot text', ...overrides };
      return status(await api.call('/v1/memories', account, 'POST', input), 201);
    },
  };
  return api;
}

test('public Reel shares only selected owned snapshots and media without publishing private source records', async t => {
  const api = await fixture(t), owner = api.account('owner'), viewer = api.account('viewer');
  const photo = await api.upload(owner), unselected = await api.upload(owner);
  const source = await api.publish(owner, { mediaIds: [photo.id] });
  const hidden = await api.publish(owner, { mediaIds: [unselected.id] });
  const visit = await api.publish(owner, { kind: 'poi', caption: '', place: { name: 'Private café', category: 'coffee' } });
  const parent = await api.publish(owner, { visibility: 'public', caption: '',
    cluster: { title: '  Weekend  ', memoryIds: [visit.id, source.id] } });
  assert.deepEqual(parent.cluster, { id: parent.id, title: 'Weekend', members: [visit, source] });
  assert.equal(parent.caption, ''); assert.deepEqual(parent.media, []);
  const viewed = status(await api.call(`/v1/memories/${parent.id}`, viewer), 200);
  assert.deepEqual(viewed.cluster, parent.cluster);
  assert.deepEqual(status(await api.call('/v1/me/memories', owner), 200).items[0].cluster, parent.cluster);
  for (const privateID of [visit.id, source.id, hidden.id]) status(await api.call(`/v1/memories/${privateID}`, viewer), 404);
  status(await api.call(photo.path, viewer), 200);
  status(await api.call(photo.path, viewer, 'HEAD'), 200);
  status(await api.call(photo.path, viewer, 'GET', undefined, { range: 'bytes=0-3' }), 206);
  status(await api.call(photo.path), 401);
  status(await api.call(unselected.path, viewer), 404);
  status(await api.call(`/v1/places/${visit.place.id}/memories`, viewer), 404);
  for (const path of ['/v1/feed', '/v1/map/memories?west=-123&east=-121&south=37&north=38', `/v1/users/${owner.id}/memories`]) {
    const page = status(await api.call(path, viewer), 200);
    assert.deepEqual(page.items.map(item => item.id), [parent.id]);
    assert.deepEqual(page.items[0].cluster, parent.cluster);
  }
  assert.equal(status(await api.call(`/v1/memories/${source.id}`, owner), 200).visibility, 'private');
  const frozen = parent.cluster;
  status(await api.call(`/v1/memories/${source.id}`, owner, 'PATCH', { caption: 'Edited later' }), 200);
  status(await api.call(`/v1/memories/${visit.id}`, owner, 'DELETE'), 204);
  await api.restart();
  assert.deepEqual(status(await api.call(`/v1/memories/${parent.id}`, viewer), 200).cluster, frozen);
  status(await api.call(`/v1/memories/${parent.id}`, owner, 'PATCH', { caption: '' }), 200);
});

test('cluster media obey parent privacy, moderation, blocks and owner deletion state', async t => {
  const api = await fixture(t), owner = api.account('owner'), viewer = api.account('viewer');
  const photo = await api.upload(owner), source = await api.publish(owner, { mediaIds: [photo.id] });
  const parent = await api.publish(owner, { caption: '', cluster: { title: 'Private', memoryIds: [source.id] } });
  const check = async expected => {
    status(await api.call(`/v1/memories/${parent.id}`, viewer), expected);
    status(await api.call(photo.path, viewer), expected);
    status(await api.call(photo.path, viewer, 'HEAD'), expected);
  };
  await check(404);
  status(await api.call(`/v1/memories/${parent.id}`, owner, 'PATCH', { visibility: 'public' }), 200);
  await check(200);
  api.db(db => db.prepare("UPDATE memories SET moderation_status = 'rejected' WHERE id = ?").run(parent.id));
  await check(404);
  api.db(db => db.prepare("UPDATE memories SET moderation_status = 'approved' WHERE id = ?").run(parent.id));
  status(await api.call('/v1/blocks', viewer, 'POST', { userId: owner.id }), 204);
  await check(404);
  status(await api.call(`/v1/blocks/${owner.id}`, viewer, 'DELETE'), 204);
  await check(200);
  status(await api.call('/v1/blocks', owner, 'POST', { userId: viewer.id }), 204);
  await check(404);
  status(await api.call(`/v1/blocks/${viewer.id}`, owner, 'DELETE'), 204);
  api.db(db => db.prepare('UPDATE users SET deletion_started_at = ? WHERE id = ?').run(Date.now(), owner.id));
  await check(404);
  api.db(db => db.prepare('UPDATE users SET deletion_started_at = NULL WHERE id = ?').run(owner.id));
  status(await api.call(`/v1/memories/${parent.id}`, owner, 'PATCH', { visibility: 'private' }), 200);
  await check(404);
});

test('independent clusters retain deleted source media until the last parent/reference is deleted', async t => {
  const api = await fixture(t), owner = api.account('owner'), viewer = api.account('viewer');
  const photo = await api.upload(owner), pending = await api.upload(owner);
  const source = await api.publish(owner, { mediaIds: [photo.id] });
  const input = { id: randomUUID(), kind: 'reel', visibility: 'public', location: LOCATION,
    cluster: { title: 'Frozen', memoryIds: [source.id] } };
  const first = status(await api.call('/v1/memories', owner, 'POST', input), 201);
  const second = await api.publish(owner, { cluster: input.cluster });
  status(await api.call(`/v1/memories/${source.id}`, owner, 'DELETE'), 204);
  assert.deepEqual(status(await api.call('/v1/memories', owner, 'POST', input), 200).cluster, first.cluster);
  status(await api.call(photo.path, owner, 'DELETE'), 409);
  status(await api.call(`/v1/media/by-upload-key/${photo.key}`, owner, 'DELETE'), 409);
  status(await api.call(photo.path, viewer), 200);
  status(await api.call(`/v1/memories/${first.id}`, owner, 'DELETE'), 204);
  status(await api.call(photo.path, viewer), 404);
  status(await api.call(photo.path, owner), 200);
  assert.deepEqual(status(await api.call(`/v1/memories/${second.id}`, owner), 200).cluster.members, first.cluster.members);
  status(await api.call(`/v1/memories/${second.id}`, owner, 'DELETE'), 204);
  status(await api.call(photo.path, owner), 404);
  status(await api.call(pending.path, owner), 200);
  status(await api.call('/v1/memories', owner, 'POST', input), 410);
  api.db(db => {
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM cluster_media').get().n, 0);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM memory_clusters').get().n, 0);
    assert.equal(db.prepare('SELECT media_id FROM media_upload_requests WHERE request_id = ?').get(photo.key).media_id, null);
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
  });
});

test('cluster validation is atomic, owner-scoped, bounded, and rejects nested or client-authored snapshots', async t => {
  const api = await fixture(t), owner = api.account('owner'), other = api.account('other');
  const source = await api.publish(owner), foreign = await api.publish(other, { visibility: 'public' });
  const parentID = randomUUID();
  const base = { id: parentID, kind: 'reel', visibility: 'public', location: LOCATION, caption: '' };
  const cluster = { title: 'Title', memoryIds: [source.id] };
  const cases = [
    [{ cluster: null }, 422], [{ cluster: {} }, 422], [{ cluster: { ...cluster, title: '' } }, 422],
    [{ cluster: { ...cluster, title: ' ' } }, 422], [{ cluster: { ...cluster, title: 'x'.repeat(161) } }, 422],
    [{ cluster: { ...cluster, memoryIds: [] } }, 422], [{ cluster: { ...cluster, memoryIds: Array.from({ length: 51 }, randomUUID) } }, 422],
    [{ cluster: { ...cluster, memoryIds: [source.id, source.id.toUpperCase()] } }, 422],
    [{ cluster: { ...cluster, memoryIds: [parentID] } }, 422], [{ cluster: { ...cluster, memoryIds: ['bad'] } }, 422],
    [{ cluster: { ...cluster, memoryIds: [source.id, foreign.id] } }, 404],
    [{ cluster: { ...cluster, memoryIds: [source.id, randomUUID()] } }, 404],
    [{ cluster: { ...cluster, members: [source] } }, 422], [{ cluster: { ...cluster, id: randomUUID() } }, 422],
    [{ kind: 'poi', place: { name: 'Place', category: 'coffee' }, cluster }, 422],
  ];
  for (const [overrides, expected] of cases) {
    status(await api.call('/v1/memories', owner, 'POST', { ...base, ...overrides }), expected);
    api.db(db => {
      assert.equal(db.prepare('SELECT 1 FROM memories WHERE id = ?').get(parentID), undefined);
      assert.equal(db.prepare('SELECT COUNT(*) AS n FROM memory_clusters').get().n, 0);
    });
  }
  api.db(db => db.prepare("UPDATE memories SET moderation_status = 'rejected' WHERE id = ?").run(source.id));
  status(await api.call('/v1/memories', owner, 'POST', { ...base, cluster }), 404);
  api.db(db => db.prepare("UPDATE memories SET moderation_status = 'approved' WHERE id = ?").run(source.id));
  const first = status(await api.call('/v1/memories', owner, 'POST', { ...base, cluster }), 201);
  const outer = await api.publish(owner, { cluster: { title: 'Flat', memoryIds: [first.id, source.id] } });
  assert.equal(outer.cluster.members[0].cluster, undefined);
  assert.equal(outer.cluster.members[0].id, first.id);
  status(await api.call(`/v1/memories/${outer.id}`, owner, 'PATCH', { cluster }), 422);
});

test('ordered 50-member requests are idempotent and changed selection/order conflicts without changing snapshots', async t => {
  const api = await fixture(t), owner = api.account('owner');
  const members = [];
  for (let n = 0; n < 50; n++) members.push(await api.publish(owner, { caption: `Record ${n}` }));
  const input = { id: randomUUID(), kind: 'reel', visibility: 'private', location: LOCATION,
    cluster: { title: 'x'.repeat(160), memoryIds: members.map(member => member.id).reverse() } };
  const results = await Promise.all([1, 2].map(() => api.call('/v1/memories', owner, 'POST', input)));
  assert.deepEqual(results.map(result => result.status).sort(), [200, 201]);
  assert.deepEqual(results[0].data.cluster.members.map(member => member.id), input.cluster.memoryIds);
  const frozen = results[0].data.cluster;
  status(await api.call('/v1/memories', owner, 'POST', { ...input,
    cluster: { ...input.cluster, memoryIds: [...input.cluster.memoryIds].reverse() } }), 409);
  status(await api.call('/v1/memories', owner, 'POST', { ...input, cluster: { ...input.cluster, title: 'Changed' } }), 409);
  await api.restart();
  assert.deepEqual(status(await api.call('/v1/memories', owner, 'POST', input), 200).cluster, frozen);
});

test('deleting parent preserves source and avatar references; deleting account safely cascades clusters', async t => {
  const api = await fixture(t), owner = api.account('owner'), viewer = api.account('viewer');
  const photo = await api.upload(owner), source = await api.publish(owner, { mediaIds: [photo.id] });
  const parent = await api.publish(owner, { visibility: 'public', cluster: { title: 'Source stays', memoryIds: [source.id] } });
  status(await api.call(`/v1/memories/${parent.id}`, owner, 'DELETE'), 204);
  status(await api.call(photo.path, owner), 200);
  status(await api.call(photo.path, viewer), 404);
  const another = await api.publish(owner, { visibility: 'public', cluster: { title: 'Account cleanup', memoryIds: [source.id] } });
  status(await api.call('/v1/me', owner, 'PATCH', { handle: 'owner', avatarMediaId: photo.id }), 200);
  status(await api.call(`/v1/memories/${source.id}`, owner, 'DELETE'), 204);
  status(await api.call(`/v1/memories/${another.id}`, owner, 'DELETE'), 204);
  status(await api.call(photo.path, owner), 200);
  const source2 = await api.publish(owner, { mediaIds: [photo.id] });
  await api.publish(owner, { cluster: { title: 'Cascade', memoryIds: [source2.id] } });
  status(await api.call('/v1/me', owner, 'DELETE'), 204);
  status(await api.call(photo.path, viewer), 404);
  api.db(db => {
    for (const table of ['memories', 'media', 'memory_clusters', 'cluster_media']) assert.equal(db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n, 0);
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
  });
});

test('schema12 migration and independent backup preserve all old rows and old absent-cluster retry hashes', async t => {
  const api = await fixture(t), owner = api.account('owner');
  const photo = await api.upload(owner);
  const legacy = { id: randomUUID(), kind: 'reel', visibility: 'public', location: LOCATION,
    caption: 'Before clusters', mediaIds: [photo.id] };
  await api.publish(owner, legacy);
  const oldHash = digest(JSON.stringify({ ...legacy, place: null, placeId: null }));
  api.db(db => {
    assert.equal(db.prepare('SELECT request_hash FROM memories WHERE id = ?').get(legacy.id).request_hash, oldHash);
    db.prepare('INSERT INTO comments VALUES (?, ?, ?, NULL, ?, ?)').run(randomUUID(), owner.id, legacy.id, 'Old reply', 1);
    db.exec('DROP TABLE cluster_media; DROP TABLE memory_clusters; PRAGMA user_version = 12;');
    db.prepare('INSERT INTO media_upload_sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
      .run(owner.id, randomUUID(), 'video/mp4', 5, '0'.repeat(64), 2, 1, 2);
    const pending = db.prepare('SELECT request_id FROM media_upload_sessions').get().request_id;
    db.prepare('INSERT INTO media_upload_chunks VALUES (?, ?, 0, ?)').run(owner.id, pending, Buffer.from('ab'));
  });
  const before = api.db(db => Object.fromEntries(db.prepare("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
    .all().map(({ name }) => [name, db.prepare(`SELECT * FROM ${name}`).all()])));
  const backupPath = `${api.databasePath}.backup`;
  await backupDatabase(api.databasePath, backupPath);
  for (const path of [api.databasePath, backupPath]) {
    const migrated = openDatabase(path);
    try {
      assert.equal(migrated.prepare('PRAGMA user_version').get().user_version, 13);
      for (const [table, rows] of Object.entries(before)) assert.deepEqual(migrated.prepare(`SELECT * FROM ${table}`).all(), rows, table);
      for (const table of ['memory_clusters', 'cluster_media']) assert.equal(migrated.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n, 0);
      assert.deepEqual(migrated.prepare('PRAGMA foreign_key_check').all(), []);
      assert.equal(migrated.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
    } finally { migrated.close(); }
  }
  status(await api.call('/v1/memories', owner, 'POST', legacy), 200);
  assert.equal(status(await api.call(`/v1/memories/${legacy.id}`, owner), 200).cluster, undefined);
});
