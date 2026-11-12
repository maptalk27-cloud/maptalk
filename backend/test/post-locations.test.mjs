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

const LOCATION = { latitude: 37.3688, longitude: -122.0363 };

function status(result, expected) {
  assert.equal(result.status, expected, JSON.stringify(result.data));
  return result.data;
}

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-post-location-'));
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
          .run(id, handle, 'local-test-only', Date.now());
        return { id, ...issueSession(db, id, Date.now()) };
      });
    },
    async restart() {
      await backend.close(); backend = createBackend({ databasePath }); address = await backend.listen(0);
    },
    async call(path, account, method = 'GET', json) {
      const response = await fetch(new URL(path, address.url), { method,
        headers: { ...(account ? { authorization: `Bearer ${account.token}` } : {}),
          ...(json !== undefined ? { 'content-type': 'application/json' } : {}) },
        body: json === undefined ? undefined : JSON.stringify(json) });
      const text = await response.text();
      return { status: response.status, data: text ? JSON.parse(text) : null };
    },
  };
  return api;
}

function post(overrides = {}) {
  return { id: randomUUID(), kind: 'reel', visibility: 'public', location: LOCATION,
    caption: 'A quiet afternoon.', ...overrides };
}

test('named Post coordinates persist across publication, public browsing, caption edits and restart', async t => {
  const api = await fixture(t), owner = api.account('owner'), viewer = api.account('viewer');
  assert.equal(status(await api.call('/health'), 200).supportsPostLocationNames, true);
  const draft = post({ location: { latitude: 37.3791, longitude: -122.0467 }, locationName: '  Our sunset spot  ' });
  const saved = status(await api.call('/v1/memories', owner, 'POST', draft), 201);
  assert.deepEqual(saved.location, draft.location);
  assert.equal(saved.locationName, 'Our sunset spot');
  assert.equal(saved.place, null, 'A named Post must not create a check-in landmark.');
  assert.equal(api.db(db => db.prepare('SELECT COUNT(*) AS n FROM places').get().n), 0);
  assert.deepEqual(status(await api.call('/v1/memories', owner, 'POST', draft), 200), saved);
  status(await api.call('/v1/memories', owner, 'POST', { ...draft, locationName: 'Different place' }), 409);
  // Same location is reusable for an independent Post, not an update to the first.
  status(await api.call('/v1/memories', owner, 'POST', { ...draft, id: randomUUID() }), 201);
  for (const path of ['/v1/me/memories', '/v1/posts', `/v1/users/${owner.id}/memories`,
    '/v1/map/memories?west=-123&east=-121&south=37&north=38']) {
    const page = status(await api.call(path, path === '/v1/me/memories' ? owner : viewer), 200);
    assert.equal(page.items.find(item => item.id === saved.id)?.locationName, saved.locationName, path);
  }
  status(await api.call(`/v1/memories/${saved.id}`, owner, 'PATCH', { caption: 'Updated caption' }), 200);
  await api.restart();
  const reloaded = status(await api.call(`/v1/memories/${saved.id}`, viewer), 200);
  assert.equal(reloaded.locationName, saved.locationName);
  assert.deepEqual(reloaded.location, saved.location);
  assert.equal(reloaded.caption, 'Updated caption');
});

test('a private Post location name is shared only through an explicitly attached snapshot', async t => {
  const api = await fixture(t), owner = api.account('owner'), viewer = api.account('viewer');
  const source = status(await api.call('/v1/memories', owner, 'POST',
    post({ visibility: 'private', locationName: 'Family picnic spot' })), 201);
  status(await api.call(`/v1/memories/${source.id}`, viewer), 404);
  assert.equal(status(await api.call('/v1/posts', viewer), 200).items.length, 0);
  const parent = status(await api.call('/v1/memories', owner, 'POST',
    post({ cluster: { title: 'Weekend', memoryIds: [source.id] } })), 201);
  assert.equal(parent.cluster.members[0].locationName, source.locationName);
  status(await api.call(`/v1/memories/${source.id}`, owner, 'DELETE'), 204);
  await api.restart();
  const viewed = status(await api.call(`/v1/memories/${parent.id}`, viewer), 200);
  assert.equal(viewed.cluster.members[0].locationName, source.locationName);
  assert.deepEqual(viewed.cluster.members[0].location, source.location);
  assert.equal(Object.hasOwn(viewed, 'locationName'), false, 'A member name must not name the parent.');
});

test('location names are optional Reel-only text with an 80 UTF-16 unit boundary', async t => {
  const api = await fixture(t), owner = api.account('owner');
  for (const locationName of ['', ' \n\t ', null, 123, {}, 'a'.repeat(81), '🌅'.repeat(41),
    'Two\nlines', 'Null\u0000byte', 'Hidden\u200emark']) {
    status(await api.call('/v1/memories', owner, 'POST', post({ locationName })), 422);
  }
  for (const locationName of ['a'.repeat(80), '🌅'.repeat(40)]) {
    assert.equal(status(await api.call('/v1/memories', owner, 'POST', post({ locationName })), 201).locationName,
      locationName);
  }
  status(await api.call('/v1/memories', owner, 'POST', post({ kind: 'poi', caption: '',
    locationName: 'Cannot rename this check-in', place: { name: 'Real café', category: 'coffee' } })), 422);
  status(await api.call('/v1/memories', owner, 'POST', post({ caption: '', locationName: 'A name is not content' })), 422);
  const legacy = status(await api.call('/v1/memories', owner, 'POST', post()), 201);
  assert.equal(Object.hasOwn(legacy, 'locationName'), false);
});

test('schema 14 to 15 preserves original records, backups and old absent-name retry hashes', async t => {
  const api = await fixture(t), owner = api.account('owner');
  const draft = post({ capturedAt: new Date().toISOString() });
  const original = status(await api.call('/v1/memories', owner, 'POST', draft), 201);
  const oldNormalized = { id: draft.id, kind: draft.kind, visibility: draft.visibility,
    location: draft.location, caption: draft.caption, mediaIds: [], place: null, placeId: null,
    capturedAt: draft.capturedAt };
  const expectedHash = digest(JSON.stringify(oldNormalized));
  api.db(db => {
    assert.equal(db.prepare('SELECT request_hash FROM memories WHERE id = ?').get(draft.id).request_hash, expectedHash);
    // A genuine pre-feature shape, not just a changed version marker.
    db.exec('ALTER TABLE memories DROP COLUMN location_name; PRAGMA user_version = 14;');
  });
  const tables = api.db(db => db.prepare("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
    .all().map(({ name }) => name));
  const before = api.db(db => Object.fromEntries(tables.map(name => [name, db.prepare(`SELECT * FROM ${name}`).all()])));
  const backup = `${api.databasePath}.backup`;
  await backupDatabase(api.databasePath, backup);
  for (const path of [api.databasePath, backup]) {
    const migrated = openDatabase(path);
    try {
      assert.equal(migrated.prepare('PRAGMA user_version').get().user_version, 15);
      for (const [table, rows] of Object.entries(before)) {
        const expected = table === 'memories'
          ? rows.map(row => Object.assign(Object.create(null), row, { location_name: null })) : rows;
        assert.deepEqual(migrated.prepare(`SELECT * FROM ${table}`).all(), expected, table);
      }
      assert.deepEqual(migrated.prepare('PRAGMA foreign_key_check').all(), []);
      assert.equal(migrated.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
    } finally { migrated.close(); }
  }
  await api.restart();
  assert.deepEqual(status(await api.call('/v1/memories', owner, 'POST', draft), 200), original);
  assert.equal(api.db(db => db.prepare('SELECT request_hash FROM memories WHERE id = ?').get(draft.id).request_hash), expectedHash);
});
