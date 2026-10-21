import test from 'node:test';
import assert from 'node:assert/strict';
import { deflateSync } from 'node:zlib';
import sharp from 'sharp';
import { normalizePhoto, PhotoProcessingError, PHOTO_LIMITS } from '../src/photo-processing.mjs';

const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

// Small, valid PNG/APNG fixtures built in memory rather than checked-in media.
function pngChunk(type, payload = Buffer.alloc(0)) {
  const body = Buffer.concat([Buffer.from(type), payload]);
  let checksum = 0xffffffff;
  for (const byte of body) {
    checksum ^= byte;
    for (let bit = 0; bit < 8; bit++) checksum = (checksum >>> 1) ^ ((checksum & 1) ? 0xedb88320 : 0);
  }
  const result = Buffer.alloc(payload.length + 12);
  result.writeUInt32BE(payload.length);
  body.copy(result, 4);
  result.writeUInt32BE((checksum ^ 0xffffffff) >>> 0, result.length - 4);
  return result;
}

function pngHeader(width, height) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 6; // RGBA, one filter byte per scanline.
  return pngChunk('IHDR', header);
}

function smallPNG({ width = 1, height = 1, pixels = Buffer.from([0, 255, 0, 0, 255]) } = {}) {
  return Buffer.concat([signature, pngHeader(width, height), pngChunk('IDAT', deflateSync(pixels)), pngChunk('IEND')]);
}

function animatedPNG() {
  const animation = Buffer.alloc(8);
  animation.writeUInt32BE(2);
  function frame(sequence) {
    const payload = Buffer.alloc(26);
    payload.writeUInt32BE(sequence, 0);
    payload.writeUInt32BE(1, 4);
    payload.writeUInt32BE(1, 8);
    payload.writeUInt16BE(1, 20);
    payload.writeUInt16BE(10, 22);
    return pngChunk('fcTL', payload);
  }
  const second = Buffer.alloc(4);
  second.writeUInt32BE(2);
  return Buffer.concat([signature, pngHeader(1, 1), pngChunk('acTL', animation), frame(0),
    pngChunk('IDAT', deflateSync(Buffer.from([0, 255, 0, 0, 255]))), frame(1),
    pngChunk('fdAT', Buffer.concat([second, deflateSync(Buffer.from([0, 0, 0, 255, 255]))])), pngChunk('IEND')]);
}

async function photo(format = 'jpeg', width = 40, height = 20) {
  return sharp({ create: { width, height, channels: 3, background: '#e04d34' } }).toFormat(format).toBuffer();
}

function rejects(status, code) {
  return error => error instanceof PhotoProcessingError && error.status === status && error.code === code
    && typeof error.message === 'string' && error.message.length > 0;
}

for (const format of ['jpeg', 'png', 'webp']) {
  test(`${format}: fully decodes and returns a fresh still JPEG without enlarging`, async () => {
    const input = await photo(format);
    const result = await normalizePhoto(input, `image/${format}`);
    assert.equal(result.mimeType, 'image/jpeg');
    assert.notEqual(result.bytes, input);
    const output = await sharp(result.bytes).metadata();
    assert.equal(output.format, 'jpeg');
    assert.equal(output.width, 40);
    assert.equal(output.height, 20);
    assert.equal(output.pages, undefined);
    assert.ok(result.bytes.length <= PHOTO_LIMITS.outputBytes);
    const pixels = await sharp(result.bytes).raw().toBuffer();
    assert.equal(pixels.length, 40 * 20 * 3);
  });
}

test('applies EXIF orientation to pixels and strips GPS, EXIF, XMP and ICC', async () => {
  const input = await sharp({ create: { width: 60, height: 30, channels: 3, background: '#d92340' } })
    .withMetadata({ orientation: 6 })
    .withExifMerge({ IFD0: { Artist: 'private-person', ImageDescription: 'private-location' },
      IFD3: { GPSLatitudeRef: 'N', GPSLatitude: '37/1 22/1 0/1',
        GPSLongitudeRef: 'W', GPSLongitude: '122/1 2/1 0/1' } })
    .withXmp('<x:xmpmeta xmlns:x="adobe:ns:meta/">private-location</x:xmpmeta>')
    .jpeg().toBuffer();
  const before = await sharp(input).metadata();
  assert.equal(before.orientation, 6);
  assert.ok(before.exif?.length);
  assert.ok(before.icc?.length);
  assert.ok(before.xmp?.length);
  const result = await normalizePhoto(input, 'image/jpeg');
  const after = await sharp(result.bytes).metadata();
  assert.equal(after.width, 30);
  assert.equal(after.height, 60);
  for (const key of ['orientation', 'exif', 'xmp', 'icc', 'iptc']) assert.equal(after[key], undefined, key);
  assert.equal(after.hasProfile, false);
  assert.ok(!result.bytes.includes(Buffer.from('private-person')));
  assert.ok(!result.bytes.includes(Buffer.from('private-location')));
});

test('bounds output dimensions and converts transparent pixels to white', async () => {
  const input = await sharp({ create: { width: 4096, height: 2048, channels: 4,
    background: { r: 0, g: 0, b: 0, alpha: 0 } } }).png().toBuffer();
  const { bytes } = await normalizePhoto(input, 'image/png');
  const metadata = await sharp(bytes).metadata();
  assert.equal(metadata.width, 2048);
  assert.equal(metadata.height, 1024);
  assert.equal(metadata.hasAlpha, false);
  const { data } = await sharp(bytes).resize(1, 1).raw().toBuffer({ resolveWithObject: true });
  assert.ok(data.every(channel => channel >= 250));
});

test('accepts and downscales a valid photo at the 24-megapixel boundary', async () => {
  const input = await photo('png', 6000, 4000);
  const result = await normalizePhoto(input, 'image/png');
  const metadata = await sharp(result.bytes).metadata();
  assert.equal(metadata.width, 2048);
  assert.equal(metadata.height, 1365);
  assert.ok(result.bytes.length <= PHOTO_LIMITS.outputBytes);
});

test('rejects unsupported types, incorrect MIME, paths and pretend signatures', async () => {
  await assert.rejects(normalizePhoto('/etc/passwd', 'image/jpeg'), rejects(422, 'invalid_photo'));
  await assert.rejects(normalizePhoto(Buffer.alloc(0), 'image/jpeg'), rejects(422, 'invalid_photo'));
  await assert.rejects(normalizePhoto(Buffer.from('<svg/>'), 'image/svg+xml'), rejects(415, 'unsupported_photo_type'));
  await assert.rejects(normalizePhoto(await photo('png'), 'image/jpeg'), rejects(415, 'photo_type_mismatch'));
  for (const [input, mime] of [[Buffer.from([255, 216, 255, 217]), 'image/jpeg'],
    [signature, 'image/png'], [Buffer.from('RIFF\x04\x00\x00\x00WEBP', 'binary'), 'image/webp']]) {
    await assert.rejects(normalizePhoto(input, mime), rejects(422, 'invalid_photo'));
  }
});

test('rejects truncated containers and damaged compressed pixel data', async () => {
  for (const format of ['jpeg', 'png', 'webp']) {
    const input = await photo(format, 300, 200);
    await assert.rejects(normalizePhoto(input.subarray(0, input.length - 2), `image/${format}`), rejects(422, 'invalid_photo'));
  }
  // A complete PNG envelope and readable dimensions are not enough: the zlib
  // payload must decode as a complete image too.
  const invalidPixels = Buffer.concat([signature, pngHeader(10, 10),
    pngChunk('IDAT', deflateSync(Buffer.from([0, 255, 0, 0, 255]))), pngChunk('IEND')]);
  await assert.rejects(normalizePhoto(invalidPixels, 'image/png'), rejects(422, 'invalid_photo'));
  const jpeg = await photo('jpeg', 300, 200);
  const shortJPEG = Buffer.concat([jpeg.subarray(0, Math.floor(jpeg.length * 0.75)), Buffer.from([255, 217])]);
  await assert.rejects(normalizePhoto(shortJPEG, 'image/jpeg'), rejects(422, 'invalid_photo'));
  assert.equal((await normalizePhoto(smallPNG(), 'image/png')).mimeType, 'image/jpeg', 'a failure releases admission');
});

test('rejects byte, pixel and dimension limits before allocating an unbounded image', async () => {
  await assert.rejects(normalizePhoto(Buffer.alloc(PHOTO_LIMITS.inputBytes + 1), 'image/jpeg'), rejects(413, 'photo_too_large'));
  // Deliberately hostile headers; pixel payloads are never supposed to decode.
  await assert.rejects(normalizePhoto(smallPNG({ width: 6000, height: 4001 }), 'image/png'), rejects(413, 'photo_dimensions_exceeded'));
  await assert.rejects(normalizePhoto(smallPNG({ width: PHOTO_LIMITS.inputDimension + 1 }), 'image/png'), rejects(413, 'photo_dimensions_exceeded'));
});

test('rejects animated WebP and APNG rather than silently taking frame zero', async () => {
  const red = await photo('png', 2, 2);
  const blue = await sharp({ create: { width: 2, height: 2, channels: 3, background: '#0000ff' } }).png().toBuffer();
  const webp = await sharp([red, blue], { join: { animated: true } }).webp({ delay: [100, 100], loop: 0 }).toBuffer();
  assert.equal((await sharp(webp).metadata()).pages, 2);
  await assert.rejects(normalizePhoto(webp, 'image/webp'), rejects(415, 'animated_photo_not_supported'));
  const apng = animatedPNG();
  assert.equal((await sharp(apng).metadata()).format, 'png');
  await assert.rejects(normalizePhoto(apng, 'image/png'), rejects(415, 'animated_photo_not_supported'));
});

test('one process has one admitted decoder and rejects excess work immediately', async () => {
  const input = await photo('jpeg', 1200, 800);
  const admitted = normalizePhoto(input, 'image/jpeg');
  await assert.rejects(normalizePhoto(input, 'image/jpeg'), rejects(429, 'photo_processing_busy'));
  assert.equal((await admitted).mimeType, 'image/jpeg');
  assert.equal((await normalizePhoto(input, 'image/jpeg')).mimeType, 'image/jpeg');
});
