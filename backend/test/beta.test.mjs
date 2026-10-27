import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomUUID, sign } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { request as httpRequest } from 'node:http';
import sharp from 'sharp';
import { createBackend } from '../src/server.mjs';
import { openDatabase } from '../src/database.mjs';
import { createConcurrentGate, deploymentConfiguration, issueInvite, moderateMemory, revokeBetaAccess } from '../src/beta.mjs';
import { readConfig } from '../src/runtime-config.mjs';
import { videoFixture } from './helpers/video.mjs';
import { digest } from '../src/security.mjs';
import { UPLOAD_CHUNK_SIZE } from '../src/resumable-uploads.mjs';

const SERVER_ID = '100000-beta.apps.googleusercontent.com';
const IOS_ID = '100000-ios.apps.googleusercontent.com';
const ORIGIN = 'https://beta.maptalk.example';
const START = Date.UTC(2026, 9, 18, 12);
const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = { ...publicKey.export({ format: 'jwk' }), kid: 'beta-test', alg: 'RS256', use: 'sig' };
const encode = data => Buffer.from(JSON.stringify(data)).toString('base64url');
function identity(subject) {
  const content = `${encode({ alg: 'RS256', kid: 'beta-test' })}.${encode({ iss: 'https://accounts.google.com',
    aud: SERVER_ID, azp: IOS_ID, sub: subject, iat: START / 1000, exp: START / 1000 + 3600 })}`;
  return `${content}.${sign('RSA-SHA256', Buffer.from(content), privateKey).toString('base64url')}`;
}

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-beta-'));
  const databasePath = join(directory, 'beta.sqlite');
  let time = START;
  const codes = new Map();
  const configuration = { databasePath, authLimit: 1000, now: () => time,
    deployment: { mode: 'beta', publicOrigin: ORIGIN },
    google: { iosClientID: IOS_ID, serverClientID: SERVER_ID, clientSecret: 'fake-secret-tests-only',
      fetch: async (url, init) => {
        if (url === 'https://www.googleapis.com/oauth2/v3/certs') return Response.json({ keys: [jwk] });
        assert.equal(url, 'https://oauth2.googleapis.com/token');
        return Response.json({ id_token: identity(codes.get(new URLSearchParams(init.body).get('code'))) });
      } },
  };
  let backend = createBackend(configuration);
  let address = await backend.listen(0);
  t.after(async () => { await backend.close(); await rm(directory, { recursive: true, force: true }); });
  const api = {
    databasePath,
    get url() { return address.url; },
    advance(ms) { time += ms; },
    admin(work) { const db = openDatabase(databasePath); try { return work(db); } finally { db.close(); } },
    async restart() { await backend.close(); backend = createBackend(configuration); address = await backend.listen(0); },
    async call(path, { method = 'GET', json, token, body, headers = {} } = {}) {
      return new Promise((resolve, reject) => {
        const req = httpRequest(`${address.url}${path}`, { method,
          headers: { host: 'beta.maptalk.example', ...(token ? { authorization: `Bearer ${token}` } : {}),
            ...(json !== undefined ? { 'content-type': 'application/json' } : {}), ...headers } }, response => {
          const parts = [];
          response.on('data', part => parts.push(part));
          response.on('end', () => {
            const data = Buffer.concat(parts);
            resolve({ status: response.statusCode, data: data.length && response.headers['content-type']?.includes('json') ? JSON.parse(data) : data,
              headers: response.headers });
          });
          response.on('error', reject);
        });
        req.on('error', reject);
        req.end(json !== undefined ? JSON.stringify(json) : body);
      });
    },
    async account(subject, invited = true) {
      const challenge = await api.call('/v1/auth/google/challenge', { method: 'POST', json: {} });
      assert.equal(challenge.status, 200, JSON.stringify(challenge.data));
      const code = randomUUID(); codes.set(code, subject);
      const result = await api.call('/v1/auth/google', { method: 'POST', json: { challengeId: challenge.data.challengeId, code } });
      assert.equal(result.status, 200, JSON.stringify(result.data));
      if (invited) {
        const invitation = api.admin(db => issueInvite(db, { now: time }));
        assert.equal((await api.call('/v1/beta/redeem', { method: 'POST', token: result.data.token, json: { code: invitation.code } })).status, 204);
      }
      return result.data;
    },
    async post(account, extra = {}) {
      const result = await api.call('/v1/memories', { method: 'POST', token: account.token, json: {
        id: randomUUID(), kind: 'reel', visibility: 'public', caption: 'Test beta post',
        location: { latitude: 37, longitude: -122 }, ...extra,
      } });
      assert.equal(result.status, 201, JSON.stringify(result.data));
      return result.data;
    },
  };
  return api;
}

test('hosted deployment requires opt-in, HTTPS canonical origin, persistent path and backup configuration', () => {
  for (const publicOrigin of ['http://beta.example.com', 'https://beta.example.com/', 'https://beta.example.com/path',
    'https://user:pass@beta.example.com', 'https://127.0.0.1', 'https://example.local']) {
    assert.throws(() => deploymentConfiguration({ mode: 'beta', publicOrigin }));
  }
  assert.throws(() => deploymentConfiguration({ bind: '0.0.0.0' }));
  assert.throws(() => readConfig({ NODE_ENV: 'production' }));
  assert.throws(() => readConfig({ MAPTALK_MODE: 'beta', MAPTALK_PUBLIC_ORIGIN: ORIGIN }));
  assert.throws(() => readConfig({ MAPTALK_MODE: 'beta', MAPTALK_PUBLIC_ORIGIN: ORIGIN, MAPTALK_DATABASE: '/tmp/example.db' }));
  assert.equal(readConfig({}).backend.deployment.mode, 'local');
});

test('beta comment threads enforce invitations, revoked author visibility and owner access on reads and retries', async t => {
  const api = await fixture(t);
  const owner = await api.account('comments-owner');
  const author = await api.account('comments-author');
  const viewer = await api.account('comments-viewer');
  const uninvited = await api.account('comments-uninvited', false);
  const post = await api.post(owner);
  const path = `/v1/memories/${post.id}/comments`;
  const payload = { id: randomUUID(), text: 'A comment, not a check-in' };
  for (const method of ['GET', 'POST']) {
    assert.equal((await api.call(path, { method, token: uninvited.token,
      ...(method === 'POST' ? { json: payload } : {}) })).status, 403);
  }
  assert.equal((await api.call(path, { method: 'POST', token: author.token, json: payload })).status, 201);
  assert.equal((await api.call(path, { token: viewer.token })).data.items.length, 1);
  api.admin(db => revokeBetaAccess(db, { userID: author.user.id, now: START }));
  assert.equal((await api.call(path, { token: viewer.token })).data.items.length, 0);
  assert.equal((await api.call(path, { token: author.token })).status, 403);
  assert.equal((await api.call(path, { method: 'POST', token: author.token, json: payload })).status, 403);
  api.admin(db => revokeBetaAccess(db, { userID: owner.user.id, now: START }));
  assert.equal((await api.call(path, { token: viewer.token })).status, 404);
  assert.equal((await api.call(path, { method: 'POST', token: viewer.token,
    json: { id: randomUUID(), text: 'No longer accessible' } })).status, 404);
});

test('beta media retries return the original normalized photo, not a second asset, and respect revoked access', async t => {
  const api = await fixture(t);
  const account = await api.account('offline-upload');
  const photo = await sharp({ create: { width: 32, height: 24, channels: 3, background: 'red' } }).png().toBuffer();
  const options = { method: 'POST', token: account.token, body: photo,
    headers: { 'content-type': 'image/png', 'idempotency-key': randomUUID() } };
  const first = await api.call('/v1/media', options);
  assert.equal(first.status, 201, JSON.stringify(first.data));
  assert.equal(first.data.mimeType, 'image/jpeg');
  await api.restart();
  const again = await api.call('/v1/media', options);
  assert.equal(again.status, 200, JSON.stringify(again.data));
  assert.deepEqual(again.data, first.data);
  api.admin(db => {
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM media').get().n, 1);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM media_upload_requests').get().n, 1);
    db.prepare("UPDATE beta_members SET status = 'revoked' WHERE user_id = ?").run(account.user.id);
  });
  assert.equal((await api.call('/v1/media', options)).status, 403);
});

test('beta video chunks have an independent bounded transfer budget and never block cancellation, deletion or profile changes', async t => {
  const api = await fixture(t), owner = await api.account('transfer-budget'), other = await api.account('transfer-independent');
  const post = await api.post(owner);
  const bytes = Buffer.alloc(20 * 1024 * 1024, 5), chunk = bytes.subarray(0, UPLOAD_CHUNK_SIZE);
  const metadata = { mimeType: 'video/mp4', byteCount: bytes.length, sha256: digest(bytes) };
  const keys = [randomUUID(), randomUUID()];
  const begin = (key, token = owner.token) => api.call(`/v1/media/uploads/${key}`, { method: 'PUT', token, json: metadata });
  for (const key of keys) {
    assert.equal((await begin(key)).status, 200);
    for (let offset = 0; offset < bytes.length; offset += UPLOAD_CHUNK_SIZE) {
      const result = await api.call(`/v1/media/uploads/${key}`, { method: 'PATCH', token: owner.token, body: chunk,
        headers: { 'content-type': 'application/octet-stream', 'upload-offset': String(offset) } });
      assert.equal(result.status, 200, JSON.stringify(result.data));
      assert.equal(result.data.receivedBytes, offset + chunk.length);
    }
  }
  // Two PUTs + 80 PATCHes, all inside the same fixed clock minute.
  assert.equal((await api.call('/v1/me', { method: 'PATCH', token: owner.token, json: { handle: 'profile_during_upload' } })).status, 200);
  for (let i = 82; i < 120; i++) assert.equal((await begin(keys[1])).status, 200);
  const limited = await begin(keys[1]);
  assert.equal(limited.status, 429); assert.equal(limited.data.error.code, 'upload_rate_limited');
  assert.equal(limited.headers['retry-after'], '60');
  assert.equal((await api.call(`/v1/media/uploads/${keys[1]}`, { token: owner.token })).data.receivedBytes, bytes.length);
  assert.equal((await begin(keys[1], other.token)).status, 200, 'one uploader cannot exhaust another account budget');
  assert.equal((await api.call(`/v1/media/by-upload-key/${keys[0]}`, { method: 'DELETE', token: owner.token })).status, 204);
  assert.equal((await api.call(`/v1/memories/${post.id}`, { method: 'DELETE', token: owner.token })).status, 204);
  assert.equal((await api.call('/v1/me', { method: 'PATCH', token: owner.token, json: { handle: 'profile_after_limit' } })).status, 200);
  api.advance(60_000);
  assert.equal((await begin(keys[1])).status, 200, 'transfer limiter recovers after its own window');
  for (let i = 1; i < 121; i++) await begin(keys[1]);
  assert.equal((await api.call('/v1/me', { method: 'DELETE', token: owner.token })).status, 204, 'account deletion remains available while transfer-limited');
  api.admin(db => {
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM media_upload_sessions WHERE owner_id = ?').get(owner.user.id).n, 0);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM media_upload_chunks WHERE owner_id = ?').get(owner.user.id).n, 0);
  });
});

test('beta user-mutation protections remain independent from video transfer allowance', async t => {
  const api = await fixture(t), owner = await api.account('mutation-budget');
  // Invitation redemption already used one mutation in this minute.
  for (let i = 1; i < 60; i++) {
    assert.equal((await api.call('/v1/me', { method: 'PATCH', token: owner.token, json: { handle: 'mutation_preserved' } })).status, 200);
  }
  const blocked = await api.call('/v1/me', { method: 'PATCH', token: owner.token, json: { handle: 'still_limited' } });
  assert.equal(blocked.status, 429); assert.equal(blocked.data.error.code, 'rate_limited');
  const bytes = Buffer.from('independent'), key = randomUUID();
  assert.equal((await api.call(`/v1/media/uploads/${key}`, { method: 'PUT', token: owner.token,
    json: { mimeType: 'video/mp4', byteCount: bytes.length, sha256: digest(bytes) } })).status, 200);
});

test('beta videos use the same invitation, moderation and blocking boundaries for full and ranged playback', async t => {
  const api = await fixture(t);
  const owner = await api.account('video-owner');
  const viewer = await api.account('video-viewer');
  const pending = await api.account('video-pending', false);
  const video = await videoFixture({ rotation: 90 });
  const upload = { method: 'POST', token: owner.token, body: video,
    headers: { 'content-type': 'video/mp4', 'idempotency-key': randomUUID() } };
  const media = await api.call('/v1/media', upload);
  assert.equal(media.status, 201, JSON.stringify(media.data));
  const mediaPath = media.data.path;
  const post = await api.post(owner, { mediaIds: [media.data.id] });
  for (const method of ['GET', 'HEAD']) {
    assert.equal((await api.call(mediaPath, { method, token: viewer.token, headers: { range: 'bytes=0-1' } })).status, 206);
    assert.equal((await api.call(mediaPath, { method, token: pending.token, headers: { range: 'bytes=0-1' } })).status, 403);
  }
  api.admin(db => moderateMemory(db, post.id, 'reject'));
  assert.equal((await api.call(mediaPath, { token: viewer.token, headers: { range: 'bytes=0-1' } })).status, 404);
  assert.equal((await api.call(mediaPath, { token: owner.token, headers: { range: 'bytes=0-1' } })).status, 206);
  api.admin(db => moderateMemory(db, post.id, 'approve'));
  assert.equal((await api.call('/v1/blocks', { method: 'POST', token: viewer.token, json: { userId: owner.user.id } })).status, 204);
  assert.equal((await api.call(mediaPath, { token: viewer.token, headers: { range: 'bytes=0-1' } })).status, 404);
  api.admin(db => revokeBetaAccess(db, { userID: owner.user.id, now: START + 1 }));
  assert.equal((await api.call('/v1/media', upload)).status, 403);
  assert.equal((await api.call(mediaPath, { token: owner.token })).status, 403);
});

test('hosted rejects forged Host/Origin, password routes, and promoting a nonempty local DB', async t => {
  const api = await fixture(t);
  assert.equal((await api.call('/health')).status, 200);
  assert.equal((await api.call('/health', { headers: { host: 'attacker.example' } })).status, 403);
  assert.equal((await api.call('/health', { headers: { origin: 'https://attacker.example' } })).status, 403);
  assert.equal((await api.call('/health', { headers: { origin: ORIGIN } })).status, 200);
  for (const route of ['register', 'login']) assert.equal((await api.call(`/v1/auth/${route}`, {
    method: 'POST', json: { handle: 'test', password: 'test-password-123' },
  })).status, 403);
  assert.throws(() => createBackend({ databasePath: api.databasePath }), /beta database/);
  const localPath = join(api.databasePath, '..', 'local.sqlite');
  const db = openDatabase(localPath);
  db.prepare('INSERT INTO users(id,handle,password_hash,created_at) VALUES (?,?,?,?)').run(randomUUID(), 'local', 'hash', 1);
  db.close();
  assert.throws(() => createBackend({ databasePath: localPath, deployment: { mode: 'beta', publicOrigin: ORIGIN } }), /new empty database/);
});

test('invitations bind verified accounts once, persist only hashes, expire, and revoked membership cannot rejoin', async t => {
  const api = await fixture(t);
  const alice = await api.account('alice', false);
  const bob = await api.account('bob', false);
  assert.deepEqual((await api.call('/v1/beta/access', { token: alice.token })).data, { required: true, status: 'pending' });
  for (const path of ['/v1/feed', '/v1/me/memories', '/v1/map/memories?west=-180&east=180&south=-90&north=90']) {
    assert.equal((await api.call(path, { token: alice.token })).data.error.code, 'beta_access_required');
  }
  const invite = api.admin(db => issueInvite(db, { now: START }));
  api.admin(db => assert.ok(!JSON.stringify(db.prepare('SELECT * FROM beta_invites').all()).includes(invite.code)));
  const redeem = account => api.call('/v1/beta/redeem', { method: 'POST', token: account.token, json: { code: invite.code } });
  const raced = await Promise.all([redeem(alice), redeem(bob)]);
  assert.deepEqual(raced.map(x => x.status).sort(), [204, 422]);
  const winner = raced[0].status === 204 ? alice : bob;
  assert.equal((await redeem(winner)).status, 204);
  await api.restart();
  assert.equal((await api.call('/v1/feed', { token: winner.token })).status, 200);
  api.admin(db => revokeBetaAccess(db, { inviteID: invite.id, now: START + 1 }));
  assert.equal((await api.call('/v1/feed', { token: winner.token })).data.error.code, 'beta_access_revoked');
  assert.equal((await api.call('/v1/beta/access', { token: winner.token })).data.status, 'revoked');
  const fresh = api.admin(db => issueInvite(db, { now: START }));
  assert.equal((await api.call('/v1/beta/redeem', { method: 'POST', token: winner.token, json: { code: fresh.code } })).status, 403);
  assert.equal((await api.call('/v1/me', { token: winner.token })).status, 200);
  const other = winner === alice ? bob : alice;
  const expired = api.admin(db => issueInvite(db, { now: START - 4_000_000, hours: 1 }));
  assert.equal((await api.call('/v1/beta/redeem', { method: 'POST', token: other.token, json: { code: expired.code } })).status, 422);
});

test('public beta posts are immediately visible; rejection, blocking and revocation still hide cross-user surfaces', async t => {
  const api = await fixture(t);
  const alice = await api.account('alice');
  const bob = await api.account('bob');
  const photo = await sharp({ create: { width: 12, height: 12, channels: 3, background: 'red' } }).png().toBuffer();
  const upload = await api.call('/v1/media', { method: 'POST', token: alice.token, body: photo, headers: { 'content-type': 'image/png' } });
  assert.equal(upload.status, 201, JSON.stringify(upload.data));
  assert.equal(upload.data.mimeType, 'image/jpeg');
  const post = await api.post(alice, { mediaIds: [upload.data.id] });
  assert.equal(post.moderationStatus, 'approved');
  assert.equal((await api.call(`/v1/memories/${post.id}`, { token: alice.token })).status, 200);
  const hiddenPaths = [`/v1/memories/${post.id}`, upload.data.path];
  for (const path of hiddenPaths) assert.equal((await api.call(path, { token: bob.token })).status, 200);
  assert.equal((await api.call('/v1/feed', { token: bob.token })).data.items.length, 1);
  for (const path of ['/v1/map/memories?west=-180&east=180&south=-90&north=90', `/v1/users/${alice.user.id}/memories`]) {
    assert.deepEqual((await api.call(path, { token: bob.token })).data.items.map(item => item.id), [post.id]);
  }
  assert.equal((await api.call(upload.data.path, { token: bob.token })).status, 200);
  assert.equal((await api.call('/v1/reports', { method: 'POST', token: bob.token, json: { memoryId: post.id, reason: 'unsafe content' } })).status, 204);
  assert.equal((await api.call('/v1/blocks', { method: 'POST', token: bob.token, json: { userId: alice.user.id } })).status, 204);
  for (const path of [...hiddenPaths, `/v1/users/${alice.user.id}`, `/v1/users/${alice.user.id}/memories`]) {
    assert.equal((await api.call(path, { token: bob.token })).status, 404, path);
  }
  assert.equal((await api.call(`/v1/users/${bob.user.id}`, { token: alice.token })).status, 404, 'block works both ways');
  for (const path of ['/v1/feed', '/v1/map/memories?west=-180&east=180&south=-90&north=90']) {
    assert.equal((await api.call(path, { token: bob.token })).data.items.length, 0);
  }
  assert.equal((await api.call(`/v1/blocks/${alice.user.id}`, { method: 'DELETE', token: bob.token })).status, 204);
  assert.equal((await api.call('/v1/feed', { token: bob.token })).data.items.length, 1);
  api.admin(db => moderateMemory(db, post.id, 'reject'));
  assert.equal((await api.call(`/v1/memories/${post.id}`, { token: bob.token })).status, 404);
  api.admin(db => moderateMemory(db, post.id, 'approve'));
  api.admin(db => revokeBetaAccess(db, { userID: alice.user.id }));
  assert.equal((await api.call(upload.data.path, { token: bob.token })).status, 404);
  assert.equal((await api.call('/v1/feed', { token: bob.token })).data.items.length, 0);
});

test('private beta posts remain private until shared and rejected posts stay rejected through visibility changes and restart', async t => {
  const api = await fixture(t);
  const alice = await api.account('alice');
  const bob = await api.account('bob');
  const post = await api.post(alice, { visibility: 'private' });
  assert.equal(post.moderationStatus, 'approved');
  assert.equal(post.publishedAt, null);
  assert.equal((await api.call(`/v1/memories/${post.id}`, { token: bob.token })).status, 404);
  assert.equal((await api.call('/v1/feed', { token: bob.token })).data.items.length, 0);
  const published = await api.call(`/v1/memories/${post.id}`, { method: 'PATCH', token: alice.token, json: { visibility: 'public' } });
  assert.equal(published.status, 200);
  assert.equal(published.data.moderationStatus, 'approved');
  assert.equal((await api.call('/v1/feed', { token: bob.token })).data.items[0].id, post.id);
  api.admin(db => moderateMemory(db, post.id, 'reject'));
  for (const visibility of ['private', 'public']) {
    const changed = await api.call(`/v1/memories/${post.id}`, { method: 'PATCH', token: alice.token, json: { visibility } });
    assert.equal(changed.data.moderationStatus, 'rejected');
  }
  await api.restart();
  assert.equal((await api.call(`/v1/memories/${post.id}`, { token: bob.token })).status, 404);
  assert.equal((await api.call('/v1/feed', { token: bob.token })).data.items.length, 0);
});

test('beta avatar photos use normalized uploads and preserve active membership, block, deletion and owner boundaries', async t => {
  const api = await fixture(t);
  const alice = await api.account('alice');
  const bob = await api.account('bob');
  const pending = await api.account('pending', false);
  const photo = await sharp({ create: { width: 20, height: 12, channels: 3, background: 'blue' } }).png().toBuffer();
  const uploaded = await api.call('/v1/media', { method: 'POST', token: alice.token, body: photo,
    headers: { 'content-type': 'image/png' } });
  assert.equal(uploaded.status, 201);
  assert.equal(uploaded.data.mimeType, 'image/jpeg');
  const avatar = uploaded.data;
  const changed = await api.call('/v1/me', { method: 'PATCH', token: alice.token,
    json: { handle: 'Alice_Profile', avatarMediaId: avatar.id } });
  assert.equal(changed.status, 200, JSON.stringify(changed.data));
  assert.deepEqual(changed.data.user, { id: alice.user.id, handle: 'alice_profile', avatar });
  assert.equal((await api.call(avatar.path)).status, 401);
  assert.equal((await api.call(avatar.path, { token: bob.token })).status, 200, 'no public post is required for an explicitly selected avatar');
  assert.equal((await api.call(avatar.path, { token: pending.token })).status, 403);
  assert.equal((await api.call('/v1/me', { method: 'PATCH', token: pending.token, json: { handle: 'not_active' } })).status, 403);
  const returned = await api.account('alice', false);
  assert.deepEqual(returned.user, changed.data.user, 'verified social sign-in preserves current profile');
  const post = await api.post(alice);
  assert.deepEqual(post.owner, changed.data.user);
  for (const [blocker, blocked] of [[alice, bob], [bob, alice]]) {
    assert.equal((await api.call('/v1/blocks', { method: 'POST', token: blocker.token, json: { userId: blocked.user.id } })).status, 204);
    assert.equal((await api.call(avatar.path, { token: bob.token })).status, 404);
    assert.equal((await api.call(`/v1/users/${alice.user.id}`, { token: bob.token })).status, 404);
    assert.equal((await api.call(`/v1/blocks/${blocked.user.id}`, { method: 'DELETE', token: blocker.token })).status, 204);
  }
  api.admin(db => db.prepare('UPDATE users SET deletion_started_at = ? WHERE id = ?').run(START, alice.user.id));
  assert.equal((await api.call(avatar.path, { token: bob.token })).status, 404);
  api.admin(db => db.prepare('UPDATE users SET deletion_started_at = NULL WHERE id = ?').run(alice.user.id));
  api.admin(db => revokeBetaAccess(db, { userID: bob.user.id }));
  assert.equal((await api.call(avatar.path, { token: bob.token })).status, 403, 'revoked viewers cannot download avatars');
  api.admin(db => db.prepare("UPDATE beta_members SET status = 'active' WHERE user_id = ?").run(bob.user.id));
  api.admin(db => revokeBetaAccess(db, { userID: alice.user.id }));
  assert.equal((await api.call(avatar.path, { token: bob.token })).status, 404, 'revoked owners cannot expose avatars');
  assert.equal((await api.call('/v1/me', { method: 'PATCH', token: alice.token, json: { handle: 'revoked_name' } })).status, 403);
  assert.equal((await api.call('/v1/me', { method: 'DELETE', token: alice.token })).status, 204);
  assert.equal((await api.call(avatar.path, { token: bob.token })).status, 404);
  api.admin(db => {
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM user_profiles WHERE user_id = ?').get(alice.user.id).n, 0);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM media WHERE owner_id = ?').get(alice.user.id).n, 0);
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
  });
});

test('account deletion clears owned data/sessions and cannot recycle a redeemed invitation', async t => {
  const api = await fixture(t);
  const alice = await api.account('alice');
  const bob = await api.account('bob');
  const post = await api.post(alice);
  api.admin(db => moderateMemory(db, post.id, 'approve'));
  await api.call('/v1/reports', { method: 'POST', token: bob.token, json: { memoryId: post.id, reason: 'test' } });
  await api.call('/v1/blocks', { method: 'POST', token: alice.token, json: { userId: bob.user.id } });
  assert.equal((await api.call('/v1/me', { method: 'DELETE', token: alice.token })).status, 204);
  assert.equal((await api.call('/v1/me', { token: alice.token })).status, 401);
  assert.equal((await api.call(`/v1/memories/${post.id}`, { token: bob.token })).status, 404);
  api.admin(db => {
    for (const table of ['memories', 'media', 'user_blocks', 'content_reports']) assert.equal(db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n, 0);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM auth_identities WHERE user_id = ?').get(alice.user.id).n, 0);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM sessions WHERE user_id = ?').get(alice.user.id).n, 0);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM beta_invites WHERE redeemed_at IS NOT NULL').get().n, 2);
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
  });
  const recreated = await api.account('alice', false);
  assert.notEqual(recreated.user.id, alice.user.id);
  assert.equal((await api.call('/v1/beta/access', { token: recreated.token })).data.status, 'pending');
});

test('resource gates have exact bounds and release at most once for finish plus close', () => {
  for (const limit of [2, 8]) {
    const acquire = createConcurrentGate(limit);
    const releases = Array.from({ length: limit }, () => acquire());
    assert.ok(releases.every(release => typeof release === 'function'));
    assert.equal(acquire(), null);
    releases[0](); releases[0]();
    const one = acquire();
    assert.equal(typeof one, 'function');
    assert.equal(acquire(), null, 'duplicate socket events cannot release a second slot');
    one(); releases.forEach(release => release());
    assert.ok(Array.from({ length: limit }, () => acquire()).every(Boolean));
    assert.equal(acquire(), null);
  }
});

test('slow media uploads are refused at capacity and closing media sockets releases resources', async t => {
  const api = await fixture(t);
  const account = await api.account('media-limits');
  const heldUploads = [];
  try {
    for (let i = 0; i < 2; i++) {
      const request = httpRequest(`${api.url}/v1/media`, { method: 'POST', headers: {
        host: 'beta.maptalk.example', authorization: `Bearer ${account.token}`, 'content-type': 'image/jpeg',
        'content-length': 10 * 1024 * 1024,
      } });
      request.on('error', () => {});
      request.write(Buffer.alloc(1024));
      heldUploads.push(request);
    }
    await new Promise(resolve => setTimeout(resolve, 30));
    const refused = await api.call('/v1/media', { method: 'POST', token: account.token,
      headers: { 'content-type': 'image/jpeg' }, body: Buffer.from([0xff, 0xd8, 0xff, 0x00]) });
    assert.equal(refused.status, 429);
    assert.equal(refused.data.error.code, 'upload_busy');
  } finally { heldUploads.forEach(request => request.destroy()); }

  const mediaID = randomUUID();
  // Controlled storage fixture specifically exercises socket backpressure, not
  // photo decoding (the separate processing tests cover those bytes).
  api.admin(db => db.prepare('INSERT INTO media(id,owner_id,mime_type,byte_count,bytes,created_at) VALUES (?,?,?,?,?,?)')
    .run(mediaID, account.user.id, 'image/jpeg', 4 * 1024 * 1024, Buffer.alloc(4 * 1024 * 1024), START));
  const heldDownloads = [];
  try {
    for (let i = 0; i < 8; i++) {
      await new Promise((resolve, reject) => {
        const request = httpRequest(`${api.url}/v1/media/${mediaID}`, { headers: {
          host: 'beta.maptalk.example', authorization: `Bearer ${account.token}`,
        } }, response => {
          assert.equal(response.statusCode, 200);
          response.pause();
          heldDownloads.push({ request, response });
          resolve();
        });
        request.on('error', reject);
        request.end();
      });
    }
    const refused = await api.call(`/v1/media/${mediaID}`, { token: account.token });
    // macOS may have accepted a complete 4MiB response into its TCP buffers
    // before this ninth request. Then that server-side slot is correctly free.
    // Exact active-slot admission is independently tested above, without relying
    // on the machine's dynamic socket-buffer tuning.
    assert.ok([200, 429].includes(refused.status));
    if (refused.status === 429) assert.equal(refused.data.error.code, 'media_busy');
  } finally { heldDownloads.forEach(({ request, response }) => { response.destroy(); request.destroy(); }); }
  await new Promise(resolve => setTimeout(resolve, 30));
  assert.equal((await api.call(`/v1/media/${mediaID}`, { token: account.token })).status, 200, 'closing connections releases slots');
});
