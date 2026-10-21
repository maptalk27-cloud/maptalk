import assert from 'node:assert/strict';
import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { mkdtempSync, mkdirSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { checkDeploymentConfiguration, checkDeploymentFiles } from '../scripts/deployment-preflight.mjs';

function fixture(t) {
  const directory = mkdtempSync(join(tmpdir(), 'maptalk-preflight-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const keyPath = join(directory, 'apple.p8');
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  writeFileSync(keyPath, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
  mkdirSync(join(directory, 'data'));
  mkdirSync(join(directory, 'backups'));
  const env = {
    NODE_ENV: 'production', MAPTALK_MODE: 'beta', MAPTALK_DEPLOYMENT_TARGET: 'aws',
    MAPTALK_DOMAIN: 'api.maptalk.app', MAPTALK_PUBLIC_ORIGIN: 'https://api.maptalk.app',
    MAPTALK_DATABASE: join(directory, 'data', 'maptalk.sqlite'),
    MAPTALK_BACKUP_DIRECTORY: join(directory, 'backups'),
    MAPTALK_BACKUP_ENCRYPTION_KEY: randomBytes(32).toString('base64'),
    MAPTALK_APPLE_TOKEN_ENCRYPTION_KEY: randomBytes(32).toString('base64'),
    MAPTALK_APPLE_CLIENT_ID: 'com.test.maptalk',
    MAPTALK_APPLE_TEAM_ID: 'AAAAAAAAAA', MAPTALK_APPLE_KEY_ID: 'BBBBBBBBBB',
    MAPTALK_APPLE_PRIVATE_KEY_PATH: keyPath,
    AWS_REGION: 'us-east-2', MAPTALK_BACKUP_S3_BUCKET: 'maptalk-preflight-fixture',
  };
  return { env, directory };
}

test('AWS preflight validates files and Apple keys without opening a database or accessing AWS', t => {
  const { env } = fixture(t);
  const configuration = checkDeploymentConfiguration(env);
  assert.equal(configuration.backup.s3.region, 'us-east-2');
  checkDeploymentFiles(configuration);
  assert.throws(() => statSync(env.MAPTALK_DATABASE), { code: 'ENOENT' });
});

test('preflight fails closed for wrong region, missing off-machine backup, or placeholder domain', t => {
  const { env } = fixture(t);
  assert.throws(() => checkDeploymentConfiguration({ ...env, AWS_REGION: 'us-east-1' }));
  assert.throws(() => checkDeploymentConfiguration({ ...env, MAPTALK_BACKUP_S3_BUCKET: '' }));
  assert.throws(() => checkDeploymentConfiguration({ ...env,
    MAPTALK_DOMAIN: 'api.example.com', MAPTALK_PUBLIC_ORIGIN: 'https://api.example.com' }));
});

test('preflight rejects incomplete Apple deletion support and shared encryption keys without echoing secrets', t => {
  const { env } = fixture(t);
  assert.throws(() => checkDeploymentConfiguration({ ...env, MAPTALK_APPLE_TEAM_ID: '' }), /complete Apple/);
  assert.throws(() => checkDeploymentConfiguration({ ...env,
    MAPTALK_APPLE_TOKEN_ENCRYPTION_KEY: env.MAPTALK_BACKUP_ENCRYPTION_KEY }), /separate encryption keys/);
  const secret = 'not-a-valid-secret-value';
  assert.throws(() => checkDeploymentConfiguration({ ...env, MAPTALK_APPLE_TOKEN_ENCRYPTION_KEY: secret }),
    error => error.message.includes('canonical base64') && !error.message.includes(secret));
});

test('preflight requires existing writable directories and a regular database file', t => {
  const { env, directory } = fixture(t);
  let configuration = checkDeploymentConfiguration(env);
  mkdirSync(env.MAPTALK_DATABASE);
  assert.throws(() => checkDeploymentFiles(configuration), /regular file/);
  rmSync(env.MAPTALK_DATABASE, { recursive: true });
  configuration = checkDeploymentConfiguration({ ...env, MAPTALK_BACKUP_DIRECTORY: join(directory, 'absent') });
  assert.throws(() => checkDeploymentFiles(configuration), /Backup directory must exist/);
  configuration = checkDeploymentConfiguration({ ...env, MAPTALK_BACKUP_DIRECTORY: join(directory, 'data') });
  assert.throws(() => checkDeploymentFiles(configuration), /separate directory/);
});

test('preflight rejects directory aliases and unusable existing SQLite sidecars', t => {
  const { env, directory } = fixture(t);
  symlinkSync(join(directory, 'data'), join(directory, 'data-alias'));
  const alias = checkDeploymentConfiguration({ ...env, MAPTALK_BACKUP_DIRECTORY: join(directory, 'data-alias') });
  assert.throws(() => checkDeploymentFiles(alias), /separate directory/);
  const configuration = checkDeploymentConfiguration(env);
  writeFileSync(env.MAPTALK_DATABASE, '');
  mkdirSync(`${env.MAPTALK_DATABASE}-wal`);
  assert.throws(() => checkDeploymentFiles(configuration), /SQLite WAL/);
});

test('preflight rejects an existing database not owned by the runtime UID', t => {
  const { env } = fixture(t);
  writeFileSync(env.MAPTALK_DATABASE, '');
  const configuration = checkDeploymentConfiguration(env);
  const actualOwner = statSync(env.MAPTALK_DATABASE).uid;
  assert.throws(() => checkDeploymentFiles(configuration, { effectiveUID: actualOwner + 1 }), /owned by the container user/);
});
