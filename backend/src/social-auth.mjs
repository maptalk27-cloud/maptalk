import { createPublicKey, randomBytes, randomUUID, verify } from 'node:crypto';
import { digest, issueSession } from './security.mjs';
import { transaction } from './database.mjs';
import { userJSON } from './user-profile.mjs';

const GOOGLE_TOKEN_URL = 'https://oauth2.googleapis.com/token';
const GOOGLE_KEYS_URL = 'https://www.googleapis.com/oauth2/v3/certs';
const WECHAT_TOKEN_URL = 'https://api.weixin.qq.com/sns/oauth2/access_token';
const CHALLENGE_LIFETIME = 5 * 60_000;
const CODE_RETENTION = 24 * 60 * 60_000;
const LABELS = { google: 'Google', wechat: 'WeChat' };

export class SocialAuthError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function invalid(provider) {
  return new SocialAuthError(401, `invalid_${provider}_identity`,
    `${LABELS[provider]} sign-in could not be verified. Please start again.`);
}

function expired(provider) {
  return new SocialAuthError(401, `${provider}_challenge_expired`, 'This sign-in attempt expired. Please start again.');
}

function unavailable(provider) {
  return new SocialAuthError(503, `${provider}_unavailable`,
    `Cannot verify ${LABELS[provider]} sign-in right now. Please start again.`);
}

// The only injectable seam is HTTPS transport. There is no development identity
// override: tests still exchange codes and verify real RSA signatures.
async function providerJSON(provider, transport, url, init = {}) {
  try {
    const response = await transport(url, { ...init, signal: AbortSignal.timeout(8000), redirect: 'error' });
    if (Number(response.headers.get('content-length')) > 65_536) throw unavailable(provider);
    let bytes = 0;
    const parts = [];
    for await (const chunk of response.body ?? []) {
      bytes += chunk.length;
      if (bytes > 65_536) throw unavailable(provider);
      parts.push(Buffer.from(chunk));
    }
    const body = JSON.parse(Buffer.concat(parts).toString('utf8'));
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw unavailable(provider);
    return { response, body };
  } catch (error) {
    if (error instanceof SocialAuthError) throw error;
    // Do not include provider errors/URLs: WeChat's official URL contains a secret.
    throw unavailable(provider);
  }
}

function jwtPart(value) {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw invalid('google');
  try {
    const result = JSON.parse(Buffer.from(value, 'base64url').toString('utf8'));
    if (!result || typeof result !== 'object' || Array.isArray(result)) throw new Error();
    return result;
  } catch { throw invalid('google'); }
}

function googleVerifier({ serverClientID, iosClientID, now, transport }) {
  let keys = new Map();
  let expiresAt = 0;
  let fetchedAt = -Infinity;
  let refresh;
  async function refreshKeys() {
    if (refresh) return refresh;
    refresh = (async () => {
      const { response, body } = await providerJSON('google', transport, GOOGLE_KEYS_URL);
      if (!response.ok || !Array.isArray(body.keys) || !body.keys.length || body.keys.length > 20) {
        throw unavailable('google');
      }
      const next = new Map();
      try {
        for (const jwk of body.keys) {
          if (jwk.kty !== 'RSA' || jwk.alg !== 'RS256' || jwk.use !== 'sig'
            || typeof jwk.kid !== 'string' || !jwk.kid.length || jwk.kid.length > 128) continue;
          const key = createPublicKey({ key: jwk, format: 'jwk' });
          if (key.asymmetricKeyDetails?.modulusLength < 2048 || next.has(jwk.kid)) throw new Error();
          next.set(jwk.kid, key);
        }
        if (!next.size) throw new Error();
      } catch { throw unavailable('google'); }
      const maxAge = /(?:^|,)\s*max-age=(\d+)/i.exec(response.headers.get('cache-control') ?? '')?.[1];
      keys = next;
      fetchedAt = now();
      expiresAt = fetchedAt + Math.min(21_600, Math.max(60, Number(maxAge ?? 3600))) * 1000;
    })();
    try { await refresh; } finally { refresh = undefined; }
  }

  return async identityToken => {
    if (typeof identityToken !== 'string' || identityToken.length > 16_384) throw invalid('google');
    const parts = identityToken.split('.');
    if (parts.length !== 3 || !/^[A-Za-z0-9_-]+$/.test(parts[2])) throw invalid('google');
    const header = jwtPart(parts[0]);
    const claims = jwtPart(parts[1]);
    const time = Math.floor(now() / 1000);
    if (header.alg !== 'RS256' || typeof header.kid !== 'string' || header.kid.length > 128
      || header.crit !== undefined || !['https://accounts.google.com', 'accounts.google.com'].includes(claims.iss)
      || claims.aud !== serverClientID
      || (claims.azp !== undefined && ![iosClientID, serverClientID].includes(claims.azp))
      || !Number.isSafeInteger(claims.exp) || claims.exp <= time
      || !Number.isSafeInteger(claims.iat) || claims.iat > time + 60 || claims.exp <= claims.iat
      || (claims.nbf !== undefined && (!Number.isSafeInteger(claims.nbf) || claims.nbf > time))
      || typeof claims.sub !== 'string' || !claims.sub.length || claims.sub.length > 255) throw invalid('google');
    if (now() >= expiresAt || (!keys.has(header.kid) && now() - fetchedAt >= 60_000)) await refreshKeys();
    const key = keys.get(header.kid);
    if (!key || !verify('RSA-SHA256', Buffer.from(`${parts[0]}.${parts[1]}`), key,
      Buffer.from(parts[2], 'base64url')) || claims.exp <= Math.floor(now() / 1000)) throw invalid('google');
    return claims.sub;
  };
}

function configuredValue(value, pattern, variable) {
  if (value !== undefined && (typeof value !== 'string' || !pattern.test(value))) {
    throw new Error(`${variable} has an invalid format.`);
  }
  return value;
}

export function createSocialAuthentication({ db, now = () => Date.now(), google = {}, wechat = {} }) {
  const clientPattern = /^[A-Za-z0-9_-]{3,200}\.apps\.googleusercontent\.com$/;
  const secretPattern = /^[^\s\x00-\x1f\x7f]{1,4096}$/;
  const iosClientID = configuredValue(google.iosClientID, clientPattern, 'MAPTALK_GOOGLE_IOS_CLIENT_ID');
  const serverClientID = configuredValue(google.serverClientID, clientPattern, 'MAPTALK_GOOGLE_SERVER_CLIENT_ID');
  const clientSecret = configuredValue(google.clientSecret, secretPattern, 'MAPTALK_GOOGLE_CLIENT_SECRET');
  const appID = configuredValue(wechat.appID, /^wx[a-fA-F0-9]{16}$/, 'MAPTALK_WECHAT_APP_ID');
  const appSecret = configuredValue(wechat.appSecret, secretPattern, 'MAPTALK_WECHAT_APP_SECRET');
  const googleTransport = google.fetch ?? fetch;
  const wechatTransport = wechat.fetch ?? fetch;
  const verifyGoogle = googleVerifier({ serverClientID, iosClientID, now, transport: googleTransport });
  const available = { google: Boolean(iosClientID && serverClientID && clientSecret), wechat: Boolean(appID && appSecret) };

  function status(provider) {
    return { id: provider, available: available[provider], ...(!available[provider] ? {
      reason: `${LABELS[provider]} sign-in is not configured on this development server yet.`,
    } : {}) };
  }

  function requireConfiguration(provider) {
    if (!available[provider]) throw new SocialAuthError(503, `${provider}_not_configured`, status(provider).reason);
  }

  async function exchangeGoogle(code) {
    const { response, body } = await providerJSON('google', googleTransport, GOOGLE_TOKEN_URL, {
      method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ code, client_id: serverClientID, client_secret: clientSecret,
        grant_type: 'authorization_code', redirect_uri: '' }).toString(),
    });
    if (body.error === 'invalid_client' || body.error === 'unauthorized_client') throw unavailable('google');
    if (!response.ok || body.error) {
      if (response.status === 429 || response.status >= 500) throw unavailable('google');
      throw invalid('google');
    }
    // The SDK's server code is one-use; never accept an arbitrary client id_token.
    return verifyGoogle(body.id_token);
  }

  async function exchangeWeChat(code) {
    const url = new URL(WECHAT_TOKEN_URL);
    url.search = new URLSearchParams({ appid: appID, secret: appSecret, code, grant_type: 'authorization_code' });
    const { response, body } = await providerJSON('wechat', wechatTransport, url);
    if (!response.ok || body.errcode) {
      if (response.status === 429 || response.status >= 500 || [-1, 45011, 40013, 40125].includes(body.errcode)) {
        throw unavailable('wechat');
      }
      throw invalid('wechat');
    }
    if (typeof body.openid !== 'string' || !/^[A-Za-z0-9_-]{1,255}$/.test(body.openid)
      || typeof body.access_token !== 'string' || !body.access_token.length || body.access_token.length > 4096
      || !Number.isSafeInteger(body.expires_in) || body.expires_in <= 0
      || typeof body.scope !== 'string' || !body.scope.split(',').includes('snsapi_userinfo')) throw invalid('wechat');
    // OpenID is stable within this app. Do not silently merge accounts via optional
    // UnionID, email, nickname, or an identity supplied by the mobile client.
    return `${appID}:${body.openid}`;
  }

  return {
    providers() { return ['google', 'wechat'].map(status); },
    challenge(provider) {
      requireConfiguration(provider);
      const challengeId = randomUUID();
      const state = provider === 'wechat' ? randomBytes(32).toString('base64url') : undefined;
      const expires = now() + CHALLENGE_LIFETIME;
      db.prepare('DELETE FROM oauth_auth_challenges WHERE expires_at <= ?').run(now());
      db.prepare('DELETE FROM oauth_used_codes WHERE expires_at <= ?').run(now());
      db.prepare('INSERT INTO oauth_auth_challenges(id, provider, state_hash, expires_at) VALUES (?, ?, ?, ?)')
        .run(challengeId, provider, state ? digest(state) : null, expires);
      return { challengeId, ...(state ? { state } : {}), expiresAt: new Date(expires).toISOString() };
    },

    async exchange(provider, { challengeId, code, state }) {
      requireConfiguration(provider);
      // Consume BEFORE network exchange. A timeout may already have consumed the
      // upstream code, so the user must restart rather than replay it. Atomic DB
      // claims prevent racing sessions, including across processes/restarts.
      const expiresAt = transaction(db, () => {
        const challenge = db.prepare('SELECT * FROM oauth_auth_challenges WHERE id = ? AND provider = ?')
          .get(challengeId, provider);
        if (!challenge || challenge.expires_at <= now()
          || (provider === 'wechat' && (typeof state !== 'string' || digest(state) !== challenge.state_hash))) {
          throw expired(provider);
        }
        const claimed = db.prepare('INSERT OR IGNORE INTO oauth_used_codes(provider, code_hash, expires_at) VALUES (?, ?, ?)')
          .run(provider, digest(code), now() + CODE_RETENTION);
        if (claimed.changes !== 1) throw invalid(provider);
        db.prepare('DELETE FROM oauth_auth_challenges WHERE id = ?').run(challengeId);
        return challenge.expires_at;
      });
      const subject = await (provider === 'google' ? exchangeGoogle(code) : exchangeWeChat(code));
      return transaction(db, () => {
        if (expiresAt <= now()) throw expired(provider);
        let user = db.prepare(`SELECT users.id, users.handle, users.deletion_started_at FROM auth_identities
          JOIN users ON users.id = auth_identities.user_id WHERE provider = ? AND provider_subject = ?`)
          .get(provider, subject);
        if (user?.deletion_started_at !== null && user?.deletion_started_at !== undefined) {
          throw new SocialAuthError(409, 'account_deleting', 'Account deletion is in progress. Retry deletion with your existing session.');
        }
        if (!user) {
          const userID = randomUUID();
          user = { id: userID, handle: `member_${userID.replaceAll('-', '').slice(0, 20)}` };
          db.prepare('INSERT INTO users(id, handle, password_hash, created_at) VALUES (?, ?, ?, ?)')
            .run(user.id, user.handle, '', now());
          db.prepare('INSERT INTO auth_identities(provider, provider_subject, user_id, created_at) VALUES (?, ?, ?, ?)')
            .run(provider, subject, user.id, now());
        }
        return { user: userJSON(db, user), ...issueSession(db, user.id, now()) };
      });
    },
  };
}
