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
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1cAAAAASUVORK5CYII=', 'base64');

function status(result, expected) {
  assert.equal(result.status, expected, JSON.stringify(result.data));
  return result.data;
}

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-photo-visits-'));
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
    async call(path, account, method = 'GET', json, bytes) {
      const response = await fetch(new URL(path, address.url), { method,
        headers: { ...(account ? { authorization: `Bearer ${account.token}` } : {}),
          ...(bytes ? { 'content-type': 'image/png' } : json !== undefined ? { 'content-type': 'application/json' } : {}) },
        body: bytes ?? (json === undefined ? undefined : JSON.stringify(json)) });
      const text = await response.text();
      return { status: response.status, data: text ? JSON.parse(text) : null };
    },
    publish(account, draft) { return api.call('/v1/memories', account, 'POST', draft); },
    async photo(account) { return status(await api.call('/v1/media', account, 'POST', undefined, PNG), 201).id; },
    video(account) {
      // The video payload is irrelevant to eligibility; a persisted video row
      // exercises the same MIME/ownership check without an FFmpeg dependency.
      const id = randomUUID();
      api.db(db => db.prepare('INSERT INTO media VALUES (?, ?, ?, ?, ?, ?)')
        .run(id, account.id, 'video/mp4', 3, Buffer.from('MP4'), time));
      return id;
    },
  };
  return api;
}

function photoVisit(overrides = {}) {
  return { location: CENTER, capturedAt: iso(NOW - HOUR), ...overrides };
}

function checkIn(mediaID, overrides = {}) {
  return { id: randomUUID(), kind: 'poi', visibility: 'public', location: CENTER,
    capturedAt: iso(NOW), mediaIds: [mediaID], photoVisit: photoVisit(),
    place: { name: 'Coffee stop', category: 'coffee', coordinate: CENTER }, ...overrides };
}

test('photo metadata cannot enable remote check-in and nearby publishing preserves existing facts', async t => {
  const api = await fixture(t), owner = api.account(), viewer = api.account('viewer');
  const health = status(await api.call('/health'), 200);
  assert.equal(health.supportsPhotoPlaceVisits, undefined);
  assert.equal(health.supportsVideoPlaceVisits, undefined);
  assert.equal(health.supportsRecentPlaceVisits, undefined);
  assert.equal(health.supportsMediaPlaceVisits, false);
  assert.equal(health.poiCheckInRadiusMeters, 500);
  const draft = checkIn(await api.photo(owner));
  status(await api.publish(owner, { ...draft, location: gpsAt(8000) }), 422);
  const saved = status(await api.publish(owner, draft), 201);
  assert.deepEqual(saved.location, draft.location);
  assert.deepEqual(saved.place.coordinate, CENTER);
  assert.equal(saved.createdAt, iso(NOW));
  assert.equal(saved.publishedAt, iso(NOW));
  assert.equal(saved.media.length, 1);
  assert.equal(saved.photoVisit, undefined);
  assert.equal(status(await api.call(`/v1/memories/${saved.id}`, viewer), 200).photoVisit, undefined);
  api.db(db => {
    assert.equal(db.prepare('PRAGMA user_version').get().user_version, 19);
    const row = db.prepare('SELECT * FROM memories WHERE id = ?').get(saved.id);
    assert.equal(JSON.stringify(row).includes(draft.photoVisit.capturedAt), false, 'photo metadata is not persisted');
  });
});

test('photo age does not widen or restrict current-GPS check-in eligibility', async t => {
  const api = await fixture(t), owner = api.account(), photo = await api.photo(owner);
  for (const age of [-1, 0, 24 * HOUR, 24 * HOUR + 1]) {
    status(await api.publish(owner, checkIn(photo, { photoVisit: photoVisit({ capturedAt: iso(NOW - age) }) })), 201);
    status(await api.publish(owner, checkIn(photo, { location: gpsAt(8000),
      photoVisit: photoVisit({ capturedAt: iso(NOW - age) }) })), 422);
  }
});

test('invalid photo metadata is rejected without inventing accuracy or accepting other fields', async t => {
  const api = await fixture(t), owner = api.account(), photo = await api.photo(owner);
  const invalid = [null, [], {}, photoVisit({ capturedAt: 'invalid' }),
    photoVisit({ capturedAt: '2026-02-30T12:00:00Z' }), photoVisit({ capturedAt: '2026-11-12T19:00:00+00:00' }),
    photoVisit({ capturedAt: undefined }), photoVisit({ location: { latitude: 91, longitude: 0 } }),
    photoVisit({ location: { latitude: 0, longitude: 181 } }), photoVisit({ location: { latitude: '47', longitude: 0 } }),
    photoVisit({ location: { ...CENTER, extra: true } }), photoVisit({ horizontalAccuracy: 0 })];
  for (const evidence of invalid) {
    status(await api.publish(owner, checkIn(photo, { location: CENTER, photoVisit: evidence })), 422);
  }
  status(await api.publish(owner, { id: randomUUID(), kind: 'reel', visibility: 'public', location: CENTER,
    caption: 'Post, not a check-in', mediaIds: [photo], photoVisit: photoVisit() }), 422);
});

test('legacy photo fields retain attachment ownership and type validation', async t => {
  const api = await fixture(t), owner = api.account(), other = api.account('other');
  const photo = await api.photo(owner);
  status(await api.publish(owner, checkIn(photo, { mediaIds: [] })), 422);
  status(await api.publish(owner, checkIn(photo, { mediaIds: undefined })), 422);
  status(await api.publish(owner, checkIn(randomUUID())), 404);
  status(await api.publish(other, checkIn(photo)), 404);
  status(await api.publish(owner, checkIn(api.video(owner))), 422);
  status(await api.publish(owner, checkIn(photo)), 201);
});

test('only current GPS determines500m eligibility, not photo or airport metadata', async t => {
  const api = await fixture(t), owner = api.account(), photo = await api.photo(owner);
  for (const place of [{ name: 'Cafe', category: 'coffee', coordinate: CENTER },
    { name: 'Airport', category: 'airport', coordinate: CENTER, sourceId: randomUUID(), directoryKind: 'airport' }]) {
    status(await api.publish(owner, checkIn(photo, { place, location: gpsAt(499),
      photoVisit: photoVisit({ location: gpsAt(8000) }) })), 201);
    status(await api.publish(owner, checkIn(photo, { place, location: gpsAt(8000),
      photoVisit: photoVisit({ location: gpsAt(499) }) })), 422);
    for (const location of [gpsAt(501), gpsAt(8000)]) {
      status(await api.publish(owner, checkIn(photo, { place, location,
        photoVisit: photoVisit({ location: gpsAt(501) }) })), 422);
    }
  }
});

test('delayed uploads and retries preserve first publish time, and changed evidence is not the same retry', async t => {
  const api = await fixture(t), owner = api.account(), photo = await api.photo(owner);
  const draft = checkIn(photo);
  api.advance(3 * 24 * HOUR);
  const saved = status(await api.publish(owner, draft), 201);
  assert.equal(saved.createdAt, iso(NOW));
  api.advance(24 * HOUR);
  assert.deepEqual(status(await api.publish(owner, draft), 200), saved);
  status(await api.publish(owner, { ...draft, photoVisit: photoVisit({ capturedAt: iso(NOW - 2 * HOUR) }) }), 409);
});

test('without first publish time request time is used and accepted retries remain stable', async t => {
  const api = await fixture(t), owner = api.account(), photo = await api.photo(owner);
  const draft = checkIn(photo, { capturedAt: undefined });
  const saved = status(await api.publish(owner, draft), 201);
  api.advance(2 * 24 * HOUR);
  assert.deepEqual(status(await api.publish(owner, draft), 200), saved);
  status(await api.publish(owner, { ...draft, id: randomUUID(), location: gpsAt(8000) }), 422);
});

test('canonical source and place IDs keep original coordinates and privacy checks', async t => {
  const api = await fixture(t), owner = api.account(), viewer = api.account('viewer');
  const photo = await api.photo(owner), viewerPhoto = await api.photo(viewer), sourceId = randomUUID();
  const first = status(await api.publish(owner, checkIn(photo, {
    place: { name: 'Original', category: 'coffee', coordinate: CENTER, sourceId } })), 201);
  for (const selected of [{ place: undefined, placeId: first.place.id },
    { place: { name: 'Do not rename', category: 'other', coordinate: gpsAt(8000), sourceId } }]) {
    const draft = checkIn(viewerPhoto, selected);
    assert.deepEqual(status(await api.publish(viewer, draft), 201).place, first.place);
    status(await api.publish(viewer, { ...draft, id: randomUUID(), location: gpsAt(8000),
      photoVisit: photoVisit({ location: gpsAt(8000) }) }), 422);
  }
  const hidden = status(await api.publish(owner, checkIn(photo, { visibility: 'private' })), 201);
  status(await api.publish(viewer, checkIn(viewerPhoto, { place: undefined, placeId: hidden.place.id })), 404);
});

test('new places without a directory coordinate still use current GPS, not photo location', async t => {
  const api = await fixture(t), owner = api.account(), photo = await api.photo(owner);
  const saved = status(await api.publish(owner, checkIn(photo, { location: CENTER,
    place: { name: 'New place', category: 'other' } })), 201);
  assert.deepEqual(saved.place.coordinate, CENTER);
  const elsewhere = gpsAt(8000);
  const newPlace = status(await api.publish(owner, checkIn(photo, { location: elsewhere,
    place: { name: 'New place', category: 'other' } })), 201);
  assert.deepEqual(newPlace.place.coordinate, elsewhere);
});

test('legacy requests omit photo evidence from normalized hashes and preserve retries', async t => {
  const api = await fixture(t), owner = api.account(), photo = await api.photo(owner);
  const draft = checkIn(photo, { location: CENTER, photoVisit: undefined });
  const saved = status(await api.publish(owner, draft), 201);
  const normalized = { id: draft.id, kind: draft.kind, visibility: draft.visibility,
    location: draft.location, caption: '', mediaIds: [photo], place: draft.place, placeId: null, capturedAt: draft.capturedAt };
  assert.equal(api.db(db => db.prepare('SELECT request_hash FROM memories WHERE id = ?').get(saved.id).request_hash),
    digest(JSON.stringify(normalized)));
  assert.deepEqual(status(await api.publish(owner, draft), 200), saved);
});

test('an accepted remote photo check-in remains retryable after disabling media fallback, but a new ID is rejected', async t => {
  const api = await fixture(t), owner = api.account(), photo = await api.photo(owner);
  const draft = checkIn(photo);
  const saved = status(await api.publish(owner, draft), 201);
  const remote = { ...draft, location: gpsAt(8000) };
  const normalized = { id: remote.id, kind: remote.kind, visibility: remote.visibility,
    location: remote.location, caption: '', mediaIds: [photo], place: remote.place, placeId: null,
    capturedAt: remote.capturedAt, photoVisit: remote.photoVisit };
  // Reproduce a previously accepted record, not a new remote publication.
  api.db(db => db.prepare('UPDATE memories SET latitude = ?, longitude = ?, request_hash = ? WHERE id = ?')
    .run(remote.location.latitude, remote.location.longitude, digest(JSON.stringify(normalized)), remote.id));
  api.advance(3 * 24 * HOUR);
  const retried = status(await api.publish(owner, remote), 200);
  assert.deepEqual(retried, { ...saved, location: remote.location });
  status(await api.publish(owner, { ...remote, id: randomUUID() }), 422);
});
