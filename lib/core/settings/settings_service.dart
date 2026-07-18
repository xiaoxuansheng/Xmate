/// XMate 设置服务
///
/// 基于 JSON 文件的持久化设置存储。
/// 全局设置与插件设置通过 key 前缀隔离。
library;
import 'dart:convert';
import 'dart:io';

import '../utils/logger.dart';
import 'package:path_provider/path_provider.dart';

class SettingsService {
  static final SettingsService _instance = SettingsService._();
  factory SettingsService() => _instance;
  SettingsService._();

  Map<String, dynamic> _data = {};
  String? _filePath;
  bool _dirty = false;

  /// 初始化设置文件
  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    final settingsDir = Directory('${dir.path}/xmate');
    if (!await settingsDir.exists()) {
      await settingsDir.create(recursive: true);
    }
    _filePath = '${settingsDir.path}/settings.json';
    await _load();
  }

  Future<void> _load() async {
    if (_filePath == null) return;
    final file = File(_filePath!);
    if (await file.exists()) {
      try {
        final content = await file.readAsString();
        final decoded = json.decode(content);
        _data = (decoded is Map<String, dynamic>) ? decoded : <String, dynamic>{};
        logger.info('设置加载成功: $_filePath');
      } catch (e) {
        logger.warn('设置文件解析失败，使用默认设置: $e');
        _data = {};
      }
    } else {
      _data = {};
    }
  }

  Future<void> _save() async {
    if (!_dirty) return;
    final file = File(_filePath!);
    try {
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(_data),
      );
      _dirty = false;
    } catch (e) {
      logger.error('设置保存失败', e);
    }
  }

  /// 获取设置值
  dynamic get(String key) {
    return _data[key];
  }

  /// 设置值并持久化
  Future<void> set(String key, dynamic value) async {
    _data[key] = value;
    _dirty = true;
    await _save();
  }

  /// 从磁盘重新加载设置（用于跨进程同步）
  Future<void> reload() async => await _load();

  /// 获取带默认值的设置
  T getWithDefault<T>(String key, T defaultValue) {
    final value = _data[key];
    return value != null ? value as T : defaultValue;
  }

  /// 删除设置项
  Future<void> remove(String key) async {
    _data.remove(key);
    _dirty = true;
    await _save();
  }

  /// 获取插件的所有设置
  Map<String, dynamic> getPluginSettings(String pluginId) {
    final prefix = '$pluginId.';
    final result = <String, dynamic>{};
    for (final entry in _data.entries) {
      if (entry.key.startsWith(prefix)) {
        result[entry.key.substring(prefix.length)] = entry.value;
      }
    }
    return result;
  }
}
