import { DatabaseSync, backup } from 'node:sqlite';
import { chmod, copyFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { constants } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

export async function backupDatabase(source, destination) {
  const target = resolve(destination);
  if (resolve(source) === target) throw new Error('Backup must not replace the source database.');
  await mkdir(dirname(target), { recursive: true, mode: 0o700 });
  const temporary = await mkdtemp(join(dirname(target), '.maptalk-backup-'));
  let database;
  try {
    database = new DatabaseSync(resolve(source), { readOnly: true });
    const staging = join(temporary, 'snapshot.sqlite');
    await backup(database, staging);
    await chmod(staging, 0o600);
    // The staging file is complete, including WAL contents. Never overwrite an
    // existing backup, and never copy a live SQLite database with plain cp.
    await copyFile(staging, target, constants.COPYFILE_EXCL);
    await chmod(target, 0o600);
    return target;
  } finally {
    database?.close();
    await rm(temporary, { recursive: true, force: true });
  }
}
