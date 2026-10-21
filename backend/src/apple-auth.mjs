import { createPublicKey, randomBytes, randomUUID, verify } from 'node:crypto';
import { digest, issueSession } from './security.mjs';
import { transaction } from './database.mjs';
import { createAppleLifecycle, AppleLifecycleError } from './apple-lifecycle.mjs';
import { userJSON } from './user-profile.mjs';

const ISSUER = 'https://appleid.apple.com';
const KEYS_URL = `${ISSUER}/auth/keys`;
const CHALLENGE_LIFETIME = 5 * 60 * 1000;
const KEY_LIFETIME = 60 * 60 * 1000;

export class AppleAuthError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function invalidToken() {
  return new AppleAuthError(401, 'invalid_apple_identity', 'Apple sign-in could not be verified. Please try again.');
}

function invalidChallenge() {
  return new AppleAuthError(401, 'apple_challenge_expired', 'This sign-in attempt expired. Please start again.');
}

function jsonSegment(segment) {
  if (!/^[A-Za-z0-9_-]+$/.test(segment)) throw invalidToken();
  let value;
  try { value = JSON.parse(Buffer.from(segment, 'base64url').toString('utf8')); } catch { throw invalidToken(); }
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw invalidToken();
  return value;
}

/** The endpoint/issuer are fixed, never supplied by a token or HTTP request.
 * fetchKeys is a transport test seam; tests still sign and verify actual RSA JWTs.
 */
export function createAppleIdentityVerifier({ clientID, now = () => Date.now(), fetchKeys = fetch }) {
  let cache = new Map();
  let fetchedAt = -Infinity;
  let refreshing;

  async function refreshKeys() {
    if (refreshing) return refreshing;
    refreshing = (async () => {
      try {
        const response = await fetchKeys(KEYS_URL, { signal: AbortSignal.timeout(5000), redirect: 'error' });
        if (!response.ok || Number(response.headers.get('content-length')) > 65_536) throw new Error();
        const text = await response.text();
        if (text.length > 65_536) throw new Error();
        const result = JSON.parse(text);
        if (!Array.isArray(result.keys) || result.keys.length === 0 || result.keys.length > 20) throw new Error();
        const keys = new Map();
        for (const jwk of result.keys) {
          if (jwk.kty !== 'RSA' || jwk.alg !== 'RS256' || jwk.use !== 'sig'
            || typeof jwk.kid !== 'string' || jwk.kid.length === 0 || jwk.kid.length > 128) continue;
          const key = createPublicKey({ key: jwk, format: 'jwk' });
          if (key.asymmetricKeyDetails?.modulusLength < 2048 || keys.has(jwk.kid)) throw new Error();
          keys.set(jwk.kid, key);
        }
        if (!keys.size) throw new Error();
        cache = keys;
        fetchedAt = now();
      } catch {
        throw new AppleAuthError(503, 'apple_unavailable', 'Cannot verify Apple sign-in right now. Please try again.');
      }
    })();
    try { await refreshing; } finally { refreshing = undefined; }
  }

  return async function verifyIdentity(identityToken, nonceHash) {
    if (typeof identityToken !== 'string' || identityToken.length > 16_384) throw invalidToken();
    const parts = identityToken.split('.');
    if (parts.length !== 3 || !/^[A-Za-z0-9_-]+$/.test(parts[2])) throw invalidToken();
    const header = jsonSegment(parts[0]);
    const claims = jsonSegment(parts[1]);
    const time = Math.floor(now() / 1000);
    if (header.alg !== 'RS256' || typeof header.kid !== 'string' || header.kid.length > 128
      || header.crit !== undefined || claims.iss !== ISSUER || claims.aud !== clientID
      || !Number.isSafeInteger(claims.exp) || claims.exp <= time
      || !Number.isSafeInteger(claims.iat) || claims.iat > time + 60 || claims.exp <= claims.iat
      || (claims.nbf !== undefined && (!Number.isSafeInteger(claims.nbf) || claims.nbf > time))
      || typeof claims.sub !== 'string' || claims.sub.length === 0 || claims.sub.length > 255
      || typeof claims.nonce !== 'string' || claims.nonce.length > 128 || digest(claims.nonce) !== nonceHash) {
      throw invalidToken();
    }
    // Cache Apple's keys; an unknown kid may refresh after a short cooldown for rotation.
    if (now() - fetchedAt >= KEY_LIFETIME || (!cache.has(header.kid) && now() - fetchedAt >= 60_000)) {
      await refreshKeys();
    }
    const key = cache.get(header.kid);
    if (!key || !verify('RSA-SHA256', Buffer.from(`${parts[0]}.${parts[1]}`), key, Buffer.from(parts[2], 'base64url'))) {
      throw invalidToken();
    }
    // Fetching Apple's keys may have crossed the token's expiration boundary.
    if (claims.exp <= Math.floor(now() / 1000)) throw invalidToken();
    return { subject: claims.sub };
  };
}

export function createAppleAuthentication({ db, clientID, now = () => Date.now(), fetchKeys,
  requireLifecycle = false, ...lifecycleConfiguration }) {
  if (clientID !== undefined && (typeof clientID !== 'string' || !/^[A-Za-z0-9.-]{3,255}$/.test(clientID))) {
    throw new Error('MAPTALK_APPLE_CLIENT_ID must be the exact iOS app bundle identifier.');
  }
  const verifyIdentity = createAppleIdentityVerifier({ clientID, now, fetchKeys });
  const lifecycle = createAppleLifecycle({ clientID, now, ...lifecycleConfiguration });
  if (requireLifecycle && clientID && !lifecycle.configured) {
    throw new Error('Beta Apple sign-in requires team ID, key ID, .p8 private key, and token encryption key for account deletion.');
  }

  function requireConfiguration() {
    if (!clientID) {
      throw new AppleAuthError(503, 'apple_not_configured',
        'Apple sign-in is not configured on this development server yet.');
    }
  }

  return {
    preflightDeletion(userID) {
      if (!db.prepare("SELECT 1 FROM auth_identities WHERE provider = 'apple' AND user_id = ?").get(userID)) return;
      if (!lifecycle.configured || !db.prepare('SELECT 1 FROM apple_refresh_tokens WHERE user_id = ?').get(userID)) {
        throw new AppleLifecycleError(409, 'apple_revocation_required',
          'Sign in with Apple again before deleting this account. Apple token revocation must be configured by the operator.');
      }
    },
    async revokeUser(userID) {
      const stored = db.prepare('SELECT * FROM apple_refresh_tokens WHERE user_id = ?').get(userID);
      if (!stored || stored.revoked_at !== null) return;
      await lifecycle.revoke(stored.encrypted_token, userID);
      db.prepare('UPDATE apple_refresh_tokens SET revoked_at = ? WHERE user_id = ?').run(now(), userID);
    },
    challenge() {
      requireConfiguration();
      const time = now();
      const challengeId = randomUUID();
      const nonce = randomBytes(32).toString('base64url');
      const expires = time + CHALLENGE_LIFETIME;
      db.prepare('DELETE FROM apple_auth_challenges WHERE expires_at <= ?').run(time);
      db.prepare('INSERT INTO apple_auth_challenges(id, nonce_hash, expires_at) VALUES (?, ?, ?)')
        .run(challengeId, digest(nonce), expires);
      return { challengeId, nonce, expiresAt: new Date(expires).toISOString() };
    },

    async exchange({ challengeId, identityToken, authorizationCode }) {
      requireConfiguration();
      const challenge = db.prepare('SELECT nonce_hash, expires_at FROM apple_auth_challenges WHERE id = ?')
        .get(challengeId);
      if (!challenge || challenge.expires_at <= now()) throw invalidChallenge();
      const identity = await verifyIdentity(identityToken, challenge.nonce_hash);
      let refreshToken;
      if (lifecycle.configured) {
        if (typeof authorizationCode !== 'string' || !/^[\x21-\x7e]{1,4096}$/.test(authorizationCode)) {
          throw new AppleAuthError(422, 'apple_authorization_code_required', 'Provide the Apple authorization code.');
        }
        transaction(db, () => {
          const consumed = db.prepare('DELETE FROM apple_auth_challenges WHERE id = ? AND expires_at > ?').run(challengeId, now());
          if (consumed.changes !== 1) throw invalidChallenge();
          db.prepare('DELETE FROM apple_used_codes WHERE expires_at <= ?').run(now());
          if (db.prepare('INSERT OR IGNORE INTO apple_used_codes VALUES (?, ?)').run(digest(authorizationCode), now() + 86_400_000).changes !== 1) {
            throw invalidChallenge();
          }
        });
        const result = await lifecycle.exchange(authorizationCode);
        const verified = await verifyIdentity(result.identityToken, challenge.nonce_hash);
        if (verified.subject !== identity.subject) throw invalidToken();
        refreshToken = result.refreshToken;
      }
      return transaction(db, () => {
        // A replay/racing request can never issue a second session, even across restarts.
        if (challenge.expires_at <= now()) throw invalidChallenge();
        if (!lifecycle.configured) {
          const consumed = db.prepare('DELETE FROM apple_auth_challenges WHERE id = ? AND expires_at > ?').run(challengeId, now());
          if (consumed.changes !== 1) throw invalidChallenge();
        }
        let user = db.prepare(`SELECT users.id, users.handle, users.deletion_started_at FROM auth_identities
          JOIN users ON users.id = auth_identities.user_id
          WHERE provider = 'apple' AND provider_subject = ?`).get(identity.subject);
        if (user?.deletion_started_at !== null && user?.deletion_started_at !== undefined) {
          throw new AppleAuthError(409, 'account_deleting', 'Account deletion is in progress. Retry deletion with your existing session.');
        }
        if (!user) {
          const userID = randomUUID();
          // Do not link by email/name, and never make an Apple account password-accessible.
          user = { id: userID, handle: `member_${userID.replaceAll('-', '').slice(0, 20)}` };
          db.prepare('INSERT INTO users(id, handle, password_hash, created_at) VALUES (?, ?, ?, ?)')
            .run(user.id, user.handle, '', now());
          db.prepare(`INSERT INTO auth_identities(provider, provider_subject, user_id, created_at)
            VALUES ('apple', ?, ?, ?)`).run(identity.subject, user.id, now());
        }
        if (refreshToken) {
          db.prepare(`INSERT INTO apple_refresh_tokens(user_id, encrypted_token, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(user_id) DO UPDATE SET encrypted_token = excluded.encrypted_token,
              updated_at = excluded.updated_at, revoked_at = NULL`)
            .run(user.id, lifecycle.encrypt(refreshToken, user.id), now());
        }
        return { user: userJSON(db, user), ...issueSession(db, user.id, now()) };
      });
    },
  };
}
