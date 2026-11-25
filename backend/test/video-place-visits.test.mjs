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
const CENTER = { latitude: 21.2779877, longitude: -157.8335273 };
const gpsAt = meters => ({ latitude: CENTER.latitude + meters / 6_371_000 * 180 / Math.PI,
  longitude: CENTER.longitude });
const iso = time => new Date(time).toISOString();

function status(result, expected) {
  assert.equal(result.status, expected, JSON.stringify(result.data));
  return result.data;
}

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-video-visits-'));
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
    media(account, mimeType = 'video/mp4') {
      // Upload/transcode already has separate tests. Seed only the processed
      // attachment row to isolate location eligibility, MIME and ownership.
      const id = randomUUID();
      api.db(db => db.prepare('INSERT INTO media VALUES (?, ?, ?, ?, ?, ?)')
        .run(id, account.id, mimeType, 3, Buffer.from('MP4'), time));
      return id;
    },
  };
  return api;
}

function videoVisit(overrides = {}) {
  return { location: CENTER, capturedAt: iso(NOW - HOUR), ...overrides };
}

function checkIn(mediaID, overrides = {}) {
  return { id: randomUUID(), kind: 'poi', visibility: 'public', location: CENTER,
    capturedAt: iso(NOW), mediaIds: [mediaID], videoVisit: videoVisit(),
    place: { name: 'Steak Shack', category: 'restaurant', coordinate: CENTER }, ...overrides };
}

test('video metadata cannot enable remote check-in and nearby publishing preserves existing facts', async t => {
  const api = await fixture(t), owner = api.account(), viewer = api.account('viewer');
  const health = status(await api.call('/health'), 200);
  assert.equal(health.supportsVideoPlaceVisits, undefined);
  assert.equal(health.supportsPhotoPlaceVisits, undefined);
  assert.equal(health.supportsRecentPlaceVisits, undefined);
  assert.equal(health.supportsMediaPlaceVisits, false);
  assert.equal(health.poiCheckInRadiusMeters, 500);
  const draft = checkIn(api.media(owner));
  status(await api.publish(owner, { ...draft, location: gpsAt(8000) }), 422);
  const saved = status(await api.publish(owner, draft), 201);
  assert.deepEqual(saved.location, draft.location);
  assert.deepEqual(saved.place.coordinate, CENTER);
  assert.equal(saved.createdAt, iso(NOW));
  assert.equal(saved.publishedAt, iso(NOW));
  assert.equal(saved.media[0].mimeType, 'video/mp4');
  assert.equal(saved.videoVisit, undefined);
  assert.equal(status(await api.call(`/v1/memories/${saved.id}`, viewer), 200).videoVisit, undefined);
  api.db(db => {
    assert.equal(db.prepare('PRAGMA user_version').get().user_version, 19);
    assert.equal(JSON.stringify(db.prepare('SELECT * FROM memories WHERE id = ?').get(saved.id))
      .includes(draft.videoVisit.capturedAt), false, 'original metadata is not separately persisted');
  });
});

test('video age does not widen or restrict current-GPS check-in eligibility', async t => {
  const api = await fixture(t), owner = api.account(), media = api.media(owner);
  for (const age of [-1, 0, 24 * HOUR, 24 * HOUR + 1]) {
    status(await api.publish(owner, checkIn(media, { videoVisit: videoVisit({ capturedAt: iso(NOW - age) }) })), 201);
    status(await api.publish(owner, checkIn(media, { location: gpsAt(8000),
      videoVisit: videoVisit({ capturedAt: iso(NOW - age) }) })), 422);
  }
});

test('video metadata requires valid coordinates and UTC calendar date without additional fields', async t => {
  const api = await fixture(t), owner = api.account(), media = api.media(owner);
  const invalid = [null, [], {}, videoVisit({ capturedAt: 'invalid' }),
    videoVisit({ capturedAt: '2026-02-30T12:00:00Z' }), videoVisit({ capturedAt: '2026-11-12T19:00:00+00:00' }),
    videoVisit({ capturedAt: undefined }), videoVisit({ location: { latitude: 91, longitude: 0 } }),
    videoVisit({ location: { latitude: 0, longitude: 181 } }), videoVisit({ location: { latitude: '21', longitude: 0 } }),
    videoVisit({ location: { ...CENTER, extra: true } }), videoVisit({ horizontalAccuracy: 0 })];
  for (const evidence of invalid) {
    status(await api.publish(owner, checkIn(media, { location: CENTER, videoVisit: evidence })), 422);
  }
  status(await api.publish(owner, { id: randomUUID(), kind: 'reel', visibility: 'public', location: CENTER,
    caption: 'Post, not a check-in', mediaIds: [media], videoVisit: videoVisit() }), 422);
});

test('legacy video fields retain attachment ownership and type validation and cannot also claim a photo', async t => {
  const api = await fixture(t), owner = api.account(), other = api.account('other');
  const media = api.media(owner);
  status(await api.publish(owner, checkIn(media, { mediaIds: [] })), 422);
  status(await api.publish(owner, checkIn(media, { mediaIds: undefined })), 422);
  status(await api.publish(owner, checkIn(randomUUID())), 404);
  status(await api.publish(other, checkIn(media)), 404);
  for (const type of ['image/jpeg', 'image/png', 'image/webp']) {
    status(await api.publish(owner, checkIn(api.media(owner, type))), 422);
  }
  // Raw/unprocessed formats cannot enter persisted media in the first place.
  for (const type of ['video/quicktime', 'application/octet-stream']) {
    assert.throws(() => api.media(owner, type), /CHECK constraint failed/);
  }
  status(await api.publish(owner, checkIn(media, { photoVisit: videoVisit() })), 422);
  status(await api.publish(owner, checkIn(media, { mediaIds: [media, api.media(owner)] })), 422);
  status(await api.publish(owner, checkIn(media)), 201);
});

test('only current GPS determines500m eligibility, not video or airport metadata', async t => {
  const api = await fixture(t), owner = api.account(), media = api.media(owner);
  for (const place of [{ name: 'Restaurant', category: 'restaurant', coordinate: CENTER },
    { name: 'Airport', category: 'airport', coordinate: CENTER, sourceId: randomUUID(), directoryKind: 'airport' }]) {
    status(await api.publish(owner, checkIn(media, { place, location: gpsAt(499),
      videoVisit: videoVisit({ location: gpsAt(8000) }) })), 201);
    status(await api.publish(owner, checkIn(media, { place, location: gpsAt(8000),
      videoVisit: videoVisit({ location: gpsAt(499) }) })), 422);
    for (const location of [gpsAt(501), gpsAt(8000)]) {
      status(await api.publish(owner, checkIn(media, { place, location,
        videoVisit: videoVisit({ location: gpsAt(501) }) })), 422);
    }
  }
});

test('delayed video upload and retry use immutable first publish time instead of upload or transcode completion', async t => {
  const api = await fixture(t), owner = api.account(), media = api.media(owner);
  const draft = checkIn(media);
  api.advance(3 * 24 * HOUR);
  const saved = status(await api.publish(owner, draft), 201);
  assert.equal(saved.createdAt, iso(NOW));
  api.advance(24 * HOUR);
  assert.deepEqual(status(await api.publish(owner, draft), 200), saved);
  status(await api.publish(owner, { ...draft, videoVisit: videoVisit({ capturedAt: iso(NOW - 2 * HOUR) }) }), 409);
});

test('without first publish time request time is used and accepted retries remain stable', async t => {
  const api = await fixture(t), owner = api.account(), media = api.media(owner);
  const draft = checkIn(media, { capturedAt: undefined });
  const saved = status(await api.publish(owner, draft), 201);
  api.advance(2 * 24 * HOUR);
  assert.deepEqual(status(await api.publish(owner, draft), 200), saved);
  status(await api.publish(owner, { ...draft, id: randomUUID(), location: gpsAt(8000) }), 422);
});

test('video uses the persisted canonical source coordinates and preserves private place access control', async t => {
  const api = await fixture(t), owner = api.account(), viewer = api.account('viewer');
  const media = api.media(owner), viewerMedia = api.media(viewer), sourceId = randomUUID();
  const first = status(await api.publish(owner, checkIn(media, {
    place: { name: 'Original', category: 'restaurant', coordinate: CENTER, sourceId } })), 201);
  for (const selected of [{ place: undefined, placeId: first.place.id },
    { place: { name: 'Do not rename', category: 'other', coordinate: gpsAt(8000), sourceId } }]) {
    const draft = checkIn(viewerMedia, selected);
    assert.deepEqual(status(await api.publish(viewer, draft), 201).place, first.place);
    status(await api.publish(viewer, { ...draft, id: randomUUID(), location: gpsAt(8000),
      videoVisit: videoVisit({ location: gpsAt(8000) }) }), 422);
  }
  const hidden = status(await api.publish(owner, checkIn(media, { visibility: 'private' })), 201);
  status(await api.publish(viewer, checkIn(viewerMedia, { place: undefined, placeId: hidden.place.id })), 404);
});

test('new places still use current GPS rather than video coordinates', async t => {
  const api = await fixture(t), owner = api.account(), media = api.media(owner);
  const saved = status(await api.publish(owner, checkIn(media, { location: CENTER,
    place: { name: 'New place', category: 'other' } })), 201);
  assert.deepEqual(saved.place.coordinate, CENTER);
  const elsewhere = gpsAt(8000);
  const newPlace = status(await api.publish(owner, checkIn(media, { location: elsewhere,
    place: { name: 'New place', category: 'other' } })), 201);
  assert.deepEqual(newPlace.place.coordinate, elsewhere);
});

test('legacy photo requests retain their normalized hash after adding video support', async t => {
  const api = await fixture(t), owner = api.account(), media = api.media(owner, 'image/jpeg');
  const draft = checkIn(media, { videoVisit: undefined, photoVisit: videoVisit() });
  const saved = status(await api.publish(owner, draft), 201);
  const normalized = { id: draft.id, kind: draft.kind, visibility: draft.visibility,
    location: draft.location, caption: '', mediaIds: [media], place: draft.place, placeId: null,
    capturedAt: draft.capturedAt, photoVisit: draft.photoVisit };
  assert.equal(api.db(db => db.prepare('SELECT request_hash FROM memories WHERE id = ?').get(saved.id).request_hash),
    digest(JSON.stringify(normalized)));
  assert.deepEqual(status(await api.publish(owner, draft), 200), saved);
});

test('an accepted remote video check-in remains retryable after disabling media fallback, but a new ID is rejected', async t => {
  const api = await fixture(t), owner = api.account(), media = api.media(owner);
  const draft = checkIn(media);
  const saved = status(await api.publish(owner, draft), 201);
  const remote = { ...draft, location: gpsAt(8000) };
  const normalized = { id: remote.id, kind: remote.kind, visibility: remote.visibility,
    location: remote.location, caption: '', mediaIds: [media], place: remote.place, placeId: null,
    capturedAt: remote.capturedAt, videoVisit: remote.videoVisit };
  // Reproduce a previously accepted record, not a new remote publication.
  api.db(db => db.prepare('UPDATE memories SET latitude = ?, longitude = ?, request_hash = ? WHERE id = ?')
    .run(remote.location.latitude, remote.location.longitude, digest(JSON.stringify(normalized)), remote.id));
  api.advance(3 * 24 * HOUR);
  const retried = status(await api.publish(owner, remote), 200);
  assert.deepEqual(retried, { ...saved, location: remote.location });
  status(await api.publish(owner, { ...remote, id: randomUUID() }), 422);
});
