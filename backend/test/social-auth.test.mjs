import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomUUID, sign } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { createBackend } from '../src/server.mjs';
import { digest } from '../src/security.mjs';

const START = Date.UTC(2026, 9, 18, 12);
const IOS_ID = '100000-ios.apps.googleusercontent.com';
const SERVER_ID = '100000-server.apps.googleusercontent.com';
const GOOGLE_SECRET = 'google-test-secret-not-a-real-credential';
const WECHAT_ID = 'wx0123456789abcdef';
const WECHAT_SECRET = 'wechat-test-secret-not-a-real-credential';
const KEY_ID = 'test-google-key';
const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const wrongKey = generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey;
const jwk = { ...publicKey.export({ format: 'jwk' }), kid: KEY_ID, alg: 'RS256', use: 'sig' };

function token(changes = {}, { key = privateKey, header = {} } = {}) {
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const body = `${encode({ alg: 'RS256', kid: KEY_ID, ...header })}.${encode({
    iss: 'https://accounts.google.com', aud: SERVER_ID, azp: IOS_ID, sub: 'google-alice',
    iat: START / 1000, exp: START / 1000 + 3600, ...changes,
  })}`;
  return `${body}.${sign('RSA-SHA256', Buffer.from(body), key).toString('base64url')}`;
}

async function fixture(t, options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-social-auth-'));
  const databasePath = join(directory, 'test.sqlite');
  let time = START;
  const googleCodes = new Map();
  const wechatCodes = new Map();
  let keyRequests = 0;
  const requests = [];
  const transport = async (url, init) => {
    url = new URL(url);
    requests.push(url.origin + url.pathname);
    assert.equal(url.protocol, 'https:');
    assert.equal(init.redirect, 'error');
    assert.ok(init.signal instanceof AbortSignal);
    if (url.href === 'https://www.googleapis.com/oauth2/v3/certs') {
      keyRequests++;
      return Response.json({ keys: [jwk] }, { headers: { 'cache-control': 'public, max-age=3600' } });
    }
    if (url.href === 'https://oauth2.googleapis.com/token') {
      assert.equal(init.method, 'POST');
      const form = new URLSearchParams(init.body);
      assert.equal(form.get('client_id'), SERVER_ID);
      assert.equal(form.get('client_secret'), GOOGLE_SECRET);
      assert.equal(form.get('grant_type'), 'authorization_code');
      assert.equal(form.get('redirect_uri'), '');
      const result = googleCodes.get(form.get('code'));
      return typeof result === 'function' ? result() : Response.json(result ?? { error: 'invalid_grant' });
    }
    assert.equal(url.origin + url.pathname, 'https://api.weixin.qq.com/sns/oauth2/access_token');
    assert.equal(url.searchParams.get('appid'), WECHAT_ID);
    assert.equal(url.searchParams.get('secret'), WECHAT_SECRET);
    assert.equal(url.searchParams.get('grant_type'), 'authorization_code');
    const result = wechatCodes.get(url.searchParams.get('code'));
    return typeof result === 'function' ? result() : Response.json(result ?? { errcode: 40029, errmsg: 'invalid code' });
  };
  const config = {
    databasePath, authLimit: 300, now: () => time,
    google: { iosClientID: IOS_ID, serverClientID: SERVER_ID, clientSecret: GOOGLE_SECRET, fetch: transport },
    wechat: { appID: WECHAT_ID, appSecret: WECHAT_SECRET, fetch: transport }, ...options,
  };
  let backend = createBackend(config);
  let address = await backend.listen(0);
  t.after(async () => {
    await backend.close();
    await rm(directory, { recursive: true, force: true });
  });
  const api = {
    databasePath, requests,
    get keyRequests() { return keyRequests; },
    advance(milliseconds) { time += milliseconds; },
    async restart() {
      await backend.close();
      backend = createBackend(config);
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
    async challenge(provider) {
      const result = await api.call(`/v1/auth/${provider}/challenge`, { json: {} });
      assert.equal(result.status, 200, JSON.stringify(result.data));
      return result.data;
    },
    code(provider, body) {
      const code = `provider-code-${randomUUID()}`;
      (provider === 'google' ? googleCodes : wechatCodes).set(code, body ?? (provider === 'google'
        ? { id_token: token(), access_token: 'discard-google-access', refresh_token: 'discard-google-refresh' }
        : { openid: 'wechat-alice', unionid: 'union-alice', scope: 'snsapi_userinfo', expires_in: 7200,
          access_token: 'discard-wechat-access', refresh_token: 'discard-wechat-refresh' }));
      return code;
    },
    async exchange(provider, challenge, code) {
      return api.call(`/v1/auth/${provider}`, { json: { challengeId: challenge.challengeId, code,
        ...(provider === 'wechat' ? { state: challenge.state } : {}) } });
    },
    async signIn(provider, body) {
      return api.exchange(provider, await api.challenge(provider), api.code(provider, body));
    },
  };
  return api;
}

test('provider status is public and secret-free; missing/partial configuration fails closed', async t => {
  const api = await fixture(t, { google: { iosClientID: IOS_ID }, wechat: {} });
  const status = await api.call('/v1/auth/providers');
  assert.equal(status.status, 200);
  assert.deepEqual(status.data.providers.map(x => [x.id, x.available]), [
    ['apple', false], ['google', false], ['wechat', false],
  ]);
  assert.ok(status.data.providers.every(x => x.reason));
  assert.ok(!JSON.stringify(status.data).includes('clientSecret'));
  for (const provider of ['google', 'wechat']) {
    const result = await api.call(`/v1/auth/${provider}/challenge`, { json: {} });
    assert.equal(result.status, 503);
    assert.equal(result.data.error.code, `${provider}_not_configured`);
    const exchange = await api.call(`/v1/auth/${provider}`, { json: {
      challengeId: randomUUID(), code: 'not-real', ...(provider === 'wechat' ? { state: 'A'.repeat(43) } : {}),
    } });
    assert.equal(exchange.status, 503);
  }
  assert.equal(api.requests.length, 0);
});

for (const provider of ['google', 'wechat']) {
  test(`${provider}: reauthentication includes the current edited profile`, async t => {
    const api = await fixture(t);
    const signedIn = await api.signIn(provider);
    const photo = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1cAAAAASUVORK5CYII=', 'base64');
    const upload = await api.call('/v1/media', { method: 'POST', session: signedIn.data.token,
      body: photo, headers: { 'content-type': 'image/png' } });
    assert.equal(upload.status, 201);
    const changed = await api.call('/v1/me', { method: 'PATCH', session: signedIn.data.token,
      json: { handle: `${provider}_profile`, avatarMediaId: upload.data.id } });
    assert.equal(changed.status, 200);
    assert.deepEqual(changed.data.user, { id: signedIn.data.user.id, handle: `${provider}_profile`, avatar: upload.data });
    await api.restart();
    assert.deepEqual((await api.signIn(provider)).data.user, changed.data.user);
    assert.deepEqual((await api.call('/v1/me', { session: signedIn.data.token })).data.user, changed.data.user);
  });

  test(`${provider}: verified identity has stable normal sessions across restart and no password access`, async t => {
    const api = await fixture(t);
    const first = await api.signIn(provider);
    assert.equal(first.status, 200, JSON.stringify(first.data));
    assert.match(first.data.user.handle, /^member_[0-9a-f]{20}$/);
    const second = await api.signIn(provider);
    assert.equal(second.data.user.id, first.data.user.id);
    assert.notEqual(second.data.token, first.data.token);
    await api.restart();
    assert.equal((await api.call('/v1/me', { session: first.data.token })).status, 200);
    assert.equal((await api.signIn(provider)).data.user.id, first.data.user.id);
    assert.equal((await api.call('/v1/auth/login', { json: {
      handle: first.data.user.handle, password: 'test-password-cannot-sign-in',
    } })).status, 401);
    assert.equal((await api.call('/v1/auth/logout', { json: {}, session: first.data.token })).status, 204);
    assert.equal((await api.call('/v1/me', { session: first.data.token })).status, 401);
    assert.equal((await api.call('/v1/me', { session: second.data.token })).status, 200);
    const db = new DatabaseSync(api.databasePath, { readOnly: true });
    try {
      assert.equal(db.prepare('SELECT COUNT(*) AS n FROM users').get().n, 1);
      const stored = JSON.stringify(db.prepare('SELECT * FROM oauth_used_codes').all());
      assert.ok(!stored.includes('provider-code-'));
      assert.ok(!stored.includes('discard-'));
      assert.equal(db.prepare('SELECT password_hash FROM users').get().password_hash, '');
    } finally { db.close(); }
    assert.ok(!JSON.stringify(first.data).includes('discard-'), 'never return provider access/refresh tokens');
  });

  test(`${provider}: racing, replayed, expired, and cross-provider challenges are rejected`, async t => {
    const api = await fixture(t);
    const challenge = await api.challenge(provider);
    const code = api.code(provider);
    await api.restart();
    const concurrent = await Promise.all([api.exchange(provider, challenge, code), api.exchange(provider, challenge, code)]);
    assert.deepEqual(concurrent.map(x => x.status).sort(), [200, 401]);
    await api.restart();
    assert.equal((await api.exchange(provider, challenge, code)).status, 401);
    assert.equal((await api.exchange(provider, await api.challenge(provider), code)).status, 401,
      'reusing a code with a fresh challenge cannot create a second session');
    const other = await api.challenge(provider === 'google' ? 'wechat' : 'google');
    if (provider === 'wechat') other.state = 'A'.repeat(43);
    assert.equal((await api.exchange(provider, other, api.code(provider))).status, 401);
    const old = await api.challenge(provider);
    api.advance(5 * 60_000);
    const before = api.requests.length;
    assert.equal((await api.exchange(provider, old, api.code(provider))).status, 401);
    assert.equal(api.requests.length, before, 'invalid local challenges never call providers');
  });

  test(`${provider}: network failure consumes attempt safely and fresh sign-in can succeed`, async t => {
    const api = await fixture(t);
    const challenge = await api.challenge(provider);
    const code = api.code(provider, () => { throw new Error('transport failure with secret'); });
    const result = await api.exchange(provider, challenge, code);
    assert.equal(result.status, 503);
    assert.ok(!JSON.stringify(result.data).includes('secret'));
    assert.equal((await api.exchange(provider, challenge, code)).status, 401);
    assert.equal((await api.signIn(provider)).status, 200);
  });

  test(`${provider}: state cannot expire while provider exchange is in flight`, async t => {
    const api = await fixture(t);
    const challenge = await api.challenge(provider);
    const code = api.code(provider, () => {
      api.advance(5 * 60_000);
      return Response.json(provider === 'google' ? { id_token: token() }
        : { openid: 'alice', scope: 'snsapi_userinfo', access_token: 'token', expires_in: 7200 });
    });
    assert.equal((await api.exchange(provider, challenge, code)).status, 401);
  });
}

test('Google code result is independently verified, keys cached, and untrusted claims cannot authenticate', async t => {
  const api = await fixture(t);
  const cases = [
    [{}, { key: wrongKey }], [{ iss: 'https://attacker.example' }], [{ aud: IOS_ID }],
    [{ aud: [SERVER_ID] }], [{ azp: 'attacker.apps.googleusercontent.com' }],
    [{ exp: START / 1000 }], [{ iat: START / 1000 + 120 }], [{ nbf: START / 1000 + 120 }],
    [{ sub: '' }], [{ sub: undefined }], [{}, { header: { alg: 'none' } }],
    [{}, { header: { kid: 'unknown' } }], [{}, { header: { crit: ['b64'], b64: false } }],
  ];
  for (const [claims, options] of cases) {
    const result = await api.signIn('google', { id_token: token(claims, options) });
    assert.equal(result.status, 401, JSON.stringify({ claims, options, result }));
  }
  for (const value of ['x.y.z', 'unsigned', null]) {
    assert.equal((await api.signIn('google', { id_token: value })).status, 401);
  }
  const one = await api.signIn('google', { id_token: token({ email: 'shared@example.com' }) });
  const two = await api.signIn('google', { id_token: token({ sub: 'different-sub', email: 'shared@example.com' }) });
  assert.equal(one.status, 200);
  assert.equal(two.status, 200);
  assert.notEqual(one.data.user.id, two.data.user.id);
  assert.equal(api.keyRequests, 1);
});

test('WeChat requires exact callback state, stores only its hash, and keeps app-scoped OpenID stable', async t => {
  const api = await fixture(t);
  const challenge = await api.challenge('wechat');
  const db = new DatabaseSync(api.databasePath, { readOnly: true });
  try {
    const stored = db.prepare('SELECT * FROM oauth_auth_challenges').get();
    assert.equal(stored.state_hash, digest(challenge.state));
    assert.ok(!JSON.stringify(stored).includes(challenge.state));
  } finally { db.close(); }
  const code = api.code('wechat');
  assert.equal((await api.exchange('wechat', { ...challenge, state: 'A'.repeat(43) }, code)).status, 401);
  assert.equal(api.requests.length, 0);
  const first = await api.exchange('wechat', challenge, code);
  assert.equal(first.status, 200);
  const second = await api.signIn('wechat', { openid: 'wechat-alice', unionid: 'changed-union',
    access_token: 'valid', scope: 'snsapi_userinfo', expires_in: 7200 });
  assert.equal(second.data.user.id, first.data.user.id);
  const another = await api.signIn('wechat', { openid: 'different-openid', unionid: 'union-alice',
    access_token: 'valid', scope: 'snsapi_userinfo', expires_in: 7200 });
  assert.notEqual(another.data.user.id, first.data.user.id, 'UnionID is not an automatic account-linking authority');
  for (const body of [{ errcode: 40029, errmsg: 'invalid code' }, { openid: 'forged' },
    { openid: 'alice', access_token: 'x', scope: 'snsapi_base', expires_in: 7200 },
    { openid: 'alice', access_token: 'x', scope: 'snsapi_userinfo', expires_in: 0 }]) {
    assert.equal((await api.signIn('wechat', body)).status, 401);
  }
});

test('providers never merge identities with matching subject text or accept client identity overrides', async t => {
  const api = await fixture(t);
  const google = await api.signIn('google', { id_token: token({ sub: `${WECHAT_ID}:wechat-alice` }) });
  const wechat = await api.signIn('wechat');
  assert.notEqual(google.data.user.id, wechat.data.user.id);
  for (const provider of ['google', 'wechat']) {
    assert.equal((await api.call(`/v1/auth/${provider}/challenge`, { json: { clientID: 'attacker' } })).status, 422);
    const challenge = await api.challenge(provider);
    const base = { challengeId: challenge.challengeId, code: api.code(provider),
      ...(provider === 'wechat' ? { state: challenge.state } : {}) };
    for (const extra of [{ identityToken: token() }, { openid: 'forged' }, { userID: randomUUID() }, { clientSecret: 'override' }]) {
      assert.equal((await api.call(`/v1/auth/${provider}`, { json: { ...base, ...extra } })).status, 422);
    }
    for (const code of ['', 'x'.repeat(4097), 'with space', null]) {
      assert.equal((await api.call(`/v1/auth/${provider}`, { json: { ...base, code } })).status, 422);
    }
  }
});

test('provider rate limiting applies to challenge requests and refuses overlarge responses', async t => {
  const api = await fixture(t, { authLimit: 3 });
  assert.equal((await api.signIn('google', () => new Response('x'.repeat(70_000)))).status, 503);
  assert.equal((await api.call('/v1/auth/wechat/challenge', { json: {} })).status, 200);
  assert.equal((await api.call('/v1/auth/google/challenge', { json: {} })).status, 429);
});
