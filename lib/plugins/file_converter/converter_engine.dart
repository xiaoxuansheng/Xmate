/// FFmpeg subprocess wrapper — spawns FFmpeg, parses progress, supports cancel.
///
/// Also dispatches Office documents to [OfficeComEngine] for MS Office COM
/// conversion (mirrors C# `ConversionJobFactory.Create`).
///
/// Progress parsing mirrors C# `ConversionJob_FFMPEG.ParseFFMPEGOutput`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'models/conversion_job.dart';
import 'models/output_type.dart';
import 'utils/ffmpeg_args.dart';
import 'engines/office_com_engine.dart';
import 'engines/qpdf_engine.dart';
import 'models/conversion_settings.dart' as cs;

/// Regex patterns from C# `ConversionJob_FFMPEG`.
final _durationRe = RegExp(
    r'Duration:\s*(\d{2}):(\d{2}):(\d{2})\.(\d{2}),.*bitrate:\s*(\d+) kb\/s');
final _progressRe = RegExp(
    r'size=\s*(\d+).*time=(\d{2}):(\d{2}):(\d{2}).(\d{2})\s+bitrate=\s*(\d+.\d)');

/// Runs a single file conversion via FFmpeg subprocess.
class ConverterEngine {
  final ConversionJob job;
  final String ffmpegPath;
  final String qpdfPath;
  final HardwareAcceleration hwAccel;
  Process? _process;
  Timer? _killTimer;

  /// Stream controller for job progress updates.
  final _progressCtrl = StreamController<ConversionJob>.broadcast();
  Stream<ConversionJob> get progressStream => _progressCtrl.stream;

  /// Stream controller for completion (true = success, false = failure).
  final _doneCtrl = StreamController<bool>.broadcast();
  Stream<bool> get doneStream => _doneCtrl.stream;

  ConverterEngine({
    required this.job,
    required this.ffmpegPath,
    this.qpdfPath = '',
    this.hwAccel = HardwareAcceleration.off,
  });

  /// Run the conversion. Returns true on success.
  Future<bool> run() async {
    // Dispatch Office documents to COM engine (mirrors C# ConversionJobFactory)
    if (OfficeComEngine.canHandle(job.inputPath)) {
      return _runOfficeConversion();
    }

    // Standard FFmpeg path
    return _runFfmpeg();
  }

  /// Run Office document → PDF/image via MS Office COM PowerShell.
  Future<bool> _runOfficeConversion() async {
    job.markStarted();
    _emitProgress();

    final engine = OfficeComEngine(ffmpegPath: ffmpegPath);
    final result = await engine.convert(job);

    if (result.success) {
      if (!await _qpdfPostProcess()) return false;
      job.markDone();
      _emitProgress();
      _doneCtrl.add(true);
      return true;
    } else {
      job.markFailed(result.errorMessage ?? 'Office conversion failed');
      _emitProgress();
      _doneCtrl.add(false);
      return false;
    }
  }

  /// Standard FFmpeg conversion path.
  Future<bool> _runFfmpeg() async {
    // Check FFmpeg exists
    if (!File(ffmpegPath).existsSync()) {
      job.markFailed('FFmpeg not found: $ffmpegPath');
      _doneCtrl.add(false);
      return false;
    }

    // Combined job: two phases — per-file transform → temp, then concat → final
    if (job.inputPaths != null && job.inputPaths!.length > 1) {
      return _runCombinedPipeline();
    }

    // Standalone single-file conversion
    final ok = await _runSingleFile(job.inputPath, job.outputPath, job.settings, job);
    if (ok) {
      if (!await _qpdfPostProcess()) return false;
      job.markDone();
      _emitProgress();
      _doneCtrl.add(true);
      return true;
    }
    _doneCtrl.add(false);
    return false;
  }

  /// Run a single-file conversion (used for both standalone and per-file combine phases).
  Future<bool> _runSingleFile(
      String inputPath, String outputPath, Map<String, String> settings,
      ConversionJob progressJob) async {
    final passes = buildFfmpegPasses(
      ffmpegPath: ffmpegPath,
      inputPath: inputPath,
      outputPath: outputPath,
      outputType: progressJob.outputType,
      settings: settings,
      hwAccel: hwAccel,
    );

    if (passes.isEmpty) {
      progressJob.markFailed('No FFmpeg arguments for ${progressJob.outputType.label}');
      _doneCtrl.add(false);
      return false;
    }

    for (int i = 0; i < passes.length; i++) {
      if (progressJob.cancelRequested) {
        progressJob.markFailed('Cancelled');
        _doneCtrl.add(false);
        return false;
      }
      await _writeConcatFile(passes[i]);
      final ok = await _runPass(passes[i], passIndex: i, totalPasses: passes.length);
      if (!ok) {
        _cleanupPasses(passes);
        return false;
      }
    }
    _cleanupPasses(passes);
    if (!File(outputPath).existsSync()) {
      progressJob.markFailed('FFmpeg exited OK but output missing: $outputPath');
      _doneCtrl.add(false);
      return false;
    }
    return true;
  }

  /// Two-phase combine pipeline: per-file convert → temp files → concat → final.
  Future<bool> _runCombinedPipeline() async {
    final inputPaths = job.inputPaths!;
    final perSettings = job.perFileSettings ?? [];
    final n = inputPaths.length;
    final tempFiles = <String>[];

    // Phase 1: per-file conversion → temp files of the same output type
    for (int i = 0; i < n; i++) {
      if (job.cancelRequested) {
        job.markFailed('Cancelled');
        _cleanupTemps(tempFiles);
        _doneCtrl.add(false);
        return false;
      }

      final filePath = inputPaths[i];
      if (!File(filePath).existsSync()) {
        job.markFailed('Input not found: $filePath');
        _cleanupTemps(tempFiles);
        _doneCtrl.add(false);
        return false;
      }

      final settings = i < perSettings.length ? perSettings[i] : job.settings;
      final ext = job.outputType.extension;
      final tempPath = _tempPath(i, ext);
      tempFiles.add(tempPath);

      job.updateProgress(i * 0.7 / n, userState: 'Preparing file ${i + 1}/$n…');
      final ok = await _runSingleFile(filePath, tempPath, settings, job);
      if (!ok) { _cleanupTemps(tempFiles); return false; }

      if (!File(tempPath).existsSync()) {
        job.markFailed('Phase 1 produced no output: $tempPath');
        _cleanupTemps(tempFiles);
        _doneCtrl.add(false);
        return false;
      }
    }

    // Phase 2: concat temp files → final output
    if (job.cancelRequested) {
      job.markFailed('Cancelled');
      _cleanupTemps(tempFiles);
      _doneCtrl.add(false);
      return false;
    }

    job.updateProgress(0.8, userState: 'Combining files…');

    // ── PDF combine: use qpdf --pages for native PDF merging ──
    if (job.outputType == OutputType.pdf && qpdfPath.isNotEmpty) {
      final qr = await _runQpdfCombine(tempFiles, job.outputPath);
      _cleanupTemps(tempFiles);
      if (!qr.success) {
        job.markFailed(qr.errorMessage ?? 'qpdf combine failed');
        _doneCtrl.add(false);
        return false;
      }
      if (!await _qpdfPostProcess()) return false;
      job.markDone();
      _emitProgress();
      _doneCtrl.add(true);
      return true;
    }

    final combinePass = buildConcatPass(
      tempPaths: tempFiles,
      outputPath: job.outputPath,
      outputType: job.outputType,
      settings: job.settings,
    );

    if (combinePass == null) {
      job.markFailed('Cannot combine into ${job.outputType.label}');
      _cleanupTemps(tempFiles);
      _doneCtrl.add(false);
      return false;
    }

    await _writeConcatFile(combinePass);
    final combineOk = await _runPass(combinePass, passIndex: 0, totalPasses: 1);

    // GIF combines need second pass: paletteuse (save palette path before cleanup)
    if (job.outputType == OutputType.gif) {
      final gifPalettePath = combinePass.fileToDelete;
      _cleanupPasses([combinePass]);
      if (gifPalettePath != null && File(gifPalettePath).existsSync()) {
        final nImgs = tempFiles.length;
        final fps = int.tryParse(job.settings[cs.kVideoFramesPerSecond] ?? '') ?? 15;
        final inputArgs = tempFiles.map((p) => '-i "$p"').join(' ');
        final refs = List.generate(nImgs, (i) => '[$i:v]').join();
        final paletteFilter = '$refs concat=n=$nImgs:v=1:a=0,fps=$fps[v1];'
            '[v1][${nImgs}:v]paletteuse';
        final gifPass2 = FfmpegPass('Create GIF',
            '-n $inputArgs -i "$gifPalettePath" '
            '-filter_complex "$paletteFilter" "${job.outputPath}"');
        final ok2 = await _runPass(gifPass2, passIndex: 1, totalPasses: 1);
        _cleanupPasses([gifPass2]);
        _cleanupTemps(tempFiles);
        if (!ok2) return false;
      } else {
        _cleanupTemps(tempFiles);
        _doneCtrl.add(false);
        return false;
      }
    } else {
      _cleanupPasses([combinePass]);
      _cleanupTemps(tempFiles);
      if (!combineOk) return false;
    }

    // Verify output exists
    if (!File(job.outputPath).existsSync()) {
      job.markFailed('Combine output was not created');
      _doneCtrl.add(false);
      return false;
    }

    if (!await _qpdfPostProcess()) return false;

    job.markDone();
    _emitProgress();
    _doneCtrl.add(true);
    return true;
  }

  Future<void> _writeConcatFile(FfmpegPass pass) async {
    if (pass.concatFilePath != null && pass.concatListContent != null) {
      try {
        File(pass.concatFilePath!).writeAsStringSync(pass.concatListContent!);
      } catch (e) {
        // Will fail later in _runPass
      }
    }
  }

  void _cleanupTemps(List<String> paths) {
    for (final p in paths) {
      try {
        final f = File(p);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  String _tempPath(int index, String ext) {
    final dir = Directory.systemTemp.path;
    final ts = DateTime.now().millisecondsSinceEpoch;
    return '$dir${Platform.pathSeparator}xmate_p1_${index}_$ts.$ext';
  }

  /// Cancel the running conversion.
  void cancel() {
    job.cancel();
    // Set a 5-second deadline for graceful shutdown
    _killTimer?.cancel();
    _killTimer = Timer(const Duration(seconds: 5), () {
      job.forceKill();
    });
  }

  void dispose() {
    _killTimer?.cancel();
    job.forceKill();
    _progressCtrl.close();
    _doneCtrl.close();
  }

  // ── Internal ──

  Future<bool> _runPass(FfmpegPass pass,
      {int passIndex = 0, int totalPasses = 1}) async {
    Duration? fileDuration;
    Duration? actualDuration;

    try {
      _process = await Process.start(
        ffmpegPath,
        parseFfmpegArgs(pass.arguments),
      );

      job.markStarted(_process!);
      _emitProgress();

      // Drain stdout to prevent pipe-buffer deadlock. FFmpeg may write progress
      // (pipe:1) or banner text to stdout; we parse progress from stderr only.
      unawaited(_process!.stdout.drain<void>());

      // Collect stderr for error diagnostics
      final errBuffer = StringBuffer();

      // Read stderr line by line (FFmpeg outputs progress on stderr)
      final stderrStream = _process!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in stderrStream) {
        errBuffer.writeln(line);
        if (job.cancelRequested) {
          _killTimer?.cancel();
          // Already sent 'q' via job.cancel(); wait briefly then force kill
          await Future.delayed(const Duration(seconds: 2));
          job.forceKill();
          job.markFailed('Cancelled');
          _emitProgress();
          return false;
        }

        // Parse duration
        final durMatch = _durationRe.firstMatch(line);
        if (durMatch != null && durMatch.groupCount >= 5) {
          fileDuration = Duration(
            hours: int.parse(durMatch.group(1)!),
            minutes: int.parse(durMatch.group(2)!),
            seconds: int.parse(durMatch.group(3)!),
            milliseconds: int.parse(durMatch.group(4)!) * 10,
          );
          continue;
        }

        // Parse progress
        if (fileDuration != null && fileDuration.inMilliseconds > 0) {
          final progMatch = _progressRe.firstMatch(line);
          if (progMatch != null && progMatch.groupCount >= 7) {
            actualDuration = Duration(
              hours: int.parse(progMatch.group(2)!),
              minutes: int.parse(progMatch.group(3)!),
              seconds: int.parse(progMatch.group(4)!),
              milliseconds: int.parse(progMatch.group(5)!) * 10,
            );

            final passProgress =
                actualDuration.inMilliseconds / fileDuration.inMilliseconds;
            final totalProgress =
                (passIndex + passProgress) / totalPasses;
            job.updateProgress(totalProgress.clamp(0.0, 1.0),
                userState: pass.name);
            _emitProgress();
            continue;
          }
        }

        // Error detection (remove file paths first to avoid false positives)
        final sanitized = line
            .replaceAll(job.inputPath, '')
            .replaceAll(job.outputPath, '');
        if (sanitized.contains('Error') ||
            sanitized.contains('Unsupported dimensions') ||
            sanitized.contains('No such file or directory') ||
            sanitized.contains('Invalid data found when processing input')) {
          // Known false-positive: "Error while decoding stream … Invalid data"
          if (!(sanitized.contains('Error while decoding stream') &&
              sanitized.contains('Invalid data found when processing input'))) {
            job.markFailed(line);
            _emitProgress();
            return false;
          }
        }
      }

      // Wait for process exit
      final exitCode = await _process!.exitCode;
      _process = null;

      if (exitCode != 0) {
        final tail = _lastLines(errBuffer.toString(), 3);
        job.markFailed('FFmpeg exit $exitCode: $tail');
        _emitProgress();
        return false;
      }

      return true;
    } catch (e) {
      job.markFailed('FFmpeg error: $e');
      _emitProgress();
      return false;
    }
  }

  /// Return the last N non-empty lines from [text].
  static String _lastLines(String text, int n) {
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.length <= n) return lines.join(' | ');
    return lines.sublist(lines.length - n).join(' | ');
  }

  /// qpdf post-processing for PDF output.
  /// Only runs when [qpdfPath] is configured and settings request qpdf operations.
  Future<QpdfResult> _runQpdf(
      String inputPath, String outputPath, Map<String, String> settings) async {
    if (!QpdfEngine.isRequested(settings)) {
      return const QpdfResult(success: true);
    }
    final engine = QpdfEngine(qpdfPath: qpdfPath);
    return engine.process(inputPath, outputPath, settings);
  }

  /// Run qpdf post-processing on [job.outputPath] if applicable.
  /// Returns true if no processing needed or processing succeeded.
  Future<bool> _qpdfPostProcess() async {
    if (job.outputType != OutputType.pdf || qpdfPath.isEmpty) return true;
    final qr = await _runQpdf(job.outputPath, job.outputPath, job.settings);
    if (!qr.success) {
      job.markFailed(qr.errorMessage ?? 'qpdf processing failed');
      _emitProgress();
      _doneCtrl.add(false);
      return false;
    }
    return true;
  }

  /// Combine multiple PDF temp files into a single PDF via qpdf --pages.
  Future<QpdfResult> _runQpdfCombine(
      List<String> pdfPaths, String outputPath) async {
    final engine = QpdfEngine(qpdfPath: qpdfPath);
    return engine.combine(pdfPaths, outputPath);
  }

  void _emitProgress() {
    if (!_progressCtrl.isClosed) {
      _progressCtrl.add(job);
    }
  }

  /// Clean up intermediate files (e.g. GIF palette, concat lists).
  void _cleanupPasses(List<FfmpegPass> passes) {
    for (final pass in passes) {
      if (pass.fileToDelete != null) {
        try {
          final f = File(pass.fileToDelete!);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
      if (pass.concatFilePath != null) {
        try {
          final f = File(pass.concatFilePath!);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    }
  }

}
