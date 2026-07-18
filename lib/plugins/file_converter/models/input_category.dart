/// Input extension classification — translated from C# Helpers.cs.
library;

import 'output_type.dart';

/// Map extension (lowercase, no dot) → InputCategory.
/// Full list from C# `Helpers.CompatibleInputExtensions` + category mapping.
InputCategory getInputCategory(String ext) {
  switch (ext) {
    // Audio
    case 'aac':
    case 'aiff':
    case 'ape':
    case 'cda':
    case 'flac':
    case 'mp3':
    case 'm4a':
    case 'm4b':
    case 'oga':
    case 'ogg':
    case 'opus':
    case 'wav':
    case 'wma':
      return InputCategory.audio;

    // Video
    case '3gp':
    case '3gpp':
    case 'avi':
    case 'bik':
    case 'flv':
    case 'm4v':
    case 'mp4':
    case 'mpg':
    case 'mpeg':
    case 'mov':
    case 'mkv':
    case 'ogv':
    case 'rm':
    case 'ts':
    case 'vob':
    case 'webm':
    case 'wmv':
      return InputCategory.video;

    // Image (including RAW camera formats)
    case 'arw':
    case 'avif':
    case 'bmp':
    case 'cr2':
    case 'dds':
    case 'dng':
    case 'exr':
    case 'heic':
    case 'heif':
    case 'ico':
    case 'jfif':
    case 'jpg':
    case 'jpeg':
    case 'nef':
    case 'png':
    case 'psd':
    case 'raf':
    case 'tga':
    case 'tif':
    case 'tiff':
    case 'svg':
    case 'xcf':
    case 'webp':
      return InputCategory.image;

    // Animated image (GIF is special — both image + animated)
    case 'gif':
      return InputCategory.animatedImage;

    // Documents
    case 'pdf':
    case 'doc':
    case 'docx':
    case 'ppt':
    case 'pptx':
    case 'odp':
    case 'ods':
    case 'odt':
    case 'xls':
    case 'xlsx':
      return InputCategory.document;

    default:
      return InputCategory.misc;
  }
}

/// Check whether [outputType] is compatible with the given input [category].
/// Translated from C# `Helpers.IsOutputTypeCompatibleWithCategory`.
bool isOutputCompatibleWithCategory(OutputType outputType, InputCategory category) {
  if (category == InputCategory.misc) {
    // Misc = tolerant, assume compatible.
    return true;
  }

  switch (outputType) {
    case OutputType.aac:
    case OutputType.flac:
    case OutputType.mp3:
    case OutputType.ogg:
    case OutputType.wav:
      return category == InputCategory.audio || category == InputCategory.video;

    case OutputType.avi:
    case OutputType.mkv:
    case OutputType.mp4:
    case OutputType.ogv:
    case OutputType.webm:
      return category == InputCategory.video ||
          category == InputCategory.animatedImage;

    case OutputType.avif:
    case OutputType.ico:
    case OutputType.jpg:
    case OutputType.png:
    case OutputType.webp:
      return category == InputCategory.image ||
          category == InputCategory.document ||
          category == InputCategory.animatedImage;

    case OutputType.gif:
      return category == InputCategory.image ||
          category == InputCategory.video ||
          category == InputCategory.animatedImage;

    case OutputType.pdf:
      return category == InputCategory.image ||
          category == InputCategory.document;

    case OutputType.none:
      return false;
  }
}

/// All extensions that FileConverter can handle as input (60+ extensions).
const compatibleInputExtensions = {
  '3gp', '3gpp', 'aac', 'aiff', 'ape', 'arw', 'avi', 'avif', 'bik', 'bmp',
  'cda', 'cr2', 'dds', 'dng', 'doc', 'docx', 'exr', 'flac', 'flv', 'gif',
  'heic', 'heif', 'ico', 'jfif', 'jpg', 'jpeg', 'm4a', 'm4b', 'm4v', 'mkv', 'mov',
  'mp3', 'mp4', 'mpg', 'mpeg', 'nef', 'odp', 'ods', 'odt', 'oga', 'ogg',
  'ogv', 'opus', 'pdf', 'png', 'ppt', 'pptx', 'psd', 'raf', 'rm', 'svg',
  'tga', 'tif', 'tiff', 'ts', 'vob', 'wav', 'webm', 'webp', 'wma', 'wmv',
  'xcf', 'xls', 'xlsx',
};
