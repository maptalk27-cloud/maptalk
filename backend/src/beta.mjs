import { randomBytes, randomUUID } from 'node:crypto';
import { digest } from './security.mjs';
import { transaction } from './database.mjs';

export class BetaError extends Error {
  constructor(status, code, message) { super(message); Object.assign(this, { status, code }); }
}

export function createConcurrentGate(limit) {
  let active = 0;
  return () => {
    if (active >= limit) return null;
    active++;
    let released = false;
    return () => { if (!released) { released = true; active--; } };
  };
}

export function deploymentConfiguration({ mode = 'local', publicOrigin, bind = '127.0.0.1' } = {}) {
  if (!['local', 'beta'].includes(mode)) throw new Error('MAPTALK_MODE must be local or beta.');
  if (!['127.0.0.1', '0.0.0.0', '::1', '::'].includes(bind)) throw new Error('MAPTALK_BIND must be a supported explicit bind address.');
  if (mode === 'local') {
    if (bind !== '127.0.0.1' || publicOrigin) throw new Error('Local mode only allows 127.0.0.1 without a public origin.');
    return { mode, bind, publicOrigin: null, publicHost: null };
  }
  let origin;
  try { origin = new URL(publicOrigin); } catch { throw new Error('Beta requires MAPTALK_PUBLIC_ORIGIN as a canonical HTTPS origin.'); }
  if (origin.protocol !== 'https:' || origin.username || origin.password || origin.pathname !== '/'
    || origin.search || origin.hash || origin.origin !== publicOrigin
    || !origin.hostname.includes('.') || origin.hostname === 'localhost'
    || /^\d+(\.\d+){3}$/.test(origin.hostname) || origin.hostname.endsWith('.local')) {
    throw new Error('Beta requires a canonical public HTTPS origin, without a path, credentials or IP address.');
  }
  return { mode, bind, publicOrigin: origin.origin, publicHost: origin.host };
}

export function betaAccess(db, userID, required) {
  if (!required) return { required: false, status: 'active' };
  const member = db.prepare('SELECT status FROM beta_members WHERE user_id = ?').get(userID);
  return { required: true, status: member?.status ?? 'pending' };
}

export function requireBetaAccess(db, userID, required) {
  const access = betaAccess(db, userID, required);
  if (access.status === 'revoked') throw new BetaError(403, 'beta_access_revoked', 'Your beta access has been revoked.');
  if (access.status !== 'active') throw new BetaError(403, 'beta_access_required', 'Enter your invitation code to join this private beta.');
}

export function issueInvite(db, { hours = 168, now = Date.now() } = {}) {
  if (!Number.isInteger(hours) || hours < 1 || hours > 24 * 30) throw new Error('Invite lifetime must be 1–720 hours.');
  const id = randomUUID();
  const code = randomBytes(24).toString('base64url');
  const expires = now + hours * 3_600_000;
  db.prepare('INSERT INTO beta_invites(id, code_hash, created_at, expires_at) VALUES (?, ?, ?, ?)')
    .run(id, digest(code), now, expires);
  return { id, code, expiresAt: new Date(expires).toISOString() };
}

export function redeemInvite(db, userID, code, now = Date.now()) {
  if (typeof code !== 'string' || !/^[A-Za-z0-9_-]{32}$/.test(code)) {
    throw new BetaError(422, 'invalid_invite', 'This invitation code is invalid or no longer available.');
  }
  return transaction(db, () => {
    if (betaAccess(db, userID, true).status === 'revoked') {
      throw new BetaError(403, 'beta_access_revoked', 'Your beta access has been revoked.');
    }
    const invite = db.prepare('SELECT * FROM beta_invites WHERE code_hash = ?').get(digest(code));
    // Repeating a successfully completed request by the same user is harmless.
    if (invite?.redeemed_by === userID && invite.redeemed_at !== null && !invite.revoked_at
      && betaAccess(db, userID, true).status === 'active') return;
    if (!invite || invite.expires_at <= now || invite.revoked_at !== null || invite.redeemed_at !== null) {
      throw new BetaError(422, 'invalid_invite', 'This invitation code is invalid or no longer available.');
    }
    db.prepare('UPDATE beta_invites SET redeemed_at = ?, redeemed_by = ? WHERE id = ?').run(now, userID, invite.id);
    db.prepare(`INSERT INTO beta_members(user_id, status, updated_at) VALUES (?, 'active', ?)
      ON CONFLICT(user_id) DO UPDATE SET status = 'active', updated_at = excluded.updated_at`).run(userID, now);
  });
}

export function revokeBetaAccess(db, { userID, inviteID, now = Date.now() }) {
  if (Boolean(userID) === Boolean(inviteID)) throw new Error('Specify exactly one user or invite ID.');
  return transaction(db, () => {
    if (inviteID) {
      const invite = db.prepare('SELECT redeemed_by FROM beta_invites WHERE id = ?').get(inviteID);
      if (!invite) throw new Error('Invitation not found.');
      db.prepare('UPDATE beta_invites SET revoked_at = ? WHERE id = ?').run(now, inviteID);
      userID = invite.redeemed_by;
    }
    if (userID) {
      if (!db.prepare('SELECT id FROM users WHERE id = ?').get(userID)) throw new Error('Account not found.');
      db.prepare(`INSERT INTO beta_members(user_id, status, updated_at) VALUES (?, 'revoked', ?)
        ON CONFLICT(user_id) DO UPDATE SET status = 'revoked', updated_at = excluded.updated_at`).run(userID, now);
    }
  });
}

export function moderateMemory(db, memoryID, decision) {
  if (!['approve', 'reject'].includes(decision)) throw new Error('Use approve or reject.');
  const result = db.prepare('UPDATE memories SET moderation_status = ? WHERE id = ?')
    .run(decision === 'approve' ? 'approved' : 'rejected', memoryID);
  if (!result.changes) throw new Error('Memory not found.');
}
