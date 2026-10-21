import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';

const execute = promisify(execFile);
export const VIDEO_LIMITS = Object.freeze({
  inputBytes: 20 * 1024 * 1024, outputBytes: 20 * 1024 * 1024,
  durationSeconds: 60, longEdge: 1280, shortEdge: 720, framesPerSecond: 60,
  concurrent: 1,
});
let processing = 0;

export class VideoProcessingError extends Error {
  constructor(status, code, message) {
    super(message);
    this.name = 'VideoProcessingError';
    this.status = status;
    this.code = code;
  }
}
const invalid = () => new VideoProcessingError(422, 'invalid_video',
  'This video is damaged or incomplete. Please choose another video.');
const unsupported = () => new VideoProcessingError(415, 'unsupported_video',
  'Choose an MP4 video exported as H.264 with AAC audio.');

// Reject truncation before calling a native decoder. This is deliberately a
// narrow, self-contained MP4 contract, not a generic media/playlist importer.
export function validateVideoContainer(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 24) throw invalid();
  let offset = 0;
  const boxes = new Set();
  while (offset < bytes.length) {
    if (offset + 8 > bytes.length) throw invalid();
    let size = bytes.readUInt32BE(offset);
    const type = bytes.toString('ascii', offset + 4, offset + 8);
    let header = 8;
    if (size === 1) {
      if (offset + 16 > bytes.length) throw invalid();
      const large = bytes.readBigUInt64BE(offset + 8);
      if (large > BigInt(bytes.length)) throw invalid();
      size = Number(large); header = 16;
    } else if (size === 0) size = bytes.length - offset;
    if (size < header || offset + size > bytes.length) throw invalid();
    if (offset === 0 && (type !== 'ftyp' || size < header + 8)) throw unsupported();
    if (type === 'moof' || type === 'mfra') throw unsupported();
    if (type === 'moov' && boxes.has(type)) throw invalid();
    boxes.add(type);
    offset += size;
  }
  if (!boxes.has('moov') || !boxes.has('mdat')) throw invalid();
}

const inputOptions = ['-f', 'mov', '-protocol_whitelist', 'file,pipe',
  '-enable_drefs', '0', '-use_absolute_path', '0', '-threads', '1',
  // Enforce at the decoder too: an H.264 stream can change its dimensions
  // after the first header that ffprobe reported.
  '-max_pixels', String(VIDEO_LIMITS.longEdge * VIDEO_LIMITS.shortEdge), '-max_samples', '65536'];
const toolOptions = { encoding: 'utf8', maxBuffer: 128 * 1024,
  killSignal: 'SIGKILL', windowsHide: true,
  // Media decoders do not need signing/encryption keys from the API environment.
  env: { PATH: process.env.PATH, LANG: 'C', LC_ALL: 'C' } };

async function tool(name, args, timeout) {
  try {
    const result = await execute(name, ['-hide_banner', '-v', 'error', '-max_alloc', '67108864', ...args],
      { ...toolOptions, timeout });
    // ffprobe can return success after logging a damaged packet. Error-level
    // decoder output is a rejection even when the process exits with code 0.
    if (result.stderr.trim()) throw invalid();
    return result;
  } catch (error) {
    if (error.code === 'ENOENT') throw new VideoProcessingError(503, 'video_processing_unavailable',
      'Video uploads are temporarily unavailable. Your video can be retried later.');
    // Never return native logs, embedded metadata or file paths to callers.
    throw invalid();
  }
}

async function probe(path) {
  const result = await tool('ffprobe', [...inputOptions, '-show_entries',
    'format=duration:stream=codec_type,codec_name,width,height,pix_fmt,duration,avg_frame_rate,channels,sample_rate:stream_disposition=attached_pic:stream_side_data_list',
    '-of', 'json', path], 10_000);
  return JSON.parse(result.stdout);
}

export function validateVideoMetadata(metadata) {
  const streams = metadata?.streams;
  if (!Array.isArray(streams)) throw invalid();
  const video = streams.filter(stream => stream.codec_type === 'video');
  const audio = streams.filter(stream => stream.codec_type === 'audio');
  if (video.length !== 1 || audio.length > 1 || streams.length !== video.length + audio.length) throw unsupported();
  const track = video[0];
  if (track.codec_name !== 'h264' || !['yuv420p', 'yuvj420p'].includes(track.pix_fmt)
    || track.disposition?.attached_pic) throw unsupported();
  // AVAssetExport can retain a portrait display transform. This is essential
  // orientation, not private metadata; allow quarter turns and preserve it.
  for (const side of track.side_data_list ?? []) {
    if (side.rotation !== undefined && (!Number.isFinite(side.rotation)
      || Math.abs(side.rotation / 90 - Math.round(side.rotation / 90)) > 0.001)) throw unsupported();
  }
  if (![track.width, track.height].every(value => Number.isSafeInteger(value) && value > 0)
    || Math.max(track.width, track.height) > VIDEO_LIMITS.longEdge
    || Math.min(track.width, track.height) > VIDEO_LIMITS.shortEdge) {
    throw new VideoProcessingError(413, 'video_dimensions_exceeded', 'Export this video at 720p or smaller.');
  }
  const duration = Number(track.duration);
  const containerDuration = Number(metadata.format?.duration);
  if (!Number.isFinite(duration) || duration <= 0 || !Number.isFinite(containerDuration) || containerDuration <= 0) throw invalid();
  // AAC can add a final fraction of a frame; the video itself remains <=60 s.
  if (duration > VIDEO_LIMITS.durationSeconds + 0.001 || containerDuration > VIDEO_LIMITS.durationSeconds + 0.1
    || audio.some(stream => Number(stream.duration) > VIDEO_LIMITS.durationSeconds + 0.1)) {
    throw new VideoProcessingError(413, 'video_duration_exceeded', 'Choose a video up to 60 seconds long.');
  }
  const [numerator, denominator] = String(track.avg_frame_rate).split('/').map(Number);
  const fps = numerator / denominator;
  if (!Number.isFinite(fps) || fps <= 0 || fps > VIDEO_LIMITS.framesPerSecond + 0.01) throw unsupported();
  if (audio.some(stream => stream.codec_name !== 'aac' || ![1, 2].includes(stream.channels)
    || !Number.isFinite(Number(stream.sample_rate)) || Number(stream.sample_rate) < 8000
    || Number(stream.sample_rate) > 48000)) throw unsupported();
}

/** Validate every frame, then create a fresh fast-start, metadata-free MP4.
 * The phone does expensive resizing/encoding. The server still independently
 * checks the content, not its MIME/header, and never stores the original file.
 * One job and <=40 MiB of temporary files fit the existing 64 MiB tmpfs.
 */
export async function normalizeVideo(bytes, mimeType) {
  if (mimeType !== 'video/mp4') throw unsupported();
  if (bytes?.length > VIDEO_LIMITS.inputBytes) throw new VideoProcessingError(413, 'video_too_large', 'Choose a video smaller than 20 MiB.');
  validateVideoContainer(bytes);
  if (processing >= VIDEO_LIMITS.concurrent) throw new VideoProcessingError(429, 'video_processing_busy',
    'Another video is being processed. Please try again shortly.');
  processing++;
  let directory;
  try {
    directory = await mkdtemp(join(tmpdir(), 'maptalk-video-'));
    const input = join(directory, 'input.mp4');
    const output = join(directory, 'output.mp4');
    await writeFile(input, bytes, { mode: 0o600, flag: 'wx' });
    const original = await probe(input);
    validateVideoMetadata(original);
    // Decode the complete movie: merely reading a valid header does not prove
    // that a file is complete. No arbitrary protocols, external refs or shell.
    const decoded = await tool('ffmpeg', ['-nostdin', '-xerror', '-err_detect', 'explode',
      ...inputOptions, '-i', input, '-map', '0:v:0', '-map', '0:a:0?',
      '-threads', '1', '-filter_threads', '1', '-progress', 'pipe:1', '-nostats', '-f', 'null', '-'], 45_000);
    const frames = [...decoded.stdout.matchAll(/^frame=(\d+)$/gm)].map(match => Number(match[1]));
    if (!frames.length || frames.at(-1) < 1 || frames.at(-1) > VIDEO_LIMITS.durationSeconds * VIDEO_LIMITS.framesPerSecond + 1) throw invalid();
    await tool('ffmpeg', ['-nostdin', ...inputOptions, '-i', input,
      '-map', '0:v:0', '-map', '0:a:0?', '-c', 'copy', '-bsf:v', 'filter_units=remove_types=6',
      '-map_metadata', '-1', '-map_metadata:s', '-1', '-map_chapters', '-1',
      '-movflags', '+faststart', '-fs', String(VIDEO_LIMITS.outputBytes + 1), '-f', 'mp4', output], 15_000);
    const information = await stat(output);
    if (information.size > VIDEO_LIMITS.outputBytes) throw new VideoProcessingError(413, 'video_too_large', 'Choose a video smaller than 20 MiB.');
    const normalized = await probe(output);
    validateVideoMetadata(normalized);
    for (const type of ['video', 'audio']) {
      const before = original.streams.find(stream => stream.codec_type === type);
      const after = normalized.streams.find(stream => stream.codec_type === type);
      // A resource limit must reject, never silently truncate someone's video.
      if (Boolean(before) !== Boolean(after)
        || (before && Math.abs(Number(before.duration) - Number(after.duration)) > 0.001)) throw invalid();
      if (type === 'video' && before) {
        const rotation = track => ((track.side_data_list?.find(side => side.rotation !== undefined)?.rotation ?? 0) % 360 + 360) % 360;
        if (Math.abs(rotation(before) - rotation(after)) > 0.001) throw invalid();
      }
    }
    const result = await readFile(output);
    validateVideoContainer(result);
    return { bytes: result, mimeType: 'video/mp4' };
  } catch (error) {
    if (error instanceof VideoProcessingError) throw error;
    throw invalid();
  } finally {
    try { if (directory) await rm(directory, { recursive: true, force: true }); }
    finally { processing--; }
  }
}
