/// Output types and input categories — mirrors FileConverter C# enums.
library;

import 'package:flutter/material.dart';

/// Supported output formats (17 types, matching C# `OutputType` enum).
enum OutputType {
  none,
  aac,
  avi,
  avif,
  flac,
  gif,
  ico,
  jpg,
  mkv,
  mp3,
  mp4,
  ogg,
  ogv,
  pdf,
  png,
  wav,
  webm,
  webp,
}

/// File extension tool methods on [OutputType].
extension OutputTypeExt on OutputType {
  /// The lowercase file extension (no leading dot).
  String get extension {
    switch (this) {
      case OutputType.aac: return 'aac';
      case OutputType.avi: return 'avi';
      case OutputType.avif: return 'avif';
      case OutputType.flac: return 'flac';
      case OutputType.gif: return 'gif';
      case OutputType.ico: return 'ico';
      case OutputType.jpg: return 'jpg';
      case OutputType.mkv: return 'mkv';
      case OutputType.mp3: return 'mp3';
      case OutputType.mp4: return 'mp4';
      case OutputType.ogg: return 'ogg';
      case OutputType.ogv: return 'ogv';
      case OutputType.pdf: return 'pdf';
      case OutputType.png: return 'png';
      case OutputType.wav: return 'wav';
      case OutputType.webm: return 'webm';
      case OutputType.webp: return 'webp';
      case OutputType.none: return '';
    }
  }

  /// Human-readable label for UI.
  String get label {
    switch (this) {
      case OutputType.aac: return 'AAC Audio';
      case OutputType.avi: return 'AVI Video';
      case OutputType.avif: return 'AVIF Image';
      case OutputType.flac: return 'FLAC Audio';
      case OutputType.gif: return 'GIF Animation';
      case OutputType.ico: return 'ICO Icon';
      case OutputType.jpg: return 'JPEG Image';
      case OutputType.mkv: return 'MKV Video';
      case OutputType.mp3: return 'MP3 Audio';
      case OutputType.mp4: return 'MP4 Video';
      case OutputType.ogg: return 'OGG Audio';
      case OutputType.ogv: return 'OGV Video';
      case OutputType.pdf: return 'PDF Document';
      case OutputType.png: return 'PNG Image';
      case OutputType.wav: return 'WAV Audio';
      case OutputType.webm: return 'WebM Video';
      case OutputType.webp: return 'WebP Image';
      case OutputType.none: return 'None';
    }
  }

  /// Category group for UI grouping.
  OutputCategory get category {
    switch (this) {
      case OutputType.aac:
      case OutputType.flac:
      case OutputType.mp3:
      case OutputType.ogg:
      case OutputType.wav:
        return OutputCategory.audio;
      case OutputType.avi:
      case OutputType.mkv:
      case OutputType.mp4:
      case OutputType.ogv:
      case OutputType.webm:
        return OutputCategory.video;
      case OutputType.avif:
      case OutputType.gif:
      case OutputType.ico:
      case OutputType.jpg:
      case OutputType.png:
      case OutputType.webp:
        return OutputCategory.image;
      case OutputType.pdf:
        return OutputCategory.document;
      case OutputType.none:
        return OutputCategory.none;
    }
  }

  /// Whether multiple input files can be combined into a single output.
  bool get supportsCombine {
    switch (this) {
      case OutputType.aac:
      case OutputType.flac:
      case OutputType.mp3:
      case OutputType.ogg:
      case OutputType.wav:
      case OutputType.avi:
      case OutputType.mkv:
      case OutputType.mp4:
      case OutputType.ogv:
      case OutputType.webm:
      case OutputType.gif:
      case OutputType.pdf:
        return true;
      // Single-frame image formats — combining is meaningless
      case OutputType.avif:
      case OutputType.ico:
      case OutputType.jpg:
      case OutputType.png:
      case OutputType.webp:
      case OutputType.none:
        return false;
    }
  }

  /// Whether Phase 1 FFmpeg can produce this output type.
  bool get isPhase1Supported {
    switch (this) {
      case OutputType.aac:
      case OutputType.avi:
      case OutputType.flac:
      case OutputType.gif:
      case OutputType.ico:
      case OutputType.jpg:
      case OutputType.mkv:
      case OutputType.mp3:
      case OutputType.mp4:
      case OutputType.ogg:
      case OutputType.ogv:
      case OutputType.pdf:
      case OutputType.png:
      case OutputType.wav:
      case OutputType.webm:
      case OutputType.webp:
        return true;
      case OutputType.none:
        return false;
      case OutputType.avif:
        return true;
    }
  }

  // ── Feature capability flags ──

  /// Whether this format supports a full transform chain (rotation, flip,
  /// crop, pad) beyond simple scale. JPG/PNG/WebP only do simple
  /// scale+maxSize in their FFmpeg builders; AVIF/GIF/ICO/video formats use
  /// the full [_computeTransformArgs] chain.
  bool get supportsFullTransform {
    switch (this) {
      case OutputType.avif:
      case OutputType.gif:
      case OutputType.ico:
      case OutputType.avi:
      case OutputType.mkv:
      case OutputType.mp4:
      case OutputType.ogv:
      case OutputType.webm:
        return true;
      case OutputType.jpg:
      case OutputType.png:
      case OutputType.webp:
      case OutputType.aac:
      case OutputType.flac:
      case OutputType.mp3:
      case OutputType.ogg:
      case OutputType.wav:
      case OutputType.pdf:
      case OutputType.none:
        return false;
    }
  }

  /// Whether the "Max Size" constraint is meaningful for this output.
  /// Only relevant for still-image formats where the user may want to cap
  /// output dimensions. Redundant for ICO (always ≤256) and inapplicable
  /// to video/animation.
  bool get supportsMaxSize {
    switch (this) {
      case OutputType.jpg:
      case OutputType.png:
      case OutputType.webp:
      case OutputType.avif:
        return true;
      default:
        return false;
    }
  }

  /// Whether clamp-to-power-of-2 is applicable.
  /// Only image formats that go through [_computeTransformArgs].
  bool get supportsClampPo2 {
    switch (this) {
      case OutputType.avif:
      case OutputType.gif:
      case OutputType.ico:
        return true;
      default:
        return false;
    }
  }

  /// Whether the format offers multiple encoder choices.
  bool get supportsEncoderSelection {
    switch (this) {
      case OutputType.mkv:
      case OutputType.mp4:
        return true;
      // AVI (MPEG-4 only), OGV (Theora only), WebM (VP9 only) — single encoder
      default:
        return false;
    }
  }

  /// Whether video encoding speed preset is applicable.
  /// Only H.264/H.265 encoders support speed presets.
  bool get supportsSpeedPreset {
    switch (this) {
      case OutputType.mkv:
      case OutputType.mp4:
        return true;
      // AVI (MPEG-4 only), OGV (Theora), WebM (VP9) — no speed preset
      default:
        return false;
    }
  }

  /// Whether variable frame rate (PFR) is safe for this container.
  /// AVI stores a fixed FPS in its header — VFR playback is unreliable.
  bool get supportsVFR {
    switch (this) {
      case OutputType.avi:
        return false;
      default:
        return true;
    }
  }

  /// Whether playback speed adjustment is applicable.
  /// Video uses setpts filter; audio uses atempo. Not applicable to images/docs.
  bool get supportsSpeed {
    switch (this) {
      case OutputType.aac:
      case OutputType.avi:
      case OutputType.flac:
      case OutputType.mkv:
      case OutputType.mp3:
      case OutputType.mp4:
      case OutputType.ogg:
      case OutputType.ogv:
      case OutputType.wav:
      case OutputType.webm:
        return true;
      default:
        return false;
    }
  }

  /// Short format-only label for dropdown (e.g. "AAC", "MP4").
  String get shortLabel {
    switch (this) {
      case OutputType.aac: return 'AAC';
      case OutputType.avi: return 'AVI';
      case OutputType.avif: return 'AVIF';
      case OutputType.flac: return 'FLAC';
      case OutputType.gif: return 'GIF';
      case OutputType.ico: return 'ICO';
      case OutputType.jpg: return 'JPEG';
      case OutputType.mkv: return 'MKV';
      case OutputType.mp3: return 'MP3';
      case OutputType.mp4: return 'MP4';
      case OutputType.ogg: return 'OGG';
      case OutputType.ogv: return 'OGV';
      case OutputType.pdf: return 'PDF';
      case OutputType.png: return 'PNG';
      case OutputType.wav: return 'WAV';
      case OutputType.webm: return 'WebM';
      case OutputType.webp: return 'WebP';
      case OutputType.none: return '';
    }
  }
}

/// Category for grouping output types in UI.
enum OutputCategory { none, audio, video, image, document }

extension OutputCategoryExt on OutputCategory {
  IconData get icon {
    switch (this) {
      case OutputCategory.audio: return Icons.headphones;
      case OutputCategory.video: return Icons.videocam;
      case OutputCategory.image: return Icons.image;
      case OutputCategory.document: return Icons.description;
      case OutputCategory.none: return Icons.insert_drive_file;
    }
  }
}

/// Input file category (mirrors C# `InputCategoryNames`).
enum InputCategory { audio, video, image, animatedImage, document, misc }

/// Post-conversion action on input file.
enum PostConversionAction { none, moveInArchiveFolder, delete }

/// Conversion state machine.
enum ConversionState { unknown, ready, inProgress, done, failed }

/// Audio encoding mode for MP3 / WAV.
enum AudioEncodingMode { mp3VBR, mp3CBR, wav8, wav16, wav24, wav32 }

/// Video encoding speed preset.
enum VideoEncodingSpeed {
  ultraFast, superFast, veryFast, faster, fast,
  medium, slow, slower, verySlow,
}

/// Hardware acceleration mode.
enum HardwareAcceleration { off, cuda, amf }
