import { createCipheriv, createDecipheriv, createPrivateKey, randomBytes, sign } from 'node:crypto';

export class AppleLifecycleError extends Error {
  constructor(status, code, message) { super(message); Object.assign(this, { status, code }); }
}

function unavailable() {
  return new AppleLifecycleError(503, 'apple_lifecycle_unavailable', 'Cannot complete Apple authorization right now. Please try again.');
}

export function createAppleLifecycle({ clientID, teamID, keyID, privateKey, encryptionKey,
  now = () => Date.now(), fetchTokens = fetch } = {}) {
  const configured = Boolean(clientID && teamID && keyID && privateKey && encryptionKey);
  let signingKey;
  let cipherKey;
  if (configured) {
    if (!/^[A-Z0-9]{10}$/.test(teamID) || !/^[A-Z0-9]{10}$/.test(keyID)) throw new Error('Apple team and key IDs must be 10 uppercase letters/digits.');
    try {
      signingKey = createPrivateKey(privateKey);
      cipherKey = Buffer.from(encryptionKey, 'base64');
      if (signingKey.asymmetricKeyType !== 'ec' || signingKey.asymmetricKeyDetails?.namedCurve !== 'prime256v1'
        || cipherKey.length !== 32 || cipherKey.toString('base64') !== encryptionKey) throw new Error();
    } catch { throw new Error('Apple lifecycle requires a P-256 .p8 key and a canonical base64 32-byte encryption key.'); }
  }
  function clientSecret() {
    const encode = data => Buffer.from(JSON.stringify(data)).toString('base64url');
    const time = Math.floor(now() / 1000);
    const body = `${encode({ alg: 'ES256', kid: keyID, typ: 'JWT' })}.${encode({ iss: teamID, iat: time,
      exp: time + 300, aud: 'https://appleid.apple.com', sub: clientID })}`;
    return `${body}.${sign('sha256', Buffer.from(body), { key: signingKey, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
  }
  async function post(endpoint, fields) {
    if (!configured) throw new AppleLifecycleError(409, 'apple_revocation_required', 'Apple account deletion is not configured. Contact the beta operator.');
    try {
      const response = await fetchTokens(`https://appleid.apple.com/auth/${endpoint}`, {
        method: 'POST', redirect: 'error', signal: AbortSignal.timeout(8000),
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ client_id: clientID, client_secret: clientSecret(), ...fields }).toString(),
      });
      let size = 0;
      const chunks = [];
      for await (const chunk of response.body ?? []) {
        size += chunk.length;
        if (size > 65_536) throw unavailable();
        chunks.push(Buffer.from(chunk));
      }
      const text = Buffer.concat(chunks).toString('utf8');
      const body = text ? JSON.parse(text) : {};
      if (!response.ok || body.error) {
        if (endpoint === 'token' && body.error === 'invalid_grant') {
          throw new AppleLifecycleError(401, 'invalid_apple_authorization_code', 'Apple authorization expired. Please start sign-in again.');
        }
        throw unavailable();
      }
      return body;
    } catch (error) {
      if (error instanceof AppleLifecycleError) throw error;
      throw unavailable();
    }
  }
  return {
    configured,
    async exchange(code) {
      const result = await post('token', { code, grant_type: 'authorization_code' });
      if (typeof result.refresh_token !== 'string' || !result.refresh_token.length || result.refresh_token.length > 8192
        || typeof result.id_token !== 'string' || result.id_token.length > 16_384) throw unavailable();
      return { identityToken: result.id_token, refreshToken: result.refresh_token };
    },
    encrypt(token, userID) {
      const iv = randomBytes(12);
      const cipher = createCipheriv('aes-256-gcm', cipherKey, iv);
      cipher.setAAD(Buffer.from(`maptalk:apple:${userID}`));
      const encrypted = Buffer.concat([cipher.update(token, 'utf8'), cipher.final()]);
      return `v1.${iv.toString('base64url')}.${cipher.getAuthTag().toString('base64url')}.${encrypted.toString('base64url')}`;
    },
    async revoke(encrypted, userID) {
      let token;
      try {
        const [version, iv, tag, data, extra] = encrypted.split('.');
        if (version !== 'v1' || extra !== undefined) throw new Error();
        const decipher = createDecipheriv('aes-256-gcm', cipherKey, Buffer.from(iv, 'base64url'));
        decipher.setAAD(Buffer.from(`maptalk:apple:${userID}`));
        decipher.setAuthTag(Buffer.from(tag, 'base64url'));
        token = Buffer.concat([decipher.update(Buffer.from(data, 'base64url')), decipher.final()]).toString('utf8');
      } catch { throw unavailable(); }
      // Apple returns success for already-invalid tokens too: safe to retry when
      // the remote revoke succeeded but the connection/DB transaction failed.
      await post('revoke', { token, token_type_hint: 'refresh_token' });
    },
  };
}
