import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { VIDEO_LIMITS, normalizeVideo, validateVideoContainer, validateVideoMetadata, validateVideoPreservation } from '../src/video-processing.mjs';
import { mediaByteRange } from '../src/media-range.mjs';
import { appleEditListVideoFixture, videoFixture } from './helpers/video.mjs';

const execute = promisify(execFile);
const rejects = code => error => error.code === code;

test('video normalization strips location/title/stream metadata while keeping video, audio and portrait rotation', async () => {
  for (const rotation of [0, 90, -90, 180]) {
    const input = await videoFixture({ rotation });
    const result = await normalizeVideo(input, 'video/mp4');
    assert.equal(result.mimeType, 'video/mp4');
    assert.ok(result.bytes.length < VIDEO_LIMITS.outputBytes);
    assert.notDeepEqual(result.bytes, input);
    const directory = await mkdtemp(join(tmpdir(), 'maptalk-video-check-'));
    try {
      const path = join(directory, 'normalized.mp4');
      await writeFile(path, result.bytes);
      const { stdout } = await execute('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', path]);
      const metadata = JSON.parse(stdout);
      assert.equal(metadata.streams[0].codec_name, 'h264');
      assert.equal(metadata.streams[1].codec_name, 'aac');
      assert.equal(Number(metadata.streams[0].duration), 1);
      assert.doesNotMatch(stdout, /private title|private camera info|37\.3688|122\.0363|"location"/);
      const actualRotation = metadata.streams[0].side_data_list?.find(side => side.rotation !== undefined)?.rotation ?? 0;
      assert.equal((actualRotation % 360 + 360) % 360, (rotation % 360 + 360) % 360);
      assert.ok(result.bytes.indexOf(Buffer.from('moov')) < result.bytes.indexOf(Buffer.from('mdat')), 'fast-start MP4');
    } finally { await rm(directory, { recursive: true, force: true }); }
  }
});

test('video rejects fake MIME, truncation, invalid packets, excessive duration, dimensions and unsupported codecs', async () => {
  const valid = await videoFixture({ audio: false });
  await assert.rejects(normalizeVideo(valid, 'video/quicktime'), rejects('unsupported_video'));
  await assert.rejects(normalizeVideo(Buffer.from('<svg/>'), 'video/mp4'), rejects('invalid_video'));
  await assert.rejects(normalizeVideo(valid.subarray(0, valid.length - 10), 'video/mp4'), rejects('invalid_video'));
  const damaged = Buffer.from(valid);
  const start = damaged.indexOf(Buffer.from('mdat')) + 4;
  damaged.fill(0xff, start, damaged.length);
  await assert.rejects(normalizeVideo(damaged, 'video/mp4'), rejects('invalid_video'));
  await assert.rejects(normalizeVideo(await videoFixture({ duration: 61, dimensions: '32x32', fps: 1, audio: false }), 'video/mp4'), rejects('video_duration_exceeded'));
  // The native max_pixels cap may reject before metadata gets far enough to
  // produce the more specific dimensions error; either path must fail closed.
  await assert.rejects(normalizeVideo(await videoFixture({ dimensions: '1920x1080', audio: false }), 'video/mp4'),
    error => ['video_dimensions_exceeded', 'invalid_video'].includes(error.code));
  await assert.rejects(normalizeVideo(await videoFixture({ codec: 'mpeg4', audio: false }), 'video/mp4'), rejects('unsupported_video'));
  await assert.rejects(normalizeVideo(Buffer.alloc(VIDEO_LIMITS.inputBytes + 1), 'video/mp4'), rejects('video_too_large'));
  const padded = Buffer.concat([valid, Buffer.alloc(1)]);
  assert.throws(() => validateVideoContainer(padded), rejects('invalid_video'));
});

test('video accepts the 60-second boundary and silent portrait inputs', async () => {
  const silent = await normalizeVideo(await videoFixture({ duration: 60, dimensions: '180x320', fps: 1, audio: false }), 'video/mp4');
  assert.equal(silent.mimeType, 'video/mp4');
});

test('Apple edit-list video keeps every picture and AAC packet without expanding its presentation timeline', async () => {
  for (const options of [
    { duration: 3.137, fps: '30000/1001', audio: true },
    { duration: 3, fps: 30, audio: false, rotation: 90, variableFrameRate: true },
    { duration: 60, fps: 30, audio: true, dimensions: '32x32' },
  ]) {
    const input = await appleEditListVideoFixture(options);
    const directory = await mkdtemp(join(tmpdir(), 'maptalk-apple-timing-check-'));
    try {
      const source = join(directory, 'source.mp4');
      const output = join(directory, 'normalized.mp4');
      await writeFile(source, input);
      const metadata = async file => JSON.parse((await execute('ffprobe', ['-v', 'error', '-count_packets',
        '-show_entries', 'format=duration:stream=codec_type,duration,nb_read_packets', '-of', 'json', file])).stdout);
      const before = await metadata(source);
      // Different FFmpeg versions expose edit-list padding differently. The
      // contract is preservation of this valid, sub-millisecond presentation
      // timeline, not a particular incorrect plain-remux duration.
      const normalized = await normalizeVideo(input, 'video/mp4');
      await writeFile(output, normalized.bytes);
      const after = await metadata(output);
      for (const stream of before.streams) {
        const preserved = after.streams.find(item => item.codec_type === stream.codec_type);
        assert.ok(preserved);
        assert.equal(preserved.nb_read_packets, stream.nb_read_packets, `every ${stream.codec_type} packet survives`);
        assert.ok(Math.abs(Number(preserved.duration) - Number(stream.duration)) <= 0.001);
      }
      assert.ok(Number(after.format.duration) <= VIDEO_LIMITS.durationSeconds + 0.1);
      // Compare decoded pixels too: duration repair may not change picture
      // content, presentation order, or delete the final encoded frame.
      const pictures = async file => (await execute('ffmpeg', ['-v', 'error', '-i', file,
        '-map', '0:v:0', '-fps_mode', 'passthrough', '-f', 'framemd5', '-'], { maxBuffer: 1024 * 1024 })).stdout
        .split('\n').filter(line => line && !line.startsWith('#')).map(line => line.split(',').at(-1).trim());
      assert.deepEqual(await pictures(output), await pictures(source));
    } finally { await rm(directory, { recursive: true, force: true }); }
  }
});

test('remux preservation allows one bounded iPhone clock tick, never a missing packet or frame-sized duration change', () => {
  const original = { streams: [
    { codec_type: 'video', duration: '5.568333', time_base: '1/600', nb_read_packets: '167' },
    { codec_type: 'audio', duration: '5.566667', time_base: '1/48000', nb_read_packets: '263' },
  ] };
  const normalized = { streams: [
    { ...original.streams[0], duration: '5.570000', time_base: '1/19200' },
    { ...original.streams[1] },
  ] };
  assert.doesNotThrow(() => validateVideoPreservation(original, normalized));
  for (const patch of [{ duration: '5.571000' }, { duration: '5.601667' },
    { duration: 'NaN' }, { nb_read_packets: '166' }, { nb_read_packets: '0' },
    { side_data_list: [{ rotation: 90 }] }]) {
    assert.throws(() => validateVideoPreservation(original,
      { streams: [{ ...normalized.streams[0], ...patch }, normalized.streams[1]] }), rejects('invalid_video'));
  }
  assert.throws(() => validateVideoPreservation(original,
    { streams: [normalized.streams[0]] }), rejects('invalid_video'));
  assert.throws(() => validateVideoPreservation(original,
    { streams: [normalized.streams[0], { ...normalized.streams[1], nb_read_packets: '262' }] }), rejects('invalid_video'));
  // A forged/coarse time base cannot grant a larger tolerance, and a precise
  // source does not get the iPhone's 1/600 s rounding allowance.
  for (const time_base of ['1/1', '1/24']) {
    assert.throws(() => validateVideoPreservation(
      { streams: [{ ...original.streams[0], time_base }] },
      { streams: [{ ...normalized.streams[0], duration: '5.571000' }] }), rejects('invalid_video'));
  }
  assert.throws(() => validateVideoPreservation(
    { streams: [{ ...original.streams[0], time_base: '1/19200' }] },
    { streams: [normalized.streams[0]] }), rejects('invalid_video'));
});

test('only a validated remux gets source-clock rounding at 60 seconds; input duration limits stay strict', () => {
  const original = { streams: [{ codec_type: 'video', codec_name: 'h264', pix_fmt: 'yuv420p',
    width: 1280, height: 720, duration: '60', avg_frame_rate: '30/1',
    time_base: '1/600', nb_read_packets: '1800' }], format: { duration: '60' } };
  const normalized = { streams: [{ ...original.streams[0], duration: '60.001667', time_base: '1/19200' }],
    format: { duration: '60.001667' } };
  assert.doesNotThrow(() => validateVideoMetadata(original));
  assert.throws(() => validateVideoMetadata(normalized), rejects('video_duration_exceeded'));
  assert.doesNotThrow(() => validateVideoPreservation(original, normalized));
  assert.doesNotThrow(() => validateVideoMetadata(normalized, { normalizationSource: original }));
  assert.throws(() => validateVideoMetadata({ ...normalized,
    streams: [{ ...normalized.streams[0], duration: '60.004' }] },
  { normalizationSource: original }), rejects('video_duration_exceeded'));
});

test('only one video decoder runs at a time and its slot is released after completion', async () => {
  const fixture = await videoFixture();
  const pending = normalizeVideo(fixture, 'video/mp4');
  await assert.rejects(normalizeVideo(fixture, 'video/mp4'), rejects('video_processing_busy'));
  await pending;
  assert.equal((await normalizeVideo(fixture, 'video/mp4')).mimeType, 'video/mp4');
});

test('video metadata rejects unusual tracks, high frame rate, dimensions, invalid duration and audio configurations', () => {
  const base = { streams: [{ codec_type: 'video', codec_name: 'h264', pix_fmt: 'yuv420p',
    width: 1280, height: 720, duration: '10', avg_frame_rate: '30/1' }], format: { duration: '10' } };
  assert.doesNotThrow(() => validateVideoMetadata(base));
  for (const patch of [{ codec_name: 'hevc' }, { pix_fmt: 'yuv420p10le' }, { width: 4000 },
    { height: 1280 }, { avg_frame_rate: '120/1' }, { avg_frame_rate: '0/0' }, { duration: 'Infinity' },
    { duration: '61' }, { disposition: { attached_pic: 1 } }, { side_data_list: [{ rotation: 45 }] }]) {
    assert.throws(() => validateVideoMetadata({ ...base, streams: [{ ...base.streams[0], ...patch }] }));
  }
  for (const additional of [{ codec_type: 'subtitle' }, { codec_type: 'video' },
    { codec_type: 'audio', codec_name: 'aac', sample_rate: '96000', channels: 2 },
    { codec_type: 'audio', codec_name: 'aac', sample_rate: '44100', channels: 6 },
    { codec_type: 'audio', codec_name: 'mp3', sample_rate: '44100', channels: 2 }]) {
    assert.throws(() => validateVideoMetadata({ ...base, streams: [...base.streams, additional] }));
  }
});

test('single media byte ranges handle prefix, suffix, open-ended, clipping and unsafe inputs', () => {
  assert.deepEqual(mediaByteRange(undefined, 100), { start: 0, end: 99, partial: false });
  assert.deepEqual(mediaByteRange('bytes=0-1', 100), { start: 0, end: 1, partial: true });
  assert.deepEqual(mediaByteRange('bytes=50-', 100), { start: 50, end: 99, partial: true });
  assert.deepEqual(mediaByteRange('bytes=-10', 100), { start: 90, end: 99, partial: true });
  assert.deepEqual(mediaByteRange('bytes=-200', 100), { start: 0, end: 99, partial: true });
  assert.deepEqual(mediaByteRange('bytes=98-200', 100), { start: 98, end: 99, partial: true });
  for (const invalid of ['bytes=100-', 'bytes=10-0', 'bytes=-0', 'bytes=-', 'items=0-1',
    'bytes=0-1,5-6', 'bytes=0-1\n', 'bytes=9007199254740992-', 'bytes=-9007199254740992']) {
    assert.equal(mediaByteRange(invalid, 100), null, invalid);
  }
});
