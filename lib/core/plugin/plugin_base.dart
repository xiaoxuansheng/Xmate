/// XMate 插件协议 —— 插件基类与相关数据模型
///
/// 所有业务功能以插件形式接入。
/// 插件实现 [XMatePlugin] 基类，通过 [PluginContext] 访问核心服务。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ===== 数据模型 =====

/// 命令面板中的一个命令项
class CommandItem {
  final String id;
  final String text;
  final List<String> aliases;
  final String description;
  final IconData icon;
  final VoidCallback onExecute;

  const CommandItem({
    required this.id,
    required this.text,
    this.aliases = const [],
    this.description = '',
    this.icon = Icons.extension,
    required this.onExecute,
  });

  /// 获取所有可用于匹配的关键词（命令文本 + 别名）
  List<String> get matchTerms => [text, ...aliases];
}

/// 快捷键定义
class HotKeyDef {
  final int keyCode;
  final List<int> modifiers; // 0=ctrl, 1=alt, 2=shift, 3=win

  const HotKeyDef({
    required this.keyCode,
    this.modifiers = const [],
  });

  /// 创建控制台可读的快捷键描述
  String get displayString {
    final parts = <String>[];
    if (modifiers.contains(3)) parts.add('Win');
    if (modifiers.contains(0)) parts.add('Ctrl');
    if (modifiers.contains(1)) parts.add('Alt');
    if (modifiers.contains(2)) parts.add('Shift');
    // keyCode is a USB HID usage ID (same as LogicalKeyboardKey.keyId).
    // Use findKeyByKeyId so the label is correct regardless of platform layout.
    final k = LogicalKeyboardKey.findKeyByKeyId(keyCode);
    if (k != null) {
      final n = k.keyLabel;
      if (n.length == 1 && n.codeUnitAt(0) >= 0x41 && n.codeUnitAt(0) <= 0x5A) {
        parts.add(n);
      } else if (n == ' ') {
        parts.add('Space');
      } else {
        parts.add(n);
      }
    }
    return parts.isEmpty ? 'Unset' : parts.join('+');
  }
}

// ===== 插件上下文 =====

/// 插件上下文 —— 插件通过它访问核心框架的服务
class PluginContext {
  final void Function(String action, HotKeyDef key, VoidCallback callback)
      registerHotKeyFn;
  final void Function(String eventName, {Map<String, dynamic>? data})
      emitEventFn;
  final dynamic Function(String key) getSettingFn;
  final Future<void> Function(String key, dynamic value) setSettingFn;

  PluginContext({
    required this.registerHotKeyFn,
    required this.emitEventFn,
    required this.getSettingFn,
    required this.setSettingFn,
  });

  void registerHotKey(String action, HotKeyDef key, VoidCallback callback) {
    registerHotKeyFn(action, key, callback);
  }

  void emitEvent(String eventName, {Map<String, dynamic>? data}) {
    emitEventFn(eventName, data: data);
  }

  dynamic getSetting(String key) {
    return getSettingFn(key);
  }

  Future<void> setSetting(String key, dynamic value) {
    return setSettingFn(key, value);
  }
}

// ===== 插件基类 =====

/// XMate 插件抽象基类
///
/// 每个插件必须实现此基类，提供元数据、命令列表、快捷键等。
abstract class XMatePlugin {
  /// 唯一标识（全小写，蛇形命名），如 "screenshot"
  String get id;

  /// 显示名称，如 "截图"
  String get name;

  /// 描述，如 "快速截图并进行标注"
  String get description;

  /// 插件图标
  IconData get icon;

  /// 命令列表 —— 用于命令面板匹配
  List<CommandItem> get commands;

  /// 默认快捷键映射
  /// key: 动作名（如 "activate"）, value: 快捷键定义
  Map<String, HotKeyDef> get defaultHotKeys;

  /// 是否启用
  bool get enabled => true;

  /// 插件设置页面（可为 null 表示无设置页）
  Widget? get settingsPage => null;

  /// 插件初始化（注册到核心时调用）
  Future<void> onInit(PluginContext context) async {}

  /// 插件销毁（应用退出时调用）
  Future<void> onDispose() async {}
}
