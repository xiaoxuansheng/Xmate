/// XMate 功能使用统计服务
///
/// 记录每个功能/命令的使用次数，持久化到独立 JSON 文件。
/// 线程安全（Dart 单线程），零外部依赖。
library;

import 'dart:convert';
import 'dart:io';

import '../utils/logger.dart';

class UsageStatsService {
  static final UsageStatsService _instance = UsageStatsService._();
  factory UsageStatsService() => _instance;
  UsageStatsService._();

  final Map<String, int> _counts = {};
  String? _filePath;
  bool _dirty = false;
  bool _initialized = false;

  /// 初始化：加载已有的统计数据文件。
  Future<void> init() async {
    if (_initialized) return;
    final appData = Platform.environment['APPDATA'];
    if (appData == null) return;
    final dir = Directory('$appData\\XMate');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _filePath = '${dir.path}\\stats.json';
    await _load();
    _initialized = true;
    logger.info('UsageStatsService initialized: $_filePath');
  }

  Future<void> _load() async {
    if (_filePath == null) return;
    final file = File(_filePath!);
    if (await file.exists()) {
      try {
        final content = await file.readAsString();
        final decoded = json.decode(content);
        if (decoded is Map<String, dynamic>) {
          for (final entry in decoded.entries) {
            final v = entry.value;
            if (v is int) {
              _counts[entry.key] = v;
            } else if (v is num) {
              _counts[entry.key] = v.toInt();
            }
          }
        }
        logger.info('Stats loaded: ${_counts.length} entries');
      } catch (e) {
        logger.warn('Stats file parse failed: $e');
        _counts.clear();
      }
    }
  }

  Future<void> _save() async {
    if (!_dirty || _filePath == null) return;
    final file = File(_filePath!);
    try {
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(_counts),
      );
      _dirty = false;
    } catch (e) {
      logger.error('Stats save failed', e);
    }
  }

  /// 记录一次功能使用。每 10 次写入磁盘一次以减少 I/O。
  void record(String featureId) {
    _counts[featureId] = (_counts[featureId] ?? 0) + 1;
    _dirty = true;
    // Batch saves: write every 10 increments (or every increment for
    // low-frequency features with count <= 10).
    final c = _counts[featureId]!;
    if (c % 10 == 0 || c <= 3) {
      _save();
    }
  }

  /// 获取单个功能使用次数。
  int getCount(String featureId) => _counts[featureId] ?? 0;

  /// 获取全部统计数据（按次数降序排列）。
  Map<String, int> getAll() {
    final sorted = Map<String, int>.fromEntries(
      _counts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value)),
    );
    return sorted;
  }

  /// 获取总使用次数。
  int get totalCount => _counts.values.fold(0, (a, b) => a + b);

  /// 重置所有统计数据。
  Future<void> resetAll() async {
    _counts.clear();
    _dirty = true;
    await _save();
  }

  /// 强制立即写入磁盘。
  Future<void> flush() async {
    if (_dirty) {
      _dirty = true; // ensure _save won't skip
      await _save();
    }
  }
}
