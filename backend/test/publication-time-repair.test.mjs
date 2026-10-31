import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { openDatabase } from '../src/database.mjs';
import { auditPublicationTimes, applyPublicationTimeRepairs } from '../scripts/repair-publication-times.mjs';

const NOW = Date.UTC(2026, 9, 30), CREATED = NOW - 4 * 86_400_000, PUBLISHED = NOW - 1000;
const WINDOW = 72 * 60 * 60 * 1000;
const hash = input => createHash('sha256').update(JSON.stringify(input)).digest('hex');
async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-publication-time-repair-'));
  const path = join(directory, 'test.sqlite'), db = openDatabase(path);
  t.after(async () => { db.close(); await rm(directory, { recursive: true, force: true }); });
  db.exec(`INSERT INTO users(id, handle, password_hash, created_at) VALUES ('owner', 'alice', 'not-a-real-password-hash', 1);
    INSERT INTO users(id, handle, password_hash, created_at) VALUES ('other-owner', 'bob', 'not-a-real-password-hash', 1);
    INSERT INTO places VALUES ('place', 'Sensitive Airport Café', 'airport', 47.45, -122.31, 'airport');
    INSERT INTO place_sources VALUES ('directory-source', 'place');
    INSERT INTO media VALUES ('photo-a', 'owner', 'image/jpeg', 3, X'010203', 2);
    INSERT INTO media VALUES ('photo-b', 'owner', 'image/jpeg', 3, X'040506', 3);`);
  function add(id, options = {}) {
    const { originalAudience = 'public', visibility = 'public', owner = 'owner', kind = 'reel',
      created = CREATED, published = PUBLISHED, media = [], place = null,
      placeId = null, captured = true, cluster, caption = kind === 'reel' ? 'Private caption' : '',
      moderation = 'approved' } = options;
    const input = { id, kind, visibility: originalAudience, location: { latitude: 47.4501, longitude: -122.31 },
      caption, mediaIds: media, place, placeId };
    if (captured) input.capturedAt = new Date(created).toISOString();
    if (cluster) input.cluster = { title: cluster.title, memoryIds: cluster.members.map(member => member.id) };
    db.prepare(`INSERT INTO memories(id, owner_id, kind, visibility, latitude, longitude, caption, place_id,
      created_at, expires_at, request_hash, published_at, moderation_status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
      .run(id, owner, kind, visibility, input.location.latitude, input.location.longitude, caption,
        kind === 'poi' ? 'place' : null, created, (published ?? created) + WINDOW, hash(input), published, moderation);
    media.forEach((mediaID, position) => db.prepare('INSERT INTO memory_media VALUES (?, ?, ?)').run(id, mediaID, position));
    if (cluster) db.prepare('INSERT INTO memory_clusters VALUES (?, ?, ?)')
      .run(id, cluster.title, JSON.stringify(cluster.members));
    return input;
  }
  return { db, path, add };
}
function row(db, id) { return { ...db.prepare('SELECT * FROM memories WHERE id = ?').get(id) }; }

test('proven queued public publication moves to original tap, preserving all other data and retry hash', async t => {
  const { db, add } = await fixture(t);
  const input = add('queued', { media: ['photo-b', 'photo-a'] });
  const before = row(db, 'queued');
  const mediaBefore = db.prepare('SELECT * FROM memory_media ORDER BY position').all();
  const plan = auditPublicationTimes(db, { now: NOW });
  assert.equal(plan.counts.repairable, 1);
  for (const secret of ['Private caption', 'Sensitive Airport Café', '47.4501', 'photo-a']) {
    assert.equal(JSON.stringify(plan).includes(secret), false);
  }
  assert.deepEqual(applyPublicationTimeRepairs(db, plan), { ok: true, repaired: 1 });
  assert.deepEqual(row(db, 'queued'), { ...before, published_at: CREATED, expires_at: CREATED + WINDOW });
  assert.deepEqual(db.prepare('SELECT * FROM memory_media ORDER BY position').all(), mediaBefore);
  assert.equal(row(db, 'queued').request_hash, hash(input), 'Original POST retry still matches exactly');
  const repeatedAudit = auditPublicationTimes(db, { now: NOW });
  assert.equal(repeatedAudit.counts.alreadyCorrect, 1);
  assert.deepEqual(applyPublicationTimeRepairs(db, repeatedAudit), { ok: true, repaired: 0 });
  assert.throws(() => applyPublicationTimeRepairs(db, plan), /changed/);
});

test('private to public, currently private, unapproved, unknown and invalid timestamps stay untouched', async t => {
  const { db, add } = await fixture(t);
  add('promoted', { originalAudience: 'private' });
  add('withdrawn', { visibility: 'private' });
  add('pending', { moderation: 'pending' });
  add('missing', { published: null });
  add('same', { published: CREATED });
  add('backwards', { published: CREATED - 1 });
  add('future', { published: NOW + 1 });
  add('legacy-no-capture', { captured: false });
  add('edited');
  db.prepare('UPDATE memories SET caption = ? WHERE id = ?').run('Later edited caption', 'edited');
  const before = db.prepare('SELECT * FROM memories ORDER BY id').all();
  const plan = auditPublicationTimes(db, { now: NOW });
  assert.equal(plan.counts.originallyPrivate, 1);
  assert.equal(plan.counts.unproven, 2);
  assert.equal(plan.counts.notPublicApproved, 2);
  assert.equal(plan.counts.invalidOrMissingTime, 3);
  assert.equal(plan.repairs.length, 0);
  applyPublicationTimeRepairs(db, plan);
  assert.deepEqual(db.prepare('SELECT * FROM memories ORDER BY id').all(), before);
});

test('bounded place reconstruction verifies existing ID, custom place, directory shapes and media order', async t => {
  const { db, add } = await fixture(t);
  add('existing', { kind: 'poi', placeId: 'place', media: ['photo-a'] });
  add('custom', { kind: 'poi', place: { name: 'Sensitive Airport Café', category: 'airport' } });
  add('directory', { kind: 'poi', place: { name: 'Sensitive Airport Café', category: 'airport',
    coordinate: { latitude: 47.45, longitude: -122.31 }, sourceId: 'directory-source', directoryKind: 'airport' } });
  add('old-directory', { kind: 'poi', place: { name: 'Sensitive Airport Café', category: 'airport',
    coordinate: { latitude: 47.45, longitude: -122.31 }, sourceId: 'directory-source' } });
  add('different-directory-name', { kind: 'poi', place: { name: 'Original directory name', category: 'airport',
    coordinate: { latitude: 47.45, longitude: -122.31 }, sourceId: 'directory-source' } });
  add('ordered', { media: ['photo-b', 'photo-a'] });
  const plan = auditPublicationTimes(db, { now: NOW });
  assert.deepEqual(plan.repairs.map(item => item.id), ['custom', 'directory', 'existing', 'old-directory', 'ordered']);
  assert.equal(plan.counts.unproven, 1);
  assert.equal(applyPublicationTimeRepairs(db, plan).repaired, 5);
  assert.equal(row(db, 'different-directory-name').published_at, PUBLISHED);
});

test('cluster parent can be proven while immutable member snapshots remain unchanged', async t => {
  const { db, add } = await fixture(t);
  const members = [{ id: 'original-member', caption: 'Frozen snapshot', publishedAt: '2026-10-01T00:00:00.000Z' }];
  add('cluster-parent', { cluster: { title: 'Private cluster name', members } });
  const before = db.prepare('SELECT * FROM memory_clusters').all();
  assert.equal(applyPublicationTimeRepairs(db, auditPublicationTimes(db, { now: NOW })).repaired, 1);
  assert.deepEqual(db.prepare('SELECT * FROM memory_clusters').all(), before);
});

test('any changed guarded field rolls back the entire plan', async t => {
  for (const mutation of ["owner_id = 'other-owner'", "request_hash = 'changed'", 'created_at = created_at + 1',
    'published_at = published_at + 1', 'expires_at = expires_at + 1', "visibility = 'private'",
    "moderation_status = 'rejected'", "caption = 'edited after audit'"]) {
    await t.test(mutation.split(' = ')[0], async subtest => {
      const { db, add } = await fixture(subtest);
      add('a-first'); add('z-second');
      const plan = auditPublicationTimes(db, { now: NOW });
      db.exec(`UPDATE memories SET ${mutation} WHERE id = 'z-second'`);
      const before = db.prepare('SELECT * FROM memories ORDER BY id').all();
      assert.throws(() => applyPublicationTimeRepairs(db, plan), /changed|verified/);
      assert.deepEqual(db.prepare('SELECT * FROM memories ORDER BY id').all(), before);
    });
  }
});

test('altered repair targets, duplicate plans and owner scope cannot widen a repair', async t => {
  const { db, add } = await fixture(t);
  add('mine'); add('theirs', { owner: 'other-owner' });
  const plan = auditPublicationTimes(db, { now: NOW, ownerID: 'owner' });
  assert.deepEqual(plan.repairs.map(item => item.id), ['mine']);
  const changed = structuredClone(plan);
  changed.repairs[0].repairedPublishedAt += 1;
  assert.throws(() => applyPublicationTimeRepairs(db, changed), /changed/);
  assert.throws(() => applyPublicationTimeRepairs(db, { ...plan, repairs: [...plan.repairs, ...plan.repairs] }), /Duplicate/);
  assert.equal(applyPublicationTimeRepairs(db, plan).repaired, 1);
  assert.equal(row(db, 'theirs').published_at, PUBLISHED);
});

test('CLI is read-only and emits only counts, never candidate details', async t => {
  const { db, path, add } = await fixture(t);
  add('private-record-id');
  const before = row(db, 'private-record-id');
  const script = fileURLToPath(new URL('../scripts/repair-publication-times.mjs', import.meta.url));
  const cli = spawnSync(process.execPath, [script, path, 'owner'], { encoding: 'utf8' });
  assert.equal(cli.status, 0, cli.stderr);
  const output = JSON.parse(cli.stdout);
  assert.equal(output.ok, true);
  assert.equal(output.counts.repairable, 1);
  assert.equal(output.repairs, undefined);
  for (const privateValue of ['private-record-id', 'owner', 'Private caption', 'Sensitive Airport Café', '47.4501']) {
    assert.equal(cli.stdout.includes(privateValue), false);
  }
  assert.deepEqual(row(db, 'private-record-id'), before);
});
