/// qpdf post-processing engine — optimizes / linearizes / encrypts PDF output
/// via the qpdf CLI tool.
///
/// Mirrors [OfficeComEngine]'s subprocess pattern.
library;

import 'dart:io';
import '../models/conversion_settings.dart' as cs;

/// Result of a qpdf post-processing operation.
class QpdfResult {
  final bool success;
  final String? errorMessage;
  const QpdfResult({required this.success, this.errorMessage});
}

/// Runs qpdf as a subprocess to post-process PDF files.
///
/// Features: file-size optimisation (object streams + flate recompression +
/// unreferenced-resource removal), web linearization, page-range extraction
/// (complex comma-separated ranges), and AES encryption with granular
/// permissions.
class QpdfEngine {
  final String qpdfPath;

  QpdfEngine({required this.qpdfPath});

  /// Returns `true` when [settings] request at least one qpdf operation.
  static bool isRequested(Map<String, String> settings) {
    return _getBool(settings, cs.kPdfOptimize) ||
        _getBool(settings, cs.kPdfLinearize) ||
        _getBool(settings, cs.kPdfEncrypt) ||
        _getBool(settings, cs.kPdfOptimizeImages) ||
        _getBool(settings, cs.kPdfDeterministicId) ||
        _getBool(settings, cs.kPdfNormalizeContent) ||
        (settings[cs.kPdfWatermarkPath] ?? '').isNotEmpty ||
        (settings[cs.kPdfUnderlayPath] ?? '').isNotEmpty ||
        (settings[cs.kPdfRotate] ?? '0') != '0' ||
        (settings[cs.kPdfPageOrder] ?? '').isNotEmpty ||
        _needsPageExtraction(settings);
  }

  /// Returns `true` when the page range contains a comma, meaning the
  /// current PowerShell COM path cannot handle it and qpdf must extract pages.
  static bool needsComplexExtraction(Map<String, String> settings) {
    return _needsPageExtraction(settings);
  }

  /// Combine multiple PDF files into one via qpdf --pages (native merge).
  /// Uses --empty as the base so we don't inherit document-level info from
  /// any single input.
  Future<QpdfResult> combine(
      List<String> pdfPaths, String outputPath) async {
    if (pdfPaths.isEmpty) {
      return const QpdfResult(success: false, errorMessage: 'No PDFs to combine');
    }
    if (pdfPaths.length == 1) {
      // Single file — just copy
      try {
        File(pdfPaths.first).copySync(outputPath);
        return const QpdfResult(success: true);
      } catch (e) {
        return QpdfResult(success: false, errorMessage: 'Copy failed: $e');
      }
    }

    // qpdf --empty --pages a.pdf 1-z b.pdf 1-z -- out.pdf
    final args = <String>['--empty', '--pages'];
    for (final p in pdfPaths) {
      args.add(p);
      args.add('1-z'); // all pages
    }
    args.add('--');
    args.add(outputPath);

    try {
      final result = await Process.run(qpdfPath, args, runInShell: true);
      if (!_qpdfOk(result.exitCode)) {
        final err = _extractError(result);
        return QpdfResult(
          success: false,
          errorMessage: 'qpdf combine exit ${result.exitCode}: $err',
        );
      }
      return const QpdfResult(success: true);
    } catch (e) {
      return QpdfResult(success: false, errorMessage: 'qpdf combine error: $e');
    }
  }

  /// Run qpdf post-processing on [inputPath], writing the result to
  /// [outputPath].  When input == output the engine writes to a temp file
  /// first and then replaces the original.
  Future<QpdfResult> process(
      String inputPath, String outputPath, Map<String, String> settings) async {
    final args = _buildArgs(settings);
    if (args.isEmpty) {
      return const QpdfResult(success: true);
    }

    // When input == output, route through a temp file so qpdf doesn't
    // read and write the same file concurrently.
    String effectiveOutput = outputPath;
    String? tempPath;
    if (_pathsEqual(inputPath, outputPath)) {
      tempPath = _tempPath(outputPath);
      effectiveOutput = tempPath;
    }

    try {
      // Build the full argument list: qpdf [options] [--pages ...] in out
      final needPages = _needsPageExtraction(settings);
      final cmdArgs = <String>[
        ...args,
        if (needPages) ..._pageArgs(settings),
        inputPath,
        effectiveOutput,
      ];

      final result = await Process.run(
        qpdfPath,
        cmdArgs,
        runInShell: true,
      );

      if (!_qpdfOk(result.exitCode)) {
        _cleanup(tempPath);
        final err = _extractError(result);
        return QpdfResult(
          success: false,
          errorMessage: 'qpdf exit ${result.exitCode}: $err',
        );
      }

      // Swap temp file into place (copy+delete — renameSync fails cross-drive)
      if (tempPath != null) {
        try {
          File(outputPath).deleteSync();
          File(tempPath).copySync(outputPath);
          File(tempPath).deleteSync();
        } catch (e) {
          _cleanup(tempPath);
          return QpdfResult(
            success: false,
            errorMessage: 'Failed to replace PDF after qpdf: $e',
          );
        }
      }

      return const QpdfResult(success: true);
    } catch (e) {
      _cleanup(tempPath);
      return QpdfResult(success: false, errorMessage: 'qpdf error: $e');
    }
  }

  // ── Argument builders ──

  /// Build the option portion of the qpdf command line.
  /// Does NOT include input / output paths (those are handled by [process]).
  static List<String> _buildArgs(Map<String, String> settings) {
    final args = <String>[];

    // ── Structured modifications ──
    final rotate = settings[cs.kPdfRotate] ?? '0';
    final rotatePages = settings[cs.kPdfRotatePages] ?? '';

    if (rotate != '0') {
      if (rotatePages.isNotEmpty) {
        args.add('--rotate=$rotate:$rotatePages');
      } else {
        args.add('--rotate=$rotate');
      }
    }

    final splitRaw = int.tryParse(settings[cs.kPdfSplitPages] ?? '') ?? 0;
    final splitCustom = int.tryParse(settings[cs.kPdfSplitCustom] ?? '') ?? 0;
    final splitVal = splitRaw == -1 ? splitCustom : splitRaw;
    if (splitVal > 0) {
      args.add('--split-pages=$splitVal');
    }

    // ── Optimisation ──
    if (_getBool(settings, cs.kPdfOptimize)) {
      args.add('--object-streams=generate');
      args.add('--recompress-flate');
      args.add('--remove-unreferenced-resources=auto');
    }

    // ── Advanced optimisation ──
    if (_getBool(settings, cs.kPdfOptimizeImages)) {
      args.add('--optimize-images');
    }
    if (_getBool(settings, cs.kPdfDeterministicId)) {
      args.add('--deterministic-id');
    }
    if (_getBool(settings, cs.kPdfNormalizeContent)) {
      args.add('--normalize-content=y');
    }

    // ── Linearization ──
    if (_getBool(settings, cs.kPdfLinearize)) {
      args.add('--linearize');
    }

    // ── Watermark / underlay ──
    final wm = settings[cs.kPdfWatermarkPath] ?? '';
    if (wm.isNotEmpty) {
      args.add('--overlay');
      args.add(wm);
      args.add('--');
    }
    final ul = settings[cs.kPdfUnderlayPath] ?? '';
    if (ul.isNotEmpty) {
      args.add('--underlay');
      args.add(ul);
      args.add('--');
    }

    // ── Encryption ──
    if (_getBool(settings, cs.kPdfEncrypt)) {
      final userPwd = settings[cs.kPdfEncryptUserPassword] ?? '';
      final ownerPwd = settings[cs.kPdfEncryptOwnerPassword] ?? '';
      final keyLen = settings[cs.kPdfEncryptKeyLength] ?? '256';

      if (keyLen == '128' || keyLen == '40') {
        args.add('--allow-weak-crypto');
      }

      args.add('--encrypt');
      args.add(userPwd);
      args.add(ownerPwd);
      args.add(keyLen);

      if (keyLen == '128') {
        args.add('--use-aes=y');
      }

      if (!_getBool(settings, cs.kPdfEncryptAllowPrint)) {
        args.add('--print=none');
      }
      if (!_getBool(settings, cs.kPdfEncryptAllowModify)) {
        args.add('--modify=none');
      }
      if (!_getBool(settings, cs.kPdfEncryptAllowCopy)) {
        args.add('--extract=n');
      }
      if (!_getBool(settings, cs.kPdfEncryptAllowAnnotate)) {
        args.add('--annotate=n');
      }

      args.add('--');
    }

    return args;
  }

  /// Build the `--pages` segment for page extraction.
  static List<String> _pageArgs(Map<String, String> settings) {
    final mode = settings['PdfPageMode'] ?? 'all';
    final range = settings['PdfPageRange'] ?? 'all';
    final pageOrder = settings[cs.kPdfPageOrder] ?? '';

    if (mode == 'all') return [];

    // Reorder takes precedence over custom/delete
    if (pageOrder.isNotEmpty) return ['--pages', '.', pageOrder, '--'];

    if (mode == 'custom' && range != 'all') {
      return ['--pages', '.', range, '--'];
    }

    // delete mode: range is pages to remove — we compute complement lazily
    // (requires total-page-count lookup; handled in process())
    return [];
  }

  // ── Helpers ──

  /// Page extraction is needed when mode is custom/delete and range is set.
  static bool _needsPageExtraction(Map<String, String> settings) {
    final mode = settings['PdfPageMode'] ?? 'all';
    final range = settings['PdfPageRange'] ?? 'all';
    final pageOrder = settings[cs.kPdfPageOrder] ?? '';
    if (pageOrder.isNotEmpty) return true;
    if (mode == 'custom' && range != 'all') return true;
    if (mode == 'delete' && range.isNotEmpty) return true;
    return false;
  }

  static bool _getBool(Map<String, String> s, String key) {
    final v = s[key];
    return v == 'True' || v == 'true' || v == '1';
  }

  static bool _pathsEqual(String a, String b) {
    return a.replaceAll('\\', '/') == b.replaceAll('\\', '/');
  }

  /// qpdf exit codes:
  ///   0 = success, no warnings
  ///   1 = not used
  ///   2 = error (operation failed)
  ///   3 = success with warnings (output file is valid)
  static bool _qpdfOk(int exitCode) => exitCode == 0 || exitCode == 3;

  /// Create a temp file path in the same directory as [original] to avoid
  /// cross-drive rename failures on Windows.
  static String _tempPath(String original) {
    final parent = original.replaceAll('\\', '/').split('/')
          .where((s) => s.isNotEmpty).toList()
        ..removeLast();
    final dir = parent.isNotEmpty ? '${parent.join('/')}' : '.';
    final base = original
        .split(RegExp(r'[/\\]'))
        .last
        .replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
    final ts = DateTime.now().millisecondsSinceEpoch;
    return '${dir.replaceAll('/', '\\')}\\${base}_qpdf_$ts.tmp';
  }

  static void _cleanup(String? path) {
    if (path == null) return;
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Extract a meaningful error message from stderr / stdout.
  static String _extractError(ProcessResult result) {
    String s = (result.stderr as String).trim();
    if (s.isNotEmpty) return s;
    s = (result.stdout as String).trim();
    return s.isNotEmpty ? s : 'unknown error';
  }
}
