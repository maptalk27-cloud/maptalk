import { createHash } from 'node:crypto';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SHA256 = /^[0-9a-f]{64}$/;
function check(condition, message) { if (!condition) throw new Error(message); }
function schema(db) {
  check(db.prepare('PRAGMA user_version').get().user_version === 16, 'Expected schema 16.');
}
function scope({ ownerID, postIDs, locationID } = {}) {
  check(typeof ownerID === 'string' && UUID.test(ownerID), 'Provide an explicit owner UUID.');
  check(typeof locationID === 'string' && UUID.test(locationID), 'Provide a canonical location UUID.');
  check(Array.isArray(postIDs) && postIDs.length > 0
    && postIDs.every(id => typeof id === 'string' && UUID.test(id)), 'Provide explicit Post UUIDs.');
  check(new Set(postIDs).size === postIDs.length, 'Duplicate Post UUID.');
}
function unchangedRowHash(row) {
  // Include every original memory column, including coordinates, name, caption,
  // audience, timestamps and immutable retry hash. Only the repair target is
  // omitted, allowing the same plan to be safely retried after it succeeds.
  const unchanged = Object.fromEntries(Object.entries(row).filter(([name]) => name !== 'post_location_id'));
  return createHash('sha256').update(JSON.stringify(unchanged)).digest('hex');
}
function eligible(db, row, ownerID, locationID) {
  check(row && row.owner_id === ownerID && row.kind === 'reel' && row.place_id === null,
    'A selected Post is missing, changed owner, or is not a Post.');
  check(!db.prepare('SELECT 1 FROM deleted_memories WHERE id = ?').get(row.id),
    'A selected Post has a deletion tombstone.');
  check(row.post_location_id === null || row.post_location_id === locationID,
    'A selected Post already has a different location identity.');
}

// No CLI write mode. The caller must arrange an encrypted, restore-verified
// backup, validate the explicit selection and keep the plan on the trusted host.
// This module never migrates, chooses nearby Posts, changes names, or republishes.
export function planPostLocationRepair(db, options) {
  schema(db);
  scope(options);
  const { ownerID, postIDs, locationID, expectedPostCoordinates } = options;
  if (expectedPostCoordinates !== undefined) {
    check(expectedPostCoordinates && !Array.isArray(expectedPostCoordinates)
      && Object.keys(expectedPostCoordinates).length === postIDs.length
      && postIDs.every(id => Object.hasOwn(expectedPostCoordinates, id)),
    'Expected coordinates must cover exactly the selected Posts.');
  }
  const read = db.prepare('SELECT * FROM memories WHERE id = ?');
  const posts = postIDs.map(id => {
    const row = read.get(id);
    eligible(db, row, ownerID, locationID);
    if (expectedPostCoordinates !== undefined) {
      const expected = expectedPostCoordinates[id];
      check(expected && Number.isFinite(expected.latitude) && Number.isFinite(expected.longitude)
        && expected.latitude === row.latitude && expected.longitude === row.longitude,
      'A selected Post coordinate changed.');
    }
    return { id, previousLocationID: row.post_location_id, requestHash: row.request_hash,
      unchangedRowHash: unchangedRowHash(row) };
  });
  // No captions, place names, coordinates, media or credentials in the plan.
  return { version: 1, ownerID, locationID, posts };
}

export function applyPostLocationRepair(db, plan) {
  check(plan?.version === 1 && Array.isArray(plan.posts), 'Invalid location repair plan.');
  scope({ ...plan, postIDs: plan.posts.map(post => post?.id) });
  for (const post of plan.posts) {
    check((post.previousLocationID === null || post.previousLocationID === plan.locationID)
      && typeof post.requestHash === 'string' && SHA256.test(post.requestHash)
      && typeof post.unchangedRowHash === 'string' && SHA256.test(post.unchangedRowHash),
    'Invalid expected Post metadata.');
  }
  db.exec('BEGIN IMMEDIATE');
  try {
    schema(db);
    const read = db.prepare('SELECT * FROM memories WHERE id = ?');
    const update = db.prepare(`UPDATE memories SET post_location_id = ?
      WHERE id = ? AND owner_id = ? AND kind = 'reel' AND request_hash = ? AND post_location_id IS NULL`);
    let repaired = 0, alreadyCorrect = 0;
    for (const expected of plan.posts) {
      const row = read.get(expected.id);
      eligible(db, row, plan.ownerID, plan.locationID);
      check(row.request_hash === expected.requestHash && unchangedRowHash(row) === expected.unchangedRowHash
        && (row.post_location_id === expected.previousLocationID || row.post_location_id === plan.locationID),
      'A selected Post changed; audit again.');
      if (row.post_location_id === plan.locationID) { alreadyCorrect += 1; continue; }
      const result = update.run(plan.locationID, expected.id, plan.ownerID, expected.requestHash);
      check(result.changes === 1, 'A selected Post changed; audit again.');
      const saved = read.get(expected.id);
      check(saved?.post_location_id === plan.locationID && unchangedRowHash(saved) === expected.unchangedRowHash,
        'A repair changed unexpected Post metadata.');
      repaired += 1;
    }
    db.exec('COMMIT');
    return { ok: true, repaired, alreadyCorrect };
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  }
}
