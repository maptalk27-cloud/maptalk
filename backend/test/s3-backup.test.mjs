import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { mkdtemp, readFile, rm, symlink, truncate, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { DatabaseSync } from 'node:sqlite';
import { createEncryptedBackup, restoreEncryptedBackup } from '../src/backup-scheduler.mjs';
import { createS3BackupUploader, MAX_S3_BACKUP_BYTES } from '../src/s3-backup.mjs';

const TARGET = { region: 'us-east-2', bucket: 'maptalk-private-backup-test', prefix: 'maptalk/backups/' };
const NAME = 'maptalk-backup-2026-10-19T12-00-00.000Z-00000000-0000-4000-8000-000000000001.mtbak';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-s3-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const source = join(directory, 'source.sqlite');
  const db = new DatabaseSync(source);
  db.exec("CREATE TABLE private_data(body TEXT); INSERT INTO private_data VALUES ('secret-location-and-owner');");
  db.close();
  const key = randomBytes(32).toString('base64');
  const backupPath = join(directory, NAME);
  await createEncryptedBackup({ databasePath: source, destination: backupPath, encryptionKey: key });
  return { directory, source, key, backupPath };
}

function fakeClient(handler = () => undefined) {
  const calls = [];
  return {
    calls,
    async send(command, options) {
      calls.push({ name: command.constructor.name, input: command.input, signal: options.abortSignal });
      const result = await handler(command, options);
      if (result !== undefined) return result;
      if (command.constructor.name === 'CreateMultipartUploadCommand') return { UploadId: 'test-upload' };
      if (command.constructor.name === 'UploadPartCommand') return { ETag: `part-${command.input.PartNumber}` };
      return {};
    },
  };
}

test('SDK mock receives only authenticated ciphertext, immutable daily key and SSE-S3 without public ACL', async t => {
  const f = await fixture(t);
  const client = fakeClient();
  const uploader = createS3BackupUploader(TARGET, { client });
  assert.deepEqual(await uploader.uploadBackup(f.backupPath), { key: 'maptalk/backups/2026-10-19.mtbak' });
  assert.deepEqual(client.calls.map(call => call.name), [
    'CreateMultipartUploadCommand', 'UploadPartCommand', 'CompleteMultipartUploadCommand',
  ]);
  for (const call of client.calls) {
    assert.equal(call.input.Bucket, TARGET.bucket);
    assert.equal(call.input.Key, 'maptalk/backups/2026-10-19.mtbak');
    assert.equal(call.input.ACL, undefined);
    assert.equal(call.signal.aborted, false);
  }
  assert.equal(client.calls[0].input.ServerSideEncryption, 'AES256');
  assert.equal(client.calls[0].input.StorageClass, 'STANDARD');
  assert.equal(client.calls.at(-1).input.IfNoneMatch, '*');
  const body = client.calls[1].input.Body;
  assert.deepEqual(body, await readFile(f.backupPath));
  assert.ok(!body.includes(Buffer.from('secret-location-and-owner')));
  assert.ok(!body.includes(Buffer.from('SQLite format 3')));
  uploader.close();
  await assert.rejects(uploader.uploadBackup(f.backupPath), /closed/);
});

test('multipart upload reads sequential bounded chunks and handles a final small part', async t => {
  const f = await fixture(t);
  const bytes = Buffer.alloc(8 * 1024 * 1024 + 1);
  Buffer.from('MTBAK001').copy(bytes);
  await writeFile(f.backupPath, bytes);
  let active = 0;
  let peak = 0;
  const client = fakeClient(async command => {
    if (command.constructor.name !== 'UploadPartCommand') return;
    active++;
    peak = Math.max(peak, active);
    assert.ok(command.input.Body.length <= 8 * 1024 * 1024);
    await new Promise(resolve => setTimeout(resolve, 5));
    active--;
  });
  const uploader = createS3BackupUploader(TARGET, { client });
  await uploader.uploadBackup(f.backupPath);
  assert.equal(peak, 1);
  assert.deepEqual(client.calls.filter(call => call.name === 'UploadPartCommand').map(call => call.input.ContentLength),
    [8 * 1024 * 1024, 1]);
});

test('rejects plaintext, incomplete files, symlinks and unsupported sizes before any AWS call', async t => {
  const f = await fixture(t);
  const client = fakeClient();
  const uploader = createS3BackupUploader(TARGET, { client });
  await assert.rejects(uploader.uploadBackup(f.source), /published encrypted/);
  await writeFile(f.backupPath, await readFile(f.source));
  await assert.rejects(uploader.uploadBackup(f.backupPath), /complete encrypted/);
  await writeFile(f.backupPath, 'MTBAK001');
  await assert.rejects(uploader.uploadBackup(f.backupPath), /complete encrypted/);
  await truncate(f.backupPath, MAX_S3_BACKUP_BYTES + 1);
  await assert.rejects(uploader.uploadBackup(f.backupPath), /complete encrypted/);
  await rm(f.backupPath);
  await symlink(f.source, f.backupPath);
  await assert.rejects(uploader.uploadBackup(f.backupPath));
  assert.equal(client.calls.length, 0);
});

test('a part failure aborts multipart upload and leaves the local encrypted backup restorable', async t => {
  const f = await fixture(t);
  const client = fakeClient(command => {
    if (command.constructor.name === 'UploadPartCommand') throw new Error('mock network failure');
  });
  const uploader = createS3BackupUploader(TARGET, { client });
  await assert.rejects(uploader.uploadBackup(f.backupPath), /mock network failure/);
  assert.equal(client.calls.at(-1).name, 'AbortMultipartUploadCommand');
  const restored = join(f.directory, 'restored.sqlite');
  await restoreEncryptedBackup({ backupPath: f.backupPath, destination: restored, encryptionKey: f.key });
  const db = new DatabaseSync(restored, { readOnly: true });
  try { assert.equal(db.prepare('SELECT body FROM private_data').get().body, 'secret-location-and-owner'); }
  finally { db.close(); }
});

test('only a completion precondition failure is daily deduplication; conflicts and failed parts remain failures', async t => {
  const f = await fixture(t);
  for (const [stage, status] of [
    ['CompleteMultipartUploadCommand', 412], ['CompleteMultipartUploadCommand', 409], ['UploadPartCommand', 412],
  ]) {
    const error = Object.assign(new Error('mock conditional failure'), { $metadata: { httpStatusCode: status } });
    const client = fakeClient(command => { if (command.constructor.name === stage) throw error; });
    const uploader = createS3BackupUploader(TARGET, { client });
    if (stage === 'CompleteMultipartUploadCommand' && status === 412) {
      assert.deepEqual(await uploader.uploadBackup(f.backupPath), { key: 'maptalk/backups/2026-10-19.mtbak', alreadyExists: true });
    } else await assert.rejects(uploader.uploadBackup(f.backupPath), error);
    assert.equal(client.calls.at(-1).name, 'AbortMultipartUploadCommand');
  }
});

test('overall deadline and shutdown abort are bounded even when a mock ignores the cancellation signal', async t => {
  const f = await fixture(t);
  const hanging = () => new Promise(() => {});
  const uploader = createS3BackupUploader(TARGET, { client: fakeClient(hanging), timeoutMs: 30, cleanupTimeoutMs: 30 });
  await assert.rejects(uploader.uploadBackup(f.backupPath), { code: 'BACKUP_UPLOAD_ABORTED' });
  const stopped = new AbortController();
  stopped.abort();
  const client = fakeClient();
  const cancelled = createS3BackupUploader(TARGET, { client });
  await assert.rejects(cancelled.uploadBackup(f.backupPath, { signal: stopped.signal }), { code: 'BACKUP_UPLOAD_ABORTED' });
  assert.equal(client.calls.length, 0);
});

test('multipart cleanup has its own bounded deadline and preserves the original failure', async t => {
  const f = await fixture(t);
  const client = fakeClient(command => {
    if (command.constructor.name === 'UploadPartCommand') throw new Error('original error');
    if (command.constructor.name === 'AbortMultipartUploadCommand') return new Promise(() => {});
  });
  const uploader = createS3BackupUploader(TARGET, { client, cleanupTimeoutMs: 20 });
  await assert.rejects(uploader.uploadBackup(f.backupPath), /original error/);
});

test('uploader validates configuration and rejects overlapping uploads', async t => {
  const f = await fixture(t);
  assert.throws(() => createS3BackupUploader({ ...TARGET, region: 'us-east-1' }, { client: fakeClient() }), /us-east-2/);
  assert.throws(() => createS3BackupUploader(TARGET, { client: fakeClient(), timeoutMs: 0 }), /timeouts/);
  const uploader = createS3BackupUploader(TARGET, { client: fakeClient(() => new Promise(() => {})), timeoutMs: 20 });
  const active = uploader.uploadBackup(f.backupPath);
  await assert.rejects(uploader.uploadBackup(f.backupPath), /already uploading/);
  await assert.rejects(active, { code: 'BACKUP_UPLOAD_ABORTED' });
});
