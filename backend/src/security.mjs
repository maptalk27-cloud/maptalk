import { createHash, randomBytes, scrypt, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';

const derive = promisify(scrypt);
// One of OWASP's scrypt configurations; persist work factors with each hash.
const options = { N: 32768, r: 8, p: 3, maxmem: 64 * 1024 * 1024 };
const format = `scrypt$${options.N}$${options.r}$${options.p}`;
// Missing users still take the same password-derivation path as existing ones.
const dummyHash = `${format}$${'00'.repeat(16)}$${'00'.repeat(64)}`;

export function digest(value) {
  return createHash('sha256').update(value).digest('hex');
}

export async function hashPassword(password) {
  const salt = randomBytes(16).toString('hex');
  const key = await derive(password, salt, 64, options);
  return `${format}$${salt}$${key.toString('hex')}`;
}

export async function verifyPassword(password, encoded = dummyHash) {
  const [algorithm, N, r, p, salt, hash, extra] = encoded.split('$');
  if (`${algorithm}$${N}$${r}$${p}` !== format || extra !== undefined
    || !/^[a-f0-9]{32}$/.test(salt) || !/^[a-f0-9]{128}$/.test(hash)) {
    return false;
  }
  const key = await derive(password, salt, 64, options);
  return timingSafeEqual(key, Buffer.from(hash, 'hex'));
}

export function issueSession(db, userID, now) {
  const token = randomBytes(32).toString('base64url');
  const expires = now + 7 * 24 * 60 * 60 * 1000;
  db.prepare('DELETE FROM sessions WHERE expires_at <= ?').run(now);
  db.prepare('INSERT INTO sessions(token_hash, user_id, expires_at) VALUES (?, ?, ?)')
    .run(digest(token), userID, expires);
  return { token, expiresAt: new Date(expires).toISOString() };
}
