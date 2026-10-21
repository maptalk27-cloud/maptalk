import assert from 'node:assert/strict';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { chmodSync, linkSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { preparePrivateDeploy } from '../deploy/aws/prepare-private-deploy.mjs';
import { uploadSecrets } from '../deploy/aws/upload-secrets.mjs';

const names = ['apple-sign-in', 'apple-token-encryption', 'backup-encryption'].map(name => `maptalk/private-beta/${name}`);
const arnFor = name => `arn:aws:secretsmanager:us-east-2:579072312038:secret:${name}-abc123`;

function fixture(t) {
  const directory = mkdtempSync(join(realpathSync(tmpdir()), 'maptalk-secret-upload-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const appleKeyPath = join(directory, 'source.p8');
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  writeFileSync(appleKeyPath, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o400 });
  const bundleDirectory = join(directory, 'private');
  preparePrivateDeploy({ appleKeyPath, outputDirectory: bundleDirectory });
  const runtimePath = join(bundleDirectory, 'runtime.env');
  const env = Object.fromEntries(readFileSync(runtimePath, 'utf8').trimEnd().split('\n').map(line => {
    const index = line.indexOf('=');
    return [line.slice(0, index), line.slice(index + 1)];
  }));
  return { directory, bundleDirectory, runtimePath, values: [readFileSync(appleKeyPath, 'utf8'), env.MAPTALK_APPLE_TOKEN_ENCRYPTION_KEY, env.MAPTALK_BACKUP_ENCRYPTION_KEY] };
}

function mockService() {
  const stored = new Map();
  const calls = [];
  const error = name => Object.assign(new Error('DO-NOT-LOG-THIS-SERVICE-ERROR'), { name });
  const services = {
    async getCallerIdentity(input, options) {
      calls.push({ method: 'identity', input, options });
      return { Account: '579072312038', Arn: 'arn:aws:sts::579072312038:assumed-role/AccountFullAccessRole/test' };
    },
    async describeSecret(input, options) {
      calls.push({ method: 'describe', input, options });
      const found = stored.get(input.SecretId);
      if (!found) throw error('ResourceNotFoundException');
      return { Name: found.Name, ARN: arnFor(found.Name), Tags: found.Tags, ...found.description };
    },
    async getSecretValue(input, options) {
      calls.push({ method: 'get', input, options });
      const found = [...stored.values()].find(item => arnFor(item.Name) === input.SecretId);
      if (!found) throw error('ResourceNotFoundException');
      return { Name: found.Name, ARN: arnFor(found.Name), SecretString: found.SecretString, VersionId: found.ClientRequestToken, VersionStages: ['AWSCURRENT'], ...found.response };
    },
    async createSecret(input, options) {
      calls.push({ method: 'create', input, options });
      if (stored.has(input.Name)) throw error('ResourceExistsException');
      stored.set(input.Name, structuredClone(input));
      return { Name: input.Name, ARN: arnFor(input.Name), VersionId: input.ClientRequestToken };
    },
  };
  return { stored, calls, services, error };
}

function seed(mock, data, index) {
  const name = names[index];
  mock.stored.set(name, {
    Name: name, SecretString: data.values[index], ClientRequestToken: randomUUID(),
    Tags: Object.entries({ project: 'MapTalk', environment: 'private-beta', 'managed-by': 'Codex', purpose: name.split('/').at(-1) }).map(([Key, Value]) => ({ Key, Value })),
  });
}

test('uploads exactly three existing secrets after identity and full preflight; no replicas or customer key', async t => {
  const data = fixture(t);
  const mock = mockService();
  const before = readFileSync(data.runtimePath);
  const result = await uploadSecrets({ ...data, services: mock.services });
  assert.deepEqual(mock.calls.slice(0, 4).map(call => call.method), ['identity', 'describe', 'describe', 'describe']);
  const creates = mock.calls.filter(call => call.method === 'create');
  assert.equal(creates.length, 3);
  assert.deepEqual(creates.map(call => call.input.Name), names);
  assert.deepEqual(creates.map(call => call.input.SecretString), data.values);
  for (const { input, options } of creates) {
    assert.deepEqual(Object.keys(input).sort(), ['ClientRequestToken', 'Description', 'Name', 'SecretString', 'Tags']);
    assert.equal(options.abortSignal.aborted, false);
    assert.match(input.ClientRequestToken, /^[a-f\d-]{36}$/);
  }
  assert.deepEqual(result.map(item => item.name), names);
  for (const item of result) assert.deepEqual(Object.keys(item).sort(), ['arn', 'name', 'versionId']);
  for (const value of data.values) assert.ok(!JSON.stringify(result).includes(value));
  assert.deepEqual(readFileSync(data.runtimePath), before);
});

test('reruns compare existing current values and never overwrite or rotate', async t => {
  const data = fixture(t);
  const mock = mockService();
  const first = await uploadSecrets({ ...data, services: mock.services });
  mock.calls.length = 0;
  assert.deepEqual(await uploadSecrets({ ...data, services: mock.services }), first);
  assert.equal(mock.calls.filter(call => call.method === 'create').length, 0);
  assert.equal(mock.calls.filter(call => call.method === 'get').length, 3);
});

test('wrong AWS project fails before any Secrets Manager operations', async t => {
  const data = fixture(t);
  const mock = mockService();
  mock.services.getCallerIdentity = async () => ({ Account: '000000000000', Arn: 'arn:aws:sts::000000000000:assumed-role/test/test' });
  await assert.rejects(uploadSecrets({ ...data, services: mock.services }), /WRONG_AWS_PROJECT/);
  assert.deepEqual(mock.calls, []);
});

test('existing value mismatch fails before creating other missing secrets and never leaks either value', async t => {
  const data = fixture(t);
  const mock = mockService();
  seed(mock, data, 2);
  mock.stored.get(names[2]).SecretString = 'SECRET-SENTINEL';
  await assert.rejects(uploadSecrets({ ...data, services: mock.services }), error => {
    assert.match(error.message, /EXISTING_SECRET_VALUE_MISMATCH/);
    assert.ok(!error.message.includes('SECRET-SENTINEL'));
    assert.ok(!error.message.includes(data.values[2]));
    return true;
  });
  assert.equal(mock.calls.filter(call => call.method === 'create').length, 0);
});

test('existing secrets require matching ownership tags, names and project-region ARN', async t => {
  for (const alteration of [
    item => { item.Tags = []; },
    item => { item.description = { Name: 'unrelated' }; },
    item => { item.description = { ARN: arnFor(item.Name).replace('us-east-2', 'us-east-1') }; },
    item => { item.Tags.push({ ...item.Tags[0] }); },
    item => { item.description = { DeletedDate: new Date() }; },
    item => { item.description = { KmsKeyId: 'customer-managed-key' }; },
    item => { item.description = { ReplicationStatus: [{ Region: 'us-west-2' }] }; },
    item => { item.description = { PrimaryRegion: 'us-west-2' }; },
    item => { item.description = { RotationEnabled: true }; },
  ]) {
    const data = fixture(t);
    const mock = mockService();
    seed(mock, data, 0);
    alteration(mock.stored.get(names[0]));
    await assert.rejects(uploadSecrets({ ...data, services: mock.services }), /EXISTING_SECRET_SCOPE_MISMATCH/);
    assert.equal(mock.calls.filter(call => call.method === 'create').length, 0);
    assert.equal(mock.calls.filter(call => call.method === 'get').length, 0);
  }
});

test('a same-region primary secret with AWS-managed encryption can be reused', async t => {
  const data = fixture(t);
  const mock = mockService();
  for (let index = 0; index < names.length; index += 1) {
    seed(mock, data, index);
    mock.stored.get(names[index]).description = { PrimaryRegion: 'us-east-2', ReplicationStatus: [] };
  }
  assert.equal((await uploadSecrets({ ...data, services: mock.services })).length, 3);
  assert.equal(mock.calls.filter(call => call.method === 'create').length, 0);
});

test('concurrent create only reuses exact matching values', async t => {
  const data = fixture(t);
  const mock = mockService();
  mock.services.createSecret = async input => {
    mock.stored.set(input.Name, structuredClone(input));
    throw mock.error('ResourceExistsException');
  };
  assert.equal((await uploadSecrets({ ...data, services: mock.services })).length, 3);
});

test('untrusted SDK messages are discarded on failure', async t => {
  const data = fixture(t);
  const mock = mockService();
  mock.services.createSecret = async () => { throw mock.error('AccessDeniedException'); };
  await assert.rejects(uploadSecrets({ ...data, services: mock.services }), error => {
    assert.match(error.message, /ACCESS_DENIED/);
    assert.ok(!error.message.includes('DO-NOT-LOG'));
    assert.equal(error.cause, undefined);
    return true;
  });
});

test('deadline aborts the request and does not advance to create', async t => {
  const data = fixture(t);
  const mock = mockService();
  let signal;
  mock.services.getCallerIdentity = (_, options) => { signal = options.abortSignal; return new Promise(() => {}); };
  await assert.rejects(uploadSecrets({ ...data, services: mock.services, deadlineMs: 30 }), /DEADLINE_EXCEEDED/);
  assert.equal(signal.aborted, true);
  assert.deepEqual(mock.calls, []);
});

test('unsafe file modes, symlinks, hard links, and directory modes fail before AWS calls', async t => {
  for (const modify of [
    data => chmodSync(data.runtimePath, 0o644),
    data => chmodSync(data.bundleDirectory, 0o755),
    data => linkSync(data.runtimePath, join(data.directory, 'hard-link')),
    data => { rmSync(data.runtimePath); symlinkSync(join(data.directory, 'source.p8'), data.runtimePath); },
    data => { const alias = join(data.directory, 'alias'); symlinkSync(data.bundleDirectory, alias); data.bundleDirectory = alias; },
  ]) {
    const data = fixture(t);
    const mock = mockService();
    modify(data);
    await assert.rejects(uploadSecrets({ ...data, services: mock.services }), /UNSAFE|SYMLINK_REJECTED/);
    assert.deepEqual(mock.calls, []);
  }
});

test('invalid, duplicate or altered deployment configuration never reaches AWS', async t => {
  for (const modify of [
    text => text.replace('com.chengsi.maptalk', 'com.unrelated.app'),
    text => `${text}MAPTALK_APPLE_CLIENT_ID=com.chengsi.maptalk\n`,
    text => text.replace(/MAPTALK_BACKUP_ENCRYPTION_KEY=.*/, 'MAPTALK_BACKUP_ENCRYPTION_KEY=not-a-key'),
  ]) {
    const data = fixture(t);
    const mock = mockService();
    writeFileSync(data.runtimePath, modify(readFileSync(data.runtimePath, 'utf8')));
    await assert.rejects(uploadSecrets({ ...data, services: mock.services }), /INVALID_RUNTIME|INVALID_ENCRYPTION_KEYS/);
    assert.deepEqual(mock.calls, []);
  }
});

test('CLI requires a confirmation flag before SDK loading or private-file access', () => {
  const result = spawnSync(process.execPath, ['deploy/aws/upload-secrets.mjs'], { cwd: new URL('../', import.meta.url), encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
  assert.match(result.stderr, /EXPLICIT_UPLOAD_CONFIRMATION_REQUIRED/);
  assert.ok(!result.stderr.includes('Error:'));
});
