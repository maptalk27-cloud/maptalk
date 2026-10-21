// A single byte range is sufficient for AVPlayer. Deliberately do not generate
// multipart ranges (which amplify memory/IO); malformed/unsatisfiable ones fail.
export function mediaByteRange(header, length) {
  if (header === undefined) return { start: 0, end: length - 1, partial: false };
  const match = /^bytes=(\d*)-(\d*)$/.exec(header);
  if (!match || (!match[1] && !match[2])) return null;
  let start;
  let end;
  if (!match[1]) {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix <= 0) return null;
    start = Math.max(0, length - suffix); end = length - 1;
  } else {
    start = Number(match[1]); end = match[2] ? Number(match[2]) : length - 1;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= length || end < start) return null;
    end = Math.min(end, length - 1);
  }
  return { start, end, partial: true };
}

// SQLite substr(BLOB) returns just this chunk. Do not fetch a full 20 MiB movie
// for every 2-byte AVPlayer probe or hold it while a slow viewer downloads it.
export async function sendMediaBytes(db, response, mediaID, range) {
  const read = db.prepare('SELECT substr(bytes, ?, ?) AS bytes FROM media WHERE id = ?');
  for (let offset = range.start; offset <= range.end && !response.destroyed; offset += 64 * 1024) {
    const size = Math.min(64 * 1024, range.end - offset + 1);
    const data = read.get(offset + 1, size, mediaID)?.bytes;
    if (!data || data.byteLength !== size) { response.destroy(); return; }
    if (!response.write(Buffer.from(data.buffer, data.byteOffset, data.byteLength))) {
      await new Promise(resolve => {
        const done = () => { response.off('drain', done); response.off('close', done); resolve(); };
        response.once('drain', done); response.once('close', done);
      });
    }
  }
  if (!response.destroyed) response.end();
}
