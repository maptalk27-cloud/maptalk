import { fileURLToPath } from 'node:url';
import { backupDatabase } from '../src/backup.mjs';

const destination = process.argv[2];
if (!destination) {
  console.error('Usage: npm run backup -- /absolute/path/to/new-backup.sqlite');
  process.exitCode = 1;
} else {
  const source = process.env.MAPTALK_DATABASE ?? fileURLToPath(new URL('../data/maptalk.sqlite', import.meta.url));
  await backupDatabase(source, destination);
  console.log('Backup complete. Keep this file private; it contains account data and photos.');
}
