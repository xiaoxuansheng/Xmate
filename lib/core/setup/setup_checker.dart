/// One-click setup checker — validates XMate environment and installs
/// missing components (LibreTranslate, models, rebuild indexes, etc.).
///
/// Produces a log file saved to the user's Desktop.
library;

import 'dart:async';
import 'dart:io';

import '../../plugins/translate/server_manager.dart';
import '../../plugins/translate/model_manager.dart';
import '../../plugins/translate/python_service.dart';
import '../../plugins/dictionary/dictionary_service.dart';
import '../search/file_search_service.dart';
import '../search/file_search_channel.dart';
import '../search/file_index_config.dart';
import '../settings/settings_service.dart';

// ─── Data types ───────────────────────────────────────────────────

enum SetupItemStatus { pending, running, ok, warning, error }

class SetupCheckItem {
  final String id;
  final String label;
  final String description;
  SetupItemStatus status;
  String? detail;

  SetupCheckItem({
    required this.id,
    required this.label,
    required this.description,
    this.status = SetupItemStatus.pending,
    this.detail,
  });
}

class SetupState {
  final List<SetupCheckItem> items;
  final bool running;
  final bool done;
  final String? logPath;

  const SetupState({
    required this.items,
    this.running = false,
    this.done = false,
    this.logPath,
  });

  int get total => items.length;
  int get completed =>
      items.where((i) => i.status != SetupItemStatus.pending && i.status != SetupItemStatus.running).length;
  int get errors => items.where((i) => i.status == SetupItemStatus.error).length;
  int get warnings => items.where((i) => i.status == SetupItemStatus.warning).length;
  int get ok => items.where((i) => i.status == SetupItemStatus.ok).length;
}

// ─── Checker ──────────────────────────────────────────────────────

class SetupChecker {
  final _ctrl = StreamController<SetupState>.broadcast();
  Stream<SetupState> get onStateChanged => _ctrl.stream;
  SetupState? _last;

  final _logLines = <String>[];
  String? _logPath;

  SetupState get current => _last ?? SetupState(items: _buildItems());

  static List<SetupCheckItem> _buildItems() {
    return [
      // ── Environment checks ──
      SetupCheckItem(
        id: 'check.ffmpeg',
        label: 'FFmpeg',
        description: 'Required for screen recording and file conversion',
      ),
      SetupCheckItem(
        id: 'check.qpdf',
        label: 'qpdf',
        description: 'Required for PDF post-processing',
      ),
      SetupCheckItem(
        id: 'check.python',
        label: 'Python 3',
        description: 'Required for LibreTranslate offline translation',
      ),
      SetupCheckItem(
        id: 'check.disk_space',
        label: 'Disk Space',
        description: 'At least 500 MB free for models and indexes',
      ),
      SetupCheckItem(
        id: 'check.write_perms',
        label: 'Write Permissions',
        description: 'Can write to app directory and Desktop',
      ),
      // ── Component checks ──
      SetupCheckItem(
        id: 'check.libretranslate',
        label: 'LibreTranslate Server',
        description: 'pip package installed and runnable',
      ),
      SetupCheckItem(
        id: 'check.models',
        label: 'Translation Models',
        description: 'At least one language pair installed',
      ),
      SetupCheckItem(
        id: 'check.dict_db',
        label: 'Dictionary Database',
        description: 'ECDICT SQLite database loaded',
      ),
      SetupCheckItem(
        id: 'check.search_index',
        label: 'File Search Index',
        description: 'At least one indexed path has segments',
      ),
      SetupCheckItem(
        id: 'check.indexer_service',
        label: 'Indexer Windows Service',
        description: 'Background USN monitor installed',
      ),
      // ── Actions ──
      SetupCheckItem(
        id: 'action.install_lt',
        label: 'Install LibreTranslate',
        description: 'pip install libretranslate (may take a few minutes)',
      ),
      SetupCheckItem(
        id: 'action.models_enzh',
        label: 'Install EN↔ZH Models',
        description: 'Download English-Chinese translation models',
      ),
      SetupCheckItem(
        id: 'action.engine_index',
        label: 'Update Engine Index',
        description: 'Refresh available translation model list',
      ),
      SetupCheckItem(
        id: 'action.rebuild_index',
        label: 'Rebuild File Indexes',
        description: 'Rescan all configured index paths',
      ),
    ];
  }

  // ── Helpers ──

  void _emit(List<SetupCheckItem> items, {bool running = true, bool done = false}) {
    _last = SetupState(items: items, running: running, done: done, logPath: _logPath);
    _ctrl.add(_last!);
  }

  void _addLog(String msg) {
    final ts = DateTime.now().toIso8601String().substring(0, 19).replaceAll('T', ' ');
    _logLines.add('[$ts] $msg');
  }

  SetupCheckItem _find(List<SetupCheckItem> items, String id) =>
      items.firstWhere((i) => i.id == id);

  void _set(List<SetupCheckItem> items, String id, SetupItemStatus status, {String? detail}) {
    final item = _find(items, id);
    item.status = status;
    if (detail != null) item.detail = detail;
    _addLog('${status.name.toUpperCase()}: $id${detail != null ? " — $detail" : ""}');
    _emit(items);
  }

  // ── Resolve paths ──

  String _resolveFfmpegPath() {
    final s = SettingsService();
    final own = s.get('file_converter.ffmpegPath') as String?;
    if (own is String && own.isNotEmpty && File(own).existsSync()) return own;
    final sr = s.get('screenrecording.ffmpegPath') as String?;
    if (sr is String && sr.isNotEmpty && File(sr).existsSync()) return sr;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = '$exeDir\\ffmpeg.exe';
    if (File(bundled).existsSync()) return bundled;
    return 'ffmpeg.exe';
  }

  String _resolveQpdfPath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = '$exeDir\\qpdf.exe';
    if (File(bundled).existsSync()) return bundled;
    return 'qpdf.exe';
  }

  // ── Main entry ─────────────────────────────────────────────────

  Future<void> runAll() async {
    final items = _buildItems();
    _logLines.clear();
    _logPath = null;
    _addLog('=== XMate Setup Check started ===');
    _addLog('Date: ${DateTime.now()}');
    _addLog('');

    _emit(items, running: true);

    try {
      // ── Phase 1: Checks ──
      await _checkFfmpeg(items);
      await _checkQpdf(items);
      await _checkPython(items);
      await _checkDiskSpace(items);
      await _checkWritePerms(items);
      await _checkLibreTranslate(items);
      await _checkModels(items);
      await _checkDictDb(items);
      await _checkSearchIndex(items);
      await _checkIndexerService(items);

      // ── Phase 2: Actions (only if checks show issues) ──
      await _actionInstallLt(items);
      await _actionModelsEnZh(items);
      await _actionEngineIndex(items);
      await _actionRebuildIndex(items);
    } catch (e, st) {
      _addLog('FATAL: $e\n$st');
    }

    // Write log file to desktop
    await _writeLogFile(items);

    _addLog('=== Setup check complete ===');
    _emit(items, running: false, done: true);
  }

  // ── Check implementations ───────────────────────────────────────

  Future<void> _checkFfmpeg(List<SetupCheckItem> items) async {
    final id = 'check.ffmpeg';
    _set(items, id, SetupItemStatus.running);
    try {
      final path = _resolveFfmpegPath();
      if (!File(path).existsSync()) {
        _set(items, id, SetupItemStatus.error, detail: 'ffmpeg.exe not found');
        return;
      }
      final r = await Process.run(path, ['-version'], runInShell: true);
      if (r.exitCode == 0) {
        final firstLine = (r.stdout as String).split('\n').first.trim();
        _set(items, id, SetupItemStatus.ok, detail: path);
        _addLog('  version: $firstLine');
      } else {
        _set(items, id, SetupItemStatus.error, detail: 'ffmpeg.exe exists but failed to run');
      }
    } catch (e) {
      _set(items, id, SetupItemStatus.error, detail: '$e');
    }
  }

  Future<void> _checkQpdf(List<SetupCheckItem> items) async {
    final id = 'check.qpdf';
    _set(items, id, SetupItemStatus.running);
    try {
      final path = _resolveQpdfPath();
      if (!File(path).existsSync()) {
        _set(items, id, SetupItemStatus.error, detail: 'qpdf.exe not found (place it alongside xmate.exe)');
        return;
      }
      final r = await Process.run(path, ['--version'], runInShell: true);
      if (r.exitCode == 0 || r.exitCode == 2 || r.exitCode == 3) {
        final out = ((r.stdout as String) + (r.stderr as String)).trim();
        _set(items, id, SetupItemStatus.ok, detail: out.split('\n').first.trim());
      } else {
        _set(items, id, SetupItemStatus.error, detail: 'qpdf.exe exists but failed to run (exit ${r.exitCode})');
      }
    } catch (e) {
      _set(items, id, SetupItemStatus.error, detail: '$e');
    }
  }

  Future<void> _checkPython(List<SetupCheckItem> items) async {
    final id = 'check.python';
    _set(items, id, SetupItemStatus.running);
    try {
      final info = await PythonService.detect();
      if (info.found) {
        _set(items, id, SetupItemStatus.ok, detail: 'Python ${info.version} @ ${info.exePath}');
      } else {
        _set(items, id, SetupItemStatus.error,
            detail: 'Python 3 not found (install Python 3.10+ from python.org)');
      }
    } catch (e) {
      _set(items, id, SetupItemStatus.error, detail: '$e');
    }
  }

  Future<void> _checkDiskSpace(List<SetupCheckItem> items) async {
    final id = 'check.disk_space';
    _set(items, id, SetupItemStatus.running);
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final drive = '${exeDir[0]}:';
      final r = await Process.run('powershell', [
        '-NoProfile', '-Command',
        "(Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='$drive'\").FreeSpace"
      ], runInShell: true);
      if (r.exitCode == 0) {
        final freeBytes = int.tryParse((r.stdout as String).trim()) ?? 0;
        final freeMB = (freeBytes / (1024 * 1024)).toStringAsFixed(0);
        if (freeBytes > 500 * 1024 * 1024) {
          _set(items, id, SetupItemStatus.ok, detail: '$freeMB MB free');
        } else {
          _set(items, id, SetupItemStatus.warning, detail: 'Only $freeMB MB free (500 MB recommended)');
        }
      } else {
        _set(items, id, SetupItemStatus.warning, detail: 'Could not check disk space');
      }
    } catch (e) {
      _set(items, id, SetupItemStatus.warning, detail: '$e');
    }
  }

  Future<void> _checkWritePerms(List<SetupCheckItem> items) async {
    final id = 'check.write_perms';
    _set(items, id, SetupItemStatus.running);
    var ok = true;
    final sb = StringBuffer();
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final testFile = File('$exeDir\\.xmate_write_test');
      try {
        await testFile.writeAsString('test', flush: true);
        await testFile.delete();
      } catch (_) {
        ok = false;
        sb.write('Cannot write to app dir ($exeDir); ');
      }
      final desktop = '${Platform.environment['USERPROFILE'] ?? 'C:'}\\Desktop';
      final desktopFile = File('$desktop\\.xmate_write_test');
      try {
        await desktopFile.writeAsString('test', flush: true);
        await desktopFile.delete();
      } catch (_) {
        ok = false;
        sb.write('Cannot write to Desktop; ');
      }
      if (ok) {
        _set(items, id, SetupItemStatus.ok, detail: 'App dir + Desktop writable');
      } else {
        _set(items, id, SetupItemStatus.warning, detail: sb.toString());
      }
    } catch (e) {
      _set(items, id, SetupItemStatus.warning, detail: '$e');
    }
  }

  Future<void> _checkLibreTranslate(List<SetupCheckItem> items) async {
    final id = 'check.libretranslate';
    _set(items, id, SetupItemStatus.running);
    try {
      final sm = ServerManager();
      final installed = await sm.isInstalled();
      if (installed) {
        _set(items, id, SetupItemStatus.ok, detail: 'LibreTranslate is installed');
        if (await sm.adoptIfRunning()) {
          _addLog('  Server is currently running');
        }
      } else {
        _set(items, id, SetupItemStatus.warning,
            detail: 'Not installed — run "Install LibreTranslate" action below');
      }
    } catch (e) {
      _set(items, id, SetupItemStatus.warning, detail: '$e');
    }
  }

  Future<void> _checkModels(List<SetupCheckItem> items) async {
    final id = 'check.models';
    _set(items, id, SetupItemStatus.running);
    try {
      final pyInfo = await PythonService.detect();
      if (!pyInfo.found) {
        _set(items, id, SetupItemStatus.warning, detail: 'Python not found — cannot check models');
        return;
      }
      final mm = ModelManager();
      final installed = await mm.listInstalledPairs();
      if (installed.isNotEmpty) {
        final names = installed.map((p) => p.label).join(', ');
        _set(items, id, SetupItemStatus.ok, detail: '${installed.length} pair(s): $names');
      } else {
        _set(items, id, SetupItemStatus.warning,
            detail: 'No models installed — run "Install EN↔ZH Models" action');
      }
    } catch (e) {
      _set(items, id, SetupItemStatus.warning, detail: '$e');
    }
  }

  Future<void> _checkDictDb(List<SetupCheckItem> items) async {
    final id = 'check.dict_db';
    _set(items, id, SetupItemStatus.running);
    try {
      final ds = DictionaryService();
      if (ds.isOpen) {
        final stats = await ds.getStats();
        _set(items, id, SetupItemStatus.ok,
            detail: '${stats.entryCount} entries loaded');
      } else {
        _set(items, id, SetupItemStatus.warning,
            detail: 'No dictionary database loaded — import via Settings → Debug');
      }
    } catch (e) {
      _set(items, id, SetupItemStatus.warning, detail: '$e');
    }
  }

  Future<void> _checkSearchIndex(List<SetupCheckItem> items) async {
    final id = 'check.search_index';
    _set(items, id, SetupItemStatus.running);
    try {
      final fss = FileSearchService();
      final infos = fss.getSegmentInfos();
      final ready = infos.where((s) => s.status == SegmentStatus.ready && s.fileCount > 0);
      if (ready.isNotEmpty) {
        final totalFiles = ready.fold<int>(0, (sum, s) => sum + s.fileCount);
        _set(items, id, SetupItemStatus.ok,
            detail: '${ready.length} path(s), $totalFiles files indexed');
      } else {
        _set(items, id, SetupItemStatus.warning,
            detail: 'No indexes built — configure paths in Settings → File Search');
      }
    } catch (e) {
      _set(items, id, SetupItemStatus.warning, detail: '$e');
    }
  }

  Future<void> _checkIndexerService(List<SetupCheckItem> items) async {
    final id = 'check.indexer_service';
    _set(items, id, SetupItemStatus.running);
    try {
      final ch = FileSearchChannel();
      final installed = await ch.isIndexerServiceInstalled();
      if (installed) {
        final running = await ch.isIndexerServiceRunning();
        _set(items, id, SetupItemStatus.ok,
            detail: running ? 'Installed and running' : 'Installed (not running)');
      } else {
        _set(items, id, SetupItemStatus.warning,
            detail: 'Not installed — background USN monitoring unavailable');
      }
    } catch (e) {
      _set(items, id, SetupItemStatus.warning, detail: '$e');
    }
  }

  // ── Action implementations ──────────────────────────────────────

  Future<void> _actionInstallLt(List<SetupCheckItem> items) async {
    final id = 'action.install_lt';
    _set(items, id, SetupItemStatus.running);
    try {
      final sm = ServerManager();
      final alreadyInstalled = await sm.isInstalled();
      if (alreadyInstalled) {
        _set(items, id, SetupItemStatus.ok, detail: 'Already installed — skipped');
        return;
      }
      final mm = ModelManager();
      final ok = await mm.installServer(onLog: (line) => _addLog('  [pip] $line'));
      if (ok) {
        _set(items, id, SetupItemStatus.ok, detail: 'LibreTranslate installed successfully');
        _set(items, 'check.libretranslate', SetupItemStatus.ok, detail: 'LibreTranslate is installed');
      } else {
        _set(items, id, SetupItemStatus.error, detail: 'Installation failed — see log for details');
      }
    } catch (e) {
      _set(items, id, SetupItemStatus.error, detail: '$e');
    }
  }

  Future<void> _actionModelsEnZh(List<SetupCheckItem> items) async {
    final id = 'action.models_enzh';
    _set(items, id, SetupItemStatus.running);
    try {
      final mm = ModelManager();
      final installed = await mm.listInstalledPairs();
      final hasEnZh = installed.any((p) =>
          (p.code1 == 'en' && p.code2 == 'zh') || (p.code1 == 'zh' && p.code2 == 'en'));
      if (hasEnZh) {
        _set(items, id, SetupItemStatus.ok, detail: 'EN↔ZH models already installed — skipped');
        return;
      }
      final result = await mm.installPair('en', 'zh');
      if (result['ok'] == true) {
        _set(items, id, SetupItemStatus.ok, detail: 'EN↔ZH models installed successfully');
        final updated = await mm.listInstalledPairs();
        final names = updated.map((p) => p.label).join(', ');
        _set(items, 'check.models', SetupItemStatus.ok, detail: '${updated.length} pair(s): $names');
      } else {
        final err = result['error'] as String? ?? 'Unknown error';
        _set(items, id, SetupItemStatus.error, detail: 'Failed: $err');
      }
    } catch (e) {
      _set(items, id, SetupItemStatus.error, detail: '$e');
    }
  }

  Future<void> _actionEngineIndex(List<SetupCheckItem> items) async {
    final id = 'action.engine_index';
    _set(items, id, SetupItemStatus.running);
    try {
      final mm = ModelManager();
      final result = await mm.updateIndex();
      if (result['ok'] == true) {
        _set(items, id, SetupItemStatus.ok, detail: 'Engine index updated');
      } else {
        final err = result['error'] as String? ?? 'Unknown error';
        _set(items, id, SetupItemStatus.warning, detail: 'Update failed: $err');
      }
    } catch (e) {
      _set(items, id, SetupItemStatus.warning, detail: '$e');
    }
  }

  Future<void> _actionRebuildIndex(List<SetupCheckItem> items) async {
    final id = 'action.rebuild_index';
    _set(items, id, SetupItemStatus.running);
    try {
      final fss = FileSearchService();
      final infos = fss.getSegmentInfos();
      final pathsToRebuild = <String>[];
      for (final info in infos) {
        if (info.fileCount == 0) {
          pathsToRebuild.add(info.rootPath);
        }
      }
      if (pathsToRebuild.isEmpty) {
        _set(items, id, SetupItemStatus.ok, detail: 'All paths already indexed — skipped');
        return;
      }
      int rebuilt = 0;
      for (final rp in pathsToRebuild.take(3)) {
        _addLog('  Rebuilding: $rp');
        await for (final msg in fss.rebuildPath(rp)) {
          _addLog('    $msg');
          _set(items, id, SetupItemStatus.running, detail: msg);
        }
        rebuilt++;
      }
      if (rebuilt > 0) {
        _set(items, id, SetupItemStatus.ok, detail: '$rebuilt path(s) rebuilt');
        final updated = fss.getSegmentInfos();
        final ready = updated.where((s) => s.status == SegmentStatus.ready && s.fileCount > 0);
        final totalFiles = ready.fold<int>(0, (sum, s) => sum + s.fileCount);
        _set(items, 'check.search_index', SetupItemStatus.ok,
            detail: '${ready.length} path(s), $totalFiles files indexed');
      } else {
        _set(items, id, SetupItemStatus.warning, detail: 'No paths ready for rebuild');
      }
    } catch (e) {
      _set(items, id, SetupItemStatus.error, detail: '$e');
    }
  }

  // ── Log file ───────────────────────────────────────────────────

  Future<void> _writeLogFile(List<SetupCheckItem> items) async {
    try {
      final desktop = '${Platform.environment['USERPROFILE'] ?? 'C:'}\\Desktop';
      final now = DateTime.now();
      final ts = '${now.year}${_pad(now.month)}${_pad(now.day)}_${_pad(now.hour)}${_pad(now.minute)}${_pad(now.second)}';
      final path = '$desktop\\xmate_setup_$ts.log';
      final sb = StringBuffer();
      sb.writeln('XMate Setup Log — ${now.toIso8601String()}');
      sb.writeln('=' * 60);
      sb.writeln();
      sb.writeln('── Results ──');
      sb.writeln();
      for (final item in items) {
        final icon = item.status == SetupItemStatus.ok ? '[OK]' :
                     item.status == SetupItemStatus.warning ? '[WARN]' :
                     item.status == SetupItemStatus.error ? '[FAIL]' :
                     item.status == SetupItemStatus.running ? '[....]' : '[SKIP]';
        sb.writeln('$icon ${item.label}');
        if (item.detail != null && item.detail!.isNotEmpty) {
          sb.writeln('    ${item.detail}');
        }
      }
      sb.writeln();
      sb.writeln('── Summary ──');
      sb.writeln('  OK: ${items.where((i) => i.status == SetupItemStatus.ok).length}');
      sb.writeln('  Warnings: ${items.where((i) => i.status == SetupItemStatus.warning).length}');
      sb.writeln('  Errors: ${items.where((i) => i.status == SetupItemStatus.error).length}');
      sb.writeln();
      sb.writeln('── Detail Log ──');
      sb.writeln();
      for (final line in _logLines) {
        sb.writeln(line);
      }
      await File(path).writeAsString(sb.toString(), flush: true);
      _logPath = path;
      _addLog('Log saved to: $path');
    } catch (e) {
      _addLog('Failed to write log file: $e');
    }
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  void dispose() {
    _ctrl.close();
  }
}
