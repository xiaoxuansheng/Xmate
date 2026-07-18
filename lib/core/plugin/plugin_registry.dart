library;

import 'package:flutter/material.dart';
import 'plugin_base.dart';
import '../event/event_bus.dart';
import '../utils/logger.dart';
import '../settings/settings_service.dart';

class PluginRegistry {
  final Map<String, XMatePlugin> _plugins = {};
  final EventBus _eventBus;
  final SettingsService _settings;
  final List<(String, String, HotKeyDef, VoidCallback)> _pendingHotKeys = [];
  final List<CommandItem> _rawCommands = [];

  PluginRegistry({required this._eventBus, required this._settings});

  List<XMatePlugin> get plugins => _plugins.values.toList();
  List<XMatePlugin> get enabledPlugins =>
      _plugins.values.where((p) => p.enabled).toList();
  List<(String, String, HotKeyDef, VoidCallback)> get pendingHotKeys =>
      List.unmodifiable(_pendingHotKeys);

  /// Register a command that belongs to no plugin (core commands like Settings)
  void registerRawCommand(
    String id,
    String text, {
    IconData icon = Icons.extension,
    String description = '',
    List<String> aliases = const [],
    required VoidCallback onExecute,
  }) {
    // Avoid duplicates
    for (int i = 0; i < _rawCommands.length; i++) {
      if (_rawCommands[i].id == id) {
        _rawCommands[i] = CommandItem(
          id: id, text: text, aliases: aliases,
          description: description, icon: icon, onExecute: onExecute,
        );
        return;
      }
    }
    _rawCommands.add(CommandItem(
      id: id, text: text, aliases: aliases,
      description: description, icon: icon, onExecute: onExecute,
    ));
  }

  Future<void> register(XMatePlugin plugin) async {
    if (_plugins.containsKey(plugin.id)) {
      logger.warn('Plugin already registered: ${plugin.id}');
      return;
    }

    _plugins[plugin.id] = plugin;
    logger.info('Plugin registered: [${plugin.id}] ${plugin.name}');

    final context = PluginContext(
      registerHotKeyFn: (action, key, callback) {
        _pendingHotKeys.add((plugin.id, action, key, callback));
      },
      emitEventFn: (eventName, {data}) {
        _eventBus.emit('plugin:${plugin.id}:$eventName', data: data);
      },
      getSettingFn: (key) => _settings.get('${plugin.id}.$key'),
      setSettingFn: (key, value) => _settings.set('${plugin.id}.$key', value),
    );

    await plugin.onInit(context);

    // Auto-register default hotkeys from plugin
    for (final entry in plugin.defaultHotKeys.entries) {
      final action = entry.key;
      final hotKeyDef = entry.value;
      final cmdId = '${plugin.id}.$action';
      // Find matching command
      CommandItem? match;
      for (final c in plugin.commands) {
        if (c.id == cmdId) {
          match = c;
          break;
        }
      }
      final callback = match?.onExecute ?? (() {});
      context.registerHotKey(action, hotKeyDef, callback);
    }

    logger.info('Plugin [${plugin.id}] ready');
  }

  XMatePlugin? findById(String id) => _plugins[id];

  List<CommandItem> getAllCommands() {
    final result = <CommandItem>[];
    for (final p in enabledPlugins) {
      result.addAll(p.commands);
    }
    result.addAll(_rawCommands);
    return result;
  }

  /// Remove all raw commands whose id starts with [prefix].
  /// Used to refresh user-defined commands from settings.
  void unregisterCommandsByPrefix(String prefix) {
    _rawCommands.removeWhere((cmd) => cmd.id.startsWith(prefix));
  }

  CommandItem? findCommand(String commandId) {
    for (final cmd in _rawCommands) {
      if (cmd.id == commandId) return cmd;
    }
    for (final plugin in enabledPlugins) {
      for (final cmd in plugin.commands) {
        if (cmd.id == commandId) return cmd;
      }
    }
    return null;
  }

  Future<void> unregister(String id) async {
    final plugin = _plugins.remove(id);
    if (plugin != null) {
      await plugin.onDispose();
      logger.info('Plugin unregistered: [$id]');
    }
  }

  Future<void> disposeAll() async {
    for (final plugin in _plugins.values) {
      await plugin.onDispose();
    }
    _plugins.clear();
    _pendingHotKeys.clear();
  }
}
