/// Conversion settings — key constants + default values per output type.
///
/// Mirrors C# `ConversionPreset.ConversionSettingKeys` +
/// `ConversionPreset.InitializeDefaultSettings`.
library;

import '../models/output_type.dart';

// ── Setting key constants (mirrors C# ConversionSettingKeys) ──

const kAudioEncodingMode = 'AudioEncodingMode';
const kAudioBitrate = 'AudioBitrate';
const kAudioChannelCount = 'AudioChannelCount';
const kImageQuality = 'ImageQuality';
const kImageScale = 'ImageScale';
const kImageRotation = 'ImageRotation';
const kImageClampSizePowerOf2 = 'ImageClampSizePowerOf2';
const kImageMaximumSize = 'ImageMaximumSize';
const kVideoQuality = 'VideoQuality';
const kVideoEncodingSpeed = 'VideoEncodingSpeed';
const kVideoScale = 'VideoScale';
const kVideoRotation = 'VideoRotation';
const kVideoFramesPerSecond = 'VideoFramesPerSecond';
const kFFMPEGCustomCommand = 'FFMPEGCustomCommand';
const kEnableAudio = 'EnableAudio';
const kEnableFFMPEGCustomCommand = 'EnableFFMPEGCustomCommand';
const kHardwareAcceleration = 'HardwareAcceleration';
const kSpeedMultiplier = 'SpeedMultiplier';

// ── qpdf / PDF post-processing ──
const kPdfOptimize = 'PdfOptimize';
const kPdfLinearize = 'PdfLinearize';
const kPdfEncrypt = 'PdfEncrypt';
const kPdfEncryptUserPassword = 'PdfEncryptUserPassword';
const kPdfEncryptOwnerPassword = 'PdfEncryptOwnerPassword';
const kPdfEncryptKeyLength = 'PdfEncryptKeyLength';
const kPdfEncryptAllowPrint = 'PdfEncryptAllowPrint';
const kPdfEncryptAllowModify = 'PdfEncryptAllowModify';
const kPdfEncryptAllowCopy = 'PdfEncryptAllowCopy';
const kPdfEncryptAllowAnnotate = 'PdfEncryptAllowAnnotate';

// ── qpdf / structured modifications ──
const kPdfPageMode = 'PdfPageMode';
const kPdfRotate = 'PdfRotate';
const kPdfRotatePages = 'PdfRotatePages';
const kPdfSplitPages = 'PdfSplitPages';
const kPdfSplitCustom = 'PdfSplitCustom';
const kPdfPageOrder = 'PdfPageOrder';

// ── qpdf / advanced optimisation + watermark ──
const kPdfOptimizeImages = 'PdfOptimizeImages';
const kPdfDeterministicId = 'PdfDeterministicId';
const kPdfNormalizeContent = 'PdfNormalizeContent';
const kPdfWatermarkPath = 'PdfWatermarkPath';
const kPdfUnderlayPath = 'PdfUnderlayPath';

// ── Default settings per output type ──

/// Return default settings map for a given output type.
/// Translated from C# `ConversionPreset.InitializeDefaultSettings`.
Map<String, String> defaultSettingsFor(OutputType type) {
  switch (type) {
    // ── Audio ──
    case OutputType.aac:
      return {
        kAudioBitrate: '128',
        kAudioChannelCount: '0',
        kEnableFFMPEGCustomCommand: 'False',
        kFFMPEGCustomCommand: '',
      };
    case OutputType.flac:
      return {
        kAudioChannelCount: '0',
        kEnableFFMPEGCustomCommand: 'False',
        kFFMPEGCustomCommand: '',
      };
    case OutputType.ogg:
      return {
        kAudioBitrate: '160',
        kAudioChannelCount: '0',
        kEnableFFMPEGCustomCommand: 'False',
        kFFMPEGCustomCommand: '',
      };
    case OutputType.mp3:
      return {
        kAudioEncodingMode: 'mp3VBR',
        kAudioBitrate: '190',
        kAudioChannelCount: '0',
        kEnableFFMPEGCustomCommand: 'False',
        kFFMPEGCustomCommand: '',
      };
    case OutputType.wav:
      return {
        kAudioEncodingMode: 'wav16',
        kAudioChannelCount: '0',
        kEnableFFMPEGCustomCommand: 'False',
        kFFMPEGCustomCommand: '',
      };

    // ── Video ──
    case OutputType.avi:
      return {
        kEnableAudio: 'True',
        kVideoQuality: '20',
        kVideoScale: '1',
        kVideoRotation: '0',
        kAudioBitrate: '190',
        kEnableFFMPEGCustomCommand: 'False',
        kFFMPEGCustomCommand: '',
      };
    case OutputType.mkv:
      return {
        kEnableAudio: 'True',
        kVideoQuality: '28',
        kVideoEncodingSpeed: 'medium',
        kVideoScale: '1',
        kVideoRotation: '0',
        kAudioBitrate: '128',
        kEnableFFMPEGCustomCommand: 'False',
        kFFMPEGCustomCommand: '',
      };
    case OutputType.mp4:
      return {
        kEnableAudio: 'True',
        kVideoQuality: '28',
        kVideoEncodingSpeed: 'medium',
        kVideoScale: '1',
        kVideoRotation: '0',
        kAudioBitrate: '128',
        kEnableFFMPEGCustomCommand: 'False',
        kFFMPEGCustomCommand: '',
      };
    case OutputType.ogv:
      return {
        kEnableAudio: 'True',
        kVideoQuality: '7',
        kVideoScale: '1',
        kVideoRotation: '0',
        kAudioBitrate: '160',
        kEnableFFMPEGCustomCommand: 'False',
        kFFMPEGCustomCommand: '',
      };
    case OutputType.webm:
      return {
        kEnableAudio: 'True',
        kAudioBitrate: '160',
        kVideoQuality: '40',
        kVideoScale: '1',
        kVideoRotation: '0',
        kEnableFFMPEGCustomCommand: 'False',
        kFFMPEGCustomCommand: '',
      };

    // ── Images ──
    case OutputType.avif:
      return {
        kImageQuality: '50',
        kImageScale: '1',
        kImageRotation: '0',
        kImageClampSizePowerOf2: 'False',
        kImageMaximumSize: '0',
      };
    case OutputType.png:
      return {
        kImageScale: '1',
        kImageRotation: '0',
        kImageClampSizePowerOf2: 'False',
        kImageMaximumSize: '0',
      };
    case OutputType.jpg:
      return {
        kImageQuality: '90',
        kImageScale: '1',
        kImageRotation: '0',
        kImageClampSizePowerOf2: 'False',
        kImageMaximumSize: '0',
      };
    case OutputType.webp:
      return {
        kImageQuality: '40',
        kImageScale: '1',
        kImageRotation: '0',
        kImageClampSizePowerOf2: 'False',
        kImageMaximumSize: '0',
      };
    case OutputType.gif:
      return {
        kVideoScale: '1',
        kVideoRotation: '0',
        kVideoFramesPerSecond: '15',
      };
    case OutputType.ico:
      return {};

    // Documents
    case OutputType.pdf:
      return {
        'PdfDpi': '200',
        'PdfPageSize': 'A4',
        'PdfPageRange': 'all',
        kPdfOptimize: 'False',
        kPdfLinearize: 'False',
        kPdfEncrypt: 'False',
        kPdfEncryptUserPassword: '',
        kPdfEncryptOwnerPassword: '',
        kPdfEncryptKeyLength: '256',
        kPdfEncryptAllowPrint: 'True',
        kPdfEncryptAllowModify: 'True',
        kPdfEncryptAllowCopy: 'True',
        kPdfEncryptAllowAnnotate: 'True',
        kPdfRotate: '0',
        kPdfSplitPages: '0',
        kPdfPageOrder: '',
        kPdfOptimizeImages: 'False',
        kPdfDeterministicId: 'False',
        kPdfNormalizeContent: 'False',
        kPdfWatermarkPath: '',
        kPdfUnderlayPath: '',
      };

    case OutputType.none:
      return {};
  }
}

/// Return list of compatible input extensions for a given output type.
/// These are the most common inputs; actual compatibility is checked at runtime.
List<String> compatibleInputsFor(OutputType type) {
  switch (type) {
    case OutputType.aac:
    case OutputType.flac:
    case OutputType.mp3:
    case OutputType.ogg:
    case OutputType.wav:
      return const [
        '3gp', 'aac', 'aiff', 'ape', 'avi', 'flac', 'flv', 'm4a', 'm4b',
        'm4v', 'mkv', 'mov', 'mp3', 'mp4', 'oga', 'ogg', 'opus', 'wav',
        'webm', 'wma', 'wmv',
      ];
    case OutputType.avi:
    case OutputType.mkv:
    case OutputType.mp4:
    case OutputType.ogv:
    case OutputType.webm:
      return const [
        '3gp', 'avi', 'flv', 'gif', 'm4v', 'mkv', 'mov', 'mp4', 'mpg',
        'mpeg', 'ogv', 'webm', 'wmv',
      ];
    case OutputType.jpg:
    case OutputType.png:
    case OutputType.webp:
      return const [
        'avif', 'bmp', 'gif', 'heic', 'heif', 'ico', 'jfif', 'jpg', 'jpeg', 'png',
        'svg', 'tif', 'tiff', 'webp', 'pdf',
      ];
    case OutputType.gif:
      return const [
        'avi', 'bmp', 'gif', 'heic', 'heif', 'jpg', 'jpeg', 'mkv', 'mov', 'mp4', 'png',
        'svg', 'webm', 'webp', 'wmv',
      ];
    case OutputType.ico:
      return const [
        'bmp', 'gif', 'heic', 'heif', 'jpg', 'jpeg', 'png', 'svg', 'webp', 'ico',
      ];
    case OutputType.avif:
      return const [
        'avif', 'bmp', 'gif', 'heic', 'heif', 'jpg', 'jpeg', 'png', 'svg', 'tif', 'tiff', 'webp',
      ];
    case OutputType.pdf:
      return const [
        'bmp', 'doc', 'docx', 'jpg', 'jpeg', 'odp', 'ods', 'odt',
        'pdf', 'png', 'ppt', 'pptx', 'svg', 'tif', 'tiff', 'webp', 'xls', 'xlsx',
      ];
    case OutputType.none:
      return const [];
  }
}
