import sharp from 'sharp';

// These limits target the first 512 MiB, single-process deployment. Client-side
// resizing is only an optimisation: untrusted uploads always pass this pipeline.
export const PHOTO_LIMITS = Object.freeze({
  inputBytes: 10 * 1024 * 1024,
  inputPixels: 24_000_000,
  inputDimension: 16_384,
  outputDimension: 2048,
  outputBytes: 4 * 1024 * 1024,
  concurrent: 1,
});

// A libvips thread limit is per image, not an admission limit. Keep both limits,
// and do not retain decoded images in a process-wide operation cache.
sharp.cache(false);
sharp.concurrency(1);
let processing = 0;

export class PhotoProcessingError extends Error {
  constructor(status, code, message) {
    super(message);
    this.name = 'PhotoProcessingError';
    this.status = status;
    this.code = code;
  }
}

const invalid = () => new PhotoProcessingError(422, 'invalid_photo',
  'This photo is damaged or incomplete. Please choose another photo.');
const animated = () => new PhotoProcessingError(415, 'animated_photo_not_supported',
  'Animated images are not supported. Please choose a still photo.');
const dimensions = () => new PhotoProcessingError(413, 'photo_dimensions_exceeded',
  'This photo is too large to process. Please resize it to at most 24 megapixels.');
const MIME = Object.freeze({ jpeg: 'image/jpeg', png: 'image/png', webp: 'image/webp' });
const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

function formatOf(bytes) {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'jpeg';
  if (bytes.length >= 8 && bytes.subarray(0, 8).equals(PNG_SIGNATURE)) return 'png';
  if (bytes.length >= 12 && bytes.toString('ascii', 0, 4) === 'RIFF'
    && bytes.toString('ascii', 8, 12) === 'WEBP') return 'webp';
  throw invalid();
}

function checkContainer(bytes, format) {
  if (format === 'jpeg') {
    // Some JPEG decoders tolerate a missing EOI marker. A partial upload must
    // not silently become a partly grey photo even if the header is readable.
    if (bytes.length < 4 || bytes.at(-2) !== 0xff || bytes.at(-1) !== 0xd9) throw invalid();
    return;
  }
  if (format === 'png') {
    let offset = 8;
    while (offset + 12 <= bytes.length) {
      const length = bytes.readUInt32BE(offset);
      const type = bytes.toString('ascii', offset + 4, offset + 8);
      const end = offset + 12 + length;
      if (end > bytes.length) throw invalid();
      if (offset === 8 && (type !== 'IHDR' || length !== 13)) throw invalid();
      // libpng can expose APNG as a single still image, so metadata.pages alone
      // cannot enforce the one-frame contract.
      if (['acTL', 'fcTL', 'fdAT'].includes(type)) throw animated();
      if (type === 'IEND') {
        if (length !== 0 || end !== bytes.length) throw invalid();
        return;
      }
      offset = end;
    }
    throw invalid();
  }
  if (bytes.readUInt32LE(4) + 8 !== bytes.length) throw invalid();
  let offset = 12;
  while (offset + 8 <= bytes.length) {
    const type = bytes.toString('ascii', offset, offset + 4);
    const length = bytes.readUInt32LE(offset + 4);
    const end = offset + 8 + length + (length % 2);
    if (end > bytes.length) throw invalid();
    if (type === 'ANIM' || type === 'ANMF'
      || (type === 'VP8X' && length > 0 && (bytes[offset + 8] & 2))) throw animated();
    offset = end;
  }
  if (offset !== bytes.length) throw invalid();
}

/** Decode an untrusted still photo and return only a new, metadata-free JPEG.
 * No file paths, decoder injection, environment bypass or caller-set limits.
 * Callers should also bound simultaneous request-body reads before this stage.
 */
export async function normalizePhoto(bytes, mimeType) {
  if (!Buffer.isBuffer(bytes) || bytes.length === 0) throw invalid();
  if (bytes.length > PHOTO_LIMITS.inputBytes) {
    throw new PhotoProcessingError(413, 'photo_too_large', 'Choose a photo smaller than 10 MiB.');
  }
  if (!Object.values(MIME).includes(mimeType)) {
    throw new PhotoProcessingError(415, 'unsupported_photo_type', 'Choose a JPEG, PNG or WebP photo.');
  }
  if (processing >= PHOTO_LIMITS.concurrent) {
    throw new PhotoProcessingError(429, 'photo_processing_busy', 'Another photo is being processed. Please try again.');
  }
  processing++;
  let decoder;
  try {
    const format = formatOf(bytes);
    if (MIME[format] !== mimeType) {
      throw new PhotoProcessingError(415, 'photo_type_mismatch', 'The photo does not match its declared image type.');
    }
    checkContainer(bytes, format);
    decoder = sharp(bytes, {
      failOn: 'warning', limitInputPixels: PHOTO_LIMITS.inputPixels,
      limitInputChannels: 4, sequentialRead: true, pages: 1,
    });
    const metadata = await decoder.metadata();
    if (metadata.format !== format) throw invalid();
    if ((metadata.pages ?? 1) !== 1 || metadata.delay !== undefined || metadata.loop !== undefined) throw animated();
    if (!Number.isSafeInteger(metadata.width) || !Number.isSafeInteger(metadata.height)
      || metadata.width < 1 || metadata.height < 1) throw invalid();
    if (metadata.width > PHOTO_LIMITS.inputDimension || metadata.height > PHOTO_LIMITS.inputDimension
      || metadata.width * metadata.height > PHOTO_LIMITS.inputPixels) throw dimensions();

    // metadata() only reads headers. Awaiting this complete decoding/encoding
    // operation is essential; never persist or return the original bytes.
    const { data, info } = await decoder.autoOrient()
      .resize({ width: PHOTO_LIMITS.outputDimension, height: PHOTO_LIMITS.outputDimension,
        fit: 'inside', withoutEnlargement: true, fastShrinkOnLoad: false })
      .flatten({ background: '#ffffff' })
      .toColourspace('srgb')
      .jpeg({ quality: 82, chromaSubsampling: '4:2:0', progressive: false })
      .timeout({ seconds: 8 })
      .toBuffer({ resolveWithObject: true });
    // Sharp strips EXIF, GPS, XMP, ICC and orientation unless explicitly asked
    // to retain them. Do not add keepMetadata()/withMetadata() to this pipeline.
    if (info.format !== 'jpeg' || info.width > PHOTO_LIMITS.outputDimension
      || info.height > PHOTO_LIMITS.outputDimension || data.length > PHOTO_LIMITS.outputBytes) {
      throw new PhotoProcessingError(413, 'photo_too_large', 'This photo is too large. Please choose a smaller version.');
    }
    return { bytes: data, mimeType: 'image/jpeg' };
  } catch (error) {
    if (error instanceof PhotoProcessingError) throw error;
    if (error.message?.includes('exceeds pixel limit')) throw dimensions();
    // Do not expose native decoder diagnostics or embedded metadata in errors.
    throw invalid();
  } finally {
    decoder?.destroy();
    processing--;
  }
}
