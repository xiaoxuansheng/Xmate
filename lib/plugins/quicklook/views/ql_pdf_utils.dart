/// qpdf utilities for the QuickLook PDF viewer.
library;

import 'dart:convert';
import 'dart:io';

String resolveQpdfPath() {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final bundled = '$exeDir\\qpdf.exe';
  if (File(bundled).existsSync()) return bundled;
  return 'qpdf.exe';
}

class QlPdfResult {
  final bool success;
  final String? errorMessage;
  final String? stdout;
  const QlPdfResult({required this.success, this.errorMessage, this.stdout});
}

/// Run qpdf and return the result.
/// Accepts exit codes 0 (success) and 3 (success with warnings — output is valid).
Future<QlPdfResult> runQpdf(List<String> args) async {
  try {
    final result = await Process.run(resolveQpdfPath(), args, runInShell: true);
    if (result.exitCode != 0 && result.exitCode != 3) {
      final err = (result.stderr as String).trim();
      return QlPdfResult(success: false,
          errorMessage: err.isNotEmpty ? err : 'qpdf exit ${result.exitCode}');
    }
    return QlPdfResult(success: true, stdout: (result.stdout as String).trim());
  } catch (e) {
    return QlPdfResult(success: false, errorMessage: 'qpdf error: $e');
  }
}

Future<QlPdfResult> decryptPdf(String inputPath, String password, String outputPath) {
  return runQpdf(['--password=$password', '--decrypt', inputPath, outputPath]);
}

/// Get PDF info from `--json` output.
Future<Map<String, dynamic>?> getPdfInfo(String pdfPath) async {
  final r = await runQpdf(['--json', pdfPath]);
  if (!r.success || r.stdout == null || r.stdout!.isEmpty) return null;
  try {
    final raw = jsonDecode(r.stdout!) as Map<String, dynamic>;
    final result = <String, dynamic>{};
    for (final k in ['version', 'encrypted']) {
      if (raw.containsKey(k)) result[k] = raw[k];
    }
    // Check encryption status
    final encrypt = raw['encrypt'];
    if (encrypt is Map) {
      result['encrypted'] = encrypt['encrypted'] ?? false;
    }
    _walkPdfKeys(raw, result);
    return result;
  } catch (_) {
    return null;
  }
}

String _stripQpdfPrefix(String v) {
  if (v.length >= 2 && v[1] == ':') {
    final prefix = v[0];
    if (prefix == 'u' || prefix == 's' || prefix == 'b') return v.substring(2);
  }
  return v;
}

void _walkPdfKeys(Map<String, dynamic> src, Map<String, dynamic> dst) {
  for (final entry in src.entries) {
    final k = entry.key;
    final v = entry.value;
    if (k == '/Title' && v is String) dst['title'] = _stripQpdfPrefix(v);
    if (k == '/Author' && v is String) dst['author'] = _stripQpdfPrefix(v);
    if (k == '/Subject' && v is String) dst['subject'] = _stripQpdfPrefix(v);
    if (k == '/Keywords' && v is String) dst['keywords'] = _stripQpdfPrefix(v);
    if (v is Map<String, dynamic>) _walkPdfKeys(v, dst);
    else if (v is List) {
      for (final item in v) {
        if (item is Map<String, dynamic>) _walkPdfKeys(item, dst);
      }
    }
  }
}

/// Set PDF metadata fields via qpdf JSON roundtrip.
/// Pass null to skip a field, pass "" (empty) to clear it.
Future<bool> setPdfMetadata(String pdfPath, {
  String? title, String? author, String? subject, String? keywords,
}) async {
  final tempFiles = <String>[];
  try {
    final tmpOut = _tmpPath(pdfPath);
    tempFiles.add(tmpOut);
    final jsonFile = '${tmpOut}.json';
    tempFiles.add(jsonFile);
    final jsonMod = '${tmpOut}_mod.json';
    tempFiles.add(jsonMod);

    // Step 1: export full JSON
    var r = await runQpdf(['--json-output', pdfPath, jsonFile]);
    if (!r.success) return false;

    // Step 2: read JSON as raw string (avoid Dart's \uXXXX escaping for CJK)
    final rawText = await File(jsonFile).readAsString();
    final raw = jsonDecode(rawText) as Map<String, dynamic>;
    final q = raw['qpdf'] as List;
    if (q.length < 2) return false;
    final objects = q[1] as Map<String, dynamic>;

    // Find or create the /Info object
    final trailer = (objects['trailer'] as Map<String, dynamic>)['value'] as Map<String, dynamic>;
    final infoRef = trailer['/Info'] as String?;
    final infoKey = infoRef != null ? 'obj:$infoRef' : null;
    Map<String, dynamic> infoObj;

    if (infoKey != null && objects.containsKey(infoKey)) {
      infoObj = objects[infoKey] as Map<String, dynamic>;
    } else {
      final maxId = (q[0] as Map<String, dynamic>)['maxobjectid'] as int? ?? 2;
      final newId = maxId + 1;
      infoObj = {};
      objects['obj:$newId 0 R'] = infoObj;
      trailer['/Info'] = '$newId 0 R';
      (q[0] as Map<String, dynamic>)['maxobjectid'] = newId;
    }

    final infoValue = infoObj['value'] as Map<String, dynamic>? ?? {};

    // Apply updates; pass null=skip, ""=clear (set to empty string)
    if (title != null) infoValue['/Title'] = 'u:$title';
    if (author != null) infoValue['/Author'] = 'u:$author';
    if (subject != null) infoValue['/Subject'] = 'u:$subject';
    if (keywords != null) infoValue['/Keywords'] = 'u:$keywords';
    infoObj['value'] = infoValue;

    // Step 3: write JSON — use standard jsonEncode (\uXXXX safe for qpdf)
    final modifiedJson = jsonEncode(raw);
    await File(jsonMod).writeAsString(modifiedJson);
    r = await runQpdf([pdfPath, '--update-from-json=$jsonMod', tmpOut]);
    if (!r.success) return false;

    return await _replace(tmpOut, pdfPath);
  } catch (_) {
    return false;
  } finally {
    for (final f in tempFiles) { _clean(f); }
  }
}

/// Encrypt a PDF with user/owner password and optional permissions.
/// Remove encryption from a PDF. Requires the password used to unlock it.
Future<bool> removeEncryption(String pdfPath, String password) async {
  final tmpPath = _tmpPath(pdfPath);
  final r = await runQpdf(['--password=$password', '--decrypt', pdfPath, tmpPath]);
  if (!r.success) { _clean(tmpPath); return false; }
  return _replace(tmpPath, pdfPath);
}

Future<bool> encryptPdf(String pdfPath, {
  required String userPassword, required String ownerPassword,
  String keyLength = '256',
  bool allowPrint = true, bool allowModify = true,
  bool allowCopy = true, bool allowAnnotate = true,
}) async {
  final tmpPath = _tmpPath(pdfPath);
  final args = <String>[];
  if (keyLength == '128') args.add('--allow-weak-crypto');
  args.addAll(['--encrypt', userPassword, ownerPassword, keyLength]);
  if (keyLength == '128') args.add('--use-aes=y');
  if (!allowPrint) args.add('--print=none');
  if (!allowModify) args.add('--modify=none');
  if (!allowCopy) args.add('--extract=n');
  if (!allowAnnotate) args.add('--annotate=n');
  args.add('--');
  args.addAll([pdfPath, tmpPath]);
  final r = await runQpdf(args);
  if (!r.success) { _clean(tmpPath); return false; }
  return _replace(tmpPath, pdfPath);
}

Future<bool> rotatePages(String pdfPath, String angle, {String? pages}) async {
  final pageSpec = pages != null ? '$angle:$pages' : angle;
  final tmpPath = _tmpPath(pdfPath);
  final r = await runQpdf(['--rotate=$pageSpec', pdfPath, tmpPath]);
  if (!r.success) { _clean(tmpPath); return false; }
  return _replace(tmpPath, pdfPath);
}

Future<bool> deletePages(String pdfPath, Set<int> pagesToDelete) async {
  if (pagesToDelete.isEmpty) return false;
  final totalPages = await _getPageCount(pdfPath);
  if (totalPages == 0) return false;
  final included = <String>[];
  int? rangeStart;
  for (int i = 1; i <= totalPages; i++) {
    if (pagesToDelete.contains(i)) {
      if (rangeStart != null) {
        final end = i - 1;
        included.add(rangeStart == end ? '$rangeStart' : '$rangeStart-$end');
        rangeStart = null;
      }
    } else {
      rangeStart ??= i;
    }
  }
  if (rangeStart != null) {
    included.add(rangeStart == totalPages ? '$totalPages' : '$rangeStart-$totalPages');
  }
  if (included.isEmpty) return false;
  final pageSpec = included.join(',');
  final tmpPath = _tmpPath(pdfPath);
  final r = await runQpdf(['--pages', '.', pageSpec, '--', pdfPath, tmpPath]);
  if (!r.success) { _clean(tmpPath); return false; }
  return _replace(tmpPath, pdfPath);
}

Future<bool> extractPages(String pdfPath, Set<int> pages, String outputPath) async {
  if (pages.isEmpty) return false;
  final sorted = pages.toList()..sort();
  final pageSpec = sorted.join(',');
  final r = await runQpdf(['--pages', '.', pageSpec, '--', pdfPath, outputPath]);
  return r.success;
}

Future<bool> overlayOnPage(String pdfPath, String overlayPath, int targetPage, String outputPath) async {
  final r = await runQpdf([
    pdfPath, '--overlay', overlayPath,
    '--from=$targetPage', '--to=$targetPage',
    '--', outputPath,
  ]);
  return r.success;
}

Future<bool> optimizePdf(String pdfPath) async {
  final tmpPath = _tmpPath(pdfPath);
  final r = await runQpdf(['--object-streams=generate', '--recompress-flate',
    '--remove-unreferenced-resources=auto', pdfPath, tmpPath]);
  if (!r.success) { _clean(tmpPath); return false; }
  return _replace(tmpPath, pdfPath);
}

Future<bool> _replace(String src, String dst) async {
  try {
    File(dst).deleteSync();
    File(src).copySync(dst);
    File(src).deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}

String _tmpPath(String original) {
  final dir = File(original).parent.path;
  final base = original.split(RegExp(r'[/\\]')).last.replaceAll('.pdf', '');
  final ts = DateTime.now().millisecondsSinceEpoch;
  return '$dir\\${base}_ql_$ts.tmp';
}

void _clean(String path) {
  try { File(path).deleteSync(); } catch (_) {}
}

Future<int> _getPageCount(String pdfPath) async {
  final r = await runQpdf(['--show-npages', pdfPath]);
  if (r.success && r.stdout != null) {
    return int.tryParse(r.stdout!) ?? 0;
  }
  return 0;
}
