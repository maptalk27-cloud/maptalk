import { accessSync, constants, realpathSync, statSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createAppleLifecycle } from '../src/apple-lifecycle.mjs';
import { readConfig } from '../src/runtime-config.mjs';
import { containerConfiguration } from './container-healthcheck.mjs';

// Local checks only: no database is opened, credentials resolved, or AWS API called.
export function checkDeploymentConfiguration(env = process.env) {
  containerConfiguration(env);
  const configuration = readConfig(env);
  if (configuration.deploymentTarget !== 'aws' || !configuration.backup?.s3) {
    throw new Error('AWS deployment requires MAPTALK_DEPLOYMENT_TARGET=aws and an S3 backup target.');
  }
  if (!createAppleLifecycle(configuration.backend.apple).configured) {
    throw new Error('The first AWS beta requires complete Apple sign-in and account-deletion configuration.');
  }
  if (configuration.backup.encryptionKey === configuration.backend.apple.encryptionKey) {
    throw new Error('Use separate encryption keys for backups and Apple tokens.');
  }
  if (resolve(configuration.backend.databasePath) === resolve(configuration.backup.backupDirectory)) {
    throw new Error('The database file and backup directory must be different paths.');
  }
  return configuration;
}

function requireWritableDirectory(path, description) {
  try {
    const information = statSync(path);
    if (!information.isDirectory()) throw new Error();
    accessSync(path, constants.R_OK | constants.W_OK | constants.X_OK);
    return { path: realpathSync(path), dev: information.dev, ino: information.ino };
  } catch {
    throw new Error(`${description} must exist and be readable/writable by the container user.`);
  }
}

export function checkDeploymentFiles(configuration, { effectiveUID = process.geteuid?.() } = {}) {
  const database = configuration.backend.databasePath;
  const dataDirectory = requireWritableDirectory(dirname(database), 'Persistent data directory');
  const backupDirectory = requireWritableDirectory(configuration.backup.backupDirectory, 'Backup directory');
  if (dataDirectory.path === backupDirectory.path
    || (dataDirectory.dev === backupDirectory.dev && dataDirectory.ino === backupDirectory.ino)) {
    throw new Error('Use a separate directory for encrypted backups, not the database directory itself.');
  }
  for (const [path, label] of [[database, 'database'], [`${database}-wal`, 'SQLite WAL'], [`${database}-shm`, 'SQLite SHM']]) {
    let information;
    try { information = statSync(path); } catch (error) {
      if (error.code === 'ENOENT') continue;
      throw new Error(`An existing ${label} must be a readable/writable regular file.`);
    }
    if (effectiveUID !== undefined && information.uid !== effectiveUID) {
      throw new Error(`An existing ${label} must be owned by the container user; fix restored file ownership before startup.`);
    }
    try {
      if (!information.isFile()) throw new Error();
      accessSync(path, constants.R_OK | constants.W_OK);
    } catch {
      throw new Error(`An existing ${label} must be a readable/writable regular file.`);
    }
  }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  try {
    if (process.argv.length !== 2) throw new Error('This preflight accepts no arguments; use the runtime environment.');
    const configuration = checkDeploymentConfiguration();
    checkDeploymentFiles(configuration);
    console.log('Local AWS configuration checks passed. No cloud resources were created.');
    console.log('Still required before invitations: cost approval, DNS/TLS, real Apple login, S3 upload/restore, and two-device privacy checks.');
  } catch (error) {
    console.error(`Preflight failed: ${error.message}`);
    process.exitCode = 1;
  }
}
