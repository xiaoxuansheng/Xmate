/// Window state machine:
///   init:   C++ Show at 1x1 → Dart waitUntilReadyToShow → hide
///   palette: showFloating() → 540×420 centered near top
///   screenshot: showFullscreen() → native SetWindowPos to rcMonitor
///   settings:  showAsDialog() → 600×500 centered
///   close:  hide() (never pop routes)
library;

import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

class WindowService {
  static final WindowService _instance = WindowService._();
  factory WindowService() => _instance;
  WindowService._();

  static const _windowChannel = MethodChannel('com.xmate/window');

  Future<void> initMainWindow() async {
    await windowManager.ensureInitialized();
    // C++ showed window at 1x1 for engine init.
    // waitUntilReadyToShow fires after first Flutter frame.
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1, 1),
        skipTaskbar: true,
        backgroundColor: Colors.transparent,
      ),
      () async {
        // First frame rendered. Now hide — engine stays initialized.
        await windowManager.setAlwaysOnTop(true);
        await windowManager.hide();
      },
    );
  }

  /// Show as a centered floating window (command palette).
  /// Uses PlatformDispatcher.displays for reliable screen dimensions
  /// (unlike getBounds() which returns window size after first resize).
  Future<void> showFloating({double width = 540, double height = 420}) async {
    final display = ui.PlatformDispatcher.instance.displays.first;
    final screenW = display.size.width / display.devicePixelRatio;
    final screenH = display.size.height / display.devicePixelRatio;

    final x = ((screenW - width) / 2).roundToDouble();
    final y = (screenH / 3).roundToDouble();

    // Atomic native SetWindowPos — size + position in one call without showing.
    // Visibility is controlled below so Dart can measure while hidden.
    await setBounds(x: x, y: y, width: width, height: height);
    await windowManager.show();
    await windowManager.focus();
  }

  /// Show fullscreen (screenshot annotation).
  /// Uses native method channel (com.xmate/window) → SetWindowPos to
  /// rcMonitor — the only reliable way for WS_POPUP windows.
  Future<void> showFullscreen() async {
    await _windowChannel.invokeMethod('setFullScreen');
    await windowManager.setAlwaysOnTop(true);
    await windowManager.focus();
  }

  /// Show as a centered dialog window — for settings page
  Future<void> showAsDialog({double width = 600, double height = 500}) async {
    await windowManager.setSize(Size(width, height));
    await windowManager.center();
    await windowManager.show();
    await windowManager.focus();
  }

  /// Set window bounds (position + size) in one atomic native SetWindowPos call.
  /// Avoids the flicker of separate setSize + setPosition when window is visible.
  /// Does NOT show — window stays hidden if it was hidden. Use [showNoActivate]
  /// for the initial show-without-focus.
  Future<void> setBounds({
    required double x,
    required double y,
    required double width,
    required double height,
  }) async {
    await _windowChannel.invokeMethod('setBounds', {
      'x': x.round(),
      'y': y.round(),
      'width': width.round(),
      'height': height.round(),
    });
  }

  /// Position, size, and show the window WITHOUT activating it.
  /// Uses SetWindowPos(SWP_NOACTIVATE | SWP_SHOWWINDOW) — the foreground
  /// window (e.g. Explorer) keeps focus. Use this when the preview window
  /// should appear passively.
  Future<void> showNoActivate({
    required double x,
    required double y,
    required double width,
    required double height,
  }) async {
    await _windowChannel.invokeMethod('showNoActivate', {
      'x': x.round(),
      'y': y.round(),
      'width': width.round(),
      'height': height.round(),
    });
  }

  /// Force FlutterView child HWND to rebuild its GPU swapchain.
  /// Necessary after a dramatic window resize (e.g. palette → fullscreen)
  /// because the engine's rendering surface can stay at the old size.
  Future<void> forceChildRefresh() async {
    await _windowChannel.invokeMethod('forceChildRefresh');
  }

  /// Move the system cursor by [dx], [dy] physical pixels from its current
  /// position. Positive dx = right, positive dy = down.
  Future<void> moveCursor(int dx, int dy) async {
    await _windowChannel.invokeMethod('moveCursor', {'dx': dx, 'dy': dy});
  }

  /// Swap visible top-level windows between the first two monitors.
  /// Windows on monitor 0 move to monitor 1, and vice versa, with
  /// proportional position mapping and DPI-aware size scaling.
  /// Maximized windows are restored → moved → re-maximized.
  ///
  /// Returns a map with keys: moved (int), skipped (int), or error (String).
  Future<Map<String, dynamic>?> swapMonitors() async {
    final result = await _windowChannel.invokeMethod<String>('swapMonitors');
    if (result == null || result.isEmpty) return null;
    try {
      return Map<String, dynamic>.from(
          json.decode(result) as Map);
    } catch (_) {
      return {'error': result};
    }
  }

  /// Hide — no resize, just invisible
  Future<void> hideWindow() async => windowManager.hide();

  Future<void> dispose() async => windowManager.destroy();

  /// Cut a transparent rectangular hole in the XMate window.
  /// [x],[y],[w],[h] are logical pixels relative to the window's client area.
  /// The area becomes a true transparent hole — underlying windows are visible.
  static Future<void> setWindowHole(int x, int y, int w, int h) async {
    await _windowChannel.invokeMethod('setWindowHole', {
      'x': x, 'y': y, 'w': w, 'h': h,
    });
  }

  /// Remove any window hole — restore full window region.
  static Future<void> clearWindowHole() async {
    await _windowChannel.invokeMethod('clearWindowHole');
  }
}
