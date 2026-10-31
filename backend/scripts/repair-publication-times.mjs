import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';

const WINDOW = 72 * 60 * 60 * 1000;
const EARLIEST = Date.UTC(2000, 0, 1);
const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
class RepairError extends Error {}
function check(condition, message) { if (!condition) throw new RepairError(message); }
function schema(db) {
  check(db.prepare('PRAGMA user_version').get().user_version === 14, 'Expected schema 14.');
}
function safeTime(value) { return Number.isSafeInteger(value) && value >= EARLIEST; }

// This is a bounded reconstruction of memoryInput's normalized JSON, including
// its insertion order. A candidate is evidence only when its SHA-256 exactly
// matches the immutable original POST hash. No heuristic repairs are allowed.
function originalAudience(db, row) {
  const mediaIds = db.prepare('SELECT media_id FROM memory_media WHERE memory_id = ? ORDER BY position')
    .all(row.id).map(item => item.media_id);
  const cluster = db.prepare('SELECT title, members_json FROM memory_clusters WHERE memory_id = ?').get(row.id);
  let clusterInput;
  if (cluster) {
    let members;
    try { members = JSON.parse(cluster.members_json); } catch { return null; }
    if (!Array.isArray(members) || members.length < 1 || members.length > 50
      || members.some(member => typeof member?.id !== 'string')) return null;
    clusterInput = { title: cluster.title, memoryIds: members.map(member => member.id) };
  }
  const places = [{ place: null, placeId: null }];
  if (row.kind === 'poi') {
    places.length = 0;
    places.push({ place: null, placeId: row.place_id });
    const place = db.prepare(`SELECT places.*, place_sources.source_id FROM places
      LEFT JOIN place_sources ON place_sources.place_id = places.id WHERE places.id = ?`).get(row.place_id);
    if (place) {
      for (const withCoordinate of [false, true]) {
        for (const withSource of place.source_id ? [false, true] : [false]) {
          const directoryKinds = withCoordinate && withSource && place.directory_kind === 'airport'
            ? [false, true] : [false];
          for (const withDirectory of directoryKinds) {
            const candidate = { name: place.name, category: place.category };
            if (withCoordinate) candidate.coordinate = { latitude: place.latitude, longitude: place.longitude };
            if (withSource) candidate.sourceId = place.source_id;
            if (withDirectory) candidate.directoryKind = place.directory_kind;
            places.push({ place: candidate, placeId: null });
          }
        }
      }
    }
  }
  const audiences = new Set();
  for (const visibility of ['public', 'private']) {
    for (const place of places) {
      const input = { id: row.id, kind: row.kind, visibility,
        location: { latitude: row.latitude, longitude: row.longitude }, caption: row.caption,
        mediaIds, place: place.place, placeId: place.placeId,
        capturedAt: new Date(row.created_at).toISOString() };
      if (clusterInput) input.cluster = clusterInput;
      if (digest(input) === row.request_hash) audiences.add(visibility);
    }
  }
  return audiences.size === 1 ? [...audiences][0] : null;
}

function repairFor(row) {
  return { id: row.id, ownerID: row.owner_id, requestHash: row.request_hash,
    createdAt: row.created_at, publishedAt: row.published_at, expiresAt: row.expires_at,
    visibility: row.visibility, moderationStatus: row.moderation_status,
    repairedPublishedAt: row.created_at, repairedExpiresAt: row.created_at + WINDOW };
}

export function auditPublicationTimes(db, { now = Date.now(), ownerID } = {}) {
  schema(db);
  check(safeTime(now), 'Provide a valid audit time.');
  check(ownerID === undefined || (typeof ownerID === 'string' && ownerID.length > 0), 'Invalid owner scope.');
  const counts = { scanned: 0, notPublicApproved: 0, alreadyCorrect: 0,
    invalidOrMissingTime: 0, originallyPrivate: 0, unproven: 0, repairable: 0 };
  const rows = db.prepare(`SELECT * FROM memories ${ownerID === undefined ? '' : 'WHERE owner_id = ?'} ORDER BY id`)
    .all(...(ownerID === undefined ? [] : [ownerID]));
  const repairs = [];
  for (const row of rows) {
    counts.scanned += 1;
    if (row.visibility !== 'public' || row.moderation_status !== 'approved') { counts.notPublicApproved += 1; continue; }
    if (!safeTime(row.created_at) || !safeTime(row.published_at) || !safeTime(row.expires_at)
      || row.created_at > now || row.published_at > now || row.created_at > row.published_at
      || !Number.isSafeInteger(row.created_at + WINDOW)) { counts.invalidOrMissingTime += 1; continue; }
    if (row.created_at === row.published_at) { counts.alreadyCorrect += 1; continue; }
    const audience = originalAudience(db, row);
    if (audience === 'private') { counts.originallyPrivate += 1; continue; }
    if (audience !== 'public') { counts.unproven += 1; continue; }
    repairs.push(repairFor(row));
    counts.repairable += 1;
  }
  // The plan never carries captions, place names, coordinates or media bytes.
  return { version: 1, auditedAt: now, counts, repairs };
}

export function applyPublicationTimeRepairs(db, plan) {
  schema(db);
  check(plan?.version === 1 && safeTime(plan.auditedAt) && Array.isArray(plan.repairs), 'Invalid repair plan.');
  check(new Set(plan.repairs.map(item => item.id)).size === plan.repairs.length, 'Duplicate repair record.');
  db.exec('BEGIN IMMEDIATE');
  try {
    const read = db.prepare('SELECT * FROM memories WHERE id = ?');
    const update = db.prepare(`UPDATE memories SET published_at = ?, expires_at = ?
      WHERE id = ? AND owner_id = ? AND request_hash = ? AND created_at = ?
      AND published_at = ? AND expires_at = ? AND visibility = ? AND moderation_status = ?`);
    for (const expected of plan.repairs) {
      const row = read.get(expected.id);
      check(row && row.visibility === 'public' && row.moderation_status === 'approved'
        && safeTime(row.created_at) && safeTime(row.published_at) && safeTime(row.expires_at)
        && row.created_at < row.published_at && row.published_at <= plan.auditedAt,
      'A repair record changed; audit again.');
      const actual = repairFor(row);
      check(Object.keys(actual).every(key => expected[key] === actual[key]), 'A repair record changed; audit again.');
      // Re-prove inside the write transaction, so even a hand-edited/stale plan
      // cannot substitute a different original publication intent.
      check(originalAudience(db, row) === 'public', 'Original publication could not be verified; audit again.');
      const result = update.run(expected.repairedPublishedAt, expected.repairedExpiresAt,
        expected.id, expected.ownerID, expected.requestHash, expected.createdAt,
        expected.publishedAt, expected.expiresAt, expected.visibility, expected.moderationStatus);
      check(result.changes === 1, 'A repair record changed; audit again.');
    }
    db.exec('COMMIT');
    return { ok: true, repaired: plan.repairs.length };
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  }
}

// CLI deliberately audits only. A caller must separately arrange an encrypted,
// restore-verified backup and explicitly apply the plan through the module API.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let db;
  try {
    const [path, ownerID, ...extra] = process.argv.slice(2);
    check(path && extra.length === 0, 'Usage: repair-publication-times.mjs database [owner-id]');
    db = new DatabaseSync(path, { readOnly: true, timeout: 5000 });
    db.exec('PRAGMA query_only = ON; BEGIN;');
    const result = auditPublicationTimes(db, { ownerID });
    console.log(JSON.stringify({ ok: true, auditedAt: result.auditedAt, counts: result.counts }));
  } catch (error) {
    console.error(JSON.stringify({ ok: false,
      error: error instanceof RepairError ? error.message : 'Unable to audit publication times.' }));
    process.exitCode = 1;
  } finally { db?.close(); }
}
