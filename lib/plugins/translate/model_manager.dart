/// Dart wrapper for the Python model management script.
library;

import 'dart:convert';
import 'dart:io';

import 'translate_service.dart';
import 'python_service.dart';

// ── Ordering helper ────────────────────────────────────────────────

/// Return [code1, code2] such that English is always code2.
/// For pairs not involving English, alphabetical order.
List<String> _order(String a, String b) {
  if (a == 'en') return [b, a];
  if (b == 'en') return [a, b];
  return a.compareTo(b) < 0 ? [a, b] : [b, a];
}

String _pairKey(String a, String b) {
  final o = _order(a, b);
  return '${o[0]}<${o[1]}';
}

// ── Data classes ───────────────────────────────────────────────────

class PairedModel {
  final String code1;
  final String code2;
  final String name1;
  final String name2;
  final ModelInfo? dir1; // code1→code2
  final ModelInfo? dir2; // code2→code1

  const PairedModel({
    required this.code1,
    required this.code2,
    required this.name1,
    required this.name2,
    this.dir1,
    this.dir2,
  });

  String get label => '$name1 ↔ $name2';
  bool get isComplete => dir1 != null && dir2 != null;
  int get totalSize => (dir1?.sizeBytes ?? 0) + (dir2?.sizeBytes ?? 0);
  String get sizeLabel => '${(totalSize / (1024 * 1024)).toStringAsFixed(0)} MB';
  String get pairKey => _pairKey(code1, code2);
}

class PairedAvailable {
  final String code1;
  final String code2;
  final String name1;
  final String name2;
  final AvailablePair? dir1;
  final AvailablePair? dir2;

  const PairedAvailable({
    required this.code1,
    required this.code2,
    required this.name1,
    required this.name2,
    this.dir1,
    this.dir2,
  });

  bool get hasAny => dir1 != null || dir2 != null;
  String get pairKey => _pairKey(code1, code2);
}

class ModelInfo {
  final String fromCode;
  final String toCode;
  final String version;
  final int sizeBytes;
  final String path;

  const ModelInfo({
    required this.fromCode,
    required this.toCode,
    required this.version,
    required this.sizeBytes,
    required this.path,
  });

  factory ModelInfo.fromJson(Map<String, dynamic> json) => ModelInfo(
        fromCode: json['from'] as String? ?? '',
        toCode: json['to'] as String? ?? '',
        version: json['version'] as String? ?? '',
        sizeBytes: json['sizeBytes'] as int? ?? 0,
        path: json['path'] as String? ?? '',
      );
}

class AvailablePair {
  final String fromCode;
  final String toCode;
  final String version;
  const AvailablePair({
    required this.fromCode,
    required this.toCode,
    required this.version,
  });

  factory AvailablePair.fromJson(Map<String, dynamic> json) => AvailablePair(
        fromCode: json['from'] as String? ?? '',
        toCode: json['to'] as String? ?? '',
        version: json['version'] as String? ?? '',
      );
}

// ── Manager ────────────────────────────────────────────────────────

class ModelManager {
  static Future<String> get pythonPath async {
    final info = await PythonService.detect();
    return info.exePath ?? 'python';
  }

  /// Resolve the scripts directory from the running executable,
  /// falling back to relative paths from CWD for dev scenarios.
  static String get scriptsDir {
    try {
      final exe = File(Platform.resolvedExecutable);
      final exeDir = exe.parent.path;
      // Production: scripts/ is alongside xmate.exe, e.g.
      //   C:\Program Files\XMate\xmate.exe
      //   C:\Program Files\XMate\scripts\...
      final prod = '$exeDir\\scripts\\translate_model_manager.py';
      if (File(prod).existsSync()) return '$exeDir\\scripts';
      // Dev (flutter run): exe is under build\windows\..., scripts at repo root
      var dir = exeDir;
      for (int i = 0; i < 6; i++) {
        final dev = '$dir\\scripts\\translate_model_manager.py';
        if (File(dev).existsSync()) return '$dir\\scripts';
        dir = File(dir).parent.path;
      }
    } catch (_) {}
    // Last resort: CWD-relative
    return 'scripts';
  }

  String get _scriptPath => '$scriptsDir\\translate_model_manager.py';

  Future<Map<String, dynamic>> _run(List<String> args) async {
    try {
      final py = await pythonPath;
      final result = await Process.run(
        py, [_scriptPath, ...args], runInShell: true,
      ).timeout(const Duration(seconds: 30));
      if (result.exitCode != 0) {
        final err = (result.stderr as String).trim();
        return {'ok': false, 'error': err.isNotEmpty ? err : 'Exit code ${result.exitCode}'};
      }
      final lines = (result.stdout as String).trim().split('\n')
          .where((l) => l.trim().isNotEmpty).toList();
      if (lines.isEmpty) return {'ok': false, 'error': 'No output'};
      return jsonDecode(lines.last) as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  Future<bool> checkInstalled() async {
    final r = await _run(['check-installed']);
    return r['installed'] == true;
  }

  // ── Paired API ──────────────────────────────────────────────────

  Future<List<PairedModel>> listInstalledPairs() async {
    final r = await _run(['list-installed']);
    if (r['ok'] != true) return [];
    final raw = ((r['packages'] as List<dynamic>?) ?? [])
        .map((e) => ModelInfo.fromJson(e as Map<String, dynamic>)).toList();
    return _pairInstalled(raw);
  }

  Future<List<PairedAvailable>> listAvailablePairs() async {
    final r = await _run(['list-available']);
    if (r['ok'] != true) return [];
    final raw = ((r['packages'] as List<dynamic>?) ?? [])
        .map((e) => AvailablePair.fromJson(e as Map<String, dynamic>)).toList();
    return _pairAvailable(raw);
  }

  Future<Map<String, dynamic>> installPair(String code1, String code2) async {
    var r = await _run(['install', code1, code2]);
    if (r['ok'] != true) return r;
    r = await _run(['install', code2, code1]);
    // Preload MiniSBD models (tiny ONNX files, ~188KB each) for both languages
    _run(['preload-sbd', '$code1,$code2']); // fire-and-forget, don't block
    return r;
  }

  Future<Map<String, dynamic>> uninstallPair(String code1, String code2) async {
    var r = await _run(['uninstall', code1, code2]);
    r = await _run(['uninstall', code2, code1]);
    return r;
  }

  /// Pre-download MiniSBD sentencizer models for the given language codes.
  Future<Map<String, dynamic>> preloadSbd(List<String> langs) {
    return _run(['preload-sbd', langs.join(',')]);
  }

  Future<Map<String, dynamic>> updateIndex() => _run(['index-update']);

  // ── Install / uninstall server ─────────────────────────────────

  Future<bool> installServer({void Function(String line)? onLog}) async {
    try {
      onLog?.call('pip install libretranslate ...');
      final py = await pythonPath;
      final proc = await Process.start(
        py, ['-m', 'pip', 'install', '--progress-bar', 'off', 'libretranslate'],
        mode: ProcessStartMode.normal, runInShell: true,
      );
      final allLines = <String>[];
      final sub1 = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        allLines.add(line);
        if (line.trim().isNotEmpty) onLog?.call(line);
      });
      final sub2 = proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        allLines.add(line);
        if (line.trim().isNotEmpty) onLog?.call('[pip] $line');
      });
      final exitCode = await proc.exitCode;
      await sub1.cancel(); await sub2.cancel();
      onLog?.call(exitCode == 0 ? 'Install complete' : 'Install failed (exit $exitCode)');
      return exitCode == 0;
    } catch (e) {
      onLog?.call('Error: $e');
      return false;
    }
  }

  Future<bool> uninstallServer({void Function(String line)? onLog}) async {
    try {
      onLog?.call('pip uninstall libretranslate ...');
      final py = await pythonPath;
      final proc = await Process.start(
        py, ['-m', 'pip', 'uninstall', '-y', 'libretranslate'],
        mode: ProcessStartMode.normal, runInShell: true,
      );
      final allLines = <String>[];
      final sub1 = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        allLines.add(line);
        if (line.trim().isNotEmpty) onLog?.call(line);
      });
      final sub2 = proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        allLines.add(line);
        if (line.trim().isNotEmpty) onLog?.call('[pip] $line');
      });
      final exitCode = await proc.exitCode;
      await sub1.cancel(); await sub2.cancel();
      onLog?.call(exitCode == 0 ? 'Uninstall complete' : 'Uninstall failed (exit $exitCode)');
      return exitCode == 0;
    } catch (e) {
      onLog?.call('Error: $e');
      return false;
    }
  }

  // ── Pairing logic ───────────────────────────────────────────────

  List<PairedModel> _pairInstalled(List<ModelInfo> raw) {
    final byKey = <String, ModelInfo>{};
    for (final m in raw) {
      byKey['${m.fromCode}->${m.toCode}'] = m;
    }

    final seen = <String>{};
    final result = <PairedModel>[];

    for (final key in byKey.keys) {
      final parts = key.split('->');
      final a = parts[0], b = parts[1];
      final pk = _pairKey(a, b);
      if (seen.contains(pk)) continue;
      seen.add(pk);

      final o = _order(a, b);
      final dir1 = byKey['${o[0]}->${o[1]}'];
      final dir2 = byKey['${o[1]}->${o[0]}'];

      result.add(PairedModel(
        code1: o[0], code2: o[1],
        name1: langNameZh(o[0]), name2: langNameZh(o[1]),
        dir1: dir1, dir2: dir2,
      ));
    }

    result.sort((x, y) => x.name1.compareTo(y.name1));
    return result;
  }

  List<PairedAvailable> _pairAvailable(List<AvailablePair> raw) {
    final byKey = <String, AvailablePair>{};
    for (final a in raw) {
      byKey['${a.fromCode}->${a.toCode}'] = a;
    }

    final seen = <String>{};
    final result = <PairedAvailable>[];

    for (final key in byKey.keys) {
      final parts = key.split('->');
      final a = parts[0], b = parts[1];
      final pk = _pairKey(a, b);
      if (seen.contains(pk)) continue;
      seen.add(pk);

      final o = _order(a, b);
      final dir1 = byKey['${o[0]}->${o[1]}'];
      final dir2 = byKey['${o[1]}->${o[0]}'];

      if (dir1 != null || dir2 != null) {
        result.add(PairedAvailable(
          code1: o[0], code2: o[1],
          name1: langNameZh(o[0]), name2: langNameZh(o[1]),
          dir1: dir1, dir2: dir2,
        ));
      }
    }

    // Sort: zh↔en pinned first, then non-English groups (alphabetical by name1),
    // then English-pair groups sorted by name2
    result.sort((x, y) {
      final xPinned = (x.code1 == 'zh' && x.code2 == 'en') ? 0 : 1;
      final yPinned = (y.code1 == 'zh' && y.code2 == 'en') ? 0 : 1;
      if (xPinned != yPinned) return xPinned.compareTo(yPinned);
      final xEn = x.code1 == 'en' ? 1 : 0;
      final yEn = y.code1 == 'en' ? 1 : 0;
      if (xEn != yEn) return xEn.compareTo(yEn);
      if (xEn == 1) return x.name2.compareTo(y.name2);
      return x.name1.compareTo(y.name1);
    });
    return result;
  }
}
