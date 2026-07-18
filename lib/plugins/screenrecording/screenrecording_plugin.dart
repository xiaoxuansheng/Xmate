/// XMate screen recording plugin.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import '../../core/plugin/plugin_base.dart';
import '../../core/utils/filename_template.dart';
import '../../app.dart';
import '../screenshot/capture/capture_win32.dart';
import 'recording_engine.dart';
import 'recording_state.dart';

String _usbHidKeyName(int keyId) {
  if (keyId >= 0x04 && keyId <= 0x1D) return String.fromCharCode(0x41 + (keyId - 0x04));
  if (keyId >= 0x1E && keyId <= 0x27) return String.fromCharCode(0x31 + (keyId - 0x1E));
  if (keyId >= 0x3A && keyId <= 0x45) return 'F${keyId - 0x39}';
  switch (keyId) {
    case 0x2C: return 'Space'; case 0x28: return 'Enter'; case 0x29: return 'Esc';
    case 0x2A: return 'Backspace'; case 0x2B: return 'Tab';
    case 0x4F: return 'Right'; case 0x50: return 'Left'; case 0x51: return 'Down'; case 0x52: return 'Up';
    default:  return 'Key($keyId)';
  }
}

String formatHotkeyLabel(int mods, int keyId) {
  final parts = <String>[];
  if (mods & 1 != 0) parts.add('Alt'); if (mods & 2 != 0) parts.add('Ctrl');
  if (mods & 4 != 0) parts.add('Shift'); if (mods & 8 != 0) parts.add('Win');
  final k = LogicalKeyboardKey.findKeyByKeyId(keyId);
  String keyName;
  if (k != null) {
    final n = k.keyLabel;
    if (n.length == 1 && n.codeUnitAt(0) >= 0x41 && n.codeUnitAt(0) <= 0x5A) { keyName = n; }
    else if (n == ' ') { keyName = 'Space'; } else { keyName = n; }
  } else { keyName = _usbHidKeyName(keyId); }
  parts.add(keyName);
  return parts.isEmpty ? 'Not set' : parts.join('+');
}

class ScreenRecordingPlugin extends XMatePlugin {
  final _capture = CaptureServiceWin32();

  RecordingEngine? _engine;
  PluginContext? _context;

  @override String get id => 'screenrecording';
  @override String get name => 'Screen Recording';
  @override String get description => 'Record full screen to MP4 (FFmpeg)';
  @override IconData get icon => Icons.videocam;

  static const _kDMods = 1, _kDKeyId = 0x15; // Alt+R

  @override Map<String, HotKeyDef> get defaultHotKeys => {
    'activate': HotKeyDef(keyCode: _kDKeyId, modifiers: [_kDMods]),
  };

  @override List<CommandItem> get commands => [
    CommandItem(id: 'screenrecording.activate', text: 'Screen Recording',
        aliases: ['screenrecording', 'record', '录屏', '录制'],
        description: 'Open recording toolbar', icon: Icons.videocam, onExecute: activate),
  ];

  void setRecSavePath(String v) => _context?.setSetting('savePath', v);
  void setRecHotkeyMods(int v) => _context?.setSetting('hotkeyMods', v);
  void setRecHotkeyKeyId(int v) => _context?.setSetting('hotkeyKeyId', v);
  void setRecFfmpegPath(String v) => _context?.setSetting('ffmpegPath', v);
  void setRecEncoder(String v) => _context?.setSetting('encoder', v);
  void setRecFps(int v) => _context?.setSetting('fps', v);
  void setRecCrf(int v) => _context?.setSetting('crf', v);
  void setRecAudioDevices(List<String> v) => _context?.setSetting('audioDevices', v);
  void setRecAudioBitrate(int v) => _context?.setSetting('audioBitrate', v);
  void setRecShowMouse(bool v) => _context?.setSetting('showMouse', v);
  void setRecFilenameTemplate(String v) => _context?.setSetting('filenameTemplate', v);

  String get savePath => _context?.getSetting('savePath') as String? ?? '';
  int get hotkeyMods => _context?.getSetting('hotkeyMods') as int? ?? _kDMods;
  int get hotkeyKeyId => _context?.getSetting('hotkeyKeyId') as int? ?? _kDKeyId;
  String get ffmpegPath => _context?.getSetting('ffmpegPath') as String? ?? '';
  String get encoder => _context?.getSetting('encoder') as String? ?? 'libx264';
  int get fps => _context?.getSetting('fps') as int? ?? 30;
  int get crf => _context?.getSetting('crf') as int? ?? 23;
  List<String> get audioDevices {
    final raw = _context?.getSetting('audioDevices');
    if (raw is List) return raw.map((e) => e.toString()).toList();
    return const [];
  }
  int get audioBitrate => _context?.getSetting('audioBitrate') as int? ?? 128;
  bool get showMouse => (_context?.getSetting('showMouse') as bool?) ?? true;
  String get filenameTemplate => _context?.getSetting('filenameTemplate') as String? ?? kDefaultRecordingTemplate;
  String get hotkeyLabel => formatHotkeyLabel(hotkeyMods, hotkeyKeyId);

  bool isRecording = false;
  bool Function(int mods, int keyId, String label)? onHotkeyChanged;
  void Function(String source, bool active)? onCaptureStateChanged;

  @override Widget? get settingsPage => null;

  @override Future<void> onInit(PluginContext context) async { _context = context; }

  @override Future<void> onDispose() async {
    await _engine?.dispose();
    _context = null;
  }

  // ── Public API ──

  /// Overlay channel — managed by the recording plugin so it stays alive
  /// for the full recording lifecycle.
  static const _overlayChannel = MethodChannel('com.xmate/overlay');
  int? _overlayHandle;

  void activate() => _openToolbar();

  /// Alt+R hotkey handler — simple toggle.
  ///  - Recording → send stop (toolbar stays open, shows SAVED).
  ///  - Anything else → close old window + spawn fresh with recording started.
  Future<void> activateFromHotkey() async {
    if (isRecording) {
      stopRecording();
      return;
    }
    await _closeSrWindows();
    _startFullscreen(autoStart: true);
  }

  void toggleRecording() => activateFromHotkey();
  void stopRecording() { _engine?.ipc.stopRecording(); }

  /// Window recording entry point — called from annotate page's videocam button.
  ///
  /// [selRect] is the selection rect in widget-logical pixels (monitor-relative).
  /// [dpr] is the capture monitor's device pixel ratio.
  /// [monRect] is the monitor rect in screen-physical pixels.
  /// [overlayPng] is the pre-rendered annotation overlay with transparent background.
  Future<void> startWindowRecording(Rect selRect, double dpr, Rect monRect,
      Uint8List overlayPng) async {
    await _closeSrWindows();

    // Screen-physical coords (C++ overlay takes these directly — no DPI conversion).
    final physX = (monRect.left + selRect.left * dpr).round();
    final physY = (monRect.top  + selRect.top  * dpr).round();
    final physW = (selRect.width  * dpr).round();
    final physH = (selRect.height * dpr).round();

    // yuv420p requires even dimensions.  Round odd widths/heights down
    // by 1 px so FFmpeg doesn't reject the encode parameters.
    int evenDim(int v) => v < 2 ? 2 : (v & 1) == 1 ? v - 1 : v;
    final recW = evenDim(physW);
    final recH = evenDim(physH);
    if (recW != physW || recH != physH) {}

    // Create overlay.  PNG is already rendered at physical size (× dpr),
    // so window size = PNG dimensions = physical pixels.
    try {
      final handle = await _overlayChannel.invokeMethod<int>('createOverlay', {
        'png': overlayPng,
        'x': physX, 'y': physY,
        'w': physW, 'h': physH,
      });
      if (handle != null && handle != 0) {
        _overlayHandle = handle;
      } else {}
    } catch (_) {}

    // ── 3. Now close the screenshot window ──
    appKey.currentState?.clearOverlay();
    await windowManager.hide();

    // ── 4. Spawn recording subprocess with region mode + autoStart ──
    final outputPath = _buildOutputPath();
    if (outputPath == null) return;

    _engine = RecordingEngine(srData: SrData(
      offsetX: physX, offsetY: physY, width: recW, height: recH,
      outputPath: outputPath, ffmpegPath: ffmpegPath,
      mode: RecordingMode.region, encoder: encoder, framerate: fps, crf: crf,
      audioDeviceNames: audioDevices,
      audioBitrate: audioBitrate, showMouse: showMouse,
      autoStart: false,
    ), onStatusChanged: (s) {
      isRecording = (s == RecordingStatus.recording);
    }, onCloseRequested: () {
      _destroyOverlay();
    }, onDisconnected: () async {
      await _onEngineDisconnected();
    });
    await _engine!.spawn();
  }

  /// Destroy the annotation overlay window if it exists.
  Future<void> _destroyOverlay() async {
    if (_overlayHandle == null) return;
    final handle = _overlayHandle;
    _overlayHandle = null;
    try {
      await _overlayChannel.invokeMethod('destroyOverlay', {'handle': handle});
    } catch (_) {}
  }

  // ── Helpers ──

  /// Close any dangling subprocess windows and dispose the engine.
  /// Idempotent — safe to call even if nothing is running.
  Future<void> _closeSrWindows() async {
    await _destroyOverlay();
    // Dispose engine BEFORE spawning new one — avoids residual state.
    if (_engine != null) {
      try { await _engine!.dispose(); } catch (_) {}
      _engine = null;
      isRecording = false;
    }
    // Close stale subprocess windows.
    try {
      await const MethodChannel('com.xmate/screenrecording')
          .invokeMethod('closeSrWindows');
    } catch (_) {}
    // Clean up IPC files so the next spawn starts fresh.
    // Old subprocess may still be processing WM_CLOSE — we delete its
    // status/command files preemptively to avoid confusing the new instance.
    final appData = Platform.environment['APPDATA'] ??
        '${Platform.environment['USERPROFILE']}\\AppData\\Roaming';
    try { File('$appData\\XMate\\sr_status.json').deleteSync(); } catch (_) {}
    try { File('$appData\\XMate\\sr_command.json').deleteSync(); } catch (_) {}
  }

  /// Open the recording toolbar (command palette / tray).
  /// Always starts a fresh subprocess — mirrors QuickLook's pattern.
  Future<void> _openToolbar() async {
    await _closeSrWindows();
    await _startFullscreen(autoStart: false);
  }

  Future<void> closeToolbarIfNotRecording() async {
    if (isRecording) return;
    await _closeSrWindows();
  }

  Future<void> _onEngineDisconnected() async {
    await _engine?.dispose();
    _engine = null;
    isRecording = false;
  }

  // ── Internal ──

  Future<void> _startFullscreen({bool autoStart = true}) async {
    try {
      final cap = await _capture.captureFullScreen();
      final outputPath = _buildOutputPath();
      if (outputPath == null) return;
      _engine = RecordingEngine(srData: SrData(
        offsetX: cap.monX, offsetY: cap.monY, width: cap.monW, height: cap.monH,
        outputPath: outputPath, ffmpegPath: ffmpegPath,
        mode: RecordingMode.fullscreen, encoder: encoder, framerate: fps, crf: crf,
        audioDeviceNames: audioDevices,
        audioBitrate: audioBitrate, showMouse: showMouse,
        autoStart: autoStart,
      ), onStatusChanged: (s) {
        isRecording = (s == RecordingStatus.recording);
      }, onDisconnected: () => _onEngineDisconnected());
      await _engine!.spawn();
    } catch (_) {
      isRecording = false;
    }
  }

  String? _buildOutputPath() {
    final dir = savePath.isNotEmpty ? savePath : '${Platform.environment['USERPROFILE']}\\Videos';
    final now = DateTime.now();
    final name = formatFilename(filenameTemplate, now);
    return '$dir\\$name.mp4';
  }
}
