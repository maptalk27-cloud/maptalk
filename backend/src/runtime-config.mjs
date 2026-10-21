import { readFileSync } from 'node:fs';
import { isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deploymentConfiguration } from './beta.mjs';
import { userMediaLimitBytes } from './media-storage.mjs';

/** Pure validation only: never resolves credentials or contacts AWS. */
export function readS3BackupConfig(env = process.env, { mode = 'local' } = {}) {
  const target = env.MAPTALK_DEPLOYMENT_TARGET ?? 'local';
  if (!['local', 'aws'].includes(target)) throw new Error('MAPTALK_DEPLOYMENT_TARGET must be local or aws.');
  if (target === 'local') {
    if (env.MAPTALK_BACKUP_S3_BUCKET !== undefined || env.MAPTALK_BACKUP_S3_PREFIX !== undefined) {
      throw new Error('S3 backup configuration requires MAPTALK_DEPLOYMENT_TARGET=aws.');
    }
    return undefined;
  }
  if (mode !== 'beta') throw new Error('AWS deployment requires MAPTALK_MODE=beta.');
  if (env.AWS_REGION !== 'us-east-2') throw new Error('AWS deployment requires AWS_REGION=us-east-2.');
  const bucket = env.MAPTALK_BACKUP_S3_BUCKET;
  // Intentionally accept only conventional general-purpose bucket names, not
  // access point aliases/ARNs, directory buckets, endpoints, or dotted names.
  if (typeof bucket !== 'string' || !/^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/.test(bucket)
    || /^(xn--|sthree-|amzn-s3-demo-)/.test(bucket)
    || /(-s3alias|--ol-s3|--x-s3|--table-s3)$/.test(bucket)) {
    throw new Error('MAPTALK_BACKUP_S3_BUCKET must be a plain private general-purpose bucket name.');
  }
  const prefix = env.MAPTALK_BACKUP_S3_PREFIX ?? 'maptalk/backups/';
  if (typeof prefix !== 'string' || prefix.length > 200
    || !/^(?:[A-Za-z0-9_-]+\/)+$/.test(prefix)) {
    throw new Error('MAPTALK_BACKUP_S3_PREFIX must be a nonempty safe path ending in / (at most 200 characters).');
  }
  return { region: 'us-east-2', bucket, prefix };
}

export function readConfig(env = process.env) {
  const mediaLimit = env.MAPTALK_USER_MEDIA_LIMIT_BYTES;
  if (mediaLimit !== undefined && (typeof mediaLimit !== 'string' || !/^[1-9]\d*$/.test(mediaLimit))) {
    throw new Error('MAPTALK_USER_MEDIA_LIMIT_BYTES must be a positive integer byte count.');
  }
  const storageLimit = userMediaLimitBytes(mediaLimit === undefined ? undefined : Number(mediaLimit));
  const deployment = deploymentConfiguration({ mode: env.MAPTALK_MODE ?? 'local',
    publicOrigin: env.MAPTALK_PUBLIC_ORIGIN, bind: env.MAPTALK_BIND ?? env.HOST ?? '127.0.0.1' });
  const beta = deployment.mode === 'beta';
  const s3 = readS3BackupConfig(env, deployment);
  if (env.NODE_ENV === 'production' && !beta) throw new Error('Production requires explicit MAPTALK_MODE=beta.');
  const port = Number(env.PORT ?? 8787);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be 1–65535.');
  const databasePath = env.MAPTALK_DATABASE ?? fileURLToPath(new URL('../data/maptalk.sqlite', import.meta.url));
  if (beta && (!env.MAPTALK_DATABASE || !isAbsolute(databasePath))) throw new Error('Beta requires an absolute persistent MAPTALK_DATABASE path.');
  let privateKey;
  if (env.MAPTALK_APPLE_PRIVATE_KEY_PATH) {
    try { privateKey = readFileSync(env.MAPTALK_APPLE_PRIVATE_KEY_PATH, 'utf8'); }
    catch { throw new Error('Cannot read the configured Apple private key file.'); }
  }
  let backup;
  if (beta) {
    const encryptionKey = env.MAPTALK_BACKUP_ENCRYPTION_KEY;
    const directory = env.MAPTALK_BACKUP_DIRECTORY;
    if (!directory || !isAbsolute(directory) || typeof encryptionKey !== 'string'
      || Buffer.from(encryptionKey, 'base64').length !== 32
      || Buffer.from(encryptionKey, 'base64').toString('base64') !== encryptionKey) {
      throw new Error('Beta requires MAPTALK_BACKUP_DIRECTORY and a base64 32-byte MAPTALK_BACKUP_ENCRYPTION_KEY.');
    }
    backup = { databasePath, backupDirectory: directory, encryptionKey, s3 };
  }
  return {
    port, backup, deploymentTarget: env.MAPTALK_DEPLOYMENT_TARGET ?? 'local',
    backend: {
      databasePath, deployment, userMediaLimitBytes: storageLimit,
      apple: { clientID: env.MAPTALK_APPLE_CLIENT_ID, teamID: env.MAPTALK_APPLE_TEAM_ID,
        keyID: env.MAPTALK_APPLE_KEY_ID, privateKey, encryptionKey: env.MAPTALK_APPLE_TOKEN_ENCRYPTION_KEY },
      google: { iosClientID: env.MAPTALK_GOOGLE_IOS_CLIENT_ID, serverClientID: env.MAPTALK_GOOGLE_SERVER_CLIENT_ID,
        clientSecret: env.MAPTALK_GOOGLE_CLIENT_SECRET },
      wechat: { appID: env.MAPTALK_WECHAT_APP_ID, appSecret: env.MAPTALK_WECHAT_APP_SECRET },
    },
  };
}
