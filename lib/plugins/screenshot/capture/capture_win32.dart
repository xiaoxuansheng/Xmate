library;

import 'dart:convert';
import 'dart:developer' as dev;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:xmate/core/annotate/annotate_models.dart';
import 'capture_service.dart';

class CaptureServiceWin32 implements CaptureService {
  static const _channel = MethodChannel('com.xmate/screenshot');

  static const _debugSnap = false;

  @override
  Future<ScreenCapture> captureFullScreen() async {
    final result = await _channel.invokeMethod('captureFullScreen');
    if (result == null) throw Exception('Capture returned null');
    final map = Map<String, dynamic>.from(result as Map);
    final raw = map['png'];
    Uint8List png;
    if (raw is Uint8List) {
      png = raw;
    } else if (raw is List<int>) {
      png = Uint8List.fromList(raw);
    } else {
      throw Exception('captureFullScreen: png field missing or wrong type');
    }
    return ScreenCapture(
      png: png,
      dpr: (map['dpr'] as num).toDouble(),
      monX: (map['monX'] as num).toInt(),
      monY: (map['monY'] as num).toInt(),
      monW: (map['monW'] as num).toInt(),
      monH: (map['monH'] as num).toInt(),
    );
  }

  Future<bool> copyToClipboard(Uint8List pngData) async {
    final result = await _channel.invokeMethod<bool>('copyToClipboard', {
      'data': pngData,
    });
    return result ?? false;
  }

  /// Get the bounding rectangle of the top-level window currently under
  /// the cursor, converted to Flutter logical pixels.
  Future<Rect?> getWindowRectAtCursor({required bool outerOnly}) async {
    final result = await _channel.invokeMethod<String>(
      'getWindowRectAtCursor',
      {'outerOnly': outerOnly},
    );

    if (_debugSnap) {
      dev.log('[snap-cc] channel returned: outerOnly=$outerOnly raw="${result ?? "null"}"');
    }

    if (result == null || result.isEmpty || result == 'null') return null;

    try {
      final json = jsonDecode(result) as Map<String, dynamic>;
      final x = (json['x'] as num).toDouble();
      final y = (json['y'] as num).toDouble();
      final w = (json['w'] as num).toDouble();
      final h = (json['h'] as num).toDouble();

      // Use the first display's DPR as a reasonable default for hit-test
      // window rects.  Multi-monitor window enumeration returns screen-absolute
      // coords that span all monitors, so a single DPR is an approximation.
      // (The primary use-case — auto-snap during region selection — operates
      //  inside the captured monitor's logical coordinate space anyway.)
      final dpr = WidgetsBinding.instance.platformDispatcher
              .displays.first.devicePixelRatio;

      if (_debugSnap) {
        dev.log('[snap-cc] physical=(${x.toStringAsFixed(0)},${y.toStringAsFixed(0)} ${w.toStringAsFixed(0)}x${h.toStringAsFixed(0)}) '
            'dpr=${dpr.toStringAsFixed(2)} '
            'logical=(${(x/dpr).toStringAsFixed(0)},${(y/dpr).toStringAsFixed(0)} ${(w/dpr).toStringAsFixed(0)}x${(h/dpr).toStringAsFixed(0)})');
      }

      return Rect.fromLTWH(x / dpr, y / dpr, w / dpr, h / dpr);
    } catch (e) {
      if (_debugSnap) dev.log('[snap-cc] parse error: $e');
      return null;
    }
  }

  /// Capture a specific screen rectangle (screen-absolute physical pixels).
  /// Returns a [ScreenCapture] with PNG bytes and monitor metadata.
  Future<ScreenCapture> captureRect(int x, int y, int w, int h) async {
    final result = await _channel.invokeMethod('captureRect', {
      'x': x, 'y': y, 'w': w, 'h': h,
    });
    if (result == null) throw Exception('captureRect returned null');
    final map = Map<String, dynamic>.from(result as Map);
    final raw = map['png'];
    Uint8List png;
    if (raw is Uint8List) {
      png = raw;
    } else if (raw is List<int>) {
      png = Uint8List.fromList(raw);
    } else {
      throw Exception('captureRect: png field missing or wrong type');
    }
    return ScreenCapture(
      png: png,
      dpr: (map['dpr'] as num).toDouble(),
      monX: (map['monX'] as num).toInt(),
      monY: (map['monY'] as num).toInt(),
      monW: (map['monW'] as num).toInt(),
      monH: (map['monH'] as num).toInt(),
    );
  }

  /// Send a mouse wheel event via SendInput.
  /// [delta] is the wheel delta (typically +/-120 per notch).
  Future<void> sendMouseWheel(int delta) async {
    await _channel.invokeMethod('sendMouseWheel', {'delta': delta});
  }

  /// Post WM_MOUSEWHEEL directly to [targetHwnd] — no need to hide XMate.
  /// [delta] is the wheel delta (typically +/-120 per notch).
  Future<bool> postScrollMessage(int targetHwnd, int delta) async {
    try {
      await _channel.invokeMethod('postScrollMessage', {
        'hwnd': targetHwnd,
        'delta': delta,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Install WH_MOUSE_LL hook to detect scroll events over the hole region.
  /// [x,y,w,h] = client-relative PHYSICAL pixels (already DPI-scaled by caller).
  Future<bool> installScrollHook(int x, int y, int w, int h) async {
    final result = await _channel.invokeMethod<bool>('installScrollHook', {
      'x': x, 'y': y, 'w': w, 'h': h,
    });
    return result ?? false;
  }

  /// Uninstall the WH_MOUSE_LL hook and clear all global state.
  Future<void> uninstallScrollHook() async {
    await _channel.invokeMethod('uninstallScrollHook');
  }

  /// Identify the topmost visible window occupying a screen region
  /// (excluding XMate itself). Returns a map with hwnd, className, title
  /// or null if no suitable window found.
  /// Coordinates are screen-absolute physical pixels.
  Future<Map<String, dynamic>?> identifyWindowUnderRect(
      int x, int y, int w, int h) async {
    final result = await _channel.invokeMethod<String>(
      'identifyWindowUnderRect',
      {'x': x, 'y': y, 'w': w, 'h': h},
    );
    if (result == null || result.isEmpty || result == 'null') return null;
    try {
      return Map<String, dynamic>.from(
          jsonDecode(result) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Enumerate visible windows, excluding tool windows / cloaked / XMate itself.
  ///
  /// When [includeChildren] is true, child HWNDs are recursively enumerated
  /// down to icon level (depth-limited, de-duplicated, size-filtered).
  ///
  /// Each returned [WindowRectEntry] carries a [rank]:
  ///   - Foreground-window descendants get +1000 bonus
  ///   - Each level of child nesting adds +10
  ///   - Higher rank = more specific / more important
  ///
  /// Rects are in **screen-absolute physical pixels**.
  /// Caller must convert to logical / widget coordinates.
  Future<List<WindowRectEntry>> getWindowRects({
    required bool outerOnly,
    bool includeChildren = false,
  }) async {
    final result = await _channel.invokeMethod<String>(
      'getWindowRects', {
        'outerOnly': outerOnly,
        'includeChildren': includeChildren,
      },
    );

    if (result == null || result.isEmpty) return const [];

    try {
      final list = jsonDecode(result) as List<dynamic>;
      final entries = <WindowRectEntry>[];
      for (final item in list) {
        final m = item as Map<String, dynamic>;
        entries.add(WindowRectEntry(
          rect: Rect.fromLTWH(
            (m['x'] as num).toDouble(),
            (m['y'] as num).toDouble(),
            (m['w'] as num).toDouble(),
            (m['h'] as num).toDouble(),
          ),
          rank: (m['r'] as num?)?.toInt() ?? 0,
        ));
      }
      return entries;
    } catch (e) {
      dev.log('[getWindowRects] parse error: $e');
      return const [];
    }
  }
}
