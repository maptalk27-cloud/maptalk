import { isAbsolute } from 'node:path';
import { createEncryptedBackup, restoreEncryptedBackup } from '../src/backup-scheduler.mjs';

const [action, sourceOrDestination, restoreDestination, ...extra] = process.argv.slice(2);
const encryptionKey = process.env.MAPTALK_BACKUP_ENCRYPTION_KEY;
if (!['create', 'restore'].includes(action) || extra.length
  || !isAbsolute(sourceOrDestination ?? '')
  || (action === 'create' && restoreDestination)
  || (action === 'restore' && !isAbsolute(restoreDestination ?? ''))) {
  throw new Error('Use create /absolute/new.mtbak OR restore /absolute/backup.mtbak /absolute/new.sqlite. Set MAPTALK_BACKUP_ENCRYPTION_KEY in the environment.');
}
if (action === 'create') {
  if (!isAbsolute(process.env.MAPTALK_DATABASE ?? '')) throw new Error('Set an absolute MAPTALK_DATABASE.');
  await createEncryptedBackup({ databasePath: process.env.MAPTALK_DATABASE,
    destination: sourceOrDestination, encryptionKey });
  console.log('Encrypted backup created. Keep an off-site copy and its key separately.');
} else {
  await restoreEncryptedBackup({ backupPath: sourceOrDestination,
    destination: restoreDestination, encryptionKey });
  console.log('Backup authenticated and restored to a new database. Do not switch the live service until restore checks and deletion reconciliation are complete.');
}
