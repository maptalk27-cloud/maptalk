import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { setTimeout as pause } from 'node:timers/promises';
import { DatabaseSync } from 'node:sqlite';
import { createEncryptedBackup, restoreEncryptedBackup, startBackupScheduler } from '../src/backup-scheduler.mjs';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-encrypted-test-'));
  const source = join(directory, 'source.sqlite');
  const database = new DatabaseSync(source);
  database.exec('PRAGMA journal_mode=WAL; CREATE TABLE memories(id INTEGER PRIMARY KEY, body TEXT NOT NULL);');
  database.prepare('INSERT INTO memories VALUES (?, ?)').run(1, 'private-record-and-location-37.4');
  t.after(async () => { database.close(); await rm(directory, { recursive: true, force: true }); });
  return { directory, source, database, key: randomBytes(32).toString('base64') };
}

async function backupNames(directory) {
  return (await readdir(directory)).filter(name => name.endsWith('.mtbak')).sort();
}

async function eventually(check) {
  for (let attempt = 0; attempt < 200; attempt++) {
    if (await check()) return;
    await pause(10);
  }
  assert.fail('Timed out waiting for the backup scheduler.');
}

test('encrypted online backup restores committed WAL content without changing its source', async t => {
  const f = await fixture(t);
  const target = join(f.directory, 'snapshot.mtbak');
  const restored = join(f.directory, 'restored.sqlite');
  assert.equal(await createEncryptedBackup({ databasePath: f.source, destination: target, encryptionKey: f.key }), target);
  const encrypted = await readFile(target);
  assert.equal(encrypted.subarray(0, 8).toString(), 'MTBAK001');
  assert.ok(!encrypted.includes(Buffer.from('SQLite format 3')));
  assert.ok(!encrypted.includes(Buffer.from('private-record-and-location')));
  assert.equal((await stat(target)).mode & 0o777, 0o600);
  assert.equal(await restoreEncryptedBackup({ backupPath: target, destination: restored, encryptionKey: f.key }), restored);
  const db = new DatabaseSync(restored, { readOnly: true });
  try {
    assert.equal(db.prepare('SELECT body FROM memories WHERE id=1').get().body, 'private-record-and-location-37.4');
    assert.equal(db.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
  } finally { db.close(); }
  assert.equal((await stat(restored)).mode & 0o777, 0o600);
  assert.equal(f.database.prepare('SELECT COUNT(*) AS n FROM memories').get().n, 1);
  assert.ok(!(await readdir(f.directory)).some(name => name.startsWith('.maptalk-')), 'no plaintext staging remains');
});

test('a random nonce gives distinct ciphertext for repeated snapshots', async t => {
  const f = await fixture(t);
  const one = join(f.directory, 'one.mtbak');
  const two = join(f.directory, 'two.mtbak');
  await createEncryptedBackup({ databasePath: f.source, destination: one, encryptionKey: f.key });
  await createEncryptedBackup({ databasePath: f.source, destination: two, encryptionKey: f.key });
  assert.notDeepEqual(await readFile(one), await readFile(two));
});

test('never overwrites a backup, source or existing restore target', async t => {
  const f = await fixture(t);
  const target = join(f.directory, 'snapshot.mtbak');
  await createEncryptedBackup({ databasePath: f.source, destination: target, encryptionKey: f.key });
  const original = await readFile(target);
  await assert.rejects(createEncryptedBackup({ databasePath: f.source, destination: target, encryptionKey: f.key }), { code: 'EEXIST' });
  await assert.rejects(createEncryptedBackup({ databasePath: f.source, destination: f.source, encryptionKey: f.key }), /must not replace/);
  await assert.rejects(restoreEncryptedBackup({ backupPath: target, destination: f.source, encryptionKey: f.key }), { code: 'EEXIST' });
  await assert.rejects(restoreEncryptedBackup({ backupPath: target, destination: target, encryptionKey: f.key }), /must not replace/);
  assert.deepEqual(await readFile(target), original);
  assert.equal(f.database.prepare('SELECT COUNT(*) AS n FROM memories').get().n, 1);
});

test('wrong keys, tampered ciphertext/header and truncated files never publish plaintext', async t => {
  const f = await fixture(t);
  const target = join(f.directory, 'snapshot.mtbak');
  await createEncryptedBackup({ databasePath: f.source, destination: target, encryptionKey: f.key });
  const original = await readFile(target);
  const corrupted = Buffer.from(original);
  corrupted[30] ^= 1;
  const header = Buffer.from(original);
  header[8] ^= 1;
  const cases = [
    [original, randomBytes(32).toString('base64')], [corrupted, f.key], [header, f.key],
    [original.subarray(0, 10), f.key], [original.subarray(0, original.length - 1), f.key],
  ];
  for (const [index, [bytes, key]] of cases.entries()) {
    const backupPath = join(f.directory, `invalid-${index}.mtbak`);
    const destination = join(f.directory, `must-not-exist-${index}.sqlite`);
    await writeFile(backupPath, bytes, { flag: 'wx', mode: 0o600 });
    await assert.rejects(restoreEncryptedBackup({ backupPath, destination, encryptionKey: key }), { code: 'INVALID_ENCRYPTED_BACKUP' });
    await assert.rejects(stat(destination), { code: 'ENOENT' });
    assert.ok(!(await readdir(f.directory)).some(name => name.startsWith('.maptalk-')));
  }
});

test('invalid configuration and missing source fail without leaving staging files', async t => {
  const f = await fixture(t);
  for (const key of ['', 'not-a-key', randomBytes(16).toString('base64'), f.key.replace(/=$/, '')]) {
    await assert.rejects(createEncryptedBackup({ databasePath: f.source, destination: join(f.directory, 'bad.mtbak'), encryptionKey: key }), /32 random bytes/);
  }
  await assert.rejects(createEncryptedBackup({ databasePath: ':memory:', destination: join(f.directory, 'bad.mtbak'), encryptionKey: f.key }), /persistent filesystem/);
  await assert.rejects(createEncryptedBackup({ databasePath: join(f.directory, 'missing.sqlite'), destination: join(f.directory, 'bad.mtbak'), encryptionKey: f.key }));
  assert.ok(!(await readdir(f.directory)).some(name => name.startsWith('.maptalk-')));
  await assert.rejects(stat(join(f.directory, 'bad.mtbak')), { code: 'ENOENT' });
});

test('scheduler starts immediately; stop waits for the first backup and prevents further work', async t => {
  const f = await fixture(t);
  const directory = join(f.directory, 'backups');
  const errors = [];
  const scheduler = startBackupScheduler({ databasePath: f.source, backupDirectory: directory, encryptionKey: f.key,
    intervalMs: 50, onError: error => errors.push(error) });
  await scheduler.stop();
  assert.equal((await backupNames(directory)).length, 1);
  await pause(80);
  assert.equal((await backupNames(directory)).length, 1);
  assert.deepEqual(errors, []);
  await scheduler.stop();
});

test('scheduler serializes work and retains only its newest backups, not unrelated files', async t => {
  const f = await fixture(t);
  const directory = join(f.directory, 'backups');
  const errors = [];
  const scheduler = startBackupScheduler({ databasePath: f.source, backupDirectory: directory, encryptionKey: f.key,
    intervalMs: 15, retention: 2, onError: error => errors.push(error) });
  try {
    await eventually(async () => {
      try { return (await backupNames(directory)).length >= 1; } catch { return false; }
    });
    const firstName = (await backupNames(directory))[0];
    await writeFile(join(directory, 'keep-this.txt'), 'not a scheduled backup');
    f.database.prepare('INSERT INTO memories VALUES (?, ?)').run(2, 'after-first-snapshot');
    await eventually(async () => {
      const names = await backupNames(directory);
      return names.length === 2 && !names.includes(firstName);
    });
  } finally { await scheduler.stop(); }
  const names = await backupNames(directory);
  assert.equal(names.length, 2);
  assert.equal(await readFile(join(directory, 'keep-this.txt'), 'utf8'), 'not a scheduled backup');
  assert.ok(!(await readdir(directory)).some(name => name.startsWith('.maptalk-')));
  assert.deepEqual(errors, []);
  const destination = join(f.directory, 'latest.sqlite');
  await restoreEncryptedBackup({ backupPath: join(directory, names.at(-1)), destination, encryptionKey: f.key });
  const db = new DatabaseSync(destination, { readOnly: true });
  try { assert.equal(db.prepare('SELECT COUNT(*) AS n FROM memories').get().n, 2); } finally { db.close(); }
});

test('scheduler reports failures without unhandled rejections or pruning unrelated files', async t => {
  const f = await fixture(t);
  for (const suffix of ['1', '2']) {
    await createEncryptedBackup({ databasePath: f.source, encryptionKey: f.key,
      destination: join(f.directory, `maptalk-backup-2026-10-01T00-00-00.000Z-00000000-0000-4000-8000-00000000000${suffix}.mtbak`) });
  }
  const errors = [];
  const scheduler = startBackupScheduler({ databasePath: join(f.directory, 'missing.sqlite'), backupDirectory: f.directory,
    encryptionKey: f.key, retention: 1, onError: error => { errors.push(error); throw new Error('logger failed'); } });
  await scheduler.stop();
  assert.equal(errors.length, 1);
  assert.equal((await backupNames(f.directory)).length, 2, 'a failed new backup cannot prune either prior good backup');
  assert.equal(f.database.prepare('SELECT COUNT(*) AS n FROM memories').get().n, 1);
  assert.ok(!(await readdir(f.directory)).some(name => name.startsWith('.maptalk-')));
  for (const options of [{ intervalMs: 0 }, { retention: 0 }, { onError: false }]) {
    assert.throws(() => startBackupScheduler({ databasePath: f.source, backupDirectory: f.directory, encryptionKey: f.key, ...options }));
  }
});

test('offsite hook sees only completed ciphertext; successful upload and daily snapshot survive restarts', async t => {
  const f = await fixture(t);
  const directory = join(f.directory, 'backups');
  const uploads = [];
  const errors = [];
  const configuration = { databasePath: f.source, backupDirectory: directory, encryptionKey: f.key,
    uploadTargetID: 'test:private-backups', onError: error => errors.push(error),
    uploadBackup: async path => {
      assert.equal((await readFile(path)).subarray(0, 8).toString(), 'MTBAK001');
      assert.ok(!(await readdir(directory)).some(name => name.startsWith('.maptalk-encrypted-backup-')));
      uploads.push(path);
    } };
  await startBackupScheduler(configuration).stop();
  await startBackupScheduler(configuration).stop();
  assert.equal(uploads.length, 1);
  assert.equal((await backupNames(directory)).length, 1);
  assert.equal((await stat(join(directory, '.maptalk-s3-backup-state.json'))).mode & 0o777, 0o600);
  assert.deepEqual(errors, []);
  // A changed destination is not mistaken for success at the old destination.
  await startBackupScheduler({ ...configuration, uploadTargetID: 'test:other-backups' }).stop();
  assert.equal(uploads.length, 2);
});

test('failed uploads are reported and retried from the same durable local ciphertext after restart', async t => {
  const f = await fixture(t);
  const directory = join(f.directory, 'backups');
  const errors = [];
  const paths = [];
  const configuration = { databasePath: f.source, backupDirectory: directory, encryptionKey: f.key,
    uploadRetryMs: 150,
    uploadTargetID: 'test:private-backups', onError: error => errors.push(error),
    uploadBackup: async path => { paths.push(path); throw new Error('offsite unavailable'); } };
  await startBackupScheduler(configuration).stop();
  await startBackupScheduler(configuration).stop();
  assert.equal(errors.length, 2);
  assert.match(errors[1].message, /cooling down/);
  assert.equal(paths.length, 1, 'an immediate restart cannot bypass the failed-upload cooldown');
  await pause(170);
  await startBackupScheduler(configuration).stop();
  assert.equal(errors.length, 3);
  assert.equal(paths[0], paths[1]);
  assert.equal((await backupNames(directory)).length, 1);
  const state = JSON.parse(await readFile(join(directory, '.maptalk-s3-backup-state.json'), 'utf8'));
  assert.equal(state.succeeded, false, 'a failed upload is never recorded as success');
  await restoreEncryptedBackup({ backupPath: paths[0], destination: join(f.directory, 'restore.sqlite'), encryptionKey: f.key });
});

test('restarting near the due time does not reset the full offsite backup interval', async t => {
  const f = await fixture(t);
  const directory = join(f.directory, 'backups');
  const uploads = [];
  const intervalMs = 800;
  const configuration = { databasePath: f.source, backupDirectory: directory, encryptionKey: f.key,
    intervalMs, uploadTargetID: 'test:private-backups', uploadBackup: async path => uploads.push(path) };
  await startBackupScheduler(configuration).stop();
  await pause(600);
  const restarted = startBackupScheduler(configuration);
  try {
    await pause(450);
    assert.equal(uploads.length, 2, 'the original due time must trigger another snapshot, not restart + full interval');
  } finally { await restarted.stop(); }
});

test('scheduler shutdown waits for upload and signals cancellation after the bounded grace period', async t => {
  const f = await fixture(t);
  const errors = [];
  let signal;
  const scheduler = startBackupScheduler({ databasePath: f.source, backupDirectory: join(f.directory, 'backups'), encryptionKey: f.key,
    uploadTargetID: 'test:private-backups', onError: error => errors.push(error),
    uploadBackup: async (_, options) => {
      signal = options.signal;
      await new Promise((resolve, reject) => {
        if (signal.aborted) return reject(new Error('upload cancelled'));
        signal.addEventListener('abort', () => reject(new Error('upload cancelled')), { once: true });
      });
    } });
  await eventually(() => signal);
  await scheduler.stop({ abortAfterMs: 20 });
  assert.equal(signal.aborted, true);
  assert.equal(errors.length, 1);
});
