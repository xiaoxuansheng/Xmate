/// XMate hotkey manager
library;

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import '../plugin/plugin_base.dart';
import '../utils/logger.dart';

class HotkeyManager {
  static final HotkeyManager _instance = HotkeyManager._();
  factory HotkeyManager() => _instance;
  HotkeyManager._();

  final Map<String, _RegisteredHotKey> _hotkeys = {};

  Future<void> init() async {
    await hotKeyManager.unregisterAll();
    logger.info('Hotkey manager ready');
  }

  Future<bool> register(
    String id,
    HotKeyDef def,
    VoidCallback callback,
  ) async {
    if (_hotkeys.containsKey(id)) {
      await unregister(id);
    }

    for (final entry in _hotkeys.entries) {
      if (entry.value.def.keyCode == def.keyCode &&
          _listEquals(entry.value.def.modifiers, def.modifiers)) {
        logger.warn('Hotkey conflict: "$id" vs "${entry.key}"');
        return false;
      }
    }

    // keyCode is USB HID usage code — find PhysicalKeyboardKey
    final physicalKey = PhysicalKeyboardKey.findKeyByCode(def.keyCode);
    if (physicalKey == null) {
      logger.error('Invalid key code (USB HID): ${def.keyCode}');
      return false;
    }

    final hotKey = HotKey(
      key: physicalKey,
      modifiers: _toModifiers(def.modifiers),
      scope: HotKeyScope.system,
    );

    try {
      await hotKeyManager.register(hotKey,
          keyDownHandler: (_) => callback());
      _hotkeys[id] = _RegisteredHotKey(
          def: def, hotKey: hotKey, callback: callback);
      logger.info('Hotkey: "$id" => ${def.displayString}');
      return true;
    } catch (e) {
      logger.error('Hotkey register failed: "$id"', e);
      return false;
    }
  }

  Future<void> unregister(String id) async {
    final entry = _hotkeys[id];
    if (entry == null) return;
    try {
      await hotKeyManager.unregister(entry.hotKey);
      _hotkeys.remove(id);
      logger.info('Hotkey removed: "$id"');
    } catch (e) {
      logger.error('Hotkey unregister failed: "$id"', e);
    }
  }

  Future<void> dispose() async {
    await hotKeyManager.unregisterAll();
    _hotkeys.clear();
    logger.info('All hotkeys cleared');
  }

  List<HotKeyModifier> _toModifiers(List<int> ms) {
    final r = <HotKeyModifier>[];
    for (final m in ms) {
      switch (m) {
        case 0: r.add(HotKeyModifier.control);
        case 1: r.add(HotKeyModifier.alt);
        case 2: r.add(HotKeyModifier.shift);
        case 3: r.add(HotKeyModifier.meta);
      }
    }
    return r;
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    final sa = a.toSet(), sb = b.toSet();
    return sa.length == sb.length && sa.containsAll(sb);
  }
}

class _RegisteredHotKey {
  final HotKeyDef def;
  final HotKey hotKey;
  final VoidCallback callback;
  _RegisteredHotKey({
    required this.def,
    required this.hotKey,
    required this.callback,
  });
}
