import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { createBackend } from '../src/server.mjs';
import { digest } from '../src/security.mjs';

const CLIENT_ID = 'com.chengsi.maptalk';
const KEY_ID = 'test-apple-signing-key';
const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const wrongKey = generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey;
const jwk = { ...publicKey.export({ format: 'jwk' }), kid: KEY_ID, alg: 'RS256', use: 'sig' };
const START = Date.UTC(2026, 9, 17, 12);

function token(nonce, changes = {}, { key = privateKey, header = {} } = {}) {
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const claims = {
    iss: 'https://appleid.apple.com', aud: CLIENT_ID, sub: 'apple-subject-alice',
    iat: Math.floor(START / 1000), exp: Math.floor(START / 1000) + 3600,
    nonce, ...changes,
  };
  const content = `${encode({ alg: 'RS256', kid: KEY_ID, ...header })}.${encode(claims)}`;
  return `${content}.${sign('RSA-SHA256', Buffer.from(content), key).toString('base64url')}`;
}

async function fixture(t, options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-apple-auth-'));
  const databasePath = join(directory, 'test.sqlite');
  let time = START;
  let keyRequests = 0;
  let unavailable = false;
  const configuration = {
    databasePath, now: () => time, authLimit: 100,
    apple: {
      clientID: CLIENT_ID,
      fetchKeys: async (url, init) => {
        keyRequests++;
        assert.equal(url, 'https://appleid.apple.com/auth/keys');
        assert.equal(init.redirect, 'error');
        if (unavailable) throw new Error('Network unavailable');
        return Response.json({ keys: [jwk] });
      },
    }, ...options,
  };
  let backend = createBackend(configuration);
  let address = await backend.listen(0);
  t.after(async () => {
    await backend.close();
    await rm(directory, { recursive: true, force: true });
  });
  const api = {
    databasePath,
    get keyRequests() { return keyRequests; },
    advance(milliseconds) { time += milliseconds; },
    setUnavailable(value) { unavailable = value; },
    async restart() {
      await backend.close();
      backend = createBackend(configuration);
      address = await backend.listen(0);
    },
    async call(path, { json, session, method = json ? 'POST' : 'GET', body, headers = {} } = {}) {
      const response = await fetch(`${address.url}${path}`, {
        method,
        headers: { ...(json ? { 'content-type': 'application/json' } : {}),
          ...(session ? { authorization: `Bearer ${session}` } : {}), ...headers },
        body: json ? JSON.stringify(json) : body,
      });
      return { status: response.status, data: response.status === 204 ? null : await response.json() };
    },
    async challenge() {
      const result = await api.call('/v1/auth/apple/challenge', { json: {} });
      assert.equal(result.status, 200, JSON.stringify(result.data));
      return result.data;
    },
    async signIn(changes = {}) {
      const challenge = await api.challenge();
      return api.call('/v1/auth/apple', { json: {
        challengeId: challenge.challengeId, identityToken: token(challenge.nonce, changes),
      } });
    },
  };
  return api;
}

test('Apple sign-in is unavailable until the exact client identifier is configured', async t => {
  const api = await fixture(t, { apple: {} });
  const result = await api.call('/v1/auth/apple/challenge', { json: {} });
  assert.equal(result.status, 503);
  assert.equal(result.data.error.code, 'apple_not_configured');
  assert.equal(api.keyRequests, 0);
});

test('a verified Apple subject creates one account, persists, and uses normal sessions', async t => {
  const api = await fixture(t);
  const first = await api.signIn();
  assert.equal(first.status, 200, JSON.stringify(first.data));
  assert.match(first.data.user.handle, /^member_[a-f0-9]{20}$/);
  const second = await api.signIn({ email: 'changed-private-relay@privaterelay.appleid.com' });
  assert.equal(second.status, 200);
  assert.equal(first.data.user.id, second.data.user.id);
  assert.notEqual(first.data.token, second.data.token);
  assert.equal(api.keyRequests, 1, 'sign-ins reuse verified public keys, not another network fetch');
  const me = await api.call('/v1/me', { session: first.data.token });
  assert.equal(me.status, 200);
  assert.equal(me.data.user.id, first.data.user.id);
  await api.restart();
  assert.equal((await api.call('/v1/me', { session: first.data.token })).status, 200);
  const third = await api.signIn();
  assert.equal(third.data.user.id, first.data.user.id);
  assert.equal((await api.call('/v1/auth/logout', { json: {}, session: first.data.token })).status, 204);
  assert.equal((await api.call('/v1/me', { session: first.data.token })).status, 401);
  assert.equal((await api.call('/v1/me', { session: third.data.token })).status, 200);
});

test('Apple reauthentication returns the edited handle and avatar without changing identity', async t => {
  const api = await fixture(t);
  const signedIn = await api.signIn();
  const photo = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1cAAAAASUVORK5CYII=', 'base64');
  const upload = await api.call('/v1/media', { method: 'POST', session: signedIn.data.token,
    body: photo, headers: { 'content-type': 'image/png' } });
  assert.equal(upload.status, 201);
  const updated = await api.call('/v1/me', { method: 'PATCH', session: signedIn.data.token,
    json: { handle: 'Apple_Profile', avatarMediaId: upload.data.id } });
  assert.equal(updated.status, 200);
  assert.equal(updated.data.user.handle, 'apple_profile');
  assert.equal(updated.data.user.id, signedIn.data.user.id);
  assert.deepEqual(updated.data.user.avatar, upload.data);
  await api.restart();
  assert.deepEqual((await api.signIn()).data.user, updated.data.user);
  assert.deepEqual((await api.call('/v1/me', { session: signedIn.data.token })).data.user, updated.data.user);
});

test('distinct Apple subjects never merge by email, and Apple accounts cannot use password login', async t => {
  const api = await fixture(t);
  const alice = await api.signIn({ email: 'shared@example.com' });
  const bob = await api.signIn({ email: 'shared@example.com', sub: 'apple-subject-bob' });
  assert.equal(alice.status, 200);
  assert.equal(bob.status, 200);
  assert.notEqual(alice.data.user.id, bob.data.user.id);
  const login = await api.call('/v1/auth/login', { json: {
    handle: alice.data.user.handle, password: 'any-test-password-42',
  } });
  assert.equal(login.status, 401);
});

test('challenges persist only a nonce hash, work after restart, and cannot be replayed', async t => {
  const api = await fixture(t);
  const challenge = await api.challenge();
  const db = new DatabaseSync(api.databasePath, { readOnly: true });
  try {
    const stored = db.prepare('SELECT * FROM apple_auth_challenges').get();
    assert.equal(stored.nonce_hash, digest(challenge.nonce));
    assert.ok(!JSON.stringify(stored).includes(challenge.nonce));
  } finally { db.close(); }
  await api.restart();
  const json = { challengeId: challenge.challengeId, identityToken: token(challenge.nonce) };
  const results = await Promise.all([
    api.call('/v1/auth/apple', { json }), api.call('/v1/auth/apple', { json }),
  ]);
  assert.deepEqual(results.map(result => result.status).sort(), [200, 401]);
  await api.restart();
  const replay = await api.call('/v1/auth/apple', { json });
  assert.equal(replay.status, 401);
  assert.equal(replay.data.error.code, 'apple_challenge_expired');
  const fresh = await api.challenge();
  assert.equal((await api.call('/v1/auth/apple', { json: { ...json, challengeId: fresh.challengeId } })).status, 401);
});

test('expired Apple challenges fail even with an otherwise valid signature', async t => {
  const api = await fixture(t);
  const challenge = await api.challenge();
  api.advance(5 * 60 * 1000);
  const result = await api.call('/v1/auth/apple', { json: {
    challengeId: challenge.challengeId, identityToken: token(challenge.nonce),
  } });
  assert.equal(result.status, 401);
  assert.equal(api.keyRequests, 0);
});

test('Apple verification rejects forged, expired, misdirected, malformed and nonce-free identities', async t => {
  const api = await fixture(t);
  const invalid = [
    ['wrong signature', {}, { key: wrongKey }],
    ['wrong issuer', { iss: 'https://attacker.example' }],
    ['wrong audience', { aud: 'another.app' }],
    ['audience array', { aud: [CLIENT_ID, 'another.app'] }],
    ['expired', { exp: START / 1000 }],
    ['future issued at', { iat: START / 1000 + 120 }],
    ['future not before', { nbf: START / 1000 + 120 }],
    ['missing subject', { sub: undefined }],
    ['missing nonce', { nonce: undefined }],
    ['wrong nonce', { nonce: 'attacker-nonce' }],
    ['unsigned algorithm', {}, { header: { alg: 'none' } }],
    ['wrong key identifier', {}, { header: { kid: 'attacker-key' } }],
    ['unsupported critical headers', {}, { header: { crit: ['b64'], b64: false } }],
  ];
  for (const [name, changes, options] of invalid) {
    await t.test(name, async () => {
      const challenge = await api.challenge();
      const result = await api.call('/v1/auth/apple', { json: {
        challengeId: challenge.challengeId, identityToken: token(challenge.nonce, changes, options),
      } });
      assert.equal(result.status, 401, JSON.stringify(result.data));
      assert.equal(result.data.error.code, 'invalid_apple_identity');
    });
  }
  const challenge = await api.challenge();
  for (const identityToken of ['not.a.jwt', 'eyJhbGciOiJub25lIn0.e30.', '{}', 'a.b.c.d']) {
    assert.equal((await api.call('/v1/auth/apple', { json: {
      challengeId: challenge.challengeId, identityToken,
    } })).status, 401);
  }
  const db = new DatabaseSync(api.databasePath, { readOnly: true });
  try {
    assert.equal(db.prepare('SELECT COUNT(*) AS count FROM users').get().count, 0);
    assert.equal(db.prepare('SELECT COUNT(*) AS count FROM sessions').get().count, 0);
  } finally { db.close(); }
});

test('Apple public-key network failure is retryable without accepting or consuming the identity', async t => {
  const api = await fixture(t);
  const challenge = await api.challenge();
  const json = { challengeId: challenge.challengeId, identityToken: token(challenge.nonce) };
  api.setUnavailable(true);
  const failed = await api.call('/v1/auth/apple', { json });
  assert.equal(failed.status, 503);
  assert.equal(failed.data.error.code, 'apple_unavailable');
  api.setUnavailable(false);
  const retry = await api.call('/v1/auth/apple', { json });
  assert.equal(retry.status, 200);
});

test('Apple authentication shares rate limiting and rejects client-supplied trust/configuration fields', async t => {
  const api = await fixture(t, { authLimit: 2 });
  assert.equal((await api.call('/v1/auth/apple/challenge', { json: { clientID: 'attacker.app' } })).status, 422);
  await api.challenge();
  const limited = await api.call('/v1/auth/apple/challenge', { json: {} });
  assert.equal(limited.status, 429);
});
