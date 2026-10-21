import { createCipheriv, createDecipheriv, randomBytes, randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { appendFile, link, lstat, mkdir, mkdtemp, open, readFile, readdir, rename, rm, unlink, writeFile } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { DatabaseSync } from 'node:sqlite';
import { backupDatabase } from './backup.mjs';

const MAGIC = Buffer.from('MTBAK001');
const IV_BYTES = 12;
const TAG_BYTES = 16;
const HEADER_BYTES = MAGIC.length + IV_BYTES;
const BACKUP_NAME = /^maptalk-backup-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}\.\d{3}Z-[a-f0-9-]{36}\.mtbak$/;

function pathValue(value, label) {
  if (typeof value !== 'string' || !value.trim() || value === ':memory:' || value.startsWith('file:')) {
    throw new Error(`${label} must be a persistent filesystem path.`);
  }
  return resolve(value);
}

function keyBytes(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/]{43}=$/.test(value)) {
    throw new Error('Backup encryption key must be exactly 32 random bytes encoded as base64.');
  }
  const key = Buffer.from(value, 'base64');
  if (key.length !== 32 || key.toString('base64') !== value) {
    throw new Error('Backup encryption key must be exactly 32 random bytes encoded as base64.');
  }
  return key;
}

function invalidBackup() {
  const error = new Error('The encrypted backup is damaged, incomplete or uses a different key.');
  error.code = 'INVALID_ENCRYPTED_BACKUP';
  return error;
}

async function requireNewPath(path) {
  try {
    await lstat(path);
  } catch (error) {
    if (error.code === 'ENOENT') return;
    throw error;
  }
  const error = new Error('The destination already exists; choose a new path.');
  error.code = 'EEXIST';
  throw error;
}

async function flush(path) {
  const file = await open(path, 'r+');
  try { await file.sync(); } finally { await file.close(); }
}

async function publish(staging, target) {
  await link(staging, target);
  // Persist the directory entry too before retention can remove an older file.
  const directory = await open(dirname(target), 'r');
  try { await directory.sync(); } finally { await directory.close(); }
}

/** SQLite's online backup API needs a temporary file. Its private staging
 * directory is removed on success/failure; only the authenticated ciphertext is
 * published. An abrupt process/host crash can leave staging behind: this is not
 * a promise of plaintext-free disks or secure erasure, nor an off-site backup.
 */
export async function createEncryptedBackup({ databasePath, destination, encryptionKey }) {
  const source = pathValue(databasePath, 'databasePath');
  const target = pathValue(destination, 'destination');
  if (source === target) throw new Error('Backup must not replace the source database.');
  const key = keyBytes(encryptionKey);
  let temporary;
  try {
    await requireNewPath(target);
    await mkdir(dirname(target), { recursive: true, mode: 0o700 });
    temporary = await mkdtemp(join(dirname(target), '.maptalk-encrypted-backup-'));
    const snapshot = join(temporary, 'snapshot.sqlite');
    const encrypted = join(temporary, 'encrypted.tmp');
    // Includes committed WAL contents without changing the source's user data.
    await backupDatabase(source, snapshot);
    const header = Buffer.concat([MAGIC, randomBytes(IV_BYTES)]);
    const cipher = createCipheriv('aes-256-gcm', key, header.subarray(MAGIC.length), { authTagLength: TAG_BYTES });
    cipher.setAAD(header);
    await writeFile(encrypted, header, { flag: 'wx', mode: 0o600 });
    await pipeline(createReadStream(snapshot), cipher, createWriteStream(encrypted, { flags: 'a', mode: 0o600 }));
    await appendFile(encrypted, cipher.getAuthTag());
    await flush(encrypted);
    // Same-filesystem hard-link publication is atomic and fails if *anything*
    // already occupies the target; rename() could overwrite an existing backup.
    await publish(encrypted, target);
    return target;
  } finally {
    key.fill(0);
    if (temporary) await rm(temporary, { recursive: true, force: true });
  }
}

/** Restore only to a new path, after the entire GCM tag and SQLite integrity
 * check pass. Never point this at a running database or overwrite a live file.
 */
export async function restoreEncryptedBackup({ backupPath, destination, encryptionKey }) {
  const source = pathValue(backupPath, 'backupPath');
  const target = pathValue(destination, 'destination');
  if (source === target) throw new Error('Restore must not replace the encrypted backup.');
  const key = keyBytes(encryptionKey);
  let temporary;
  let input;
  try {
    await requireNewPath(target);
    input = await open(source, 'r');
    const details = await input.stat();
    if (!details.isFile() || details.size <= HEADER_BYTES + TAG_BYTES) throw invalidBackup();
    const header = Buffer.alloc(HEADER_BYTES);
    const tag = Buffer.alloc(TAG_BYTES);
    const start = await input.read(header, 0, header.length, 0);
    const end = await input.read(tag, 0, tag.length, details.size - TAG_BYTES);
    if (start.bytesRead !== header.length || end.bytesRead !== tag.length
      || !header.subarray(0, MAGIC.length).equals(MAGIC)) throw invalidBackup();
    await mkdir(dirname(target), { recursive: true, mode: 0o700 });
    temporary = await mkdtemp(join(dirname(target), '.maptalk-restore-'));
    const plaintext = join(temporary, 'restored.sqlite');
    const decipher = createDecipheriv('aes-256-gcm', key, header.subarray(MAGIC.length), { authTagLength: TAG_BYTES });
    decipher.setAAD(header);
    decipher.setAuthTag(tag);
    try {
      await pipeline(input.createReadStream({ start: HEADER_BYTES, end: details.size - TAG_BYTES - 1, autoClose: false }),
        decipher, createWriteStream(plaintext, { flags: 'wx', mode: 0o600 }));
    } catch (error) {
      // Preserve actionable disk failures; authentication/format errors reveal
      // neither key material nor native crypto details.
      if (['ENOSPC', 'EACCES', 'EROFS', 'EIO'].includes(error.code)) throw error;
      throw invalidBackup();
    }
    let database;
    try {
      database = new DatabaseSync(plaintext, { readOnly: true });
      const result = database.prepare('PRAGMA integrity_check').all();
      if (result.length !== 1 || result[0].integrity_check !== 'ok') throw invalidBackup();
    } catch { throw invalidBackup(); } finally { database?.close(); }
    await flush(plaintext);
    await publish(plaintext, target);
    return target;
  } finally {
    key.fill(0);
    try { await input?.close(); } finally {
      if (temporary) await rm(temporary, { recursive: true, force: true });
    }
  }
}

async function prune(directory, retention) {
  const files = (await readdir(directory, { withFileTypes: true }))
    .filter(entry => entry.isFile() && BACKUP_NAME.test(entry.name))
    .map(entry => entry.name).sort().reverse();
  for (const name of files.slice(retention)) await unlink(join(directory, name));
}

async function recentBackup(directory, intervalMs) {
  let entries;
  try { entries = await readdir(directory, { withFileTypes: true }); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
  const newest = entries.filter(entry => entry.isFile() && BACKUP_NAME.test(entry.name))
    .map(entry => entry.name).sort().at(-1);
  if (!newest) return;
  const timestamp = Date.parse(newest.slice(15, 39).replace(/T(\d{2})-(\d{2})-(\d{2})/, 'T$1:$2:$3'));
  const age = Date.now() - timestamp;
  if (age >= 0 && age < intervalMs) return { path: join(directory, newest), timestamp };
}

async function uploadState(directory, filename, targetID) {
  try {
    const data = JSON.parse(await readFile(join(directory, '.maptalk-s3-backup-state.json'), 'utf8'));
    if (data.version === 1 && data.filename === filename && data.targetID === targetID
      && Number.isSafeInteger(data.attemptedAt) && typeof data.succeeded === 'boolean') return data;
  } catch (error) {
    if (error.code === 'ENOENT' || error instanceof SyntaxError) return;
    throw error;
  }
}

async function recordUpload(directory, filename, targetID, attemptedAt, succeeded) {
  const staging = join(directory, `.maptalk-s3-backup-state-${randomUUID()}.tmp`);
  try {
    await writeFile(staging, JSON.stringify({ version: 1, filename, targetID, attemptedAt, succeeded }), { flag: 'wx', mode: 0o600 });
    await flush(staging);
    await rename(staging, join(directory, '.maptalk-s3-backup-state.json'));
    const folder = await open(directory, 'r');
    try { await folder.sync(); } finally { await folder.close(); }
  } finally { await rm(staging, { force: true }); }
}

/** One scheduler for a single-process deployment. It starts immediately, skips
 * ticks while busy, and never prunes prior good backups when a new one fails.
 * With an upload hook, recent ciphertext and a success marker survive restart.
 * Local retention is independent of upload success: the newest complete local
 * recovery copy is always kept. stop() waits for a snapshot and allows an upload
 * a bounded grace period before signalling cancellation.
 */
export function startBackupScheduler({ databasePath, backupDirectory, encryptionKey,
  intervalMs = 24 * 60 * 60 * 1000, retention = 7,
  uploadBackup, uploadTargetID, uploadRetryMs = Math.min(intervalMs, 3_600_000),
  onError = () => console.error('Encrypted database backup failed.') }) {
  const source = pathValue(databasePath, 'databasePath');
  const directory = pathValue(backupDirectory, 'backupDirectory');
  keyBytes(encryptionKey).fill(0);
  if (!Number.isSafeInteger(intervalMs) || intervalMs < 1 || intervalMs > 2_147_483_647) {
    throw new Error('Backup interval must be a positive supported timer duration.');
  }
  if (!Number.isSafeInteger(retention) || retention < 1 || retention > 365) {
    throw new Error('Backup retention must be between 1 and 365 files.');
  }
  if (typeof onError !== 'function') throw new Error('onError must be a function.');
  if (uploadBackup !== undefined && (typeof uploadBackup !== 'function'
    || typeof uploadTargetID !== 'string' || !uploadTargetID)) {
    throw new Error('An upload hook requires a function and a nonempty uploadTargetID.');
  }
  if (!Number.isSafeInteger(uploadRetryMs) || uploadRetryMs < 1 || uploadRetryMs > Math.min(intervalMs, 3_600_000)) {
    throw new Error('Upload retry delay must be positive and no longer than one hour or the backup interval.');
  }
  let stopped = false;
  let active;
  let timer;
  const shutdown = new AbortController();
  function run() {
    if (stopped || active) return;
    let nextDue = Date.now() + intervalMs;
    let retryDue = Date.now() + uploadRetryMs;
    let failed = false;
    active = (async () => {
      try {
        const recent = uploadBackup ? await recentBackup(directory, intervalMs) : undefined;
        let destination = recent?.path;
        if (recent) nextDue = recent.timestamp + intervalMs;
        if (!destination) {
          const now = Date.now();
          nextDue = now + intervalMs;
          const stamp = new Date(now).toISOString().replaceAll(':', '-');
          destination = await createEncryptedBackup({ databasePath: source, encryptionKey,
            destination: join(directory, `maptalk-backup-${stamp}-${randomUUID()}.mtbak`) });
        }
        await prune(directory, retention);
        if (uploadBackup) {
          const filename = basename(destination);
          const state = await uploadState(directory, filename, uploadTargetID);
          if (!state?.succeeded) {
            const now = Date.now();
            if (state && state.attemptedAt <= now && now - state.attemptedAt < uploadRetryMs) {
              retryDue = state.attemptedAt + uploadRetryMs;
              throw new Error('The previous encrypted offsite backup attempt failed or was interrupted; retry is cooling down.');
            }
            retryDue = now + uploadRetryMs;
            // Record before touching AWS, so a crash/restart loop cannot bypass
            // the retry cooldown and continually create multipart requests.
            await recordUpload(directory, filename, uploadTargetID, now, false);
            await uploadBackup(destination, { signal: shutdown.signal });
            await recordUpload(directory, filename, uploadTargetID, now, true);
          }
        }
      } catch (error) {
        failed = true;
        try { await onError(error); } catch { /* Reporting must not create an unhandled rejection. */ }
      }
    })().finally(() => {
      active = undefined;
      if (uploadBackup && !stopped) {
        // Preserve the original due time across process restarts. On failure,
        // retry at most hourly in production; never spin on an expired due time.
        const delay = Math.max(1, (failed ? retryDue : nextDue) - Date.now());
        timer = setTimeout(run, delay);
        timer.unref();
      }
    });
  }
  if (!uploadBackup) {
    timer = setInterval(run, intervalMs);
    timer.unref();
  }
  run();
  return {
    async stop({ abortAfterMs = 20_000 } = {}) {
      if (!Number.isSafeInteger(abortAfterMs) || abortAfterMs < 1 || abortAfterMs > 300_000) {
        throw new Error('Shutdown upload grace must be 1–300000 milliseconds.');
      }
      stopped = true;
      clearInterval(timer);
      const abortTimer = setTimeout(() => shutdown.abort(), abortAfterMs);
      try { await active; } finally { clearTimeout(abortTimer); }
    },
  };
}
