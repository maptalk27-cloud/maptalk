import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { VIDEO_LIMITS, normalizeVideo, validateVideoContainer, validateVideoMetadata } from '../src/video-processing.mjs';
import { mediaByteRange } from '../src/media-range.mjs';
import { videoFixture } from './helpers/video.mjs';

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
