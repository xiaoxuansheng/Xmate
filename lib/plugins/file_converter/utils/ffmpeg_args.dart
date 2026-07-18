/// FFmpeg command-line argument builder — translated from C#
/// `ConversionJob_FFMPEG.cs` + `ConversionJob_FFMPEG.Converters.cs`.
library;

import 'dart:io';
import '../models/output_type.dart';
import '../models/conversion_settings.dart' as cs;

// ── FFmpeg pass ──

/// A single FFmpeg invocation (multi-pass formats like GIF need 2).
class FfmpegPass {
  final String name;
  final String arguments;
  final String? fileToDelete;
  /// If set, this temp file must be created before the pass runs
  /// (e.g. concat demuxer file list).
  final String? concatFilePath;
  final String? concatListContent;

  const FfmpegPass(this.name, this.arguments,
      {this.fileToDelete, this.concatFilePath, this.concatListContent});
}

// ── Builder ──

/// Build FFmpeg arguments for a conversion.
///
/// Returns a list of passes (most formats: 1 pass; GIF: 2 passes).
List<FfmpegPass> buildFfmpegPasses({
  required String ffmpegPath,
  required String inputPath,
  required String outputPath,
  required OutputType outputType,
  required Map<String, String> settings,
  HardwareAcceleration hwAccel = HardwareAcceleration.off,
}) {
  // -n = no overwrite (safe with unique output paths).
  // No -progress pipe:1 — we parse progress from stderr, and writing to stdout
  // would fill the OS pipe buffer (nobody reads stdout), deadlocking FFmpeg for
  // videos longer than ~8 seconds.
  const baseArgs = '-n';

  // Build full base args: -n + optional trim (-ss/-to)
  final trim = _trimInputArgs(settings);
  final fullBaseArgs = '$baseArgs $trim'.trimRight();

  // Check custom command first (matches C# logic).
  final customEnabled = _getBool(settings, cs.kEnableFFMPEGCustomCommand);
  if (customEnabled) {
    final customCmd = settings[cs.kFFMPEGCustomCommand] ?? '';
    return [
      FfmpegPass('Conversion',
          '$fullBaseArgs -i "$inputPath" $customCmd "$outputPath"'),
    ];
  }

  switch (outputType) {
    case OutputType.aac:
      return _injectSpeed(_buildAac(fullBaseArgs, inputPath, outputPath, settings), outputType, settings);
    case OutputType.avi:
      return _injectSpeed(_buildAvi(fullBaseArgs, inputPath, outputPath, settings), outputType, settings);
    case OutputType.flac:
      return _injectSpeed(_buildFlac(fullBaseArgs, inputPath, outputPath, settings), outputType, settings);
    case OutputType.gif:
      return _buildGif(fullBaseArgs, inputPath, outputPath, settings);
    case OutputType.ico:
      return _buildIco(fullBaseArgs, inputPath, outputPath, settings);
    case OutputType.jpg:
      return _buildJpg(fullBaseArgs, inputPath, outputPath, settings);
    case OutputType.mp4:
      return _injectSpeed(_buildMp4(fullBaseArgs, inputPath, outputPath, settings, hwAccel), outputType, settings);
    case OutputType.mkv:
      return _injectSpeed(_buildMkv(fullBaseArgs, inputPath, outputPath, settings, hwAccel), outputType, settings);
    case OutputType.mp3:
      return _injectSpeed(_buildMp3(fullBaseArgs, inputPath, outputPath, settings), outputType, settings);
    case OutputType.ogg:
      return _injectSpeed(_buildOgg(fullBaseArgs, inputPath, outputPath, settings), outputType, settings);
    case OutputType.ogv:
      return _injectSpeed(_buildOgv(fullBaseArgs, inputPath, outputPath, settings), outputType, settings);
    case OutputType.png:
      return _buildPng(fullBaseArgs, inputPath, outputPath, settings);
    case OutputType.wav:
      return _injectSpeed(_buildWav(fullBaseArgs, inputPath, outputPath, settings), outputType, settings);
    case OutputType.webm:
      return _injectSpeed(_buildWebm(fullBaseArgs, inputPath, outputPath, settings), outputType, settings);
    case OutputType.webp:
      return _buildWebp(fullBaseArgs, inputPath, outputPath, settings);
    case OutputType.avif:
      return _buildAvif(fullBaseArgs, inputPath, outputPath, settings);
    case OutputType.pdf:
      return _buildPdf(fullBaseArgs, inputPath, outputPath, settings);
    default:
      // Fallback: encode copy
      return [
        FfmpegPass('Conversion',
            '$fullBaseArgs -i "$inputPath" -c copy "$outputPath"'),
      ];
  }
}

/// Build the final concat pass for combine mode.
/// Phase 1 already converted each input to a temp file with per-file settings.
/// Phase 2 concatenates the temp files into the final output.
///
/// Returns null if the output type doesn't support combining.
FfmpegPass? buildConcatPass({
  required List<String> tempPaths,
  required String outputPath,
  required OutputType outputType,
  required Map<String, String> settings,
}) {
  const baseArgs = '-n';
  final n = tempPaths.length;

  switch (outputType) {
    // ── Audio: concat demuxer with stream copy ──
    case OutputType.aac:
    case OutputType.flac:
    case OutputType.mp3:
    case OutputType.ogg:
    case OutputType.wav:
      return _concatDemuxerPass(baseArgs, tempPaths, outputPath, 'audio');

    // ── Video: concat demuxer with stream copy ──
    case OutputType.avi:
    case OutputType.mkv:
    case OutputType.mp4:
    case OutputType.ogv:
    case OutputType.webm:
      return _concatDemuxerPass(baseArgs, tempPaths, outputPath, 'video');

    // ── GIF: multi-image → palette gen (pass 1 only, pass 2 in engine) ──
    case OutputType.gif:
      final fps = int.tryParse(settings[cs.kVideoFramesPerSecond] ?? '') ?? 15;
      final inputArgs = tempPaths.map((p) => '-i "$p"').join(' ');
      final refs = List.generate(n, (i) => '[$i:v]').join();
      final paletteFilter = '$refs concat=n=$n:v=1:a=0,fps=$fps[outv];[outv]palettegen';
      final baseName = outputPath.split(RegExp(r'[/\\]')).last.replaceAll(RegExp(r'\.[^.]+$'), '');
      final palettePath = _tempFilePath('$baseName - palette.png');
      return FfmpegPass('Combine to GIF',
          '$baseArgs $inputArgs -filter_complex "$paletteFilter" "$palettePath"',
          fileToDelete: palettePath);

    // ── PDF: multi-image → multi-page PDF ──
    case OutputType.pdf:
      final dpi = int.tryParse(settings['PdfDpi'] ?? '') ?? 200;
      final pageSize = settings['PdfPageSize'] ?? 'A4';
      final dims = _pdfPageDims(pageSize);
      final inputArgs = tempPaths.map((p) => '-i "$p"').join(' ');
      // Build per-page pad filter
      final parts = <String>[];
      for (int i = 0; i < n; i++) {
        if (dims != null) {
          final w = (dims.$1 * dpi / 72).round();
          final h = (dims.$2 * dpi / 72).round();
          parts.add('[$i:v]scale=$w:$h:force_original_aspect_ratio=decrease,'
              'pad=$w:$h:(ow-iw)/2:(oh-ih)/2:white[p$i]');
        } else {
          parts.add('[$i:v]copy[p$i]');
        }
      }
      final vf = '-filter_complex "${parts.join(";")}"';
      final maps = List.generate(n, (i) => '-map "[p$i]"').join(' ');
      return FfmpegPass('Combine to PDF',
          '$baseArgs $inputArgs $vf $maps -f pdf "$outputPath"');

    default:
      return null;
  }
}

/// Build concat demuxer file list + return pass that references it.
/// Build a proper temp file path using the system temp directory.
String _tempFilePath(String name) =>
    '${Directory.systemTemp.path}${Platform.pathSeparator}$name';

FfmpegPass _concatDemuxerPass(
    String baseArgs, List<String> paths, String output, String label) {
  final concatFile = _uniquePath(_tempFilePath('xmate_concat_${output.hashCode.abs().toRadixString(36)}.txt'));
  final concatContent = paths.map((p) => "file '${p.replaceAll("'", "'\\''")}'").join('\n');
  return FfmpegPass('Combine $label',
      '$baseArgs -f concat -safe 0 -i "$concatFile" -c copy "$output"',
      concatFilePath: concatFile, concatListContent: concatContent);
}


// ── Audio converters ──

List<FfmpegPass> _buildAac(
    String baseArgs, String input, String output, Map<String, String> s) {
  final channel = _channelArgs(int.tryParse(s[cs.kAudioChannelCount] ?? '') ?? 0);
  final bitrate = int.tryParse(s[cs.kAudioBitrate] ?? '') ?? 128;
  final quality = aacBitrateToQuality(bitrate);
  return [
    FfmpegPass('Convert to AAC',
        '$baseArgs -i "$input" -c:a aac -q:a $quality $channel -write_apetag 1 "$output"'),
  ];
}

List<FfmpegPass> _buildFlac(
    String baseArgs, String input, String output, Map<String, String> s) {
  final channel = _channelArgs(int.tryParse(s[cs.kAudioChannelCount] ?? '') ?? 0);
  return [
    FfmpegPass('Convert to FLAC',
        '$baseArgs -i "$input" -compression_level 12 $channel "$output"'),
  ];
}

List<FfmpegPass> _buildMp3(
    String baseArgs, String input, String output, Map<String, String> s) {
  final channel = _channelArgs(int.tryParse(s[cs.kAudioChannelCount] ?? '') ?? 0);
  final mode = s[cs.kAudioEncodingMode] ?? 'mp3VBR';
  final bitrate = int.tryParse(s[cs.kAudioBitrate] ?? '') ?? 190;
  const meta = '-id3v2_version 3 -write_id3v1 1';

  if (mode == 'mp3CBR') {
    return [
      FfmpegPass('Convert to MP3 (CBR)',
          '$baseArgs -i "$input" -codec:a libmp3lame -b:a ${bitrate}k $channel $meta "$output"'),
    ];
  }
  // VBR (default)
  final quality = mp3VbrBitrateToQuality(bitrate);
  return [
    FfmpegPass('Convert to MP3 (VBR)',
        '$baseArgs -i "$input" -codec:a libmp3lame -q:a $quality $channel $meta "$output"'),
  ];
}

List<FfmpegPass> _buildOgg(
    String baseArgs, String input, String output, Map<String, String> s) {
  final channel = _channelArgs(int.tryParse(s[cs.kAudioChannelCount] ?? '') ?? 0);
  final bitrate = int.tryParse(s[cs.kAudioBitrate] ?? '') ?? 160;
  final quality = oggVbrBitrateToQuality(bitrate);
  return [
    FfmpegPass('Convert to OGG',
        '$baseArgs -i "$input" -vn -codec:a libvorbis -qscale:a $quality $channel "$output"'),
  ];
}

List<FfmpegPass> _buildWav(
    String baseArgs, String input, String output, Map<String, String> s) {
  final channel = _channelArgs(int.tryParse(s[cs.kAudioChannelCount] ?? '') ?? 0);
  final mode = s[cs.kAudioEncodingMode] ?? 'wav16';
  final codec = wavEncodingToCodec(mode);
  return [
    FfmpegPass('Convert to WAV',
        '$baseArgs -i "$input" -acodec $codec $channel "$output"'),
  ];
}

// ── Video converters ──

List<FfmpegPass> _buildAvi(
    String baseArgs, String input, String output, Map<String, String> s) {
  final quality = int.tryParse(s[cs.kVideoQuality] ?? '') ?? 20;
  final bitrate = int.tryParse(s[cs.kAudioBitrate] ?? '') ?? 190;
  final enableAudio = _getBool(s, cs.kEnableAudio);
  final encoder = s['VideoEncoder'] ?? 'mpeg4';

  final transform = _computeTransformArgs(s, OutputType.avi);
  final vf = _encapsulate('-vf', transform);

  String audioArgs = '-an';
  if (enableAudio) {
    final aq = mp3VbrBitrateToQuality(bitrate);
    audioArgs = '-c:a libmp3lame -qscale:a $aq';
  }

  final vc = _videoCodec(encoder, quality, '', HardwareAcceleration.off);
  final fpsArgs = _fpsArgs(s);
  return [
    FfmpegPass('Convert to AVI',
        '$baseArgs -i "$input" -c:v ${vc.name} ${vc.codecArgs} $fpsArgs $audioArgs $vf -id3v2_version 3 -write_id3v1 1 "$output"'),
  ];
}

List<FfmpegPass> _buildMp4(String baseArgs, String input, String output,
    Map<String, String> s, HardwareAcceleration hwAccel) {
  final quality = int.tryParse(s[cs.kVideoQuality] ?? '') ?? 28;
  final speed = s[cs.kVideoEncodingSpeed] ?? 'medium';
  final bitrate = int.tryParse(s[cs.kAudioBitrate] ?? '') ?? 128;
  final enableAudio = _getBool(s, cs.kEnableAudio);
  final encoder = s['VideoEncoder'] ?? 'libx264';

  final transform = _computeTransformArgs(s, OutputType.mp4, hwAccel);
  final vf = _encapsulate('-vf', transform);

  String audioArgs = '-an';
  if (enableAudio) {
    final aq = aacBitrateToQuality(bitrate);
    audioArgs = '-c:a aac -qscale:a $aq';
  }

  // Build video codec args
  final vc = _videoCodec(encoder, quality, speed, hwAccel);
  final hwAccelArg = vc.hwAccelArg;
  final codecArgs = vc.codecArgs;

  final muxFlags = encoder == 'libx264' ? ' -movflags +faststart' : '';
  final fpsArgs = _fpsArgs(s);

  return [
    FfmpegPass('Convert to MP4',
        '$baseArgs $hwAccelArg-i "$input" -c:v ${vc.name} $codecArgs $fpsArgs $audioArgs $vf$muxFlags "$output"'),
  ];
}

List<FfmpegPass> _buildMkv(String baseArgs, String input, String output,
    Map<String, String> s, HardwareAcceleration hwAccel) {
  final quality = int.tryParse(s[cs.kVideoQuality] ?? '') ?? 28;
  final speed = s[cs.kVideoEncodingSpeed] ?? 'medium';
  final bitrate = int.tryParse(s[cs.kAudioBitrate] ?? '') ?? 128;
  final enableAudio = _getBool(s, cs.kEnableAudio);
  final encoder = s['VideoEncoder'] ?? 'libx264';

  final transform = _computeTransformArgs(s, OutputType.mkv, hwAccel);
  final vf = _encapsulate('-vf', transform);

  String audioArgs = '-an';
  if (enableAudio) {
    final aq = aacBitrateToQuality(bitrate);
    audioArgs = '-c:a aac -qscale:a $aq';
  }

  final vc = _videoCodec(encoder, quality, speed, hwAccel);
  final fpsArgs = _fpsArgs(s);

  return [
    FfmpegPass('Convert to MKV',
        '$baseArgs ${vc.hwAccelArg}-i "$input" -c:v ${vc.name} ${vc.codecArgs} $fpsArgs $audioArgs $vf "$output"'),
  ];
}

List<FfmpegPass> _buildOgv(
    String baseArgs, String input, String output, Map<String, String> s) {
  final quality = int.tryParse(s[cs.kVideoQuality] ?? '') ?? 7;
  final bitrate = int.tryParse(s[cs.kAudioBitrate] ?? '') ?? 160;
  final enableAudio = _getBool(s, cs.kEnableAudio);
  final encoder = s['VideoEncoder'] ?? 'libtheora';

  final transform = _computeTransformArgs(s, OutputType.ogv);
  final vf = _encapsulate('-vf', transform);

  String audioArgs = '-an';
  if (enableAudio) {
    final aq = oggVbrBitrateToQuality(bitrate);
    audioArgs = '-codec:a libvorbis -qscale:a $aq';
  }

  final vc = _videoCodec(encoder, quality, '', HardwareAcceleration.off);
  final fpsArgs = _fpsArgs(s);
  return [
    FfmpegPass('Convert to OGV',
        '$baseArgs -i "$input" -c:v ${vc.name} ${vc.codecArgs} $fpsArgs $audioArgs $vf "$output"'),
  ];
}

List<FfmpegPass> _buildWebm(
    String baseArgs, String input, String output, Map<String, String> s) {
  final quality = int.tryParse(s[cs.kVideoQuality] ?? '') ?? 40;
  final bitrate = int.tryParse(s[cs.kAudioBitrate] ?? '') ?? 160;
  final enableAudio = _getBool(s, cs.kEnableAudio);
  final encoder = s['VideoEncoder'] ?? 'libvpx-vp9';

  final transform = _computeTransformArgs(s, OutputType.webm);
  final vf = _encapsulate('-vf', transform);

  String audioArgs = '-an';
  if (enableAudio) {
    final aq = oggVbrBitrateToQuality(bitrate);
    audioArgs = '-c:a libvorbis -qscale:a $aq';
  }

  final vc = _videoCodec(encoder, quality, '', HardwareAcceleration.off);
  final fpsArgs = _fpsArgs(s);
  return [
    FfmpegPass('Convert to WebM',
        '$baseArgs -i "$input" -c:v ${vc.name} ${vc.codecArgs} $fpsArgs $audioArgs $vf "$output"'),
  ];
}

// ── Image converters ──

List<FfmpegPass> _buildJpg(
    String baseArgs, String input, String output, Map<String, String> s) {
  final quality = int.tryParse(s[cs.kImageQuality] ?? '') ?? 90;
  final scale = double.tryParse(s[cs.kImageScale] ?? '') ?? 1.0;
  final maxSize = int.tryParse(s[cs.kImageMaximumSize] ?? '') ?? 0;
  final q = jpgQualityIndex(quality);

  final scaleArgs = _mergeVf(_scaleArgs(scale), _maxSizeScaleArgs(maxSize));
  return [
    FfmpegPass('Convert to JPEG',
        '$baseArgs -i "$input" -q:v $q $scaleArgs "$output"'),
  ];
}

List<FfmpegPass> _buildPng(
    String baseArgs, String input, String output, Map<String, String> s) {
  final scale = double.tryParse(s[cs.kImageScale] ?? '') ?? 1.0;
  final maxSize = int.tryParse(s[cs.kImageMaximumSize] ?? '') ?? 0;
  final scaleArgs = _mergeVf(_scaleArgs(scale), _maxSizeScaleArgs(maxSize));
  return [
    FfmpegPass('Convert to PNG',
        '$baseArgs -i "$input" -compression_level 100 $scaleArgs "$output"'),
  ];
}

List<FfmpegPass> _buildWebp(
    String baseArgs, String input, String output, Map<String, String> s) {
  final quality = int.tryParse(s[cs.kImageQuality] ?? '') ?? 40;
  final scale = double.tryParse(s[cs.kImageScale] ?? '') ?? 1.0;
  final maxSize = int.tryParse(s[cs.kImageMaximumSize] ?? '') ?? 0;
  final scaleArgs = _mergeVf(_scaleArgs(scale), _maxSizeScaleArgs(maxSize));
  return [
    FfmpegPass('Convert to WebP',
        '$baseArgs -i "$input" -c:v libwebp -quality $quality $scaleArgs "$output"'),
  ];
}

List<FfmpegPass> _buildGif(
    String baseArgs, String input, String output, Map<String, String> s) {
  final fps = int.tryParse(s[cs.kVideoFramesPerSecond] ?? '') ?? 15;
  final transform = _computeTransformArgs(s, OutputType.gif);
  final transforms = transform.isNotEmpty ? '$transform,fps=$fps' : 'fps=$fps';

  // Two-pass GIF: 1 = palettegen, 2 = paletteuse
  final baseName = output.split(RegExp(r'[/\\]')).last.replaceAll(RegExp(r'\.[^.]+$'), '');
  final palettePath = _uniquePath(_tempFilePath('$baseName - palette.png'));

  return [
    FfmpegPass('Generate palette',
        '$baseArgs -i "$input" -vf "$transforms,palettegen" "$palettePath"',
        fileToDelete: palettePath),
    FfmpegPass('Create GIF',
        '$baseArgs -i "$input" -i "$palettePath" -lavfi "$transforms,paletteuse" "$output"'),
  ];
}

List<FfmpegPass> _buildIco(
    String baseArgs, String input, String output, Map<String, String> s) {
  // Multi-size ICO: produce 16, 32, 48, 128, 256 px variants via filter_complex.
  // Apply user transforms (scale/rotation/crop/flip/clampPo2) first, then
  // split into 5 streams, scale+pad each to the target square size.
  const sizes = [16, 32, 48, 128, 256];

  // Build pre-split transform chain from user settings
  final transform = _computeTransformArgs(s, OutputType.ico);
  final preTransform = transform.isNotEmpty ? '$transform,' : '';

  // Build split + per-size scale+pad
  final buf = StringBuffer();
  buf.write('"');
  // Split into N streams
  buf.write('[0:v]${preTransform}split=${sizes.length}');
  for (int i = 0; i < sizes.length; i++) {
    buf.write('[s$i]');
  }
  buf.write(';');

  // Per-size: scale down (if larger) + pad to square with transparency
  for (int i = 0; i < sizes.length; i++) {
    final sz = sizes[i];
    buf.write('[s$i]scale=\'min(iw,$sz)\':\'min(ih,$sz)\':force_original_aspect_ratio=decrease,');
    buf.write('pad=$sz:$sz:(ow-iw)/2:(oh-ih)/2:0x00000000[t$i]');
    if (i < sizes.length - 1) buf.write(';');
  }
  buf.write('"');

  // Build -map args for each output stream
  final mapArgs = StringBuffer();
  for (int i = 0; i < sizes.length; i++) {
    mapArgs.write(' -map "[t$i]"');
  }

  return [
    FfmpegPass('Convert to ICO (multi-size)',
        '$baseArgs -i "$input" -filter_complex ${buf.toString()}$mapArgs "$output"'),
  ];
}

/// AVIF still-image encoding via libaom-av1.
List<FfmpegPass> _buildAvif(
    String baseArgs, String input, String output, Map<String, String> s) {
  final quality = int.tryParse(s[cs.kImageQuality] ?? '') ?? 50;
  // Map 0-100 slider → CRF 63-0 (lower CRF = better quality)
  final crf = ((100 - quality) / 100.0 * 63).round().clamp(0, 63);

  final transform = _computeTransformArgs(s, OutputType.avif);
  final vf = _encapsulate('-vf', transform);

  return [
    FfmpegPass('Convert to AVIF',
        '$baseArgs -i "$input" -c:v libaom-av1 -still-picture 1 -crf $crf $vf "$output"'),
  ];
}

/// PDF output — image-to-PDF via FFmpeg pdf muxer.
/// Supports DPI (controls raster resolution) and page size (A4/Letter/etc.).
List<FfmpegPass> _buildPdf(
    String baseArgs, String input, String output, Map<String, String> s) {
  final dpi = int.tryParse(s['PdfDpi'] ?? '') ?? 200;
  final pageSize = s['PdfPageSize'] ?? 'A4';
  final dims = _pdfPageDims(pageSize);

  // Build filter chain: scale to page dimensions at target DPI, then force PDF
  final parts = <String>[];
  if (dims != null) {
    // Scale image to fit the page dimensions at the given DPI
    final w = (dims.$1 * dpi / 72).round();
    final h = (dims.$2 * dpi / 72).round();
    parts.add('scale=$w:$h:force_original_aspect_ratio=decrease');
    // Pad to exact page size with white background
    parts.add('pad=$w:$h:(ow-iw)/2:(oh-ih)/2:white');
  }
  final vf = _encapsulate('-vf', parts.join(','));

  return [
    FfmpegPass('Convert to PDF',
        '$baseArgs -i "$input" $vf -f pdf "$output"'),
  ];
}

/// Page size → (width, height) in PostScript points (1/72 inch).
(int, int)? _pdfPageDims(String size) {
  switch (size) {
    case 'A4': return (595, 842);
    case 'Letter': return (612, 792);
    case 'Legal': return (612, 1008);
    case 'A3': return (842, 1191);
    case 'A5': return (420, 595);
    case 'B5': return (499, 709);
    default: return null;
  }
}

// ── Quality mapping functions (from C# Converters.cs) ──

/// AAC VBR bitrate → quality index string.
/// From C# `AACBitrateToQualityIndex`.
String aacBitrateToQuality(int bitrate) {
  switch (bitrate) {
    case 460: return '3.9';
    case 340: return '3';
    case 256: return '2.2';
    case 224: return '1.9';
    case 192: return '1.6';
    case 155: return '1.3';
    case 128: return '1';
    case 112: return '0.9';
    case 96:  return '0.75';
    case 80:  return '0.6';
    case 64:  return '0.45';
    case 48:  return '0.3';
    case 32:  return '0.2';
    case 16:  return '0.1';
    default:  return '1'; // best-effort fallback
  }
}

/// MP3 VBR bitrate → quality index (0-9).
/// From C# `MP3VBRBitrateToQualityIndex`.
int mp3VbrBitrateToQuality(int bitrate) {
  switch (bitrate) {
    case 245: return 0;
    case 225: return 1;
    case 190: return 2;
    case 175: return 3;
    case 165: return 4;
    case 130: return 5;
    case 115: return 6;
    case 100: return 7;
    case 85:  return 8;
    case 65:  return 9;
    default:  return 2;
  }
}

/// OGG Vorbis bitrate → quality index (-2 to 10).
/// From C# `OGGVBRBitrateToQualityIndex`.
int oggVbrBitrateToQuality(int bitrate) {
  switch (bitrate) {
    case 500: return 10;
    case 320: return 9;
    case 256: return 8;
    case 224: return 7;
    case 192: return 6;
    case 160: return 5;
    case 128: return 4;
    case 112: return 3;
    case 96:  return 2;
    case 80:  return 1;
    case 64:  return 0;
    case 48:  return -1;
    case 32:  return -2;
    default:  return 5;
  }
}

/// H.264 quality (0-51) → CRF (51-0).
/// From C# `H264QualityToCRF`.
int h264QualityToCRF(int quality) => (51 - quality).clamp(0, 51);

/// MPEG4 quality (0-31) → quality index (31-0).
/// From C# `MPEG4QualityToQualityIndex`.
int mpeg4QualityIndex(int quality) => (31 - quality).clamp(0, 31);

/// JPG quality (0-100) → FFmpeg quality index (31-1).
/// From C# `JPGQualityToQualityIndex`.
int jpgQualityIndex(int quality) {
  // Map 0-100 to 31-1 (lower = better quality)
  final q = ((100 - quality) / 100.0 * 30 + 1).round();
  return q.clamp(1, 31);
}

/// WebM VP9 quality (0-63) → CRF (63-0).
/// From C# `WebmQualityToCRF`.
int webmQualityToCRF(int quality) => (63 - quality).clamp(0, 63);

/// H.264 encoding speed → preset string.
/// From C# `H264EncodingSpeedToPreset`.
String h264SpeedToPreset(VideoEncodingSpeed speed) {
  switch (speed) {
    case VideoEncodingSpeed.ultraFast: return 'ultrafast';
    case VideoEncodingSpeed.superFast: return 'superfast';
    case VideoEncodingSpeed.veryFast: return 'veryfast';
    case VideoEncodingSpeed.faster: return 'faster';
    case VideoEncodingSpeed.fast: return 'fast';
    case VideoEncodingSpeed.medium: return 'medium';
    case VideoEncodingSpeed.slow: return 'slow';
    case VideoEncodingSpeed.slower: return 'slower';
    case VideoEncodingSpeed.verySlow: return 'veryslow';
  }
}

/// WAV encoding mode → PCM codec.
/// From C# `WAVEncodingToCodecArgument`.
String wavEncodingToCodec(String mode) {
  switch (mode) {
    case 'wav8':  return 'pcm_s8le';
    case 'wav16': return 'pcm_s16le';
    case 'wav24': return 'pcm_s24le';
    case 'wav32': return 'pcm_s32le';
    default:      return 'pcm_s16le';
  }
}

// ── Helper functions ──

/// Wrap [args] in the option syntax: `-vf "args"`.
String _encapsulate(String option, String args) {
  if (args.isEmpty) return '';
  return '$option "$args"';
}

/// Compute audio channel args from C# `ComputeAudioChannelArgs`.
String _channelArgs(int channels) {
  return channels > 0 ? '-ac $channels' : '';
}

/// Compute transform (scale + rotation) args from C# `ComputeTransformArgs`.
String _computeTransformArgs(Map<String, String> s, OutputType outputType, [HardwareAcceleration hwAccel = HardwareAcceleration.off]) {
  final scale = double.tryParse(s[cs.kVideoScale] ?? s[cs.kImageScale] ?? '') ?? 1.0;
  final rotation = double.tryParse(s[cs.kVideoRotation] ?? s[cs.kImageRotation] ?? '') ?? 0.0;

  String scaleArgs = '';
  if ((scale - 1.0).abs() >= 0.005) {
    if (outputType == OutputType.mkv || outputType == OutputType.mp4) {
      // H.264 requires even dimensions
      if (hwAccel == HardwareAcceleration.cuda) {
        scaleArgs = 'scale_cuda=trunc(iw*$scale/2)*2:trunc(ih*$scale/2)*2:format=yuv420p';
      } else {
        scaleArgs = 'scale=trunc(iw*$scale/2)*2:trunc(ih*$scale/2)*2';
      }
    } else {
      scaleArgs = 'scale=iw*$scale:ih*$scale';
    }
  }

  String rotationArgs = '';
  if ((rotation - 90).abs() <= 0.05) {
    rotationArgs = 'transpose=2';
  } else if ((rotation - 180).abs() <= 0.05) {
    rotationArgs = 'vflip,hflip';
  } else if ((rotation - 270).abs() <= 0.05) {
    rotationArgs = 'transpose=1';
  }

  // Flip H / V
  final flipH = _getBool(s, 'FlipH');
  final flipV = _getBool(s, 'FlipV');

  // Crop (values in pixels)
  final cropL = int.tryParse(s['CropLeft'] ?? '') ?? 0;
  final cropT = int.tryParse(s['CropTop'] ?? '') ?? 0;
  final cropR = int.tryParse(s['CropRight'] ?? '') ?? 0;
  final cropB = int.tryParse(s['CropBottom'] ?? '') ?? 0;

  // Pad (values in pixels)
  final padL = int.tryParse(s['PadLeft'] ?? '') ?? 0;
  final padT = int.tryParse(s['PadTop'] ?? '') ?? 0;
  final padR = int.tryParse(s['PadRight'] ?? '') ?? 0;
  final padB = int.tryParse(s['PadBottom'] ?? '') ?? 0;
  final padC = s['PadColor'] ?? 'black';

  // Clamp to power of 2 (image only — stored as flag, applied via scale filter)
  final clampPo2 = _getBool(s, 'ClampPo2');

  // Max image size — constrain longest side
  final maxSize = int.tryParse(s[cs.kImageMaximumSize] ?? '') ?? 0;

  // Build combined transform
  final parts = <String>[];
  if (scaleArgs.isNotEmpty) parts.add(scaleArgs);
  if (maxSize > 0) parts.add("scale='min(iw,$maxSize)':'min(ih,$maxSize)':force_original_aspect_ratio=decrease");
  if (rotationArgs.isNotEmpty) parts.add(rotationArgs);
  if (flipH) parts.add('hflip');
  if (flipV) parts.add('vflip');
  if ((cropL + cropT + cropR + cropB) > 0) {
    parts.add('crop=in_w-${cropL + cropR}:in_h-${cropT + cropB}:$cropL:$cropT');
  }
  if (clampPo2) {
    parts.add("scale='2^round(log(iw)/log(2))':'2^round(log(ih)/log(2))'");
  }
  if ((padL + padT + padR + padB) > 0) {
    parts.add('pad=iw+${padL + padR}:ih+${padT + padB}:$padL:$padT:$padC');
  }

  // Force yuv420p for H.264 in MP4/MKV for broad compatibility.
  // CUDA already includes format=yuv420p in scale_cuda above.
  if (hwAccel != HardwareAcceleration.cuda &&
      (outputType == OutputType.mkv || outputType == OutputType.mp4)) {
    parts.add('format=yuv420p');
  }

  return parts.join(',');
}

/// Scale arg string for image output.
String _scaleArgs(double scale) {
  if ((scale - 1.0).abs() >= 0.005) {
    return '-vf scale=iw*$scale:ih*$scale';
  }
  return '';
}

/// Build scale filter arg to constrain the longest side to [maxSize] pixels.
/// Returns empty string if maxSize <= 0.
/// Uses escaped commas for FFmpeg filter graph compatibility.
String _maxSizeScaleArgs(int maxSize) {
  if (maxSize <= 0) return '';
  return "scale='min(iw,$maxSize)':'min(ih,$maxSize)':force_original_aspect_ratio=decrease";
}

/// Merge two -vf arguments (e.g. scale + maxSize) into a single -vf chain.
/// Both args are expected to start with '-vf ' or be empty.
String _mergeVf(String a, String b) {
  final aBody = a.startsWith('-vf ') ? a.substring(4) : a;
  final bBody = b.startsWith('-vf ') ? b.substring(4) : b;
  if (aBody.isEmpty) return b;
  if (bBody.isEmpty) return a.startsWith('-vf ') ? a : '-vf $aBody';
  return '-vf "$aBody,$bBody"';
}

bool _getBool(Map<String, String> m, String key) {
  final v = m[key] ?? '';
  return v == 'True' || v == 'true';
}

/// Encoder name from UI → base FFmpeg codec name.
String _encoderFfmpegName(String enc) {
  switch (enc) {
    case 'libx264': return 'libx264';
    case 'libx265': return 'libx265';
    case 'libvpx-vp9': return 'libvpx-vp9';
    case 'mpeg4': return 'mpeg4';
    case 'libtheora': return 'libtheora';
    default: return enc;
  }
}

/// Result from [_videoCodec]: codec name + args + optional hwaccel prefix.
class _VideoCodecResult {
  final String name;
  final String codecArgs;
  final String hwAccelArg;
  const _VideoCodecResult({required this.name, required this.codecArgs, this.hwAccelArg = ''});
}

/// Build codec name and arguments based on encoder, quality, speed, and hw accel.
_VideoCodecResult _videoCodec(String encoder, int quality, String speed, HardwareAcceleration hwAccel) {
  final name = _encoderFfmpegName(encoder);

  // -- Hardware acceleration overrides --
  if (hwAccel == HardwareAcceleration.cuda) {
    if (encoder == 'libx264' || encoder == 'libx265') {
      final qp = (encoder == 'libx264') ? h264QualityToCRF(quality) : (51 - quality).clamp(0, 51);
      final nvPreset = _nvencPresetStr(speed);
      return _VideoCodecResult(name: 'h264_nvenc',
          codecArgs: '-preset $nvPreset -rc constqp -qp $qp',
          hwAccelArg: '-hwaccel cuda -hwaccel_output_format cuda ');
    }
  }
  if (hwAccel == HardwareAcceleration.amf) {
    if (encoder == 'libx264') {
      final qp = h264QualityToCRF(quality);
      final amfQ = _amfQualityStr(speed);
      final bqp = (qp + 2).clamp(0, 51);
      return _VideoCodecResult(name: 'h264_amf',
          codecArgs: '-usage transcoding -quality $amfQ -qp_i $qp -qp_p $qp -qp_b $bqp');
    }
  }

  // -- Software encoding (default) --
  switch (encoder) {
    case 'libx264':
      final preset = h264SpeedToPresetStr(speed);
      final crf = h264QualityToCRF(quality);
      return _VideoCodecResult(name: name, codecArgs: '-preset $preset -crf $crf');

    case 'libx265':
      final preset = h264SpeedToPresetStr(speed);
      final crf = (51 - quality).clamp(0, 51);
      return _VideoCodecResult(name: name, codecArgs: '-preset $preset -crf $crf');

    case 'libvpx-vp9':
      if (quality == 63) {
        return _VideoCodecResult(name: name, codecArgs: '-lossless 1');
      }
      final crf = (63 - quality).clamp(0, 63);
      return _VideoCodecResult(name: name, codecArgs: '-crf $crf -b:v 0');

    case 'mpeg4':
      final q = (31 - quality).clamp(0, 31);
      return _VideoCodecResult(name: name, codecArgs: '-vtag xvid -qscale:v $q');

    case 'libtheora':
      return _VideoCodecResult(name: name, codecArgs: '-qscale:v $quality');

    default:
      return _VideoCodecResult(name: name, codecArgs: '-crf ${h264QualityToCRF(quality)}');
  }
}

String h264SpeedToPresetStr(String s) {
  switch (s.toLowerCase()) {
    case 'ultrafast': return 'ultrafast';
    case 'superfast': return 'superfast';
    case 'veryfast': return 'veryfast';
    case 'faster': return 'faster';
    case 'fast': return 'fast';
    case 'medium': return 'medium';
    case 'slow': return 'slow';
    case 'slower': return 'slower';
    case 'veryslow': return 'veryslow';
    default: return 'medium';
  }
}

String _nvencPresetStr(String s) {
  switch (s.toLowerCase()) {
    case 'ultrafast': return 'p1';
    case 'superfast': return 'p2';
    case 'veryfast': return 'p3';
    case 'faster': case 'fast': case 'medium': return 'p4';
    case 'slow': return 'p5';
    case 'slower': return 'p6';
    case 'veryslow': return 'p7';
    default: return 'p4';
  }
}

String _amfQualityStr(String s) {
  switch (s.toLowerCase()) {
    case 'ultrafast': case 'superfast': case 'veryfast': case 'faster': case 'fast': return 'speed';
    case 'medium': case 'slow': return 'balanced';
    case 'slower': case 'veryslow': return 'quality';
    default: return 'balanced';
  }
}

String _uniquePath(String path) {
  if (!File(path).existsSync()) return path;
  final dot = path.lastIndexOf('.');
  final base = dot < 0 ? path : path.substring(0, dot);
  final ext = dot < 0 ? '' : path.substring(dot);
  for (int i = 1; i < 100; i++) {
    final c = '$base ($i)$ext';
    if (!File(c).existsSync()) return c;
  }
  return path;
}

/// Build trim arguments from settings: -ss HH:MM:SS.mmm and -to HH:MM:SS.mmm.
/// Trim args go BEFORE -i for fast seeking (input-level seek).
String _trimInputArgs(Map<String, String> s) {
  final start = (s['TrimStart'] ?? '').trim();
  final end = (s['TrimEnd'] ?? '').trim();
  if (start.isEmpty && end.isEmpty) return '';
  final buf = StringBuffer();
  if (start.isNotEmpty) buf.write('-ss $start ');
  if (end.isNotEmpty) buf.write('-to $end ');
  return buf.toString();
}

/// Build FPS / PFR args for video encoders.
/// Reads VideoFramesPerSecond and VideoPeakFrameRate from settings.
String _fpsArgs(Map<String, String> s) {
  final fps = int.tryParse(s[cs.kVideoFramesPerSecond] ?? '') ?? 0;
  final pfr = _getBool(s, 'VideoPeakFrameRate');
  final buf = StringBuffer();
  if (fps > 0) buf.write('-r $fps ');
  if (pfr) buf.write('-fps_mode vfr ');
  return buf.toString();
}

/// Inject speed filter (setpts for video, atempo for audio) into pass arguments.
/// Modifies the first pass's argument string in-place.
List<FfmpegPass> _injectSpeed(List<FfmpegPass> passes, OutputType ot, Map<String, String> s) {
  final speed = double.tryParse(s[cs.kSpeedMultiplier] ?? '') ?? 1.0;
  if ((speed - 1.0).abs() < 0.01) return passes;
  if (passes.isEmpty) return passes;

  final first = passes.first;
  String args = first.arguments;
  final isVideo = ot.category == OutputCategory.video || ot == OutputType.gif;

  if (isVideo) {
    // Inject setpts into existing -vf, or create new -vf
    final factor = (1.0 / speed).toStringAsFixed(3);
    final speedFilter = 'setpts=$factor*PTS';
    args = _mergeSpeedVf(args, speedFilter);
  }

  // Audio speed: inject atempo filter
  // Audio-only formats need -af; video formats with audio also get atempo
  final isAudioOnly = ot.category == OutputCategory.audio;
  if (isAudioOnly || (isVideo && _getBool(s, cs.kEnableAudio))) {
    final speedFilter = 'atempo=${speed.toStringAsFixed(3)}';
    args = _mergeSpeedAf(args, speedFilter);
  }

  return [
    FfmpegPass(first.name, args,
        fileToDelete: first.fileToDelete,
        concatFilePath: first.concatFilePath,
        concatListContent: first.concatListContent),
    ...passes.skip(1),
  ];
}

/// Merge [speedFilter] into existing -vf arg, or create one before output path.
String _mergeSpeedVf(String args, String speedFilter) {
  final vfRe = RegExp(r'-vf\s+"([^"]*)"');
  final match = vfRe.firstMatch(args);
  if (match != null) {
    final existing = match.group(1)!;
    final newVf = '-vf "$existing,$speedFilter"';
    return args.replaceFirst(vfRe, newVf);
  }
  // Insert BEFORE the output path (last quoted string)
  return _insertBeforeLastQuote(args, '-vf "$speedFilter"');
}

/// Merge [speedFilter] into existing -af arg, or create one before output path.
String _mergeSpeedAf(String args, String speedFilter) {
  final afRe = RegExp(r'-af\s+"([^"]*)"');
  final match = afRe.firstMatch(args);
  if (match != null) {
    final existing = match.group(1)!;
    final newAf = '-af "$existing,$speedFilter"';
    return args.replaceFirst(afRe, newAf);
  }
  return _insertBeforeLastQuote(args, '-af "$speedFilter"');
}

/// Insert [insertion] before the last quoted segment (the output path).
String _insertBeforeLastQuote(String args, String insertion) {
  final lastQuote = args.lastIndexOf('"');
  if (lastQuote < 0) return '$args $insertion';
  // Walk back to find the opening quote of this quoted segment
  int open = lastQuote - 1;
  while (open >= 0 && args[open] != '"') {
    open--;
  }
  if (open < 0) return '$args $insertion';
  return '${args.substring(0, open)}$insertion ${args.substring(open)}';
}

/// Parse FFmpeg argument string into `List<String>` for `Process.start`.
///
/// Handles quoted arguments (paths with spaces). Shared by [ConverterEngine]
/// and [OfficeComEngine].
List<String> parseFfmpegArgs(String args) {
  final result = <String>[];
  final regex = RegExp(r'''"([^"]*)"|(\S+)''');
  for (final m in regex.allMatches(args)) {
    if (m.group(1) != null) {
      result.add(m.group(1)!);
    } else if (m.group(2) != null) {
      result.add(m.group(2)!);
    }
  }
  return result;
}
