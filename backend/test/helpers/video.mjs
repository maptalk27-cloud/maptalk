import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';

const execute = promisify(execFile);
let rotationSupport;
function supportsDisplayRotation() {
  // New FFmpeg releases no longer convert `metadata rotate` into a display
  // matrix. Keep real rotated fixtures on both Homebrew 9 and Debian 5.
  rotationSupport ??= execute('ffmpeg', ['-hide_banner', '-h', 'full'], { timeout: 10_000, maxBuffer: 8 * 1024 * 1024 })
    .then(({ stdout }) => stdout.includes('-display_rotation'));
  return rotationSupport;
}

// Real codec fixtures, not a forged MP4 header or a mocked decoder. Both tools
// ship in the deployment image; local npm test also requires them on PATH.
export async function videoFixture({ duration = 1, dimensions = '320x180', fps = 24,
  codec = 'libx264', audio = true, rotation = 0, variableFrameRate = false, motion = false,
  movieTimescale, videoTrackTimescale, bFrames } = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-video-fixture-'));
  try {
    const file = join(directory, 'fixture.mp4');
    await execute('ffmpeg', ['-hide_banner', '-v', 'error', '-f', 'lavfi', '-i', `${motion ? 'testsrc2=' : 'color=c=blue:'}s=${dimensions}:r=${fps}`,
      ...(audio ? ['-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100'] : []),
      '-t', String(duration), '-c:v', codec, '-pix_fmt', 'yuv420p', '-threads', '1',
      ...(bFrames === undefined ? [] : ['-bf', String(bFrames)]),
      ...(variableFrameRate ? ['-vf', "select='not(mod(n,2))+not(mod(n,3))'", '-fps_mode', 'vfr'] : []),
      ...(audio ? ['-c:a', 'aac'] : []), '-metadata', 'title=private title',
      '-metadata', 'location=+37.3688-122.0363/', '-metadata:s:v:0', 'comment=private camera info',
      ...(movieTimescale ? ['-movie_timescale', String(movieTimescale)] : []),
      ...(videoTrackTimescale ? ['-video_track_timescale', String(videoTrackTimescale)] : []),
      '-movflags', '+faststart', file], { timeout: 30_000, maxBuffer: 128 * 1024 });
    if (!rotation) return await readFile(file);
    const rotated = join(directory, 'rotated.mp4');
    const displayRotation = await supportsDisplayRotation();
    await execute('ffmpeg', ['-hide_banner', '-v', 'error',
      ...(displayRotation ? ['-display_rotation:v:0', String(rotation)] : []), '-i', file, '-c', 'copy',
      ...(displayRotation ? [] : ['-metadata:s:v:0', `rotate=${rotation}`]), rotated], { timeout: 10_000 });
    return await readFile(rotated);
  } finally { await rm(directory, { recursive: true, force: true }); }
}

// A genuine H.264/AAC movie whose last displayed frame ends between 30 fps
// ticks, on the 1/600 s clock used by Apple exports. Only MP4 presentation
// headers are shortened; encoded picture/audio packets stay untouched. No B
// frames here: FFmpeg 5 reconstructs x264 B-frame packet durations as one tick
// on this coarse clock, a separate compatibility case tested below.
export async function partialFrameClockVideoFixture({ duration, ...options }) {
  const movieTimescale = 30000;
  const videoTrackTimescale = 600;
  const source = await videoFixture({ ...options, duration: Math.ceil(duration * 30) / 30, fps: 30, motion: true,
    movieTimescale, videoTrackTimescale, bFrames: 0 });
  const boxes = timingBoxes(source);
  const ticks = Math.round(duration * videoTrackTimescale) * movieTimescale / videoTrackTimescale;
  const track = boxes.get('/moov:0/trak:0/tkhd:0');
  const edit = boxes.get('/moov:0/trak:0/edts:0/elst:0');
  const movie = boxes.get('/moov:0/mvhd:0');
  if (!track || !edit || !movie || [track, edit, movie].some(box => source[box.offset + 8] !== 0)
    || source.readUInt32BE(edit.offset + 12) !== 1) throw new Error('Unexpected synthetic presentation layout');
  source.writeUInt32BE(ticks, track.offset + 28);
  source.writeUInt32BE(ticks, edit.offset + 16);
  const trackDurations = [...boxes.entries()].filter(([key]) => key.endsWith('/tkhd:0'))
    .map(([, box]) => source.readUInt32BE(box.offset + 28));
  source.writeUInt32BE(Math.max(...trackDurations), movie.offset + 24);
  return source;
}

function timingBoxes(bytes) {
  const result = new Map();
  function visit(start, end, path = '') {
    const occurrences = new Map();
    for (let offset = start; offset < end;) {
      const size = bytes.readUInt32BE(offset);
      const type = bytes.toString('ascii', offset + 4, offset + 8);
      if (size < 8 || offset + size > end) throw new Error('Invalid synthetic fixture box');
      const occurrence = occurrences.get(type) ?? 0;
      occurrences.set(type, occurrence + 1);
      const key = `${path}/${type}:${occurrence}`;
      if (['mvhd', 'tkhd', 'elst'].includes(type)) result.set(key, { offset, size });
      if (['moov', 'trak', 'edts'].includes(type)) visit(offset + 8, offset + size, key);
      offset += size;
    }
  }
  visit(0, bytes.length);
  return result;
}

// Reproduce AVAssetExportSession's legal MP4 edit-list timing without requiring
// Apple frameworks on the Linux release image. Every encoded picture/audio
// packet is genuine: only the last picture's reorder padding and its enclosing
// presentation edit are adjusted to match a native Apple export.
export async function appleEditListVideoFixture(options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-apple-timing-fixture-'));
  try {
    const source = await videoFixture({ ...options, motion: true, movieTimescale: 30000 });
    const input = join(directory, 'source.mp4');
    const output = join(directory, 'padded.mp4');
    await writeFile(input, source);
    const { stdout } = await execute('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-count_packets',
      '-show_entries', 'stream=nb_read_packets', '-of', 'json', input]);
    const count = Number(JSON.parse(stdout).streams[0].nb_read_packets);
    await execute('ffmpeg', ['-hide_banner', '-v', 'error', '-i', input, '-map', '0', '-c', 'copy',
      '-bsf:v', `setts=pts=PTS:dts=DTS:duration='DURATION+if(eq(N,${count - 1}),${options.variableFrameRate ? 4 : 2}*DURATION,0)'`,
      '-movie_timescale', '30000', '-movflags', '+faststart', output], { timeout: 10_000 });
    const padded = await readFile(output);
    const before = timingBoxes(source);
    for (const [key, box] of timingBoxes(padded)) {
      const original = before.get(key);
      if (!original || original.size !== box.size) throw new Error('Unexpected synthetic timing layout');
      // These headers contain no media offsets. Restore the original declared
      // presentation duration while keeping the enlarged decode timeline.
      source.copy(padded, box.offset + 8, original.offset + 8, original.offset + original.size);
    }
    return padded;
  } finally { await rm(directory, { recursive: true, force: true }); }
}
