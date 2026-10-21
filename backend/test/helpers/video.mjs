import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';

const execute = promisify(execFile);

// Real codec fixtures, not a forged MP4 header or a mocked decoder. Both tools
// ship in the deployment image; local npm test also requires them on PATH.
export async function videoFixture({ duration = 1, dimensions = '320x180', fps = 24,
  codec = 'libx264', audio = true, rotation = 0 } = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'maptalk-video-fixture-'));
  try {
    const file = join(directory, 'fixture.mp4');
    await execute('ffmpeg', ['-hide_banner', '-v', 'error', '-f', 'lavfi', '-i', `color=c=blue:s=${dimensions}:r=${fps}`,
      ...(audio ? ['-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100'] : []),
      '-t', String(duration), '-c:v', codec, '-pix_fmt', 'yuv420p', '-threads', '1',
      ...(audio ? ['-c:a', 'aac'] : []), '-metadata', 'title=private title',
      '-metadata', 'location=+37.3688-122.0363/', '-metadata:s:v:0', 'comment=private camera info',
      '-movflags', '+faststart', file], { timeout: 30_000, maxBuffer: 128 * 1024 });
    if (!rotation) return await readFile(file);
    const rotated = join(directory, 'rotated.mp4');
    await execute('ffmpeg', ['-hide_banner', '-v', 'error', '-i', file, '-c', 'copy',
      '-metadata:s:v:0', `rotate=${rotation}`, rotated], { timeout: 10_000 });
    return await readFile(rotated);
  } finally { await rm(directory, { recursive: true, force: true }); }
}
