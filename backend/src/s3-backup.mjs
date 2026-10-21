import { constants } from 'node:fs';
import { open } from 'node:fs/promises';
import { basename } from 'node:path';
import {
  AbortMultipartUploadCommand, CompleteMultipartUploadCommand, CreateMultipartUploadCommand,
  S3Client, UploadPartCommand,
} from '@aws-sdk/client-s3';
import { readS3BackupConfig } from './runtime-config.mjs';

const PART_BYTES = 8 * 1024 * 1024;
// Explicit supported bound keeps each sequential part at 8 MiB, including SDK
// retries, rather than growing the part size with the database.
export const MAX_S3_BACKUP_BYTES = PART_BYTES * 10_000;
const BACKUP_NAME = /^maptalk-backup-(\d{4}-\d{2}-\d{2})T\d{2}-\d{2}-\d{2}\.\d{3}Z-[a-f0-9-]{36}\.mtbak$/;
const MAGIC = Buffer.from('MTBAK001');

function abortError() {
  return Object.assign(new Error('Encrypted S3 backup upload was cancelled or timed out.'), { code: 'BACKUP_UPLOAD_ABORTED' });
}

// Also bounds a credential provider or a test client that ignores abortSignal.
// The SDK still receives the signal to cancel its actual HTTP request.
async function send(client, command, signal) {
  if (signal.aborted) throw abortError();
  let listener;
  try {
    return await Promise.race([
      client.send(command, { abortSignal: signal }),
      new Promise((_, reject) => {
        listener = () => reject(abortError());
        signal.addEventListener('abort', listener, { once: true });
        if (signal.aborted) listener();
      }),
    ]);
  } finally {
    if (listener) signal.removeEventListener('abort', listener);
  }
}

/** Uploads only published encrypted scheduler artifacts. Bucket provisioning,
 * Block Public Access, TLS-only policy and lifecycle are deployment prerequisites:
 * expire this prefix after 7 days and abort incomplete multipart uploads after
 * 1 day (also expire noncurrent versions if versioning is enabled).
 * This adapter never creates buckets, changes policy, or sends a public ACL.
 */
export function createS3BackupUploader(configuration, {
  client, timeoutMs = 300_000, cleanupTimeoutMs = 5_000,
} = {}) {
  const target = readS3BackupConfig({
    MAPTALK_DEPLOYMENT_TARGET: 'aws', AWS_REGION: configuration?.region,
    MAPTALK_BACKUP_S3_BUCKET: configuration?.bucket, MAPTALK_BACKUP_S3_PREFIX: configuration?.prefix,
  }, { mode: 'beta' });
  for (const value of [timeoutMs, cleanupTimeoutMs]) {
    if (!Number.isSafeInteger(value) || value < 1 || value > 300_000) throw new Error('S3 backup timeouts must be 1–300000 milliseconds.');
  }
  const ownsClient = !client;
  client ??= new S3Client({
    region: target.region, maxAttempts: 3, retryMode: 'standard',
    followRegionRedirects: false, ignoreConfiguredEndpointUrls: true,
    requestHandler: { connectionTimeout: 5_000, requestTimeout: 30_000, throwOnRequestTimeout: true,
      httpsAgent: { keepAlive: true, maxSockets: 2 } },
    // No static credentials, profile override, endpoint or logger: use the SDK's
    // default credential chain (the EC2 instance role in the AWS deployment).
  });
  let busy = false;
  let closed = false;
  return {
    targetID: `s3:${target.region}:${target.bucket}:${target.prefix}`,
    async uploadBackup(backupPath, { signal: shutdownSignal } = {}) {
      if (closed || busy) throw new Error('S3 backup uploader is closed or already uploading.');
      const match = BACKUP_NAME.exec(basename(backupPath));
      if (!match) throw new Error('S3 backup upload requires a published encrypted .mtbak artifact.');
      const key = `${target.prefix}${match[1]}.mtbak`;
      const deadline = new AbortController();
      const timer = setTimeout(() => deadline.abort(), timeoutMs);
      const signal = shutdownSignal ? AbortSignal.any([deadline.signal, shutdownSignal]) : deadline.signal;
      let file;
      let uploadID;
      let completing = false;
      busy = true;
      try {
        // O_NOFOLLOW rejects symlinks, and all reads share this one file handle.
        file = await open(backupPath, constants.O_RDONLY | constants.O_NOFOLLOW);
        const details = await file.stat();
        const header = Buffer.alloc(20);
        const { bytesRead } = await file.read(header, 0, header.length, 0);
        if (!details.isFile() || details.size <= 36 || details.size > MAX_S3_BACKUP_BYTES
          || bytesRead !== header.length || !header.subarray(0, 8).equals(MAGIC)) {
          throw new Error('S3 backup upload requires a complete encrypted artifact within the supported size limit.');
        }
        const created = await send(client, new CreateMultipartUploadCommand({
          Bucket: target.bucket, Key: key, ContentType: 'application/octet-stream',
          ServerSideEncryption: 'AES256', StorageClass: 'STANDARD',
          Metadata: { format: 'MTBAK001' },
        }), signal);
        uploadID = created.UploadId;
        if (!uploadID) throw new Error('S3 did not return an encrypted backup upload ID.');
        const parts = [];
        for (let offset = 0; offset < details.size;) {
          if (signal.aborted) throw abortError();
          const body = Buffer.allocUnsafe(Math.min(PART_BYTES, details.size - offset));
          let filled = 0;
          while (filled < body.length) {
            const result = await file.read(body, filled, body.length - filled, offset + filled);
            if (result.bytesRead === 0) throw new Error('Encrypted backup changed during upload.');
            filled += result.bytesRead;
          }
          const partNumber = parts.length + 1;
          const part = await send(client, new UploadPartCommand({
            Bucket: target.bucket, Key: key, UploadId: uploadID, PartNumber: partNumber,
            Body: body, ContentLength: body.length,
          }), signal);
          if (!part.ETag) throw new Error('S3 did not acknowledge an encrypted backup part.');
          parts.push({ ETag: part.ETag, PartNumber: partNumber });
          offset += body.length;
        }
        const after = await file.stat();
        if (after.size !== details.size || after.mtimeMs !== details.mtimeMs) throw new Error('Encrypted backup changed during upload.');
        completing = true;
        await send(client, new CompleteMultipartUploadCommand({
          Bucket: target.bucket, Key: key, UploadId: uploadID, MultipartUpload: { Parts: parts },
          // One immutable object per UTC date, even after crashes or restarts.
          IfNoneMatch: '*',
        }), signal);
        uploadID = undefined;
        return { key };
      } catch (error) {
        // A completed daily object already exists; do not replace it or create
        // another version. A 409 conflict or any other failure is not success.
        if (completing && (error?.name === 'PreconditionFailed' || error?.$metadata?.httpStatusCode === 412)) {
          return { key, alreadyExists: true };
        }
        throw error;
      } finally {
        clearTimeout(timer);
        try {
          if (uploadID) {
            const cleanup = new AbortController();
            const cleanupTimer = setTimeout(() => cleanup.abort(), cleanupTimeoutMs);
            try {
              await send(client, new AbortMultipartUploadCommand({
                Bucket: target.bucket, Key: key, UploadId: uploadID,
              }), cleanup.signal);
            } catch { /* Lifecycle must remove parts if cleanup cannot reach S3. */ }
            finally { clearTimeout(cleanupTimer); }
          }
        } finally {
          await file?.close();
          busy = false;
        }
      }
    },
    close() {
      closed = true;
      if (ownsClient) client.destroy();
    },
  };
}
