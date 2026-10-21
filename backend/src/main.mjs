import { createBackend } from './server.mjs';
import { readConfig } from './runtime-config.mjs';
import { startBackupScheduler } from './backup-scheduler.mjs';

const configuration = readConfig();
const backend = createBackend(configuration.backend);
let backups;
let offsite;
try {
  if (configuration.backup?.s3) {
    const { createS3BackupUploader } = await import('./s3-backup.mjs');
    offsite = createS3BackupUploader(configuration.backup.s3);
  }
  if (configuration.backup) backups = startBackupScheduler({ ...configuration.backup,
    uploadBackup: offsite?.uploadBackup, uploadTargetID: offsite?.targetID,
    onError: () => console.error('Encrypted backup failed. Operator action is required.') });
  const { url } = await backend.listen(configuration.port);
  console.log(configuration.backend.deployment.mode === 'beta'
    ? 'MapTalk private beta started behind the configured HTTPS origin. Invitations are required; public posts are immediately visible.'
    : `MapTalk local backend: ${url}`);
} catch (error) {
  await backups?.stop();
  offsite?.close();
  await backend.close();
  throw error;
}
let stopping = false;
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, async () => {
    if (stopping) return;
    stopping = true;
    await backups?.stop();
    offsite?.close();
    await backend.close();
    process.exit(0);
  });
}
