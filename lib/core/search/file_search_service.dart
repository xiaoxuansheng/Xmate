/// XMate File Search — Orchestrator singleton.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import '../settings/settings_service.dart';
import '../utils/logger.dart';
import 'file_index_builder.dart';
import 'file_index_config.dart';
import 'file_index_entry.dart';
import 'file_index_store.dart';
import 'file_search_channel.dart';
import 'file_search_filter.dart';
import 'file_search_priority.dart';
import 'file_search_query.dart';
import 'file_trigram_index.dart';

class FileSearchResult {
  final String name, ext, path, rootPath;
  final bool isDir;
  final double score;
  final int segmentPriority; // 0=base, 1+=incremental — higher is newer
  const FileSearchResult({required this.name, required this.ext, required this.path,
    required this.rootPath, this.isDir = false, required this.score,
    this.segmentPriority = 0});
  String get fullPath {
    final rp = rootPath.endsWith('/') || rootPath.endsWith('\\') ? rootPath : '$rootPath/';
    return '$rp$path$name${ext.isNotEmpty ? '.$ext' : ''}';
  }
  @override String toString() => 'FileSearchResult("$fullPath" score=${score.toStringAsFixed(3)})';
}

String normalizePath(String p) =>
    p.replaceAll('\\', '/').trimRight().replaceAll(RegExp(r'/+$'), '');
bool pathsMatch(String a, String b) => a.toLowerCase() == b.toLowerCase();

class _PreScore implements Comparable<_PreScore> {
  final int entryId, nameMatches, pinyinMatches;
  const _PreScore(this.entryId, this.nameMatches, this.pinyinMatches);
  @override int compareTo(_PreScore o) =>
      (o.pinyinMatches * 3 + o.nameMatches).compareTo(pinyinMatches * 3 + nameMatches);
}

/// Auto log entry — emitted by the background timer for UI display.
class AutoLogEntry {
  final DateTime time;
  final String rootPath;
  final String message;
  const AutoLogEntry({required this.time, required this.rootPath, required this.message});
}

class FileSearchService {
  static final FileSearchService _instance = FileSearchService._();
  factory FileSearchService() => _instance;
  FileSearchService._();

  /// Static wrapper to avoid capturing `this` (and its _segments → LoadedSegment.raf)
  /// in Isolate.run closures. Dart closures inside instance methods capture `this`
  /// implicitly, making all fields (including RandomAccessFile handles) unsendable.
  static Future<Map<String, dynamic>> _buildInIsolate(
      String indexPath, String contentPath,
      String rootPath, List<Map<String, dynamic>> rawEntries) {
    return Isolate.run(() => buildSegmentInIsolate({
      'indexPath': indexPath, 'contentPath': contentPath,
      'rootPath': rootPath, 'rawEntries': rawEntries,
    }));
  }

  final _settings = SettingsService();
  final _store = FileIndexStore();
  final _channel = FileSearchChannel();
  final _segments = <LoadedSegment>[];
  Set<String> _recentOpenSet = {};
  SearchConfig _config = const SearchConfig();
  Timer? _autoUpdateTimer;
  bool _initialized = false;

  // Dedup cache — resolves symlinks/junctions so paths like
  //   Start Menu/程序/foo.lnk and Start Menu/Programs/foo.lnk
  //   map to the same canonical key. Cleared per search.
  final Map<String, String> _dedupCache = {};

  /// Resolve directory symlinks/junctions to a canonical path for dedup.
  /// e.g. Start Menu/程序/foo.lnk → Start Menu/Programs/foo.lnk
  ///
  /// Symlinks are at the directory level (程序 → Programs), not per-file.
  /// We resolve only the parent directory and cache at dir granularity, so all
  /// files in the same directory share one resolution (1 syscall per dir).
  String _resolveForDedup(String path) {
    final n = normalizePath(path);
    return _dedupCache.putIfAbsent(n, () {
      final lastSlash = n.lastIndexOf('/');
      final dir = lastSlash >= 0 ? n.substring(0, lastSlash) : '.';
      final name = lastSlash >= 0 ? n.substring(lastSlash + 1) : n;

      // Resolve parent directory (cached — all files in same dir hit once)
      String resolvedDir = _dedupCache.putIfAbsent(dir, () {
        try {
          final r = Directory(dir).resolveSymbolicLinksSync();
          return r.replaceAll('\\', '/');
        } catch (_) {
          return dir;
        }
      });

      return '$resolvedDir/$name';
    });
  }

  // USN state per rootPath
  final _usnState = <String, SegmentUsnState>{};
  // Per-path intervals: -1 = auto, 0 = off, >0 = timer minutes
  final _perPathIntervals = <String, int>{};
  final _rebuildInProgress = <String>{};
  // Per-path last incremental update time (manual or auto).
  final _lastUpdateTime = <String, DateTime>{};
  // Rolling log buffer for background auto activity (latest 200 entries).
  // Rolling log buffer for background auto activity (latest 200 entries).
  final List<AutoLogEntry> autoLog = [];
  int rebuildCount = 0;
  int get minuteCounter => _minuteCounter;

  // Multi-segment incremental update support
  final _supersededPrefixes = <String, Set<String>>{};   // rootPath → S| prefixes
  final _deletedPrefixes = <String, Set<String>>{};       // rootPath → D| prefixes

  static const _kIndexPaths = 'app.filesearch.indexPaths';
  static const _kRecentOpenSet = 'app.filesearch.recentOpenSet';
  static const _kUsnState = 'app.filesearch.usnState';
  static const _kPerPathIntervals = 'app.filesearch.perPathIntervals';
  static const _kCustomFilters = 'app.filesearch.customFilters';
  static const _kPriorityRules = 'app.filesearch.priorityRules';

  // ── Filter presets ─────────────────────────────────────────────────────

  /// All currently active filters. Returns stored filters, or builtins if none saved.
  List<FileSearchFilter> getActiveFilters() {
    final raw = _settings.get(_kCustomFilters);
    if (raw is List && raw.isNotEmpty) {
      final result = <FileSearchFilter>[];
      for (final e in raw) {
        if (e is Map) {
          try {
            result.add(FileSearchFilter.fromJson(Map<String, dynamic>.from(e)));
          } catch (_) {}
        }
      }
      if (result.isNotEmpty) return result;
    }
    // No custom filters saved — seed with built-ins
    return [...FileSearchFilter.builtins];
  }

  /// Save all filters (replaces the stored list).
  void saveFilters(List<FileSearchFilter> filters) {
    _settings.set(_kCustomFilters, filters.map((f) => f.toJson()).toList());
  }

  // ── Priority rules ────────────────────────────────────────────────────

  List<PriorityRule> _activePriorityRules = [];
  final Map<int, RegExp> _priorityRegExCache = {};

  List<PriorityRule> getActivePriorityRules() {
    if (_activePriorityRules.isNotEmpty) return _activePriorityRules;
    final raw = _settings.get(_kPriorityRules);
    if (raw is List && raw.isNotEmpty) {
      final result = <PriorityRule>[];
      for (final e in raw) {
        if (e is Map) {
          try {
            result.add(PriorityRule.fromJson(Map<String, dynamic>.from(e)));
          } catch (_) {}
        }
      }
      if (result.isNotEmpty) {
        _activePriorityRules = result;
        return result;
      }
    }
    // Seed with defaults
    _activePriorityRules = PriorityRule.defaultRules();
    return _activePriorityRules;
  }

  void savePriorityRules(List<PriorityRule> rules) {
    _activePriorityRules = rules;
    _priorityRegExCache.clear();
    _settings.set(_kPriorityRules, rules.map((r) => r.toJson()).toList());
  }

  /// Compile cached regexen for priority rules (call at start of search).
  void _preparePriorityRules() {
    if (_activePriorityRules.isEmpty) _activePriorityRules = getActivePriorityRules();
    _priorityRegExCache.clear();
    for (int i = 0; i < _activePriorityRules.length; i++) {
      final re = _activePriorityRules[i].compileRegex();
      if (re != null) _priorityRegExCache[i] = re;
    }
  }

  // ── Default index directories (seed on first run) ──────────────────

  static List<String> _defaultIndexDirs(Map<String, String> env) {
    final result = <String>[
      _envAppend(env, 'USERPROFILE', 'Desktop'),
      _envAppend(env, 'APPDATA', r'Microsoft\Windows\Start Menu\Programs'),
      _envAppend(env, 'ALLUSERSPROFILE', r'Microsoft\Windows\Start Menu\Programs'),
    ];

    // Add non-C: drive roots
    for (int i = 0; i < 26; i++) {
      final letter = String.fromCharCode('A'.codeUnitAt(0) + i);
      if (letter == 'C') continue;
      final path = '$letter:\\';
      try {
        if (Directory(path).existsSync()) result.add(path);
      } catch (_) {}
    }
    return result;
  }

  static String _envAppend(Map<String, String> env, String varName, String suffix) {
    final base = (env[varName] ?? 'C:').replaceAll('\\', '/');
    return '$base/$suffix';
  }

  // ── Init ─────────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    logger.info('[init] FileSearchService init begin');
    var indexPaths = _loadJsonList(_kIndexPaths)
        .map((e) => IndexPathConfig.fromJson(e as Map<String, dynamic>)).toList();

    // Seed default directories on first run
    if (indexPaths.isEmpty) {
      final env = Platform.environment;
      final defaults = <IndexPathConfig>[];
      for (final d in _defaultIndexDirs(env)) {
        if (d.isNotEmpty && Directory(d).existsSync()) {
          defaults.add(IndexPathConfig(rootPath: normalizePath(d)));
        }
      }
      indexPaths = defaults;
      _settings.set(_kIndexPaths, indexPaths.map((p) => p.toJson()).toList());
    }
    _config = SearchConfig(indexPaths: indexPaths);

    // USN state
    final usnRaw = _settings.get(_kUsnState);
    if (usnRaw is Map) {
      for (final e in usnRaw.entries) {
        final k = normalizePath(e.key.toString());
        if (e.value is Map) _usnState[k] = SegmentUsnState.fromJson(Map<String, dynamic>.from(e.value as Map));
      }
    }

    // Per-path intervals
    final ppiRaw = _settings.get(_kPerPathIntervals);
    if (ppiRaw is Map) {
      for (final e in ppiRaw.entries) {
        _perPathIntervals[normalizePath(e.key.toString())] = (e.value as num?)?.toInt() ?? 0;
      }
    }

    final recentList = _settings.getWithDefault<List>(_kRecentOpenSet, []).cast<String>().toList();
    _recentOpenSet = recentList.map(normalizePath).toSet();
    for (final ip in _config.indexPaths) {
      final segs = await _store.loadSegments(ip.rootPath);
      _segments.addAll(segs);
      await _loadDelFile(ip.rootPath);
    }
    _restartAutoUpdateIfNeeded();
    // Kick off first USN query for auto paths after a short delay
    Future.delayed(const Duration(seconds: 2), _onMinuteTick);
    logger.info('[init] ${_segments.length} segments loaded, ${_recentOpenSet.length} recent');
  }

  SearchConfig get config => _config;

  // ── Segment infos ────────────────────────────────────────────────────────

  List<SegmentInfo> getSegmentInfos() {
    final infos = <SegmentInfo>[];
    for (final ip in _config.indexPaths) {
      final rp = normalizePath(ip.rootPath);
      final segs = _segments.where((s) => pathsMatch(s.rootPath, rp)).toList();
      final dirty = false; // timer-driven model: updates run synchronously, no pending state
      if (segs.isNotEmpty) {
        final base = segs.firstWhere((s) => s.priority == 0,
            orElse: () => segs.first);
        final ts = base.builtAt;
        final totalFiles = segs.fold<int>(0, (sum, s) => sum + s.fileCount);
        infos.add(SegmentInfo(
          rootPath: rp, status: SegmentStatus.ready, fileCount: totalFiles,
          updatedAt: '${ts.year}-${_pad(ts.month)}-${_pad(ts.day)} '
              '${_pad(ts.hour)}:${_pad(ts.minute)}:${_pad(ts.second)}',
          lastUpdated: _lastUpdateTime[rp] ?? ts,
          dirty: dirty,
          segmentCount: segs.length,
        ));
      } else {
        infos.add(SegmentInfo(rootPath: rp, dirty: dirty,
            lastUpdated: _lastUpdateTime[rp]));
      }
    }
    return infos;
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  // ── Rebuild (full, deletes existing index) ───────────────────────────────

  Stream<String> rebuildAll() async* {
    yield 'Rebuilding ${_config.indexPaths.length} path(s)...';
    for (final ip in _config.indexPaths) { yield* rebuildPath(ip.rootPath); }
    yield 'Done.';
  }

  Stream<String> rebuildPath(String rootPath) async* {
    rootPath = normalizePath(rootPath);
    yield 'Scanning $rootPath...';
    final start = DateTime.now();

    List<Map<String, dynamic>> rawEntries;
    try {
      rawEntries = await _channel.scanDirectoryAsync(rootPath);
    } catch (e) { yield 'Failed to scan $rootPath: $e'; return; }
    if (rawEntries.isEmpty) { yield 'No files found in $rootPath.'; return; }
    yield 'Scanned ${rawEntries.length} entries in ${DateTime.now().difference(start).inMilliseconds}ms.';

    // Close old segment handles BEFORE deleting files — open RAFs lock the files
    yield 'Cleaning up old index...';
    _removeSegmentsForPath(rootPath);
    _supersededPrefixes.remove(rootPath);
    _deletedPrefixes.remove(rootPath);

    yield 'Building index (in background)...';
    await _store.deleteAllSegments(rootPath);
    final (indexPath, contentPath) = await _store.segmentPathsFor(rootPath);
    Map<String, dynamic> stats;
    try {
      stats = await FileSearchService._buildInIsolate(
          indexPath, contentPath, rootPath, rawEntries);
    } catch (e) { yield 'Failed to build: $e'; return; }
    final fileCount = stats['fileCount'] as int? ?? 0;
    final indexSize = stats['indexSize'] as int? ?? 0;
    yield 'Built: $fileCount files, ${(indexSize / 1024).toStringAsFixed(0)} KB in ${DateTime.now().difference(start).inSeconds}s.';

    yield 'Loading index (metadata only)...';
    final segs = await _store.loadSegments(rootPath);
    _segments.addAll(segs);
    _ensureConfigPath(rootPath);

    // Reset USN cursor
    logger.info('[rebuild] resetting USN cursor...');
    try {
      await _updateUsnCursor(rootPath, fileCount).timeout(const Duration(seconds: 5));
    } catch (e) {
      logger.error('[rebuild] _updateUsnCursor failed/timed out: $e');
    }

    _lastUpdateTime[rootPath] = DateTime.now();
    rebuildCount++;

    yield 'Done: $rootPath → $fileCount files, ${DateTime.now().difference(start).inSeconds}s.';
  }

  // ── Del file (S|/D| prefix management) ───────────────────────────────

  Future<void> _loadDelFile(String rootPath) async {
    final delPath = await _store.delFilePathFor(rootPath);
    final f = File(delPath);
    final superseded = <String>{};
    final deleted = <String>{};
    if (f.existsSync()) {
      try {
        for (final line in f.readAsLinesSync()) {
          final t = line.trim();
          if (t.startsWith('S|')) { superseded.add(t.substring(2).toLowerCase()); }
          else if (t.startsWith('D|')) { deleted.add(t.substring(2).toLowerCase()); }
        }
      } catch (_) {}
    }
    _supersededPrefixes[rootPath] = superseded;
    _deletedPrefixes[rootPath] = deleted;
  }

  Future<void> _writeDelFile(String rootPath,
      Set<String> superseded, Set<String> deleted) async {
    final delPath = await _store.delFilePathFor(rootPath);
    final buf = StringBuffer();
    for (final s in superseded) { buf.writeln('S|$s'); }
    for (final d in deleted) { buf.writeln('D|$d'); }
    try {
      File(delPath).writeAsStringSync(buf.toString(), flush: true);
    } catch (_) {}
  }

  // ── Manual Update (USN-driven, no mtime recursion) ────────────────────

  Stream<String> manualUpdatePath(String rootPath) async* {
    rootPath = normalizePath(rootPath);
    yield 'Checking $rootPath (USN)...';

    // Step 1: Query USN — try indexer service first, fall back to direct channel
    final usn = _usnState[rootPath];
    final lastId = usn?.lastUsnId ?? 0;
    Map<String, dynamic>? result;

    // Ensure service is running before we read results
    await _ensureServiceRunning();
    // Re-read lastUsn from service if available (service updates cursors internally)
    final svcResult = await _tryReadServiceUsn(rootPath);
    if (svcResult != null && svcResult.isNotEmpty) {
      logger.debug('[update] using service USN result for $rootPath');
      result = svcResult;
    } else {
      logger.debug('[update] queryUsnWithDirsAsync rootPath=$rootPath lastUsnId=$lastId');
      result = await _channel.queryUsnWithDirsAsync(rootPath, lastId);
    }

    logger.debug('[update] USN result keys: ${result.keys}, dirty=${result['dirty']}, '
        'nextUsn=${result['nextUsn']}, '
        'dirtyDirs#=${(result['dirtyDirs'] as List?)?.length}, '
        'deletedDirs#=${(result['deletedDirs'] as List?)?.length}');
    final dirty = result['dirty'] == true;
    if (!dirty) {
      // Even when clean, update the USN cursor
      if (result['nextUsn'] is int) {
        _usnState[rootPath] = SegmentUsnState(
            lastUsnId: result['nextUsn'] as int,
            fileCount: _totalFileCount(rootPath),
            recordedAt: DateTime.now());
        _persistUsnState();
      }
      yield '$rootPath: USN clean, skip.';
      return;
    }

    final dirtyDirs = (result['dirtyDirs'] as List<dynamic>?)
        ?.map((e) => e.toString()).toList() ?? <String>[];
    final deletedDirs = (result['deletedDirs'] as List<dynamic>?)
        ?.map((e) => e.toString()).toList() ?? <String>[];
    final nextUsn = (result['nextUsn'] as num?)?.toInt() ?? 0;

    logger.debug('[update] $rootPath: USN → ${dirtyDirs.length} dirty dirs, ${deletedDirs.length} deleted dirs');

    if (dirtyDirs.isEmpty && deletedDirs.isEmpty) {
      // Update USN cursor even if no actionable changes
      _usnState[rootPath] = SegmentUsnState(
          lastUsnId: nextUsn, fileCount: _totalFileCount(rootPath),
          recordedAt: DateTime.now());
      _persistUsnState();
      yield '$rootPath: USN dirty but no resolved dirs, up to date.';
      return;
    }

    // Step 2: Threshold check — too many dirty dirs → full rebuild
    if (dirtyDirs.length > 10000) {
      yield '$rootPath: ${dirtyDirs.length} dirty dirs > 10k, falling back to full rebuild...';
      _rebuildInProgress.add(rootPath);
      try { await for (final m in rebuildPath(rootPath)) { yield '  $m'; } }
      finally { _rebuildInProgress.remove(rootPath); }
      return;
    }

    // Step 3: Enumerate dirty dirs (direct children only), no base decode
    final scanList = <Map<String, dynamic>>[];
    final newSuperseded = <String>{};

    for (final dd in dirtyDirs) {
      final dirPath = dd.isEmpty ? rootPath : '$rootPath/$dd';
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;
      final dirPrefix = dd.isEmpty ? '' : '$dd/';
      try {
        for (final c in dir.listSync()) {
          if (c is File) {
            final name = c.uri.pathSegments.last;
            final dotIdx = name.lastIndexOf('.');
            final baseName = dotIdx > 0 ? name.substring(0, dotIdx) : name;
            final ext = dotIdx > 0 ? name.substring(dotIdx + 1).toLowerCase() : '';
            scanList.add({'n': baseName, 'e': ext, 'p': dirPrefix, 'd': false});
          }
        }
      } catch (_) {}
      if (dirPrefix.isNotEmpty) newSuperseded.add(dirPrefix);
    }

    // Step 4: Merge with existing del prefixes
    final existingS = _supersededPrefixes[rootPath] ?? <String>{};
    final existingD = _deletedPrefixes[rootPath] ?? <String>{};

    for (final dd in deletedDirs) {
      if (dd.isNotEmpty) existingD.add('$dd/');
    }
    existingS.addAll(newSuperseded);

    if (scanList.isEmpty && existingD.isEmpty && newSuperseded.isEmpty) {
      yield '$rootPath: no new files to index.';
      if (existingS.isNotEmpty || existingD.isNotEmpty) {
        await _writeDelFile(rootPath, existingS, existingD);
      }
      _usnState[rootPath] = SegmentUsnState(
          lastUsnId: nextUsn, fileCount: _totalFileCount(rootPath),
          recordedAt: DateTime.now());
      _persistUsnState();
      return;
    }

    // Step 5: Build incremental segment in Isolate
    int incNum;
    if (scanList.isNotEmpty) {
      yield '$rootPath: building incremental index for ${scanList.length} files...';
      incNum = await _store.nextIncrementalNumber(rootPath);
      final (incIndex, incContent) = await _store.incrementalPathsFor(rootPath, incNum);
      try {
        await FileSearchService._buildInIsolate(
            incIndex, incContent, rootPath, scanList);
      } catch (e) { yield 'Failed to build incremental: $e'; return; }
      yield '$rootPath: incremental segment _${incNum} built ($scanList.length files)';
    } else {
      incNum = await _store.nextIncrementalNumber(rootPath) - 1;
    }

    // Step 5b: Create empty segments for renamed directories to accelerate
    // compaction (5-segment threshold → full rebuild fixes rename gaps).
    final renamedDirs = (result['renamedDirs'] as num?)?.toInt() ?? 0;
    if (renamedDirs > 0) {
      final existingInc = _segments.where((s) =>
          pathsMatch(s.rootPath, rootPath) && s.priority > 0).length;
      final addCount = (5 - existingInc).clamp(0, renamedDirs);
      for (int i = 0; i < addCount; i++) {
        final n = await _store.nextIncrementalNumber(rootPath);
        final (idx, content) = await _store.incrementalPathsFor(rootPath, n);
        await FileSearchService._buildInIsolate(idx, content, rootPath, []);
      }
      if (addCount > 0) {
        yield '$rootPath: $addCount empty segment(s) added for $renamedDirs renamed dir(s)';
      }
    }

    // Write del file with merged prefixes
    await _writeDelFile(rootPath, existingS, existingD);

    // Step 6: Reload + update USN cursor
    _removeSegmentsForPath(rootPath);
    final segs = await _store.loadSegments(rootPath);
    _segments.addAll(segs);
    await _loadDelFile(rootPath);

    _usnState[rootPath] = SegmentUsnState(
        lastUsnId: nextUsn, fileCount: _totalFileCount(rootPath),
        recordedAt: DateTime.now());
    _persistUsnState();
    _lastUpdateTime[rootPath] = DateTime.now();

    yield '$rootPath: update complete (inc #$incNum, +${scanList.length} files)';

    // Step 7: Compaction check — run synchronously to ensure
    // incremental segment files are properly deleted and replaced
    // with a clean base before the next update arrives.
    final incCount = _segments.where((s) =>
        pathsMatch(s.rootPath, rootPath) && s.priority > 0).length;
    if (incCount >= 5) {
      yield '$rootPath: compaction ($incCount inc segments ≥ 5) — running full rebuild...';
      await for (final m in rebuildPath(rootPath)) {
        yield '  $m';
      }
    }
  }

  /// Update all paths using mtime comparison.
  Stream<String> updateAll() async* {
    yield 'Checking ${_config.indexPaths.length} path(s) via USN...';
    for (final ip in _config.indexPaths) {
      yield* manualUpdatePath(ip.rootPath);
    }
    yield 'Update complete.';
  }

  // ── USN ──────────────────────────────────────────────────────────────────

  /// Reset USN cursor after a rebuild (queries current MaxUsn, no record walking).
  Future<void> _updateUsnCursor(String rootPath, int fileCount) async {
    final result = await _channel.queryUsn(rootPath, 0); // lastUsnId=0 → cursor-only
    final nextUsn = (result['nextUsn'] as num?)?.toInt() ?? 0;
    _usnState[rootPath] = SegmentUsnState(
        lastUsnId: nextUsn, fileCount: fileCount, recordedAt: DateTime.now());
    _persistUsnState();
  }

  void _persistUsnState() {
    final out = <String, Map<String, dynamic>>{};
    for (final e in _usnState.entries) { out[e.key] = e.value.toJson(); }
    _settings.set(_kUsnState, out);
  }

  // ── Incremental update scheduling ────────────────────────────────────────

  int getPerPathInterval(String rootPath) =>
      _perPathIntervals[normalizePath(rootPath)] ?? -1;

  void setPerPathInterval(String rootPath, int intervalMinutes) {
    final rp = normalizePath(rootPath);
    _perPathIntervals[rp] = intervalMinutes;
    final out = <String, int>{};
    for (final e in _perPathIntervals.entries) { out[e.key] = e.value; }
    _settings.set(_kPerPathIntervals, out);
    _restartAutoUpdateIfNeeded();
  }

  void stopAutoUpdate() { _autoUpdateTimer?.cancel(); _autoUpdateTimer = null; }

  void _restartAutoUpdateIfNeeded() {
    _autoUpdateTimer?.cancel();
    _autoUpdateTimer = null;
    bool need = false;
    for (final v in _perPathIntervals.values) {
      if (v != 0) { need = true; break; }
    }
    if (need) {
      _autoUpdateTimer = Timer.periodic(const Duration(minutes: 1), (_) => _onMinuteTick());
      _ensureServiceRunning();
      _syncServiceConfig();
      logger.info('[autoUpdate] timer started (1-min ticks)');
    } else {
      _maybeStopService();
      logger.info('[autoUpdate] stopped (no active paths)');
    }
  }

  // ── Indexer Service helpers ────────────────────────────────────────────

  /// DJB2 hash matching C++ indexer_service.cpp (31-bit, same as _hashString in file_index_store.dart).
  static int _hashPath(String s) {
    int h = 5381;
    for (int i = 0; i < s.length; i++) {
      h = ((h << 5) + h + s.codeUnitAt(i)) & 0x7FFFFFFF;
    }
    return h;
  }

  /// Start the indexer service if installed. Idempotent — no-op if already running.
  Future<void> _ensureServiceRunning() async {
    final installed = await _channel.isIndexerServiceInstalled();
    if (!installed) return;
    final running = await _channel.isIndexerServiceRunning();
    if (running) return;
    await _channel.startIndexerService();
    logger.info('[svc] started');
  }

  /// Stop the indexer service if it was running.
  Future<void> _maybeStopService() async {
    final installed = await _channel.isIndexerServiceInstalled();
    if (!installed) return;
    await _channel.stopIndexerService();
    logger.info('[svc] stopped');
  }

  /// Write index paths config so the service knows what to monitor.
  Future<void> _syncServiceConfig() async {
    final installed = await _channel.isIndexerServiceInstalled();
    if (!installed) return;
    final paths = <String>[];
    for (final ip in _config.indexPaths) {
      paths.add(ip.rootPath);
    }
    // Use the minimum non-zero interval, or 60s default
    int interval = 60;
    for (final v in _perPathIntervals.values) {
      if (v != 0) {
        // For custom intervals, use a compromise: poll frequently, let Dart
        // side throttle with its own _minuteCounter logic.
        interval = 60;
        break;
      }
    }
    await _channel.writeIndexerConfig(paths, interval);
  }

  /// Try to read USN results from the indexer service.
  /// Returns parsed JSON map or null if service unavailable or data stale.
  Future<Map<String, dynamic>?> _tryReadServiceUsn(String rootPath) async {
    final installed = await _channel.isIndexerServiceInstalled();
    if (!installed) return null;

    final hash = _hashPath(rootPath).toRadixString(16).padLeft(8, '0');
    final json = await _channel.readUsnResult(hash);
    if (json == null || json.isEmpty) return null;

    try {
      final data = jsonDecode(json) as Map<String, dynamic>;
      return data['usn'] as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  int _minuteCounter = 0;

  /// Log a message to the auto-log ring buffer (latest 200 entries).
  void _logAuto(String rootPath, String message) {
    autoLog.add(AutoLogEntry(time: DateTime.now(), rootPath: rootPath, message: message));
    if (autoLog.length > 200) autoLog.removeAt(0);
    logger.info('[autoLog] $rootPath: $message');
  }

  Future<void> _onMinuteTick() async {
    _minuteCounter++;

    for (final ip in _config.indexPaths) {
      final rp = normalizePath(ip.rootPath);
      final interval = _perPathIntervals[rp] ?? 0;
      if (interval == 0) continue;
      if (_rebuildInProgress.contains(rp)) continue;

      // Customize: only act on exact interval ticks
      if (interval > 0 && _minuteCounter % interval != 0) continue;

      // Run the EXACT same method as manual Update.
      final mode = interval == -1 ? 'auto' : 'custom ${interval}m';
      _rebuildInProgress.add(rp);
      try {
        final lines = <String>[];
        // If last update > 1 day ago and incremental segments exist, rebuild.
        final incCount = _segments.where(
            (s) => pathsMatch(s.rootPath, rp) && s.priority > 0).length;
        final lastUpd = _lastUpdateTime[rp];
        if (lastUpd != null &&
            DateTime.now().difference(lastUpd).inHours >= 24 &&
            incCount > 0) {
          _logAuto(rp, 'tick #$_minuteCounter ($mode): aging ($incCount inc, '
              '${DateTime.now().difference(lastUpd).inHours}h old) — rebuild');
          await for (final m in rebuildPath(rp)) { lines.add(m); }
        } else {
          await for (final m in manualUpdatePath(rp)) { lines.add(m); }
        }
        // Only log if something happened (not just "USN clean, skip")
        if (lines.any((l) => l.contains('update complete') || l.contains('built'))) {
          _logAuto(rp, 'tick #$_minuteCounter ($mode): ${lines.last}');
        }
      } finally {
        _rebuildInProgress.remove(rp);
      }
    }
  }

  // ── Search ───────────────────────────────────────────────────────────────

  static const _topKPhaseA = 200;

  /// Depth contribution lookup table (log-smooth, 6 levels cap).
  /// depth = segment count in relative path (root=0, subdir=1, ...).
  static const _depthScoreTable = [0.05, 0.029, 0.024, 0.021, 0.019, 0.018];

  List<FileSearchResult> search(String query, {FileSearchFilter? filter}) {
    if (_segments.isEmpty) return [];

    // _dedupCache persists across searches — only cleared on rebuild.

    final parsed = parseQuery(query);
    if (!parsed.isValid) return [];

    // Prepare priority rules once per search
    _preparePriorityRules();

    final allResults = <FileSearchResult>[];
    int totalCandidates = 0, totalDecoded = 0;

    for (final seg in _segments) {
      TrigramSearchResult nameResult;
      if (parsed.hasTextTrigrams) {
        nameResult = searchTrigrams(seg.raf, seg.nameIndex, parsed.textTrigrams);
      } else { nameResult = TrigramSearchResult({}, 0); }

      TrigramSearchResult pinyinResult;
      final pinyinTrigrams = parsed.hasPinyinTrigrams ? parsed.pinyinTrigrams : parsed.textTrigrams;
      if (pinyinTrigrams.isNotEmpty &&
          (parsed.pinyinText != parsed.normalizedText || parsed.hasTextTrigrams)) {
        pinyinResult = searchTrigrams(seg.raf, seg.pinyinIndex, pinyinTrigrams);
      } else { pinyinResult = TrigramSearchResult({}, 0); }

      final allIds = <int>{};
      allIds.addAll(nameResult.matchCounts.keys);
      allIds.addAll(pinyinResult.matchCounts.keys);
      final maxNameTri = nameResult.queryTrigramCount;
      final maxPinyinTri = pinyinResult.queryTrigramCount;

      final preScores = <_PreScore>[];
      for (final eid in allIds) {
        final nm = nameResult.matchCounts[eid] ?? 0;
        final pm = pinyinResult.matchCounts[eid] ?? 0;
        if (nm > 0 || pm > 0) preScores.add(_PreScore(eid, nm, pm));
      }
      preScores.sort(); totalCandidates += preScores.length;

      final topK = preScores.take(_topKPhaseA).toList(); totalDecoded += topK.length;
      for (final ps in topK) {
        final entry = seg.decodeEntry(ps.entryId);
        if (entry.name.isEmpty && entry.ext.isEmpty) continue;
        if (parsed.extFilters.isNotEmpty) {
          bool ok = false;
          for (final f in parsed.extFilters) { if (entry.ext == f) { ok = true; break; } }
          if (!ok) continue;
        }
        if (parsed.pathFilters.isNotEmpty) {
          bool ok = false; final lp = entry.path.toLowerCase();
          for (final f in parsed.pathFilters) { if (lp.contains(f.toLowerCase())) { ok = true; break; } }
          if (!ok) continue;
        }
        // Keyword filter (preset)
        if (filter != null && !_matchesFilter(entry, seg.rootPath, filter)) continue;

        // Priority rule matching — evaluate ALL rules.
        // Exclude beats everything; prefer and uncommon can both apply.
        final fp = normalizePath(entry.fullPath(seg.rootPath));
        bool excluded = false;
        bool gotPrefer = false;
        bool gotUncommon = false;
        for (int ri = 0; ri < _activePriorityRules.length; ri++) {
          final rule = _activePriorityRules[ri];
          if (rule.hasPath) {
            if (!fp.toLowerCase().startsWith(rule.pathLower)) continue;
          }
          if (rule.hasRegex) {
            final re = _priorityRegExCache[ri];
            if (re == null || !(re.hasMatch(entry.name) || re.hasMatch(entry.path))) continue;
          }
          // Rule matched — apply effect
          switch (rule.level) {
            case PriorityLevel.exclude:
              excluded = true;
              break;
            case PriorityLevel.prefer:
              gotPrefer = true;
              break;
            case PriorityLevel.uncommon:
              gotUncommon = true;
              break;
          }
        }
        if (excluded) continue;
        final prBonus = gotPrefer ? 0.50 : 0.0;
        final prMultiplier = gotUncommon ? 0.3 : 1.0;

        final nm = (maxNameTri > 0) ? ps.nameMatches / maxNameTri : 0.0;
        final pm = (maxPinyinTri > 0) ? ps.pinyinMatches / maxPinyinTri : 0.0;
        // Depth: count /-separated segments in relative path (strip trailing /)
        final depth = entry.path.isEmpty
            ? 0
            : entry.path.replaceAll(RegExp(r'/+$'), '').split('/').length;
        final depthScore = depth < _depthScoreTable.length
            ? _depthScoreTable[depth]
            : _depthScoreTable.last;
        final recentBoost = _recentOpenSet.any((rp) => pathsMatch(rp, fp)) ? 1.0 : 0.0;

        var score = pm * 0.35 + nm * 0.30 + depthScore + recentBoost * 0.20;
        score = score * prMultiplier + prBonus;

        allResults.add(FileSearchResult(name: entry.name, ext: entry.ext, path: entry.path,
            rootPath: seg.rootPath, isDir: entry.isDir, score: score,
            segmentPriority: seg.priority));
      }
    }

    // ── Prefix filtering (S|/D|) + dedup by resolved fullPath (symlink-aware) ─
    final filtered = <String, FileSearchResult>{};
    for (final r in allResults) {
      final fp = normalizePath(r.fullPath);
      final rp = normalizePath(r.rootPath);
      // D| prefix: filter entire subtree (all priorities)
      if (_matchAnyPrefixSubtree(fp, rp, _deletedPrefixes[rp])) continue;
      // S| prefix: only filter DIRECT children (priority=0 only), keep deep descendants
      if (r.segmentPriority == 0 && _matchSprefixDirectChild(fp, rp, _supersededPrefixes[rp])) continue;
      // Dedup: highest priority wins for same canonical path (resolves symlinks)
      final dedupKey = _resolveForDedup(fp);
      final ex = filtered[dedupKey];
      if (ex == null || r.segmentPriority > ex.segmentPriority) {
        filtered[dedupKey] = r;
      }
    }

    var finalResults = filtered.values.toList()..sort((a, b) => b.score.compareTo(a.score));

    // ── Fill to 20: if filtered < 20, fetch more from beyond TopK ─
    if (finalResults.length < 20 && totalCandidates > _topKPhaseA) {
      int extraNeeded = 20 - finalResults.length;
      final seen = finalResults.map((r) => _resolveForDedup(r.fullPath)).toSet();
      allResults.sort((a, b) => b.score.compareTo(a.score));
      for (final r in allResults) {
        if (extraNeeded <= 0) break;
        final dedupKey = _resolveForDedup(r.fullPath);
        if (!seen.contains(dedupKey)) {
          finalResults.add(r);
          seen.add(dedupKey);
          extraNeeded--;
        }
      }
    }

    final top20 = finalResults.take(20).toList();
    logger.debug('search("$query") → ${totalCandidates} total → decoded $totalDecoded → '
        'filtered ${filtered.length} → top ${top20.length}');
    return top20;
  }

  bool _matchesFilter(FileIndexEntry entry, String rootPath, FileSearchFilter filter) {
    // folder filter: directories only
    if (filter.keyword == 'folder' && !entry.isDir) return false;
    // extension list
    if (filter.extensions.isNotEmpty) {
      final lext = entry.ext.toLowerCase();
      if (!filter.extensions.any((e) => lext == e)) return false;
    }
    // path prefix
    if (filter.path != null && filter.path!.isNotEmpty) {
      final fp = normalizePath(entry.fullPath(rootPath));
      final fpLower = fp.toLowerCase();
      var filterPathLower = filter.path!.toLowerCase().replaceAll('\\', '/');
      if (!filterPathLower.endsWith('/')) filterPathLower += '/';
      if (!fpLower.startsWith(filterPathLower)) return false;
    }
    // regex
    if (filter.regex != null && filter.regex!.isNotEmpty) {
      try {
        if (!RegExp(filter.regex!, caseSensitive: false).hasMatch(entry.name)) return false;
      } catch (_) {}
    }
    return true;
  }

  /// D| prefix: filter entire subtree (all depths), across all priorities.
  bool _matchAnyPrefixSubtree(String fullPath, String rootPath, Set<String>? prefixes) {
    if (prefixes == null || prefixes.isEmpty) return false;
    final rp = normalizePath(rootPath);
    if (!fullPath.startsWith(rp)) return false;
    final rel = fullPath.length > rp.length + 1
        ? fullPath.substring(rp.length + 1)
        : '';
    for (final p in prefixes) {
      if (rel.startsWith(p)) return true;
    }
    return false;
  }

  /// S| prefix: only filter DIRECT children of dir/ (not deep descendants),
  /// and only for base (priority=0). Incremental entries are never filtered.
  bool _matchSprefixDirectChild(String fullPath, String rootPath, Set<String>? prefixes) {
    if (prefixes == null || prefixes.isEmpty) return false;
    final rp = normalizePath(rootPath);
    if (!fullPath.startsWith(rp)) return false;
    final rel = fullPath.length > rp.length + 1
        ? fullPath.substring(rp.length + 1)
        : '';
    for (final p in prefixes) {
      if (!rel.startsWith(p)) continue;
      final rest = rel.substring(p.length);
      if (!rest.contains('/')) return true;
    }
    return false;
  }

  // ── Recent open ──────────────────────────────────────────────────────────

  Future<void> markOpened(String filePath) async {
    final np = normalizePath(filePath);
    _recentOpenSet.removeWhere((rp) => pathsMatch(rp, np));
    _recentOpenSet.add(np);
    if (_recentOpenSet.length > 256) {
      _recentOpenSet = _recentOpenSet.skip(_recentOpenSet.length - 256).toSet();
    }
    await _settings.set(_kRecentOpenSet, _recentOpenSet.toList());
  }

  void addIndexPath(String rootPath) {
    rootPath = normalizePath(rootPath);
    if (_config.indexPaths.any((p) => pathsMatch(p.rootPath, rootPath))) return;
    _config = SearchConfig(
      indexPaths: [..._config.indexPaths, IndexPathConfig(rootPath: rootPath)],
    );
    _saveConfig();
  }

  Future<void> removeIndexPath(String rootPath) async {
    rootPath = normalizePath(rootPath);
    _config = SearchConfig(
      indexPaths: _config.indexPaths.where((p) => !pathsMatch(p.rootPath, rootPath)).toList(),
    );
    _saveConfig();
    _usnState.remove(rootPath);
    _perPathIntervals.remove(rootPath);
    _supersededPrefixes.remove(rootPath);
    _deletedPrefixes.remove(rootPath);
    _removeSegment(rootPath);
    await _store.deleteSegment(rootPath);
  }

  void _saveConfig() {
    _settings.set(_kIndexPaths, _config.indexPaths.map((p) => p.toJson()).toList());
  }

  void _ensureConfigPath(String rootPath) {
    if (_config.indexPaths.any((p) => pathsMatch(p.rootPath, rootPath))) return;
    _config = SearchConfig(
      indexPaths: [..._config.indexPaths, IndexPathConfig(rootPath: rootPath)],
    );
    _saveConfig();
  }

  Future<void> dispose() async {
    stopAutoUpdate();
    // Stop the indexer Windows Service so it doesn't linger after exit.
    try { await _maybeStopService(); } catch (_) {}
    for (final seg in _segments) { seg.disposeAll(); }
    _segments.clear(); _initialized = false;
  }

  void _removeSegmentsForPath(String rootPath) {
    _dedupCache.clear();
    _segments.removeWhere((seg) {
      if (pathsMatch(seg.rootPath, rootPath)) { seg.disposeAll(); return true; }
      return false;
    });
  }

  int _totalFileCount(String rootPath) {
    return _segments.where((s) => pathsMatch(s.rootPath, rootPath))
        .fold(0, (sum, s) => sum + s.fileCount);
  }

  void _removeSegment(String rootPath) => _removeSegmentsForPath(rootPath);

  List<dynamic> _loadJsonList(String key) {
    final v = _settings.get(key); return v is List ? v : [];
  }
}
