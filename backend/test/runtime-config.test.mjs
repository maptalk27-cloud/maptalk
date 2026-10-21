import test from 'node:test';
import assert from 'node:assert/strict';
import { readConfig, readS3BackupConfig } from '../src/runtime-config.mjs';

const BETA = {
  MAPTALK_MODE: 'beta', MAPTALK_PUBLIC_ORIGIN: 'https://beta.example.test',
  MAPTALK_DATABASE: '/tmp/maptalk-test-data/maptalk.sqlite',
  MAPTALK_BACKUP_DIRECTORY: '/tmp/maptalk-test-backups',
  MAPTALK_BACKUP_ENCRYPTION_KEY: Buffer.alloc(32, 7).toString('base64'),
};
const AWS = { ...BETA, MAPTALK_DEPLOYMENT_TARGET: 'aws', AWS_REGION: 'us-east-2',
  MAPTALK_BACKUP_S3_BUCKET: 'maptalk-private-backup-test' };

test('media storage budget keeps the 50 MiB default and accepts only explicit finite operator limits', () => {
  assert.equal(readConfig({}).backend.userMediaLimitBytes, 50 * 1024 * 1024);
  assert.equal(readConfig({ MAPTALK_USER_MEDIA_LIMIT_BYTES: String(100 * 1024 * 1024) }).backend.userMediaLimitBytes, 100 * 1024 * 1024);
  for (const value of ['', '0', '-1', 'Infinity', 'NaN', '1e9', ' 1048576', '1048576.5', '1048575', '1073741825']) {
    assert.throws(() => readConfig({ MAPTALK_USER_MEDIA_LIMIT_BYTES: value }), /media limit|MEDIA_LIMIT/);
  }
});

test('local mode never configures uploads; existing local beta requires no AWS credentials', () => {
  assert.equal(readConfig({}).backup, undefined);
  assert.equal(readConfig({}).deploymentTarget, 'local');
  assert.equal(readConfig(BETA).backup.s3, undefined);
  assert.throws(() => readConfig({ MAPTALK_BACKUP_S3_BUCKET: AWS.MAPTALK_BACKUP_S3_BUCKET }), /requires.*aws/);
  assert.throws(() => readConfig({ ...BETA, MAPTALK_BACKUP_S3_PREFIX: 'backup/' }), /requires.*aws/);
});

test('AWS deployment explicitly requires beta, selected Region and bucket, without accepting credential inputs', () => {
  const configuration = readConfig(AWS);
  assert.equal(configuration.deploymentTarget, 'aws');
  assert.deepEqual(configuration.backup.s3, { region: 'us-east-2', bucket: AWS.MAPTALK_BACKUP_S3_BUCKET, prefix: 'maptalk/backups/' });
  assert.deepEqual(readS3BackupConfig(AWS, { mode: 'beta' }), configuration.backup.s3);
  assert.throws(() => readConfig({ ...AWS, MAPTALK_MODE: 'local', MAPTALK_PUBLIC_ORIGIN: undefined }), /requires.*beta/);
  for (const region of [undefined, 'us-east-1', 'eu-west-1', '', ' us-east-2']) {
    assert.throws(() => readConfig({ ...AWS, AWS_REGION: region }), /AWS_REGION=us-east-2/);
  }
  assert.throws(() => readConfig({ ...AWS, MAPTALK_BACKUP_S3_BUCKET: undefined }), /bucket name/);
  assert.throws(() => readConfig({ ...AWS, MAPTALK_DEPLOYMENT_TARGET: 'other' }), /local or aws/);
});

test('rejects ambiguous bucket addressing and unsafe object prefixes without echoing supplied values', () => {
  for (const bucket of ['https://example.test', 'arn:aws:s3:::backup', 'A-bucket', 'a', 'a..b',
    'my--x-s3', 'my-s3alias', 'xn--bucket', 'secret%value', 'a'.repeat(64)]) {
    assert.throws(() => readConfig({ ...AWS, MAPTALK_BACKUP_S3_BUCKET: bucket }), error => {
      assert.equal(error.message, 'MAPTALK_BACKUP_S3_BUCKET must be a plain private general-purpose bucket name.');
      return true;
    });
  }
  for (const prefix of ['', '/', '../', 'a/../', 'a//b/', '/a/', 'a', 'a?b/', 'a%2fb/', 'a/'.repeat(101)]) {
    assert.throws(() => readConfig({ ...AWS, MAPTALK_BACKUP_S3_PREFIX: prefix }), /safe path ending/);
  }
  assert.equal(readConfig({ ...AWS, MAPTALK_BACKUP_S3_PREFIX: 'project-1/private_backups/' }).backup.s3.prefix, 'project-1/private_backups/');
});
