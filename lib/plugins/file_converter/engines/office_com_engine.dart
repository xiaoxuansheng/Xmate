/// MS Office COM conversion engine — converts Office documents to PDF via
/// PowerShell COM automation, then optionally to images via FFmpeg.
///
/// Mirrors C# `ConversionJob_Word`, `ConversionJob_Excel`, `ConversionJob_PowerPoint`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/conversion_job.dart';
import '../models/output_type.dart';
import '../utils/ffmpeg_args.dart';
import 'office_utils.dart';

/// Result of an Office COM conversion step.
class OfficeConversionResult {
  final bool success;
  final String? errorMessage;
  final String? outputPath;

  const OfficeConversionResult(
      {required this.success, this.errorMessage, this.outputPath});
}

/// Converts Office documents to PDF (or images via intermediate PDF + FFmpeg).
class OfficeComEngine {
  final String ffmpegPath;

  OfficeComEngine({required this.ffmpegPath});

  /// Check if the given input file can be handled by this engine.
  static bool canHandle(String filePath) => isOfficeDocument(filePath);

  /// Attempt a quick COM check — returns true if the specified Office app
  /// can create a COM object. Runs as a lightweight PowerShell test.
  static Future<bool> checkAvailable(OfficeApp app) async {
    final progId = app == OfficeApp.word
        ? 'Word.Application'
        : app == OfficeApp.excel
            ? 'Excel.Application'
            : 'PowerPoint.Application';
    try {
      final r = await Process.run('powershell', [
        '-NoProfile', '-Command',
        'try {\$x=New-Object -ComObject $progId;\$x.Quit();exit 0}catch{exit 1}',
      ], runInShell: true);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Convert an Office document.
  ///
  /// For PDF output: the PDF is placed directly at [job.outputPath].
  /// For image output: the PDF is an intermediate file, then FFmpeg renders it.
  Future<OfficeConversionResult> convert(ConversionJob job) async {
    final app = officeAppFor(job.inputPath);
    if (app == null) {
      return const OfficeConversionResult(
          success: false, errorMessage: 'Not an Office document');
    }

    // Step 1: Office document → PDF to a temp file
    final pdfPath = _generateTempPdfPath(job.outputPath);

    try {
      job.updateProgress(0.1, userState: 'Converting document to PDF...');

      final pages = job.settings['PdfPageRange'] ?? 'all';
      final mode = job.settings['PdfPageMode'] ?? 'all';
      // Complex page range (delete mode or comma-sep custom) → generate full PDF,
      // let qpdf handle extraction later.
      final fullPdf = mode == 'delete' || _isComplexPageRange(pages);
      final effectivePages = fullPdf ? 'all' : pages;
      final scriptText = buildPowershellScript(app, job.inputPath, pdfPath, effectivePages);
      final psResult = await _runPowershellScript(scriptText, job.inputPath, pdfPath, pages);

      if (!psResult.success) {
        return OfficeConversionResult(
            success: false,
            errorMessage: psResult.errorMessage ?? 'Failed to convert document to PDF');
      }

      // Verify PDF was created
      if (!File(pdfPath).existsSync()) {
        return const OfficeConversionResult(
            success: false, errorMessage: 'PDF was not created by Office');
      }

      // Step 2a: If target is PDF, copy the temp PDF to final output
      if (job.outputType == OutputType.pdf) {
        return _movePdf(pdfPath, job.outputPath);
      }

      // Step 2b: PDF → image via FFmpeg
      if (_isImageOutput(job.outputType)) {
        job.updateProgress(0.5, userState: 'PDF → ${job.outputType.shortLabel}...');
        final imageResult = await _pdfToImage(job, pdfPath);
        _cleanup(pdfPath);
        return imageResult;
      }

      // Other output types — not supported via Office
      _cleanup(pdfPath);
      return const OfficeConversionResult(
          success: false,
          errorMessage: 'Unsupported output type for document conversion');
    } catch (e) {
      _cleanup(pdfPath);
      return OfficeConversionResult(
          success: false, errorMessage: 'Office conversion error: $e');
    }
  }

  // ── Private ──

  /// Run a PowerShell script from its text content, returning success + any error.
  /// [args] are passed to the script as `$args[0]`, `$args[1]`, etc.
  Future<_PsResult> _runPowershellScript(String scriptText, String arg1, String arg2, String arg3) async {
    final scriptPath = '${Directory.systemTemp.path}\\xmate_office_convert.ps1';
    try {
      final scriptFile = File(scriptPath);
      scriptFile.writeAsBytesSync([0xEF, 0xBB, 0xBF, ...utf8.encode(scriptText)]);

      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', scriptPath, arg1, arg2, arg3],
        runInShell: true,
      );

      // Clean up script file
      try { scriptFile.deleteSync(); } catch (_) {}

      if (result.exitCode == 0) {
        return const _PsResult(success: true);
      }

      // Collect error messages
      final err = result.stderr.toString().trim();
      final out = result.stdout.toString().trim();
      final errorMsg = err.isNotEmpty
          ? err
          : out.isNotEmpty
              ? out
              : 'PowerShell exited with code ${result.exitCode}';

      return _PsResult(success: false, errorMessage: errorMsg);
    } catch (e) {
      // Cleanup on exception
      try { File(scriptPath).deleteSync(); } catch (_) {}
      return _PsResult(success: false, errorMessage: 'PowerShell error: $e');
    }
  }

  /// Convert intermediate PDF to image via FFmpeg.
  Future<OfficeConversionResult> _pdfToImage(
      ConversionJob job, String pdfPath) async {
    // Build FFmpeg args for PDF to image
    final passes = buildFfmpegPasses(
      ffmpegPath: ffmpegPath,
      inputPath: pdfPath,
      outputPath: job.outputPath,
      outputType: job.outputType,
      settings: job.settings,
    );

    if (passes.isEmpty) {
      return const OfficeConversionResult(
          success: false, errorMessage: 'No FFmpeg arguments for PDF→image');
    }

    for (final pass in passes) {
      try {
        final process = await Process.start(
          ffmpegPath,
          parseFfmpegArgs(pass.arguments),
        );

        // Drain stdout to prevent pipe buffer deadlock
        unawaited(process.stdout.drain<void>());

        // Collect stderr for error reporting
        final errBuf = StringBuffer();
        process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) => errBuf.writeln(line));

        final exitCode = await process.exitCode;
        if (exitCode != 0) {
          return OfficeConversionResult(
              success: false,
              errorMessage: 'FFmpeg PDF→image failed (exit $exitCode): ${errBuf.toString().trim()}');
        }
      } catch (e) {
        return OfficeConversionResult(
            success: false, errorMessage: 'FFmpeg error: $e');
      }
    }

    if (!File(job.outputPath).existsSync()) {
      return const OfficeConversionResult(
          success: false, errorMessage: 'Output image was not created');
    }

    return OfficeConversionResult(success: true, outputPath: job.outputPath);
  }

  OfficeConversionResult _movePdf(String srcPath, String dstPath) {
    if (srcPath == dstPath) {
      return OfficeConversionResult(success: true, outputPath: dstPath);
    }
    try {
      if (File(dstPath).existsSync()) {
        File(dstPath).deleteSync();
      }
      File(srcPath).renameSync(dstPath);
    } catch (_) {
      try {
        File(srcPath).copySync(dstPath);
        File(srcPath).deleteSync();
      } catch (e) {
        return OfficeConversionResult(
            success: false, errorMessage: 'Failed to save PDF: $e');
      }
    }
    return OfficeConversionResult(success: true, outputPath: dstPath);
  }

  /// Page range contains a comma → complex multi-range that PowerShell COM
  /// cannot express.  qpdf must handle extraction in a second pass.
  static bool _isComplexPageRange(String range) {
    return range != 'all' && range.contains(',');
  }

  bool _isImageOutput(OutputType type) {
    return type == OutputType.jpg ||
        type == OutputType.png ||
        type == OutputType.webp ||
        type == OutputType.avif ||
        type == OutputType.gif;
  }

  String _generateTempPdfPath(String outputPath) {
    final dir = Directory.systemTemp.path;
    final name = outputPath
        .split(RegExp(r'[/\\]'))
        .last
        .replaceAll(RegExp(r'\.[^.]+$'), '');
    return '$dir\\$name - intermediate.pdf';
  }

  void _cleanup(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}

/// Result of a PowerShell invocation.
class _PsResult {
  final bool success;
  final String? errorMessage;
  const _PsResult({required this.success, this.errorMessage});
}
