import { writeFileSync } from 'node:fs';
import { isAbsolute } from 'node:path';
import { openDatabase } from '../src/database.mjs';
import { issueInvite, moderateMemory, revokeBetaAccess } from '../src/beta.mjs';

// Administrative access is an explicit local/container command, never an HTTP
// endpoint. Run as the service operator against the backed-up writable DB.
const [command, ...args] = process.argv.slice(2);
const options = new Map();
for (let i = 0; i < args.length; i += 2) {
  if (!args[i]?.startsWith('--') || !args[i + 1] || options.has(args[i])) throw new Error('Use unique --option value pairs.');
  options.set(args[i], args[i + 1]);
}
const allowed = { issue: ['--hours'], revoke: ['--user', '--invite'], pending: [], reports: [],
  approve: ['--memory'], reject: ['--memory'], 'export-media': ['--media', '--output'] };
if (!allowed[command] || [...options.keys()].some(key => !allowed[command].includes(key))) {
  throw new Error('Commands: issue [--hours 168], revoke --user ID|--invite ID, pending, reports, approve|reject --memory ID, export-media --media ID --output /absolute/path.');
}
if (!process.env.MAPTALK_DATABASE) throw new Error('Set MAPTALK_DATABASE explicitly before using the beta administration command.');
const uuid = value => {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value ?? '')) throw new Error('Expected a UUID.');
  return value.toLowerCase();
};
const db = openDatabase(process.env.MAPTALK_DATABASE);
try {
  if (command === 'issue') {
    console.log(JSON.stringify(issueInvite(db, { hours: Number(options.get('--hours') ?? 168) }), null, 2));
    console.error('Copy this code now. The database stores only its hash. Send privately to one intended tester.');
  } else if (command === 'revoke') {
    revokeBetaAccess(db, { userID: options.has('--user') ? uuid(options.get('--user')) : undefined,
      inviteID: options.has('--invite') ? uuid(options.get('--invite')) : undefined });
    console.log('Access revoked. Existing sessions cannot access content.');
  } else if (command === 'approve' || command === 'reject') {
    moderateMemory(db, uuid(options.get('--memory')), command);
    console.log(`Memory ${command === 'approve' ? 'approved' : 'rejected'}.`);
  } else if (command === 'pending') {
    const rows = db.prepare(`SELECT id, owner_id AS ownerId, kind, caption, created_at AS createdAt
      FROM memories WHERE visibility = 'public' AND moderation_status = 'pending' ORDER BY created_at LIMIT 100`).all();
    for (const row of rows) row.media = db.prepare('SELECT media_id AS id FROM memory_media WHERE memory_id = ? ORDER BY position').all(row.id);
    console.log(JSON.stringify(rows, null, 2));
  } else if (command === 'reports') {
    console.log(JSON.stringify(db.prepare(`SELECT id, memory_id AS memoryId, reason, created_at AS createdAt
      FROM content_reports ORDER BY created_at DESC LIMIT 100`).all(), null, 2));
  } else {
    const media = db.prepare('SELECT bytes FROM media WHERE id = ?').get(uuid(options.get('--media')));
    if (!media) throw new Error('Media not found.');
    const output = options.get('--output');
    if (!output || !isAbsolute(output)) throw new Error('Choose an absolute output path. Existing files will not be overwritten.');
    writeFileSync(output, media.bytes, { flag: 'wx', mode: 0o600 });
    console.log('Private review copy written. Delete the exported copy after review; it is not managed by account deletion.');
  }
} finally { db.close(); }
