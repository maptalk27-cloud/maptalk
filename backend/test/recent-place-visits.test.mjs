import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { createBackend } from '../src/server.mjs';
import { digest, issueSession } from '../src/security.mjs';

const NOW = Date.parse('2026-11-12T20:00:00Z');
const HOUR = 60 * 60 * 1000;
const CENTER = { latitude: 47.538, longitude: -122.156 };
const gpsAt = meters => ({ latitude: CENTER.latitude + meters / 6_371_000 * 180 / Math.PI,
  longitude: CENTER.longitude });
const iso = time => new Date(time).toISOString();

function status(result, expected) {
  assert.equal(result.status, expected, JSON.stringify(result.data));
  return result.data;
}

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-recent-visits-'));
  const databasePath = join(directory, 'test.sqlite');
  let time = NOW;
  const backend = createBackend({ databasePath, now: () => time });
  t.after(async () => { await backend.close(); await rm(directory, { recursive: true, force: true }); });
  const address = await backend.listen(0);
  const api = {
    advance(milliseconds) { time += milliseconds; },
    db(work) {
      const db = new DatabaseSync(databasePath);
      try { return work(db); } finally { db.close(); }
    },
    account(handle = 'owner') {
      return api.db(db => {
        const id = randomUUID();
        db.prepare('INSERT INTO users(id, handle, password_hash, created_at) VALUES (?, ?, ?, ?)')
          .run(id, handle, 'local-test-only', time);
        return { id, ...issueSession(db, id, time) };
      });
    },
    async call(path, account, method = 'GET', json) {
      const response = await fetch(new URL(path, address.url), { method,
        headers: { ...(account ? { authorization: `Bearer ${account.token}` } : {}),
          ...(json !== undefined ? { 'content-type': 'application/json' } : {}) },
        body: json === undefined ? undefined : JSON.stringify(json) });
      const text = await response.text();
      return { status: response.status, data: text ? JSON.parse(text) : null };
    },
    publish(account, draft) { return api.call('/v1/memories', account, 'POST', draft); },
  };
  return api;
}

function visit(overrides = {}) {
  return { location: CENTER, recordedAt: iso(NOW - HOUR), horizontalAccuracy: 15, ...overrides };
}

function checkIn(overrides = {}) {
  return { id: randomUUID(), kind: 'poi', visibility: 'public', location: CENTER,
    capturedAt: iso(NOW), place: { name: 'Coffee stop', category: 'coffee', coordinate: CENTER }, ...overrides };
}

test('ordinary places and directory airports share the current-GPS 500m boundary', async t => {
  const api = await fixture(t), owner = api.account();
  const health = status(await api.call('/health'), 200);
  assert.equal(health.poiCheckInRadiusMeters, 500);
  assert.equal(health.supportsMediaPlaceVisits, false);
  assert.equal(health.supportsRecentPlaceVisits, undefined);
  for (const meters of [149, 151, 499]) {
    const draft = checkIn({ location: gpsAt(meters) });
    const saved = status(await api.publish(owner, draft), 201);
    assert.deepEqual(saved.location, draft.location);
    assert.deepEqual(saved.place.coordinate, CENTER);
  }
  status(await api.publish(owner, checkIn({ location: gpsAt(501) })), 422);
  const airport = { name: 'Airport', category: 'airport', coordinate: CENTER,
    sourceId: randomUUID(), directoryKind: 'airport' };
  status(await api.publish(owner, checkIn({ location: gpsAt(499), place: airport })), 201);
  status(await api.publish(owner, checkIn({ location: gpsAt(501), place: airport })), 422);
});

test('a recent fix cannot enable a remote check-in or change stored publication facts', async t => {
  const api = await fixture(t), owner = api.account(), viewer = api.account('viewer');
  status(await api.publish(owner, checkIn({ location: gpsAt(8000), placeVisit: visit() })), 422);
  const draft = checkIn({ location: gpsAt(400), placeVisit: visit({ location: gpsAt(8000) }) });
  const saved = status(await api.publish(owner, draft), 201);
  assert.deepEqual(saved.location, draft.location);
  assert.deepEqual(saved.place.coordinate, CENTER);
  assert.equal(saved.createdAt, iso(NOW));
  assert.equal(saved.publishedAt, iso(NOW));
  assert.equal(saved.placeVisit, undefined);
  assert.equal(status(await api.call(`/v1/memories/${saved.id}`, viewer), 200).placeVisit, undefined);
  api.db(db => {
    assert.equal(db.prepare('PRAGMA user_version').get().user_version, 19, 'no migration');
    const row = db.prepare('SELECT * FROM memories WHERE id = ?').get(saved.id);
    assert.equal(row.place_visit, undefined);
    assert.equal(JSON.stringify(row).includes(draft.placeVisit.recordedAt), false, 'visit evidence is not persisted');
  });
  status(await api.publish(owner, checkIn({ location: gpsAt(8000), placeVisit: visit({ location: gpsAt(501) }) })), 422);
});

test('legacy visit age does not grant or remove current-location eligibility', async t => {
  const api = await fixture(t), owner = api.account();
  for (const age of [-1, 0, 24 * HOUR, 24 * HOUR + 1]) {
    status(await api.publish(owner, checkIn({ location: CENTER,
      placeVisit: visit({ recordedAt: iso(NOW - age) }) })), 201);
    status(await api.publish(owner, checkIn({ location: gpsAt(8000),
      placeVisit: visit({ recordedAt: iso(NOW - age) }) })), 422);
  }
});

test('invalid accuracy, coordinates, fields, or timestamps never bypass checks even at a nearby current position', async t => {
  const api = await fixture(t), owner = api.account();
  const invalid = [null, [], {}, visit({ horizontalAccuracy: -1 }), visit({ horizontalAccuracy: 100.01 }),
    visit({ horizontalAccuracy: '15' }), visit({ horizontalAccuracy: null }), visit({ horizontalAccuracy: undefined }),
    visit({ location: { latitude: 91, longitude: 0 } }), visit({ location: { latitude: 0, longitude: 181 } }),
    visit({ recordedAt: '2026-02-30T12:00:00Z' }), visit({ recordedAt: 'invalid' }),
    visit({ recordedAt: '2026-11-12T19:00:00+00:00' }), visit({ extra: true }), visit({ location: { ...CENTER, extra: true } })];
  for (const placeVisit of invalid) {
    status(await api.publish(owner, checkIn({ placeVisit })), 422);
  }
  for (const horizontalAccuracy of [0, 100]) {
    status(await api.publish(owner, checkIn({ location: gpsAt(8000), placeVisit: visit({ horizontalAccuracy }) })), 422);
  }
  status(await api.publish(owner, { id: randomUUID(), kind: 'reel', visibility: 'public', location: CENTER,
    caption: 'Post, not a check-in', placeVisit: visit() }), 422);
});

test('delayed first upload and retries use saved publication time, not upload completion', async t => {
  const api = await fixture(t), owner = api.account();
  const draft = checkIn({ location: gpsAt(400), placeVisit: visit() });
  api.advance(3 * 24 * HOUR);
  const saved = status(await api.publish(owner, draft), 201);
  assert.equal(saved.createdAt, iso(NOW));
  assert.equal(saved.publishedAt, iso(NOW));
  api.advance(24 * HOUR);
  assert.deepEqual(status(await api.publish(owner, draft), 200), saved);
  status(await api.publish(owner, { ...draft, placeVisit: visit({ horizontalAccuracy: 20 }) }), 409);
});

test('omitting capturedAt uses request time and accepted retries remain idempotent', async t => {
  const api = await fixture(t), owner = api.account();
  const draft = checkIn({ capturedAt: undefined, location: gpsAt(400), placeVisit: visit() });
  const saved = status(await api.publish(owner, draft), 201);
  api.advance(2 * 24 * HOUR);
  assert.deepEqual(status(await api.publish(owner, draft), 200), saved);
  status(await api.publish(owner, { ...draft, id: randomUUID(), location: gpsAt(8000) }), 422);
});

test('canonical placeId and sourceId validate the original landmark rather than caller-supplied replacement coordinates', async t => {
  const api = await fixture(t), owner = api.account(), viewer = api.account('viewer');
  const sourceId = randomUUID();
  const first = status(await api.publish(owner, checkIn({ place: { name: 'Original', category: 'coffee',
    coordinate: CENTER, sourceId } })), 201);
  const remote = gpsAt(8000);
  for (const selected of [{ place: undefined, placeId: first.place.id },
    { place: { name: 'Do not rename', category: 'other', coordinate: remote, sourceId } }]) {
    const draft = checkIn({ ...selected, location: remote, placeVisit: visit() });
    status(await api.publish(viewer, draft), 422);
    const saved = status(await api.publish(viewer, { ...draft, location: gpsAt(499) }), 201);
    assert.deepEqual(saved.place, first.place);
    status(await api.publish(viewer, { ...draft, id: randomUUID(), placeVisit: visit({ location: remote }) }), 422);
  }
  const hidden = status(await api.publish(owner, checkIn({ visibility: 'private' })), 201);
  status(await api.publish(viewer, checkIn({ place: undefined, placeId: hidden.place.id,
    location: remote, placeVisit: visit() })), 404, 'recent GPS does not unlock private history');
});

test('airport metadata and history cannot extend current check-in range', async t => {
  const api = await fixture(t), owner = api.account();
  const place = { name: 'Airport', category: 'airport', coordinate: CENTER,
    sourceId: randomUUID(), directoryKind: 'airport' };
  const base = checkIn({ location: gpsAt(8000), place });
  status(await api.publish(owner, { ...base, placeVisit: visit({ location: gpsAt(499) }) }), 422);
  status(await api.publish(owner, { ...base, id: randomUUID(), placeVisit: visit({ location: gpsAt(501) }) }), 422);
});

test('legacy requests omit visit data in their normalized hashes and keep existing retries valid', async t => {
  const api = await fixture(t), owner = api.account();
  for (const capturedAt of [undefined, iso(NOW)]) {
    const draft = checkIn({ capturedAt });
    const saved = status(await api.publish(owner, draft), 201);
    const legacyNormalized = { id: draft.id, kind: draft.kind, visibility: draft.visibility,
      location: draft.location, caption: '', mediaIds: [], place: draft.place, placeId: null,
      ...(capturedAt ? { capturedAt } : {}) };
    assert.equal(api.db(db => db.prepare('SELECT request_hash FROM memories WHERE id = ?').get(saved.id).request_hash),
      digest(JSON.stringify(legacyNormalized)));
    assert.deepEqual(status(await api.publish(owner, draft), 200), saved);
  }
});

test('an already saved legacy remote check-in remains retryable but cannot be published under a new ID', async t => {
  const api = await fixture(t), owner = api.account();
  const draft = checkIn({ placeVisit: visit() });
  const saved = status(await api.publish(owner, draft), 201);
  const remote = { ...draft, location: gpsAt(8000) };
  const oldNormalized = { id: remote.id, kind: remote.kind, visibility: remote.visibility,
    location: remote.location, caption: '', mediaIds: [], place: remote.place, placeId: null,
    capturedAt: remote.capturedAt, placeVisit: remote.placeVisit };
  // Fixture of a record already accepted by the old implementation. No
  // migration or revalidation may rewrite its data on an identical retry.
  api.db(db => db.prepare('UPDATE memories SET latitude = ?, longitude = ?, request_hash = ? WHERE id = ?')
    .run(remote.location.latitude, remote.location.longitude, digest(JSON.stringify(oldNormalized)), remote.id));
  const retried = status(await api.publish(owner, remote), 200);
  assert.equal(retried.id, saved.id);
  assert.deepEqual(retried.location, remote.location);
  assert.deepEqual(retried.place, saved.place);
  assert.equal(retried.createdAt, saved.createdAt);
  status(await api.publish(owner, { ...remote, id: randomUUID() }), 422);
});
