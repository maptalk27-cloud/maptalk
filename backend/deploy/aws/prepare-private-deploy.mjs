import { createPrivateKey, randomBytes, timingSafeEqual } from 'node:crypto';
import {
  chmodSync, closeSync, constants, fstatSync, lstatSync, mkdirSync, mkdtempSync,
  openSync, readFileSync, readdirSync, renameSync, rmdirSync, rmSync, writeFileSync,
} from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repository = fileURLToPath(new URL('../../../', import.meta.url));
const members = ['runtime.env', 'apple-sign-in.p8', 'compose.env'];
const archiveName = 'secrets.tar';
const publicRuntime = {
  MAPTALK_APPLE_CLIENT_ID: 'com.chengsi.maptalk',
  MAPTALK_APPLE_TEAM_ID: 'H28S4PM4KP',
  MAPTALK_APPLE_KEY_ID: 'P2TYDWHP4C',
  MAPTALK_BACKUP_S3_BUCKET: 'maptalk-beta-579072312038-us-east-2',
  MAPTALK_BACKUP_S3_PREFIX: 'maptalk/backups/',
};
const encryptionNames = ['MAPTALK_APPLE_TOKEN_ENCRYPTION_KEY', 'MAPTALK_BACKUP_ENCRYPTION_KEY'];
const compose = Object.entries({
  MAPTALK_DOMAIN: 'api.maptalkapp.com',
  MAPTALK_ENV_FILE: '/etc/maptalk/runtime.env',
  MAPTALK_APPLE_PRIVATE_KEY_HOST_PATH: '/etc/maptalk/apple-sign-in.p8',
  MAPTALK_DATA_DIRECTORY: '/srv/maptalk/data',
  MAPTALK_BACKUP_DIRECTORY_HOST: '/srv/maptalk/backups',
  MAPTALK_CADDY_DATA_DIRECTORY: '/srv/maptalk/caddy-data',
  MAPTALK_CADDY_CONFIG_DIRECTORY: '/srv/maptalk/caddy-config',
}).map(([key, value]) => `${key}=${value}\n`).join('');

function statIfPresent(path) {
  try { return lstatSync(path); } catch (error) {
    if (error.code === 'ENOENT') return undefined;
    throw error;
  }
}

function privatePath(path) {
  if (typeof path !== 'string' || !isAbsolute(path)) throw new Error('Use explicit absolute paths.');
  path = resolve(path);
  const fromRepository = relative(repository, path);
  if (!fromRepository || (!fromRepository.startsWith(`..${sep}`) && fromRepository !== '..' && !isAbsolute(fromRepository))) {
    throw new Error('Private deployment files must stay outside the repository.');
  }
  for (let cursor = path; ; cursor = dirname(cursor)) {
    if (statIfPresent(cursor)?.isSymbolicLink()) throw new Error('Symlinks are not allowed in private deployment paths.');
    if (dirname(cursor) === cursor) break;
  }
  return path;
}

function readPrivateFile(path, expectedMode) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.nlink !== 1 || stat.uid !== process.getuid() || stat.size > 65536) {
      throw new Error('Private deployment input must be a small, owned regular file without hard links.');
    }
    const mode = stat.mode & 0o777;
    if ((mode & 0o077) !== 0 || (expectedMode !== undefined && mode !== expectedMode)) {
      throw new Error('Private deployment file permissions are too broad or unexpected.');
    }
    return readFileSync(fd);
  } finally { closeSync(fd); }
}

function verifyAppleKey(pem) {
  let key;
  try { key = createPrivateKey({ key: pem, format: 'pem', type: 'pkcs8' }); } catch {
    throw new Error('Apple key must be an unencrypted P-256 private key.');
  }
  if (key.type !== 'private' || key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') {
    throw new Error('Apple key must be an unencrypted P-256 private key.');
  }
}

function tar(args) {
  const result = spawnSync('/usr/bin/tar', args, {
    env: { PATH: '/usr/bin:/bin', COPYFILE_DISABLE: '1' },
    maxBuffer: 65536, stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error || result.status !== 0) throw new Error('Private archive operation failed; no secret output was logged.');
  return result.stdout;
}

function verifyBundle(directory, appleKey) {
  const stat = lstatSync(directory);
  if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o777) !== 0o700) {
    throw new Error('Existing private output must be an owned directory with mode 0700.');
  }
  if (readdirSync(directory).sort().join('\n') !== [...members, archiveName].sort().join('\n')) {
    throw new Error('Existing output is incomplete or unexpected; refusing to regenerate keys.');
  }
  const runtime = readPrivateFile(join(directory, 'runtime.env'), 0o600).toString('utf8');
  const entries = runtime.trimEnd().split('\n').map(line => {
    const split = line.indexOf('=');
    return [line.slice(0, split), line.slice(split + 1)];
  });
  const env = Object.fromEntries(entries);
  const expectedNames = [...Object.keys(publicRuntime), ...encryptionNames].sort();
  if (entries.length !== expectedNames.length || Object.keys(env).sort().join() !== expectedNames.join()
      || Object.entries(publicRuntime).some(([key, value]) => env[key] !== value)) {
    throw new Error('Existing runtime configuration differs; refusing to overwrite it.');
  }
  const keys = encryptionNames.map(name => Buffer.from(env[name], 'base64'));
  if (keys.some((key, index) => key.length !== 32 || key.toString('base64') !== env[encryptionNames[index]])
      || timingSafeEqual(keys[0], keys[1])) {
    throw new Error('Existing encryption keys are invalid or not independent; refusing to regenerate them.');
  }
  if (!readPrivateFile(join(directory, 'apple-sign-in.p8'), 0o400).equals(appleKey)
      || readPrivateFile(join(directory, 'compose.env'), 0o600).toString('utf8') !== compose) {
    throw new Error('Existing private deployment inputs differ; refusing to overwrite them.');
  }
  const archive = join(directory, archiveName);
  readPrivateFile(archive, 0o600);
  if (tar(['-tf', archive]).toString('utf8').trimEnd().split('\n').sort().join() !== [...members].sort().join()) {
    throw new Error('Private archive contains unexpected entries.');
  }
  for (const name of members) {
    if (!tar(['-xOf', archive, '--', name]).equals(readPrivateFile(join(directory, name)))) {
      throw new Error('Private archive does not match its source files; refusing to replace it.');
    }
  }
}

// First creation commits one complete directory. Reruns never rotate keys or overwrite files.
export function preparePrivateDeploy({ appleKeyPath, outputDirectory }) {
  appleKeyPath = privatePath(appleKeyPath);
  outputDirectory = privatePath(outputDirectory);
  const appleKey = readPrivateFile(appleKeyPath);
  verifyAppleKey(appleKey);
  const parent = dirname(outputDirectory);
  if (!statIfPresent(parent)?.isDirectory()) throw new Error('Create the private output parent directory first.');
  const lock = `${outputDirectory}.prepare-lock`;
  try { mkdirSync(lock, { mode: 0o700 }); } catch {
    throw new Error('Cannot acquire private deployment lock; another preparation may be running.');
  }
  let staging;
  try {
    if (statIfPresent(outputDirectory)) {
      verifyBundle(outputDirectory, appleKey);
      return { directory: outputDirectory, archive: join(outputDirectory, archiveName), reused: true };
    }
    staging = mkdtempSync(join(parent, '.maptalk-private-'));
    chmodSync(staging, 0o700);
    const env = { ...publicRuntime };
    for (const name of encryptionNames) env[name] = randomBytes(32).toString('base64');
    const runtime = Object.entries(env).map(([key, value]) => `${key}=${value}\n`).join('');
    writeFileSync(join(staging, 'runtime.env'), runtime, { mode: 0o600, flag: 'wx' });
    writeFileSync(join(staging, 'apple-sign-in.p8'), appleKey, { mode: 0o400, flag: 'wx' });
    writeFileSync(join(staging, 'compose.env'), compose, { mode: 0o600, flag: 'wx' });
    const archive = join(staging, archiveName);
    writeFileSync(archive, '', { mode: 0o600, flag: 'wx' });
    tar(['-cf', archive, '-C', staging, '--', ...members]);
    verifyBundle(staging, appleKey);
    if (statIfPresent(outputDirectory)) throw new Error('Output appeared during preparation; refusing to overwrite it.');
    renameSync(staging, outputDirectory);
    staging = undefined;
    return { directory: outputDirectory, archive: join(outputDirectory, archiveName), reused: false };
  } finally {
    if (staging) rmSync(staging, { recursive: true, force: true });
    rmdirSync(lock);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args.length !== 4 || args[0] !== '--apple-key' || args[2] !== '--output-dir') {
      throw new Error('Usage: node prepare-private-deploy.mjs --apple-key /absolute/key.p8 --output-dir /absolute/new-private-directory');
    }
    const result = preparePrivateDeploy({ appleKeyPath: args[1], outputDirectory: args[3] });
    console.log(`Private deployment bundle ${result.reused ? 'verified and reused' : 'prepared'}. No secret values were printed.`);
  } catch (error) {
    // Filesystem/crypto/subprocess errors must never dump input bytes or subprocess output.
    console.error(error.code ? `Private preparation failed (${error.code}).` : error.message);
    process.exitCode = 1;
  }
}
