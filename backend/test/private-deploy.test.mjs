import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import {
  chmodSync, existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync,
  realpathSync, rmSync, statSync, symlinkSync, writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { preparePrivateDeploy } from '../deploy/aws/prepare-private-deploy.mjs';

function fixture(t, curve = 'prime256v1') {
  const directory = mkdtempSync(join(realpathSync(tmpdir()), 'maptalk-private-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const appleKeyPath = join(directory, 'source.p8');
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: curve });
  writeFileSync(appleKeyPath, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o400 });
  return { directory, appleKeyPath, outputDirectory: join(directory, 'private') };
}

test('private deployment preparation creates only the intended secure files and archive', t => {
  const fixtureData = fixture(t);
  const result = preparePrivateDeploy(fixtureData);
  assert.equal(result.reused, false);
  assert.equal(statSync(result.directory).mode & 0o777, 0o700);
  assert.deepEqual(readdirSync(result.directory).sort(), ['apple-sign-in.p8', 'compose.env', 'runtime.env', 'secrets.tar']);
  for (const name of ['compose.env', 'runtime.env', 'secrets.tar']) {
    assert.equal(statSync(join(result.directory, name)).mode & 0o777, 0o600);
  }
  assert.equal(statSync(join(result.directory, 'apple-sign-in.p8')).mode & 0o777, 0o400);
  const runtime = readFileSync(join(result.directory, 'runtime.env'), 'utf8');
  const env = Object.fromEntries(runtime.trimEnd().split('\n').map(line => {
    const split = line.indexOf('=');
    return [line.slice(0, split), line.slice(split + 1)];
  }));
  assert.equal(env.MAPTALK_APPLE_CLIENT_ID, 'com.chengsi.maptalk');
  assert.equal(env.MAPTALK_BACKUP_S3_BUCKET, 'maptalk-beta-579072312038-us-east-2');
  assert.equal(Buffer.from(env.MAPTALK_APPLE_TOKEN_ENCRYPTION_KEY, 'base64').length, 32);
  assert.equal(Buffer.from(env.MAPTALK_BACKUP_ENCRYPTION_KEY, 'base64').length, 32);
  assert.notEqual(env.MAPTALK_APPLE_TOKEN_ENCRYPTION_KEY, env.MAPTALK_BACKUP_ENCRYPTION_KEY);
  assert.doesNotMatch(runtime, /AWS_ACCESS_KEY|AWS_SECRET_ACCESS|AWS_SESSION_TOKEN/);
  assert.match(readFileSync(join(result.directory, 'compose.env'), 'utf8'), /MAPTALK_DOMAIN=api\.maptalkapp\.com/);
  const archive = spawnSync('/usr/bin/tar', ['-tf', result.archive], { encoding: 'utf8' });
  assert.equal(archive.status, 0);
  assert.deepEqual(archive.stdout.trimEnd().split('\n').sort(), ['apple-sign-in.p8', 'compose.env', 'runtime.env']);
});

test('rerun preserves every file and encryption key byte for byte', t => {
  const data = fixture(t);
  preparePrivateDeploy(data);
  const names = readdirSync(data.outputDirectory);
  const before = new Map(names.map(name => [name, readFileSync(join(data.outputDirectory, name))]));
  const result = preparePrivateDeploy(data);
  assert.equal(result.reused, true);
  for (const name of names) assert.deepEqual(readFileSync(join(data.outputDirectory, name)), before.get(name));
});

test('incomplete output fails closed without replacing remaining keys or files', t => {
  const data = fixture(t);
  preparePrivateDeploy(data);
  const runtime = readFileSync(join(data.outputDirectory, 'runtime.env'));
  rmSync(join(data.outputDirectory, 'secrets.tar'));
  assert.throws(() => preparePrivateDeploy(data), /incomplete.*refusing to regenerate/);
  assert.deepEqual(readFileSync(join(data.outputDirectory, 'runtime.env')), runtime);
  assert.equal(existsSync(`${data.outputDirectory}.prepare-lock`), false);
});

test('invalid Apple input never creates a partial bundle or logs the input', t => {
  const data = fixture(t, 'secp384r1');
  assert.throws(() => preparePrivateDeploy(data), /P-256 private key/);
  chmodSync(data.appleKeyPath, 0o600);
  const sentinel = 'invalid-credential-sentinel';
  writeFileSync(data.appleKeyPath, sentinel);
  assert.throws(() => preparePrivateDeploy(data), error => /P-256/.test(error.message) && !error.message.includes(sentinel));
  assert.equal(existsSync(data.outputDirectory), false);
  assert.deepEqual(readdirSync(data.directory), ['source.p8']);
});

test('source, output, and parent symlinks are rejected without following them', t => {
  const data = fixture(t);
  const sourceAlias = join(data.directory, 'source-alias.p8');
  symlinkSync(data.appleKeyPath, sourceAlias);
  assert.throws(() => preparePrivateDeploy({ ...data, appleKeyPath: sourceAlias }), /Symlinks/);
  const actual = join(data.directory, 'actual');
  mkdirSync(actual, { mode: 0o700 });
  symlinkSync(actual, data.outputDirectory);
  assert.throws(() => preparePrivateDeploy(data), /Symlinks/);
  assert.throws(() => preparePrivateDeploy({ ...data, outputDirectory: join(data.outputDirectory, 'nested') }), /Symlinks/);
  assert.deepEqual(readdirSync(actual), []);
});

test('rerun rejects a changed Apple identity and broad file permissions', t => {
  const data = fixture(t);
  preparePrivateDeploy(data);
  const other = fixture(t);
  assert.throws(() => preparePrivateDeploy({ ...data, appleKeyPath: other.appleKeyPath }), /inputs differ/);
  chmodSync(join(data.outputDirectory, 'runtime.env'), 0o644);
  assert.throws(() => preparePrivateDeploy(data), /permissions/);
});

test('partial and invalid archives are not silently regenerated', t => {
  const data = fixture(t);
  preparePrivateDeploy(data);
  const runtime = readFileSync(join(data.outputDirectory, 'runtime.env'));
  writeFileSync(join(data.outputDirectory, 'secrets.tar'), 'broken archive');
  assert.throws(() => preparePrivateDeploy(data), /archive operation failed/);
  assert.deepEqual(readFileSync(join(data.outputDirectory, 'runtime.env')), runtime);
});
