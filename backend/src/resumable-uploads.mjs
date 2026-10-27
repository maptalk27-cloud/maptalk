import { randomUUID } from 'node:crypto';
import { transaction } from './database.mjs';
import { digest } from './security.mjs';
import { mediaJSON } from './user-profile.mjs';
import { normalizeVideo, VIDEO_LIMITS } from './video-processing.mjs';

export const UPLOAD_CHUNK_SIZE = 512 * 1024;
export const UPLOAD_TTL = 7 * 24 * 60 * 60 * 1000;
export class ResumableUploadError extends Error {
  constructor(status, code, message) { super(message); Object.assign(this, { status, code }); }
}
const fail = (status, code, message) => { throw new ResumableUploadError(status, code, message); };
const conflict = () => fail(409, 'idempotency_conflict', 'Use a new upload ID for different media.');

// Staging is private SQLite data on the existing encrypted data volume, never
// addressable through /media. Every accepted chunk and its offset commit together.
export function createResumableUploads({ db, now, storageLimit, assertOwner, normalize = normalizeVideo }) {
  const processing = new Set();
  const keyFor = (owner, key) => `${owner}:${key}`;
  const session = (owner, key) => db.prepare('SELECT * FROM media_upload_sessions WHERE owner_id = ? AND request_id = ?').get(owner, key);
  const receipt = (owner, key) => {
    const row = db.prepare('SELECT * FROM media_upload_requests WHERE owner_id = ? AND request_id = ?').get(owner, key);
    if (row && !row.media_id) fail(410, 'media_deleted', 'This upload was removed. Select the media again to upload a new copy.');
    return row;
  };
  function expire() {
    db.prepare(`DELETE FROM media_upload_sessions WHERE updated_at <= ?
      AND NOT EXISTS (SELECT 1 FROM media_upload_requests r WHERE r.owner_id = media_upload_sessions.owner_id
        AND r.request_id = media_upload_sessions.request_id)`).run(now() - UPLOAD_TTL);
  }
  function checkQuota(owner, extra, excludingKey = '') {
    const used = db.prepare('SELECT COALESCE(SUM(byte_count), 0) AS n FROM media WHERE owner_id = ?').get(owner).n;
    const reserved = db.prepare(`SELECT COALESCE(SUM(s.byte_count), 0) AS n FROM media_upload_sessions s
      WHERE s.owner_id = ? AND s.request_id != ? AND NOT EXISTS
      (SELECT 1 FROM media_upload_requests r WHERE r.owner_id = s.owner_id AND r.request_id = s.request_id)`).get(owner, excludingKey).n;
    if (used + reserved + extra > storageLimit) fail(413, 'media_quota',
      `Your media storage is full (${Math.round(storageLimit / 1024 / 1024)} MiB). Delete photos, videos or posts you no longer need, or cancel another pending upload, then retry. Media still in another post or your avatar keeps using storage.`);
  }
  function result(owner, key) {
    const saved = receipt(owner, key);
    const pending = session(owner, key);
    const media = saved && db.prepare('SELECT id, mime_type, byte_count FROM media WHERE id = ? AND owner_id = ?').get(saved.media_id, owner);
    if (!pending && !media) fail(404, 'not_found', 'Upload not found. Start the upload again.');
    // Legacy completed uploads have no source-length receipt until their first
    // PUT. Their accepted media still recovers without retransmitting its body.
    return { uploadID: key, mimeType: pending?.mime_type ?? media.mime_type,
      byteCount: pending?.byte_count ?? media.byte_count,
      receivedBytes: media ? (pending?.byte_count ?? media.byte_count) : pending.received_bytes,
      chunkSize: UPLOAD_CHUNK_SIZE, ...(media ? { media: mediaJSON(media) } : {}) };
  }
  function begin(owner, key, input) {
    if (input.mimeType !== 'video/mp4' || !Number.isSafeInteger(input.byteCount) || input.byteCount < 1
      || input.byteCount > VIDEO_LIMITS.inputBytes || typeof input.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(input.sha256)) {
      fail(422, 'invalid_request', 'Provide an MP4 size up to 20 MiB and its SHA-256 hash.');
    }
    expire();
    return transaction(db, () => {
      assertOwner(owner);
      const saved = receipt(owner, key);
      if (saved && saved.request_hash !== digest(`${input.mimeType}:${input.sha256}`)) conflict();
      const pending = session(owner, key);
      if (pending && (pending.mime_type !== input.mimeType || pending.byte_count !== input.byteCount || pending.sha256 !== input.sha256)) conflict();
      if (!pending) {
        if (!saved) {
          const count = db.prepare(`SELECT COUNT(*) AS n FROM media_upload_sessions s WHERE s.owner_id = ?
            AND NOT EXISTS (SELECT 1 FROM media_upload_requests r WHERE r.owner_id = s.owner_id AND r.request_id = s.request_id)`).get(owner).n;
          if (count >= 9) fail(429, 'upload_busy', 'Finish or cancel another pending upload first.');
          checkQuota(owner, input.byteCount);
        }
        db.prepare(`INSERT INTO media_upload_sessions(owner_id, request_id, mime_type, byte_count, sha256, received_bytes, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)`).run(owner, key, input.mimeType, input.byteCount, input.sha256,
          saved ? input.byteCount : 0, now(), now());
      } else db.prepare('UPDATE media_upload_sessions SET updated_at = ? WHERE owner_id = ? AND request_id = ?').run(now(), owner, key);
      return result(owner, key);
    });
  }
  function status(owner, key) { expire(); assertOwner(owner); return result(owner, key); }
  function append(owner, key, offset, bytes) {
    expire();
    return transaction(db, () => {
      assertOwner(owner);
      if (receipt(owner, key)) return result(owner, key);
      const pending = session(owner, key);
      if (!pending) fail(404, 'not_found', 'Upload not found. Start the upload again.');
      if (!Number.isSafeInteger(offset) || offset < 0 || offset > pending.received_bytes || offset % UPLOAD_CHUNK_SIZE !== 0)
        fail(409, 'upload_offset_mismatch', 'Check the accepted upload offset and continue from there.');
      // Fixed-sized aligned chunks bound staging rows to 40 per 20 MiB video;
      // accepting 1-byte chunks would bypass the storage reservation via overhead.
      if (!Buffer.isBuffer(bytes) || !bytes.length || bytes.length !== Math.min(UPLOAD_CHUNK_SIZE, pending.byte_count - offset))
        fail(422, 'invalid_request', 'Send a full 512 KiB chunk, or exactly the remaining final bytes.');
      if (offset < pending.received_bytes) {
        const accepted = db.prepare('SELECT bytes FROM media_upload_chunks WHERE owner_id = ? AND request_id = ? AND byte_offset = ?').get(owner, key, offset);
        if (!accepted || !Buffer.from(accepted.bytes).equals(bytes))
          fail(409, 'upload_chunk_conflict', 'This offset already contains different bytes.');
      } else {
        db.prepare('INSERT INTO media_upload_chunks(owner_id, request_id, byte_offset, bytes) VALUES (?, ?, ?, ?)').run(owner, key, offset, bytes);
        db.prepare('UPDATE media_upload_sessions SET received_bytes = received_bytes + ? WHERE owner_id = ? AND request_id = ?').run(bytes.length, owner, key);
      }
      db.prepare('UPDATE media_upload_sessions SET updated_at = ? WHERE owner_id = ? AND request_id = ?').run(now(), owner, key);
      return result(owner, key);
    });
  }
  async function complete(owner, key) {
    expire(); assertOwner(owner);
    if (receipt(owner, key)) return result(owner, key);
    const pending = session(owner, key);
    if (!pending) fail(404, 'not_found', 'Upload not found. Start the upload again.');
    if (pending.received_bytes !== pending.byte_count) fail(409, 'upload_incomplete', 'Finish uploading the remaining bytes first.');
    const processingKey = keyFor(owner, key);
    // Admit before assembling up to 20 MiB, not after allocating another movie.
    // The normalizer also shares its decoder gate with the legacy endpoint.
    if (processing.size) fail(429, 'video_processing_busy', 'A video is still being processed. Check again shortly.');
    processing.add(processingKey);
    try {
      const chunks = db.prepare('SELECT bytes FROM media_upload_chunks WHERE owner_id = ? AND request_id = ? ORDER BY byte_offset').all(owner, key);
      const bytes = Buffer.concat(chunks.map(row => Buffer.from(row.bytes)));
      if (bytes.length !== pending.byte_count || digest(bytes) !== pending.sha256)
        fail(422, 'upload_checksum_mismatch', 'The uploaded bytes do not match this video. Select the video again.');
      db.prepare('UPDATE media_upload_sessions SET updated_at = ? WHERE owner_id = ? AND request_id = ?').run(now(), owner, key);
      const normalized = await normalize(bytes, pending.mime_type);
      return transaction(db, () => {
        assertOwner(owner);
        if (receipt(owner, key)) return result(owner, key);
        const current = session(owner, key);
        if (!current) fail(404, 'not_found', 'Upload no longer exists.');
        if (current.sha256 !== pending.sha256 || current.byte_count !== pending.byte_count) conflict();
        checkQuota(owner, normalized.bytes.length, key);
        const mediaID = randomUUID();
        db.prepare('INSERT INTO media(id, owner_id, mime_type, byte_count, bytes, created_at) VALUES (?, ?, ?, ?, ?, ?)')
          .run(mediaID, owner, normalized.mimeType, normalized.bytes.length, normalized.bytes, now());
        db.prepare('INSERT INTO media_upload_requests(owner_id, request_id, request_hash, media_id, created_at) VALUES (?, ?, ?, ?, ?)')
          .run(owner, key, digest(`${pending.mime_type}:${pending.sha256}`), mediaID, now());
        clearChunks(owner, key);
        return result(owner, key);
      });
    } finally { processing.delete(processingKey); }
  }
  function clearChunks(owner, key) { db.prepare('DELETE FROM media_upload_chunks WHERE owner_id = ? AND request_id = ?').run(owner, key); }
  function remove(owner, key) { db.prepare('DELETE FROM media_upload_sessions WHERE owner_id = ? AND request_id = ?').run(owner, key); }
  function checkLegacy(owner, key, mimeType, bytes) {
    const pending = key && session(owner, key);
    if (pending && (pending.mime_type !== mimeType || pending.byte_count !== bytes.length || pending.sha256 !== digest(bytes))) conflict();
  }
  return { begin, status, append, complete, expire, checkQuota, clearChunks, remove, checkLegacy };
}
