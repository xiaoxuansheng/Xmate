/// Image format detection and bit-depth calculation.
///
/// Extracted from quicklook_image_annotator.dart so other viewers can
/// reuse format identification without depending on the full annotator.
library;

import 'dart:typed_data';
import 'package:image/image.dart' as img_lib;

/// Bits per pixel from the image lib's decoded channel info.
///
/// Formula: `numChannels × bitsPerChannel`.
/// Returns e.g. 24 for RGB, 32 for RGBA, 8 for palette-indexed.
int computeBpp(img_lib.Image img) {
  return img.numChannels * img.bitsPerChannel;
}

/// Detect image format from magic bytes.
///
/// Returns short uppercase format name: `"PNG"`, `"JPEG"`, `"WebP"`,
/// `"GIF"`, `"BMP"`, `"ICO"`, `"TIFF"`, `"HEIC"`, `"AVIF"`.
/// Returns `"?"` when no known signature is matched.
String detectImageFormat(Uint8List bytes) {
  if (bytes.length < 4) return '?';
  // PNG
  if (bytes[0]==0x89 && bytes[1]==0x50 && bytes[2]==0x4E && bytes[3]==0x47) return 'PNG';
  // JPEG
  if (bytes[0]==0xFF && bytes[1]==0xD8) return 'JPEG';
  // WebP
  if (bytes[0]==0x52 && bytes[1]==0x49 && bytes[2]==0x46 && bytes[3]==0x46) {
    if (bytes.length>=12 && bytes[8]==0x57 && bytes[9]==0x45 && bytes[10]==0x42 && bytes[11]==0x50) return 'WebP';
  }
  // GIF
  if (bytes[0]==0x47 && bytes[1]==0x49 && bytes[2]==0x46 && bytes[3]==0x38) return 'GIF';
  // BMP
  if (bytes[0]==0x42 && bytes[1]==0x4D) return 'BMP';
  // ICO
  if (bytes[0]==0x00 && bytes[1]==0x00 && bytes[2]==0x01 && bytes[3]==0x00) return 'ICO';
  // TIFF
  if ((bytes[0]==0x49 && bytes[1]==0x49 && bytes[2]==0x2A && bytes[3]==0x00) ||
      (bytes[0]==0x4D && bytes[1]==0x4D && bytes[2]==0x00 && bytes[3]==0x2A)) return 'TIFF';
  // HEIC/HEIF (ftyp box)
  if (bytes.length>=12 && bytes[4]==0x66 && bytes[5]==0x74 && bytes[6]==0x79 && bytes[7]==0x70) {
    final b = String.fromCharCodes(bytes.sublist(8,12));
    if (b=='heic'||b=='heix'||b=='hevc'||b=='hevx'||b=='mif1') return 'HEIC';
    if (b=='avif') return 'AVIF';
    return b.toUpperCase();
  }
  // AVIF (alternative — same ftyp but explicit)
  if (bytes.length>=12 && String.fromCharCodes(bytes.sublist(8,12))=='avif') return 'AVIF';
  return '?';
}
