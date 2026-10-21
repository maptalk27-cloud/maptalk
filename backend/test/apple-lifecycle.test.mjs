import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomBytes, randomUUID, sign, verify } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createBackend } from '../src/server.mjs';
import { openDatabase } from '../src/database.mjs';

const CLIENT_ID = 'com.chengsi.maptalk';
const START = Date.UTC(2026, 9, 18, 12);
const appleKey = generateKeyPairSync('rsa', { modulusLength: 2048 });
const clientKey = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const jwk = { ...appleKey.publicKey.export({ format: 'jwk' }), kid: 'test-apple', use: 'sig', alg: 'RS256' };
const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
function identity(nonce, sub = 'apple-alice') {
  const content = `${encode({ alg: 'RS256', kid: 'test-apple' })}.${encode({ iss: 'https://appleid.apple.com',
    aud: CLIENT_ID, sub, nonce, iat: START / 1000, exp: START / 1000 + 3600 })}`;
  return `${content}.${sign('RSA-SHA256', Buffer.from(content), appleKey.privateKey).toString('base64url')}`;
}

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-apple-lifecycle-'));
  const databasePath = join(directory, 'test.sqlite');
  const tokens = new Map();
  const refreshToken = `private-refresh-${randomUUID()}`;
  let failRevoke = false;
  let revocations = 0;
  const config = { databasePath, now: () => START, authLimit: 100, apple: {
    clientID: CLIENT_ID, teamID: 'TEAM123456', keyID: 'KEY1234567',
    privateKey: clientKey.privateKey.export({ type: 'pkcs8', format: 'pem' }),
    encryptionKey: randomBytes(32).toString('base64'),
    fetchKeys: async () => Response.json({ keys: [jwk] }),
    fetchTokens: async (url, init) => {
      assert.equal(init.redirect, 'error');
      assert.equal(init.method, 'POST');
      const body = new URLSearchParams(init.body);
      assert.equal(body.get('client_id'), CLIENT_ID);
      const secret = body.get('client_secret').split('.');
      const header = JSON.parse(Buffer.from(secret[0], 'base64url'));
      const claims = JSON.parse(Buffer.from(secret[1], 'base64url'));
      assert.equal(header.alg, 'ES256');
      assert.equal(header.kid, 'KEY1234567');
      assert.deepEqual(claims, { iss: 'TEAM123456', iat: START / 1000, exp: START / 1000 + 300,
        aud: 'https://appleid.apple.com', sub: CLIENT_ID });
      assert.ok(verify('sha256', Buffer.from(secret.slice(0, 2).join('.')),
        { key: clientKey.publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(secret[2], 'base64url')));
      if (url === 'https://appleid.apple.com/auth/token') {
        assert.equal(body.get('grant_type'), 'authorization_code');
        assert.equal(body.has('redirect_uri'), false, 'native Apple code exchange has no redirect_uri');
        return Response.json({ id_token: tokens.get(body.get('code')), refresh_token: refreshToken });
      }
      assert.equal(url, 'https://appleid.apple.com/auth/revoke');
      assert.equal(body.get('token'), refreshToken);
      assert.equal(body.get('token_type_hint'), 'refresh_token');
      revocations++;
      return failRevoke ? Response.json({ error: 'temporarily_unavailable' }, { status: 503 }) : new Response('', { status: 200 });
    },
  } };
  let backend = createBackend(config);
  let address = await backend.listen(0);
  t.after(async () => { await backend.close(); await rm(directory, { recursive: true, force: true }); });
  const api = {
    databasePath, refreshToken,
    get revocations() { return revocations; },
    failRevocation(value) { failRevoke = value; },
    db(work) { const db = openDatabase(databasePath); try { return work(db); } finally { db.close(); } },
    async restart() { await backend.close(); backend = createBackend(config); address = await backend.listen(0); },
    async call(path, { json, token, method = json ? 'POST' : 'GET' } = {}) {
      const response = await fetch(`${address.url}${path}`, { method,
        headers: { ...(json ? { 'content-type': 'application/json' } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}) },
        body: json ? JSON.stringify(json) : undefined });
      return { status: response.status, data: response.status === 204 ? null : await response.json() };
    },
    async signIn({ returnedSub, returnedNonce, includeCode = true } = {}) {
      const challenge = (await api.call('/v1/auth/apple/challenge', { json: {} })).data;
      const authorizationCode = randomUUID();
      tokens.set(authorizationCode, identity(returnedNonce ?? challenge.nonce, returnedSub));
      return api.call('/v1/auth/apple', { json: { challengeId: challenge.challengeId,
        identityToken: identity(challenge.nonce), ...(includeCode ? { authorizationCode } : {}) } });
    },
  };
  return api;
}

test('Apple lifecycle requires code, verifies returned subject/nonce and stores only encrypted refresh token', async t => {
  const api = await fixture(t);
  assert.equal((await api.signIn({ includeCode: false })).status, 422);
  assert.equal((await api.signIn({ returnedSub: 'different-user' })).status, 401);
  assert.equal((await api.signIn({ returnedNonce: 'different-nonce' })).status, 401);
  const signedIn = await api.signIn();
  assert.equal(signedIn.status, 200, JSON.stringify(signedIn.data));
  assert.ok(!JSON.stringify(signedIn.data).includes(api.refreshToken));
  api.db(db => {
    const row = db.prepare('SELECT * FROM apple_refresh_tokens').get();
    assert.match(row.encrypted_token, /^v1\./);
    assert.ok(!JSON.stringify(row).includes(api.refreshToken));
    assert.equal(row.user_id, signedIn.data.user.id);
  });
});

test('Apple deletion revokes upstream before deleting local data and provider failure is safely retryable', async t => {
  const api = await fixture(t);
  const signedIn = (await api.signIn()).data;
  const memory = await api.call('/v1/memories', { token: signedIn.token, json: { id: randomUUID(), kind: 'reel',
    visibility: 'private', caption: 'Private memory', location: { latitude: 37, longitude: -122 } } });
  assert.equal(memory.status, 201);
  api.failRevocation(true);
  const failed = await api.call('/v1/me', { method: 'DELETE', token: signedIn.token });
  assert.equal(failed.status, 503);
  assert.ok(!JSON.stringify(failed).includes(api.refreshToken));
  assert.equal((await api.call('/v1/me', { token: signedIn.token })).status, 200, 'failed provider revoke does not permanently lock account');
  api.db(db => assert.equal(db.prepare('SELECT COUNT(*) AS n FROM memories').get().n, 1));
  await api.restart();
  api.failRevocation(false);
  assert.equal((await api.call('/v1/me', { method: 'DELETE', token: signedIn.token })).status, 204);
  assert.equal(api.revocations, 2);
  assert.equal((await api.call('/v1/me', { token: signedIn.token })).status, 401);
  api.db(db => {
    for (const table of ['users', 'sessions', 'memories', 'auth_identities', 'apple_refresh_tokens']) {
      assert.equal(db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n, 0);
    }
  });
});

test('Apple encrypted refresh-token tampering fails closed without deleting account', async t => {
  const api = await fixture(t);
  const signedIn = (await api.signIn()).data;
  api.db(db => db.prepare("UPDATE apple_refresh_tokens SET encrypted_token = 'v1.invalid.invalid.invalid'").run());
  assert.equal((await api.call('/v1/me', { method: 'DELETE', token: signedIn.token })).status, 503);
  assert.equal(api.revocations, 0);
  assert.equal((await api.call('/v1/me', { token: signedIn.token })).status, 200);
});

test('an interrupted Apple account deletion resumes safely after process restart', async t => {
  const api = await fixture(t);
  const signedIn = (await api.signIn()).data;
  api.db(db => db.prepare('UPDATE users SET deletion_started_at = ? WHERE id = ?').run(START, signedIn.user.id));
  await api.restart();
  assert.equal(api.revocations, 1);
  assert.equal((await api.call('/v1/me', { token: signedIn.token })).status, 401);
  api.db(db => assert.equal(db.prepare('SELECT COUNT(*) AS n FROM users').get().n, 0));
});

test('beta refuses Apple-only startup without complete account-revocation configuration', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-apple-beta-config-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  assert.throws(() => createBackend({ databasePath: join(directory, 'test.sqlite'),
    deployment: { mode: 'beta', publicOrigin: 'https://beta.maptalk.example' }, apple: { clientID: CLIENT_ID } }), /account deletion/);
});
