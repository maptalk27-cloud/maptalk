import { createHash, createPrivateKey, randomUUID, timingSafeEqual } from 'node:crypto';
import { closeSync, constants, fstatSync, lstatSync, openSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const region = 'us-east-2';
const profile = 'maptalk';
const project = '579072312038';
const repository = fileURLToPath(new URL('../../../', import.meta.url));
const defaultBundle = '/Users/chengsya/.config/maptalk/secrets/private-beta-20261020';
const definitions = [
  { name: 'maptalk/private-beta/apple-sign-in', purpose: 'apple-sign-in' },
  { name: 'maptalk/private-beta/apple-token-encryption', purpose: 'apple-token-encryption' },
  { name: 'maptalk/private-beta/backup-encryption', purpose: 'backup-encryption' },
];
const publicRuntime = {
  MAPTALK_APPLE_CLIENT_ID: 'com.chengsi.maptalk',
  MAPTALK_APPLE_TEAM_ID: 'H28S4PM4KP',
  MAPTALK_APPLE_KEY_ID: 'P2TYDWHP4C',
  MAPTALK_BACKUP_S3_BUCKET: 'maptalk-beta-579072312038-us-east-2',
  MAPTALK_BACKUP_S3_PREFIX: 'maptalk/backups/',
};
const keyNames = ['MAPTALK_APPLE_TOKEN_ENCRYPTION_KEY', 'MAPTALK_BACKUP_ENCRYPTION_KEY'];

class UploadError extends Error {
  constructor(code) { super(`Secret upload stopped (${code}). No secret values were logged.`); this.code = code; }
}

function fail(code) { throw new UploadError(code); }

function privatePath(path) {
  if (typeof path !== 'string' || !isAbsolute(path)) fail('PRIVATE_PATH_REQUIRED');
  path = resolve(path);
  const fromRepository = relative(repository, path);
  if (!fromRepository || (!fromRepository.startsWith(`..${sep}`) && fromRepository !== '..' && !isAbsolute(fromRepository))) {
    fail('PRIVATE_PATH_REQUIRED');
  }
  for (let cursor = path; ; cursor = dirname(cursor)) {
    if (lstatSync(cursor).isSymbolicLink()) fail('SYMLINK_REJECTED');
    if (dirname(cursor) === cursor) break;
  }
  return path;
}

function readPrivateFile(directory, name, mode) {
  const fd = openSync(privatePath(join(directory, name)), constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.nlink !== 1 || stat.uid !== process.getuid()
        || (stat.mode & 0o777) !== mode || stat.size === 0 || stat.size > 8192) fail('UNSAFE_PRIVATE_FILE');
    return readFileSync(fd, 'utf8');
  } finally { closeSync(fd); }
}

function sameSecret(left, right) {
  // Fixed-size digests avoid a length-dependent comparison or accidental value logging.
  return timingSafeEqual(createHash('sha256').update(left).digest(), createHash('sha256').update(right).digest());
}

function readExistingValues(directory) {
  directory = privatePath(directory);
  const stat = lstatSync(directory);
  if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o777) !== 0o700) fail('UNSAFE_PRIVATE_DIRECTORY');
  const pem = readPrivateFile(directory, 'apple-sign-in.p8', 0o400);
  let key;
  try { key = createPrivateKey({ key: pem, format: 'pem', type: 'pkcs8' }); } catch { fail('INVALID_APPLE_KEY'); }
  if (key.type !== 'private' || key.asymmetricKeyType !== 'ec'
      || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') fail('INVALID_APPLE_KEY');
  const text = readPrivateFile(directory, 'runtime.env', 0o600);
  const pairs = text.trimEnd().split('\n').map(line => {
    const split = line.indexOf('=');
    if (split < 1) fail('INVALID_RUNTIME');
    return [line.slice(0, split), line.slice(split + 1)];
  });
  const env = Object.fromEntries(pairs);
  const expectedNames = [...Object.keys(publicRuntime), ...keyNames].sort();
  if (pairs.length !== expectedNames.length || Object.keys(env).sort().join() !== expectedNames.join()
      || Object.entries(publicRuntime).some(([name, value]) => env[name] !== value)) fail('INVALID_RUNTIME');
  const keys = keyNames.map(name => Buffer.from(env[name], 'base64'));
  if (keys.some((bytes, index) => bytes.length !== 32 || bytes.toString('base64') !== env[keyNames[index]])
      || timingSafeEqual(keys[0], keys[1])) fail('INVALID_ENCRYPTION_KEYS');
  keys.forEach(bytes => bytes.fill(0));
  return [pem, ...keyNames.map(name => env[name])];
}

function tagsFor(definition) {
  return Object.entries({ project: 'MapTalk', environment: 'private-beta', 'managed-by': 'Codex', purpose: definition.purpose })
    .map(([Key, Value]) => ({ Key, Value }));
}

function validateDescription(description, definition) {
  const prefix = `arn:aws:secretsmanager:${region}:${project}:secret:${definition.name}-`;
  const arn = description?.ARN;
  const tags = description?.Tags;
  if (description?.Name !== definition.name || typeof arn !== 'string' || !arn.startsWith(prefix)
      || !/^[A-Za-z0-9]{6}$/.test(arn.slice(prefix.length)) || !Array.isArray(tags)
      || new Set(tags.map(tag => tag.Key)).size !== tags.length
      || tagsFor(definition).some(expected => !tags.some(tag => tag.Key === expected.Key && tag.Value === expected.Value))
      || description.DeletedDate || description.RotationEnabled
      || (description.PrimaryRegion && description.PrimaryRegion !== region)
      || (description.ReplicationStatus?.length ?? 0) > 0
      || (description.KmsKeyId && description.KmsKeyId !== 'alias/aws/secretsmanager')) fail('EXISTING_SECRET_SCOPE_MISMATCH');
  return arn;
}

function sanitizeError(error) {
  if (error instanceof UploadError) return error;
  const code = {
    AccessDeniedException: 'ACCESS_DENIED', UnrecognizedClientException: 'AUTHENTICATION_FAILED',
    ExpiredTokenException: 'AUTHENTICATION_EXPIRED', CredentialsProviderError: 'AUTHENTICATION_FAILED',
    ThrottlingException: 'THROTTLED', AbortError: 'DEADLINE_EXCEEDED', TimeoutError: 'DEADLINE_EXCEEDED',
    ResourceExistsException: 'CONCURRENT_CREATE', ResourceNotFoundException: 'SECRET_NOT_FOUND',
  }[error?.name] ?? 'OPERATION_FAILED';
  return new UploadError(code);
}

// Services are injected in tests; the CLI below always constructs the fixed AWS clients.
// This helper only creates missing secrets. It never updates, rotates, deletes, or prints values.
export async function uploadSecrets({ services, bundleDirectory = defaultBundle, deadlineMs = 180_000 }) {
  try {
    if (!Number.isInteger(deadlineMs) || deadlineMs < 1 || deadlineMs > 180_000) fail('INVALID_DEADLINE');
    const deadline = Date.now() + deadlineMs;
    const values = readExistingValues(bundleDirectory);
    async function call(method, input) {
      const remaining = Math.min(30_000, deadline - Date.now());
      if (remaining <= 0) fail('DEADLINE_EXCEEDED');
      const controller = new AbortController();
      let timer;
      try {
        return await Promise.race([
          Promise.resolve().then(() => services[method](input, { abortSignal: controller.signal })),
          new Promise((_, reject) => {
            timer = setTimeout(() => {
              controller.abort();
              reject(new UploadError('DEADLINE_EXCEEDED'));
            }, remaining);
          }),
        ]);
      } finally { clearTimeout(timer); }
    }
    const identity = await call('getCallerIdentity', {});
    if (identity?.Account !== project || typeof identity.Arn !== 'string'
        || !identity.Arn.startsWith(`arn:aws:sts::${project}:assumed-role/`)) fail('WRONG_AWS_PROJECT');

    async function verify(definition, description, expectedValue) {
      const arn = validateDescription(description, definition);
      const result = await call('getSecretValue', { SecretId: arn, VersionStage: 'AWSCURRENT' });
      if (result?.Name !== definition.name || result.ARN !== arn
          || typeof result.VersionId !== 'string' || !/^[A-Za-z0-9-]{32,64}$/.test(result.VersionId)
          || !result.VersionStages?.includes('AWSCURRENT') || typeof result.SecretString !== 'string'
          || result.SecretBinary !== undefined || !sameSecret(result.SecretString, expectedValue)) fail('EXISTING_SECRET_VALUE_MISMATCH');
      return { name: definition.name, arn, versionId: result.VersionId };
    }

    const results = [];
    // Preflight all names before the first write: a collision must not create other secrets.
    for (const [index, definition] of definitions.entries()) {
      let description;
      try { description = await call('describeSecret', { SecretId: definition.name }); } catch (error) {
        if (error?.name !== 'ResourceNotFoundException') throw error;
      }
      results[index] = description ? await verify(definition, description, values[index]) : undefined;
    }
    for (const [index, definition] of definitions.entries()) {
      if (results[index]) continue;
      try {
        await call('createSecret', {
          Name: definition.name,
          ClientRequestToken: randomUUID(),
          Description: `MapTalk private beta ${definition.purpose}. Existing credential; no automatic rotation.`,
          SecretString: values[index],
          Tags: tagsFor(definition),
          // No KmsKeyId: use AWS-managed aws/secretsmanager. No replica Regions.
        });
      } catch (error) {
        if (error?.name !== 'ResourceExistsException') throw error;
        // Another create may have won the race. Only an exact match is reusable.
      }
      results[index] = await verify(definition, await call('describeSecret', { SecretId: definition.name }), values[index]);
    }
    return results;
  } catch (error) { throw sanitizeError(error); }
}

export function createAwsServices(sdkDirectory) {
  if (typeof sdkDirectory !== 'string' || !isAbsolute(sdkDirectory)) fail('SDK_DIRECTORY_REQUIRED');
  // Package-root imports from an external installation keep deployment-only SDKs out of the app.
  const require = createRequire(join(resolve(sdkDirectory), 'package.json'));
  const { SecretsManagerClient, DescribeSecretCommand, GetSecretValueCommand, CreateSecretCommand } = require('@aws-sdk/client-secrets-manager');
  const { STSClient, GetCallerIdentityCommand } = require('@aws-sdk/client-sts');
  const { fromIni } = require('@aws-sdk/credential-providers');
  const config = {
    region, profile, credentials: fromIni({ profile, clientConfig: { region } }), maxAttempts: 2,
    requestHandler: { connectionTimeout: 5_000, requestTimeout: 25_000 },
  };
  // Explicit endpoints prevent environment/config endpoint overrides from receiving credentials.
  const sm = new SecretsManagerClient({ ...config, endpoint: `https://secretsmanager.${region}.amazonaws.com` });
  const sts = new STSClient({ ...config, endpoint: `https://sts.${region}.amazonaws.com` });
  return {
    getCallerIdentity: (input, options) => sts.send(new GetCallerIdentityCommand(input), options),
    describeSecret: (input, options) => sm.send(new DescribeSecretCommand(input), options),
    getSecretValue: (input, options) => sm.send(new GetSecretValueCommand(input), options),
    createSecret: (input, options) => sm.send(new CreateSecretCommand(input), options),
    close: () => { sm.destroy(); sts.destroy(); },
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let services;
  try {
    const args = process.argv.slice(2);
    if (args.length !== 3 || args[0] !== '--sdk-dir' || args[2] !== '--confirm-upload') fail('EXPLICIT_UPLOAD_CONFIRMATION_REQUIRED');
    services = createAwsServices(args[1]);
    console.log(JSON.stringify(await uploadSecrets({ services })));
  } catch (error) {
    console.error(sanitizeError(error).message);
    process.exitCode = 1;
  } finally { services?.close(); }
}
