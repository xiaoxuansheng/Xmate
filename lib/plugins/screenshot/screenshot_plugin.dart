library;

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:window_manager/window_manager.dart';
import '../../core/plugin/plugin_base.dart';
import '../../core/utils/logger.dart';
import '../../core/utils/filename_template.dart';
import '../../app.dart';
import '../../core/window/window_manager.dart';
import 'capture/capture_win32.dart';
import 'annotate/annotate_page.dart';
import 'models/screenshot_data.dart';
import 'pin/pin_window.dart';
import 'screenshot_settings.dart';

/// Callback when user changes screenshot hotkey in settings.
/// Returns true if accepted, false if rejected (e.g. conflict).
typedef ScreenshotHotkeyChanged = bool Function(int mods, int keyId, String label);

class ScreenshotPlugin extends XMatePlugin {
  final _capture = CaptureServiceWin32();
  PluginContext? _context;

  /// Up to 3 previously confirmed selection rects (most recent first).
  /// Pushed on each successful copy/save/pin; skipped on cancel.
  final List<Rect> _previousRegions = [];

  void _pushRegion(Rect? sel) {
    if (sel == null) return;
    // Dedupe: remove identical rect if already in list
    _previousRegions.removeWhere((r) =>
        (r.left - sel.left).abs() < 1 &&
        (r.top - sel.top).abs() < 1 &&
        (r.width - sel.width).abs() < 1 &&
        (r.height - sel.height).abs() < 1);
    _previousRegions.insert(0, sel);
    if (_previousRegions.length > 3) _previousRegions.removeLast();
  }

  /// Set by main.dart so the plugin can notify main when the screenshot
  /// hotkey changes.  Returns true if the new hotkey was accepted,
  /// false if it conflicted with another registered hotkey.
  ScreenshotHotkeyChanged? onScreenshotHotkeyChanged;

  /// Set by main.dart so the plugin can notify main when the screenshot
  /// hotkey capture session starts/ends in settings.
  void Function(String source, bool active)? onCaptureStateChanged;

  // ── Recording toolbar integration ──
  /// Called when user clicks videocam in annotate page → start window recording.
  Future<void> Function(Rect selRect, double captureDpr, Rect captureMonitorRect, Uint8List overlayPng)? onScreenshotDoneOpenRecording;
  /// Called when screenshot is cancelled → close toolbar if not recording.
  void Function()? onScreenshotCancelCloseRecording;

  // ── Recording settings delegates (injected by main.dart) ──
  String Function()? recSavePathFn;
  ValueChanged<String>? recOnSavePathChangedFn;
  String Function()? recFfmpegPathFn;
  ValueChanged<String>? recOnFfmpegPathChangedFn;
  String Function()? recEncoderFn;
  ValueChanged<String>? recOnEncoderChangedFn;
  int Function()? recFpsFn;
  ValueChanged<int>? recOnFpsChangedFn;
  int Function()? recCrfFn;
  ValueChanged<int>? recOnCrfChangedFn;
  List<String> Function()? recAudioDevicesFn;
  ValueChanged<List<String>>? recOnAudioDevicesChangedFn;
  int Function()? recAudioBitrateFn;
  ValueChanged<int>? recOnAudioBitrateChangedFn;
  bool Function()? recShowMouseFn;
  ValueChanged<bool>? recOnShowMouseChangedFn;
  String Function()? recFilenameTemplateFn;
  ValueChanged<String>? recOnFilenameTemplateChangedFn;
  String Function()? recHotkeyLabelFn;
  bool Function(int mods, int keyId, String label)? onRecHotkeyChangedFn;
  void Function(String, bool)? onRecCaptureStateChangedFn;

  @override String get id => 'screenshot';
  @override String get name => 'Screenshot & Record';
  @override String get description => 'Region screenshot with annotation';
  @override IconData get icon => Icons.crop;

  // Default hotkey: Alt+S
  static const _kDefaultMods = 1;    // Alt (bitmask: 1=Alt, 2=Ctrl, 4=Shift, 8=Win)
  static const _kDefaultKeyId = 0x16; // USB HID usage for key S (NOT ASCII 83)

  @override Map<String, HotKeyDef> get defaultHotKeys => {
    'activate': HotKeyDef(keyCode: _kDefaultKeyId, modifiers: [1]),
  };

  @override
  List<CommandItem> get commands => [
    CommandItem(id: 'screenshot.activate', text: 'Screenshot',
      aliases: ['screenshot', 'capture', 'snip', '截图', '截屏'],
      description: 'Region screenshot', icon: Icons.crop, onExecute: activate),
  ];

  // ─── Settings ───

  String get savePath =>
      _context?.getSetting('savePath') as String? ?? '';

  String get format =>
      _context?.getSetting('format') as String? ?? 'png';

  String get filenameTemplate =>
      _context?.getSetting('filenameTemplate') as String? ?? kDefaultScreenshotTemplate;

  void setFilenameTemplate(String v) => _context?.setSetting('filenameTemplate', v);

  int get hotkeyMods =>
      _context?.getSetting('hotkeyMods') as int? ?? _kDefaultMods;

  int get hotkeyKeyId =>
      _context?.getSetting('hotkeyKeyId') as int? ?? _kDefaultKeyId;

  String get hotkeyLabel {
    final mods = hotkeyMods;
    final keyId = hotkeyKeyId;
    final parts = <String>[];
    if (mods & 1 != 0) parts.add('Alt');
    if (mods & 2 != 0) parts.add('Ctrl');
    if (mods & 4 != 0) parts.add('Shift');
    if (mods & 8 != 0) parts.add('Win');
    final k = LogicalKeyboardKey.findKeyByKeyId(keyId);
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
    return parts.isEmpty ? 'Not set' : parts.join('+');
  }

  bool _onHotkeyChanged(int mods, int keyId, String label) {
    // Save to settings first
    _context?.setSetting('hotkeyMods', mods);
    _context?.setSetting('hotkeyKeyId', keyId);
    // Let main.dart validate and re-register
    return onScreenshotHotkeyChanged?.call(mods, keyId, label) ?? true;
  }

  @override
  Widget? get settingsPage {
    return ScreenshotSettings(
      savePath: savePath,
      format: format,
      hotkeyLabel: hotkeyLabel,
      onSavePathChanged: (v) => _context?.setSetting('savePath', v),
      onFormatChanged: (v) => _context?.setSetting('format', v),
      onHotkeyChanged: _onHotkeyChanged,
      onCaptureStateChanged: onCaptureStateChanged,
      // Screenshot filename template
      ssFilenameTemplate: filenameTemplate,
      onSsFilenameTemplateChanged: (v) => setFilenameTemplate(v),
      // Recording
      recSavePath: recSavePathFn?.call() ?? '',
      onRecSavePathChanged: recOnSavePathChangedFn ?? (v) {},
      recFfmpegPath: recFfmpegPathFn?.call() ?? '',
      onRecFfmpegPathChanged: recOnFfmpegPathChangedFn ?? (v) {},
      recEncoder: recEncoderFn?.call() ?? 'libx264',
      recFps: recFpsFn?.call() ?? 30,
      recCrf: recCrfFn?.call() ?? 23,
      recAudioDevices: recAudioDevicesFn?.call() ?? const [],
      onRecAudioDevicesChanged: recOnAudioDevicesChangedFn ?? (v) {},
      onRecEncoderChanged: recOnEncoderChangedFn ?? (v) {},
      onRecFpsChanged: recOnFpsChangedFn ?? (v) {},
      onRecCrfChanged: recOnCrfChangedFn ?? (v) {},
      recAudioBitrate: recAudioBitrateFn?.call() ?? 128,
      onRecAudioBitrateChanged: recOnAudioBitrateChangedFn ?? (v) {},
      recShowMouse: recShowMouseFn?.call() ?? true,
      onRecShowMouseChanged: recOnShowMouseChangedFn ?? (v) {},
      recFilenameTemplate: recFilenameTemplateFn?.call() ?? '',
      onRecFilenameTemplateChanged: recOnFilenameTemplateChangedFn ?? (v) {},
      recHotkeyLabel: recHotkeyLabelFn?.call() ?? 'Not set',
      onRecHotkeyChanged: onRecHotkeyChangedFn,
      onRecCaptureStateChanged: onRecCaptureStateChangedFn,
    );
  }

  // ─── Lifecycle ───

  @override Future<void> onInit(PluginContext context) async {
    _context = context;
  }

  @override Future<void> onDispose() async {
    _context = null;
  }

  // ─── Activation ───

  /// Entry from command palette / tray / submenu.
  /// Keeps a 100ms delay after hide() so the palette window isn't captured.
  void activate() => _start(savePath);

  /// Entry from global hotkey (Alt+S).
  /// No hide-delay needed — the palette isn't visible when hotkey fires.
  void activateFromHotkey() => _start(savePath, skipHideDelay: true);

  Future<void> _start(String customSavePath, {bool skipHideDelay = false}) async {
    // Invalidate any in-flight palette refitWindow callbacks so they
    // don't shrink the fullscreen window after we enter screenshot mode.
    appKey.currentState?.invalidateWindowOps();
    try {
      await windowManager.hide();
      if (!skipHideDelay) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      await WindowService().showFullscreen();
      final cap = await _capture.captureFullScreen();
      logger.info('Captured: ${cap.png.length} bytes, dpr=${cap.dpr}, '
          'monRect=(${cap.monX},${cap.monY} ${cap.monW}x${cap.monH})');

      appKey.currentState?.showOverlay(AnnotatePage(
        imageBytes: cap.png,
        format: format,
        onDone: (b, a, s) => _onAnnotateDone(b, a, s),
        savePathOverride: customSavePath.isNotEmpty ? customSavePath : null,
        previousRegions: List.from(_previousRegions),
        captureDpr: cap.dpr,
        captureMonitorRect: Rect.fromLTWH(
          cap.monX.toDouble(), cap.monY.toDouble(),
          cap.monW.toDouble(), cap.monH.toDouble()),
        filenameTemplate: filenameTemplate,
        onOpenRecording: onScreenshotDoneOpenRecording,
      ));

      await _waitFrame();
      await WindowService().forceChildRefresh();
    } catch (e) {
      logger.error('Screenshot failed', e);
      _cleanup();
    }
  }

  Future<void> _cleanup() async {
    appKey.currentState?.clearOverlay();
    await windowManager.hide();
  }

  /// Handle the annotate page's onDone callback.
  ///
  /// For [ScreenshotAction.pin]: create the native pin window first,
  /// and only close the annotate page on success.  If pin creation
  /// fails the annotate page stays open so the user can retry.
  ///
  /// For all other actions: close immediately (existing behaviour).
  Future<void> _onAnnotateDone(Uint8List bytes, ScreenshotAction? action, Rect? sel) async {
    if (action == ScreenshotAction.cancel) {
      onScreenshotCancelCloseRecording?.call();
      await _cleanup();
      return;
    }
    _pushRegion(sel);

    // Pin action may keep the annotate page open on failure.
    if (action == ScreenshotAction.pin) {
      try {
        await PinService().createPin(bytes, sel);
      } catch (e) {
        logger.error('Pin window creation failed', e);
        return;
      }
    }

    await _cleanup();
  }

  /// Resolves after one Flutter frame has been rendered.
  static Future<void> _waitFrame() {
    final c = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) => c.complete());
    return c.future;
  }
}
