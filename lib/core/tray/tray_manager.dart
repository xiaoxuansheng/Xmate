library;

import 'package:flutter/services.dart';
import '../utils/logger.dart';

typedef TrayService = _TrayImpl;

class _TrayImpl {
  static final _TrayImpl _instance = _TrayImpl._();
  factory _TrayImpl() => _instance;
  _TrayImpl._();

  static const _ch = MethodChannel('com.xmate/tray');

  VoidCallback? onOpen;
  VoidCallback? onScreenshot;
  VoidCallback? onSettings;
  Future<void> Function()? onExit;

  Future<void> init({
    required VoidCallback onOpenCommandPalette,
    required VoidCallback onScreenshot,
    required VoidCallback onSettings,
    required Future<void> Function() onExit,
  }) async {
    onOpen = onOpenCommandPalette;
    onScreenshot = onScreenshot;
    this.onSettings = onSettings;
    this.onExit = onExit;

    // Listen for tray commands from native
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'trayCmd') {
        final args = call.arguments as Map;
        final cmd = args['cmd'] as int;
        switch (cmd) {
          case 1: onOpen?.call();
          case 2: onScreenshot.call();
          case 3: this.onSettings?.call();
          case 4: await this.onExit?.call();
        }
      }
      return null;
    });

    // Tell native to create the tray icon
    await _ch.invokeMethod('initTray');
    logger.info('Tray ready');
  }

  Future<bool> isAutoStart() async {
    try {
      final result = await _ch.invokeMethod('isAutoStart');
      return result == true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> toggleAutoStart() async {
    try {
      final result = await _ch.invokeMethod('toggleAutoStart');
      return result == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> dispose() async {
    // Remove tray icon immediately (before Flutter engine shutdown)
    try { await _ch.invokeMethod('removeTray'); } catch (_) {}
    _ch.setMethodCallHandler(null);
    logger.info('Tray disposed');
  }
}
