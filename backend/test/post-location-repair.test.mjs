import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openDatabase } from '../src/database.mjs';
import { planPostLocationRepair, applyPostLocationRepair } from '../scripts/repair-post-locations.mjs';

const hash = input => createHash('sha256').update(JSON.stringify(input)).digest('hex');
async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-post-location-repair-'));
  const db = openDatabase(join(directory, 'test.sqlite'));
  // The one-time repair remains explicitly scoped to its schema 16 release.
  db.exec('DROP TABLE IF EXISTS memory_custom_feelings; DROP TABLE memory_feedback; PRAGMA user_version = 16;');
  t.after(async () => { db.close(); await rm(directory, { recursive: true, force: true }); });
  const ownerID = randomUUID(), otherOwnerID = randomUUID(), locationID = randomUUID();
  const postIDs = [randomUUID(), randomUUID(), randomUUID()];
  const mediaID = randomUUID();
  const user = db.prepare('INSERT INTO users(id, handle, password_hash, created_at) VALUES (?, ?, ?, ?)');
  user.run(ownerID, 'alice', 'not-a-password', 1);
  user.run(otherOwnerID, 'bob', 'not-a-password', 1);
  db.prepare('INSERT INTO places VALUES (?, ?, ?, ?, ?, ?)')
    .run(locationID, 'Private place label', 'other', 37.37, -122.04, null);
  db.prepare('INSERT INTO media VALUES (?, ?, ?, ?, ?, ?)')
    .run(mediaID, ownerID, 'image/jpeg', 3, Buffer.from([1, 2, 3]), 2);
  function add(id = randomUUID(), { owner = ownerID, kind = 'reel', location = null,
    name = null, visibility = 'public', moderation = 'approved' } = {}) {
    const input = { id, owner, kind, visibility, caption: kind === 'reel' ? 'Private original caption' : '' };
    db.prepare(`INSERT INTO memories(id, owner_id, kind, visibility, latitude, longitude, caption, place_id,
      created_at, expires_at, request_hash, published_at, moderation_status, location_name, post_location_id)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
      .run(id, owner, kind, visibility, 37.37001, -122.04001, input.caption, kind === 'poi' ? locationID : null,
        1000, 259201000, hash(input), visibility === 'public' ? 1000 : null, moderation, name, location);
    return id;
  }
  postIDs.forEach((id, index) => add(id, { name: index === 1 ? 'Keep this existing name' : null }));
  db.prepare('INSERT INTO memory_media VALUES (?, ?, ?)').run(postIDs[0], mediaID, 0);
  db.prepare('INSERT INTO comments VALUES (?, ?, ?, ?, ?, ?)')
    .run(randomUUID(), otherOwnerID, postIDs[0], null, 'Original comment', 1001);
  db.prepare('INSERT INTO archive_hidden VALUES (?, ?, ?, ?)').run(ownerID, 'reel', postIDs[0], 1002);
  db.prepare('INSERT INTO memory_clusters VALUES (?, ?, ?)')
    .run(postIDs[1], 'Immutable authored snapshot', JSON.stringify([{ id: postIDs[0], locationName: 'Do not rewrite' }]));
  db.prepare('INSERT INTO cluster_media VALUES (?, ?)').run(postIDs[1], mediaID);
  db.prepare('INSERT INTO media_upload_sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
    .run(ownerID, randomUUID(), 'video/mp4', 5, '0'.repeat(64), 2, 1, 2);
  const pendingID = db.prepare('SELECT request_id FROM media_upload_sessions').get().request_id;
  db.prepare('INSERT INTO media_upload_chunks VALUES (?, ?, ?, ?)')
    .run(ownerID, pendingID, 0, Buffer.from([5, 6]));
  db.prepare('INSERT INTO media_upload_requests VALUES (?, ?, ?, ?, ?)')
    .run(ownerID, randomUUID(), 'original-upload-hash', mediaID, 3);
  db.prepare('INSERT INTO deleted_memories VALUES (?, ?, ?)').run(randomUUID(), ownerID, 1003);
  return { db, ownerID, otherOwnerID, locationID, postIDs, add,
    options: { ownerID, postIDs, locationID } };
}
function snapshot(db) {
  const tables = db.prepare("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
    .all().map(row => row.name);
  return Object.fromEntries(tables.map(table => [table, db.prepare(`SELECT * FROM "${table}" ORDER BY rowid`).all()
    .map(row => ({ ...row }))]));
}

test('only three explicit Post identity fields change; every other row, field, BLOB and retry hash survives', async t => {
  const { db, options, postIDs, locationID, add, otherOwnerID } = await fixture(t);
  add(); add(undefined, { owner: otherOwnerID }); add(undefined, { kind: 'poi' });
  const before = snapshot(db);
  const plan = planPostLocationRepair(db, { ...options,
    expectedPostCoordinates: Object.fromEntries(postIDs.map(id => [id, { latitude: 37.37001, longitude: -122.04001 }])) });
  assert.deepEqual(snapshot(db), before, 'Planning is read-only.');
  for (const privateValue of ['Private original caption', 'Keep this existing name', 'Private place label', '37.37001']) {
    assert.equal(JSON.stringify(plan).includes(privateValue), false);
  }
  assert.deepEqual(applyPostLocationRepair(db, plan), { ok: true, repaired: 3, alreadyCorrect: 0 });
  const expected = structuredClone(before);
  expected.memories = expected.memories.map(row => postIDs.includes(row.id) ? { ...row, post_location_id: locationID } : row);
  assert.deepEqual(snapshot(db), expected);
  assert.deepEqual(applyPostLocationRepair(db, plan), { ok: true, repaired: 0, alreadyCorrect: 3 });
  assert.deepEqual(applyPostLocationRepair(db, planPostLocationRepair(db, options)),
    { ok: true, repaired: 0, alreadyCorrect: 3 });
  assert.deepEqual(snapshot(db), expected);
  assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
  assert.equal(db.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
});

test('explicit scope rejects missing, duplicate, other-owner, POI, deleted and differently identified records', async t => {
  const { db, options, postIDs, otherOwnerID, add } = await fixture(t);
  const wrongOwner = add(undefined, { owner: otherOwnerID });
  const poi = add(undefined, { kind: 'poi' });
  const identified = add(undefined, { location: randomUUID() });
  const tombstoned = add();
  db.prepare('INSERT INTO deleted_memories VALUES (?, ?, ?)').run(tombstoned, options.ownerID, 1000);
  const before = snapshot(db);
  for (const selected of [[randomUUID()], [postIDs[0], postIDs[0]], [wrongOwner], [poi], [identified], [tombstoned]]) {
    assert.throws(() => planPostLocationRepair(db, { ...options, postIDs: selected }));
  }
  for (const bad of [{}, { ...options, ownerID: undefined }, { ...options, postIDs: [] },
    { ...options, locationID: 'not-a-uuid' }]) {
    assert.throws(() => planPostLocationRepair(db, bad));
  }
  assert.deepEqual(snapshot(db), before);
});

test('stale original fields or location identity roll back earlier updates in the same transaction', async t => {
  const mutations = [
    ['caption', 'Edited after planning'], ['location_name', 'Changed name'], ['latitude', 38], ['longitude', -123],
    ['created_at', 1001], ['published_at', 1001], ['expires_at', 259201001], ['request_hash', 'f'.repeat(64)],
    ['visibility', 'private'], ['moderation_status', 'rejected'], ['post_location_id', randomUUID()],
  ];
  for (const [field, value] of mutations) {
    await t.test(field, async subtest => {
      const { db, options, postIDs } = await fixture(subtest);
      const plan = planPostLocationRepair(db, options);
      db.prepare(`UPDATE memories SET ${field} = ? WHERE id = ?`).run(value, postIDs[2]);
      const before = snapshot(db);
      assert.throws(() => applyPostLocationRepair(db, plan), /changed|different/);
      assert.deepEqual(snapshot(db), before, 'No partial repair survives.');
    });
  }
});

test('ownership change or deletion since planning rolls back the whole selection', async t => {
  for (const mutation of ['owner', 'delete', 'tombstone']) {
    await t.test(mutation, async subtest => {
      const { db, options, postIDs, otherOwnerID } = await fixture(subtest);
      const plan = planPostLocationRepair(db, options);
      if (mutation === 'owner') db.prepare('UPDATE memories SET owner_id = ? WHERE id = ?').run(otherOwnerID, postIDs[2]);
      if (mutation === 'delete') db.prepare('DELETE FROM memories WHERE id = ?').run(postIDs[2]);
      if (mutation === 'tombstone') db.prepare('INSERT INTO deleted_memories VALUES (?, ?, ?)').run(postIDs[2], options.ownerID, 2000);
      const before = snapshot(db);
      assert.throws(() => applyPostLocationRepair(db, plan), /missing|changed|tombstone/);
      assert.deepEqual(snapshot(db), before);
    });
  }
});

test('already-correct identities are accepted, but a cleared identity is stale', async t => {
  const { db, options, postIDs, locationID } = await fixture(t);
  db.prepare('UPDATE memories SET post_location_id = ? WHERE id = ?').run(locationID, postIDs[2]);
  const plan = planPostLocationRepair(db, options);
  db.prepare('UPDATE memories SET post_location_id = NULL WHERE id = ?').run(postIDs[2]);
  const before = snapshot(db);
  assert.throws(() => applyPostLocationRepair(db, plan), /changed/);
  assert.deepEqual(snapshot(db), before);
  db.prepare('UPDATE memories SET post_location_id = ? WHERE id = ?').run(locationID, postIDs[2]);
  assert.deepEqual(applyPostLocationRepair(db, plan), { ok: true, repaired: 2, alreadyCorrect: 1 });
});

test('private and rejected Posts retain their audience and moderation; metadata repair cannot publish them', async t => {
  const { db, options, add } = await fixture(t);
  const privatePost = add(undefined, { visibility: 'private' });
  const rejectedPost = add(undefined, { moderation: 'rejected' });
  const before = snapshot(db);
  const selected = [privatePost, rejectedPost];
  const plan = planPostLocationRepair(db, { ...options, postIDs: selected });
  assert.equal(applyPostLocationRepair(db, plan).repaired, 2);
  const expected = structuredClone(before);
  expected.memories = expected.memories.map(row => selected.includes(row.id) ? { ...row, post_location_id: options.locationID } : row);
  assert.deepEqual(snapshot(db), expected);
});

test('schema mismatch, altered plan metadata, and wrong expected coordinates never write', async t => {
  const { db, options, postIDs } = await fixture(t);
  const plan = planPostLocationRepair(db, options);
  const before = snapshot(db);
  for (const invalid of [undefined, { ...plan, version: 2 },
    { ...plan, posts: [...plan.posts, plan.posts[0]] },
    { ...plan, ownerID: randomUUID() },
    { ...plan, posts: plan.posts.map((post, index) => index === 2 ? { ...post, requestHash: 'f'.repeat(64) } : post) },
    { ...plan, posts: plan.posts.map((post, index) => index === 2 ? { ...post, unchangedRowHash: 'f'.repeat(64) } : post) },
    { ...plan, posts: [{ ...plan.posts[0], previousLocationID: randomUUID() }] }]) {
    assert.throws(() => applyPostLocationRepair(db, invalid));
    assert.deepEqual(snapshot(db), before);
  }
  assert.throws(() => planPostLocationRepair(db, { ...options, expectedPostCoordinates: {} }), /exactly/);
  const coordinates = Object.fromEntries(postIDs.map(id => [id, { latitude: 37.37001, longitude: -122.04001 }]));
  coordinates[postIDs[2]].latitude += 0.00001;
  assert.throws(() => planPostLocationRepair(db, { ...options, expectedPostCoordinates: coordinates }), /coordinate changed/);
  db.exec('PRAGMA user_version = 14');
  assert.throws(() => planPostLocationRepair(db, options), /schema 16/);
  assert.throws(() => applyPostLocationRepair(db, plan), /schema 16/);
  assert.deepEqual(snapshot(db), before);
});
