/// Minimal MaterialApp for the screen recording subprocess.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import '../../core/settings/settings_service.dart';
import '../../core/theme/theme_service.dart';
import '../../core/utils/filename_template.dart';
import 'recording_state.dart';
import 'recording_service.dart';
import 'recording_indicator.dart';
import 'recording_settings_panel.dart';
import 'ipc/ipc_server.dart';

class ScreenRecordingApp extends StatefulWidget {
  final SrData data;
  const ScreenRecordingApp({super.key, required this.data});

  @override State<ScreenRecordingApp> createState() =>
      _ScreenRecordingAppState();
}

class _ScreenRecordingAppState extends State<ScreenRecordingApp> {
  late final RecordingService _service;
  late final IpcServer _ipc;

  static const double _barW = 360;
  static const double _barH = 30;
  static const double _collapsedH = 1;  // effectively invisible
  static const double _settingsH = 200;
  static const double _fileBarH = 48;

  RecordingStatus _status = RecordingStatus.idle;
  bool _showSettings = false;
  bool _showFileBar = false;
  int _fileSize = 0;

  // Auto-hide
  bool _collapsed = false;
  Timer? _hideTimer;

  // Close guard: set true when onClose fires; blocks IPC commands
  // and local button presses during the main-process sync delay.
  bool _closing = false;

  // Current settings
  late String _encoder;
  late int _fps;
  late int _crf;
  late List<String> _audioDevices;
  late int _audioBitrate;
  bool _showMouse = true;
  bool _allMonitors = false;

  @override void initState() {
    super.initState();
    ThemeService().init();
    _encoder = widget.data.encoder;
    _fps = widget.data.framerate;
    _crf = widget.data.crf;
    // Audio devices MUST come from settings.  The CLI→C++→JSON chain
    // corrupts CJK text because Process.start args pass through the
    // Windows ANSI code page.  Settings are UTF-8 JSON — safe.
    final rawDevs = SettingsService().get('screenrecording.audioDevices');
    if (rawDevs is List) {
      _audioDevices = rawDevs.map((e) => e.toString()).toList();
    } else {
      _audioDevices = <String>[];
    }
    _audioBitrate = SettingsService().get('screenrecording.audioBitrate') as int? ?? 128;
    _showMouse = (SettingsService().get('screenrecording.showMouse') as bool?) ?? true;
    _allMonitors = (SettingsService().get('screenrecording.allMonitors') as bool?) ?? false;

    _service = RecordingService(
      onProgress: (_) { if (mounted) setState(() {}); },
      onStatusChanged: (s) {
        if (!mounted) return;
        setState(() {
          _status = s;
          if (s == RecordingStatus.stopped) {
            _fileSize = _service.fileSize;
            _showFileBar = true;
          }
          // Auto-expand on status change so user sees the result.
          _collapsed = false;
          _cancelHideTimer();
        });
        _updateWindowSize();
        _ipc.writeStatus();
      },
    );

    _ipc = IpcServer(onCommand: _onIpcCommand, service: _service);

    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  void _onIpcCommand(String command) {
    if (_closing) return;
    if (command == 'stop') _service.stop();
    if (command == 'start') _onRecord();
  }

  Future<void> _begin() async {
    final disp = WidgetsBinding.instance.platformDispatcher.displays;
    final screen = disp.isNotEmpty ? disp.first : null;
    double ssW = screen != null
        ? screen.size.width / screen.devicePixelRatio : 1920;

    // Always top-center regardless of recording mode.
    final double x = (ssW - _barW) / 2;
    const double y = 0;

    await _positionWindow(x, y, _barW, _barH);

    try {
      await const MethodChannel('com.xmate/window').invokeMethod('forceChildRefresh');
    } catch (_) {}

    // Always on top so toolbar floats above all windows.
    try { await windowManager.setAlwaysOnTop(true); } catch (_) {}

    // Start IPC.
    _ipc.startPolling();

    if (widget.data.autoStart) {
      // Alt+R → start recording immediately.
      final ok = await _service.start(widget.data);
      if (!ok) {
        _ipc.writeStatus();
        if (mounted) setState(() {});
        return;
      }
    } else {
      // Command palette / region → toolbar in IDLE. Write initial status.
      _ipc.writeStatus();
    }

    // Start auto-hide timer.
    _resetHideTimer();
  }

  Future<void> _positionWindow(double x, double y, double w, double h) async {
    try {
      await windowManager.setPosition(Offset(x, y));
      await windowManager.setSize(Size(w, h));
    } catch (_) {}
  }

  double _currentContentH() {
    double h = _barH;
    if (_showSettings) h += _settingsH;
    if (_showFileBar) h += _fileBarH;
    return h;
  }

  Future<void> _updateWindowSize() async {
    if (_collapsed) return; // don't resize while collapsed
    final totalH = _currentContentH();
    try {
      await windowManager.setSize(Size(_barW, totalH));
      await Future.delayed(const Duration(milliseconds: 30));
      try {
        await const MethodChannel('com.xmate/window').invokeMethod('forceChildRefresh');
      } catch (_) {}
    } catch (_) {}
  }

  // ── Auto-hide / show ──

  void _cancelHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _resetHideTimer() {
    _cancelHideTimer();
    _hideTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted) return;
      if (_showSettings) {
        // Don't auto-hide while settings panel is open.
        _resetHideTimer();
        return;
      }
      _setCollapsed(true);
    });
  }

  Future<void> _setCollapsed(bool v) async {
    if (_collapsed == v) return;
    _collapsed = v;
    if (v) {
      try {
        await windowManager.setSize(const Size(_barW, _collapsedH));
        await Future.delayed(const Duration(milliseconds: 30));
        try {
          await const MethodChannel('com.xmate/window').invokeMethod('forceChildRefresh');
        } catch (_) {}
      } catch (_) {}
    } else {
      await _updateWindowSize();
      _resetHideTimer();
    }
  }

  // ── Button handlers ──

  String _buildFreshOutputPath() {
    final savePath = SettingsService().get('screenrecording.savePath') as String? ?? '';
    final dir = savePath.isNotEmpty
        ? savePath
        : '${Platform.environment['USERPROFILE']}\\Videos';
    final template = SettingsService().get('screenrecording.filenameTemplate')
        as String? ?? kDefaultRecordingTemplate;
    final now = DateTime.now();
    final name = formatFilename(template, now);
    return '$dir\\$name.mp4';
  }

  SrData _buildSrData({String? outputPath}) {
    return SrData(
      offsetX: widget.data.offsetX,
      offsetY: widget.data.offsetY,
      width: widget.data.width,
      height: widget.data.height,
      outputPath: outputPath ?? widget.data.outputPath,
      ffmpegPath: widget.data.ffmpegPath,
      mode: widget.data.mode,
      encoder: _encoder,
      framerate: _fps,
      crf: _crf,
      audioSource: _audioDevices.isEmpty ? 'none' : _audioDevices.join(','),
      audioDeviceName: _audioDevices.isNotEmpty ? _audioDevices.first : '',
      audioDeviceNames: _audioDevices,
      audioBitrate: _audioBitrate,
      showMouse: _showMouse,
      allMonitors: _allMonitors,
    );
  }

  void _onToggleMouse() {
    setState(() => _showMouse = !_showMouse);
    SettingsService().set('screenrecording.showMouse', _showMouse);
  }

  void _onToggleAllMonitors() {
    setState(() => _allMonitors = !_allMonitors);
    SettingsService().set('screenrecording.allMonitors', _allMonitors);
  }

  void _onRecord() {
    if (_status == RecordingStatus.idle ||
        _status == RecordingStatus.stopped ||
        _status == RecordingStatus.error) {
      _showFileBar = false;
      _fileSize = 0;
      _updateWindowSize();
      _service.start(_buildSrData(outputPath: _buildFreshOutputPath()));
    } else {
      _service.stop();
    }
  }

  void _onPause() {
    if (_status == RecordingStatus.recording) {
      _service.pause();
    } else if (_status == RecordingStatus.paused) {
      _service.resume();
    }
  }

  void _onToggleSettings() {
    setState(() { _showSettings = !_showSettings; });
    _updateWindowSize();
    if (!_showSettings) _resetHideTimer();
    else _cancelHideTimer();
  }

  void _onOpenFolder() {
    final path = _service.outputPath;
    if (path == null) return;
    Process.run('explorer', ['/select,', path], runInShell: true);
  }

  void _onDeleteFile() {
    final path = _service.outputPath;
    if (path == null) return;
    try { File(path).deleteSync(); } catch (_) {}
    setState(() { _showFileBar = false; });
    _updateWindowSize();
  }

  void _onDismissFileBar() {
    setState(() { _showFileBar = false; });
    _updateWindowSize();
  }

  @override void dispose() {
    _cancelHideTimer();
    _ipc.dispose();
    _service.dispose();
    super.dispose();
  }

  @override Widget build(BuildContext context) {
    final ts = ThemeService();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: ts.themeMode,
      theme: ts.lightTheme,
      darkTheme: ts.darkTheme,
      home: ExcludeSemantics(
        child: MouseRegion(
        onEnter: (_) {
          if (_collapsed) _setCollapsed(false);
          _cancelHideTimer(); // stay visible while mouse is inside
        },
        onExit: (_) {
          if (!_collapsed) _resetHideTimer(); // start countdown when mouse leaves
        },
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(children: [
            // Invisible hit-extension strip below the bar.
            // When the bar is collapsed (1 px), the MouseRegion above
            // would otherwise be too small to reliably detect hover.
            // This invisible Container extends the hit area downward
            // so the mouse stays "entered" when near the bar.
            Positioned(
              top: 0, left: 0, right: 0,
              height: 24, // generous hit zone
              child: const ColoredBox(color: Colors.transparent),
            ),
            Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            RecordingIndicator(
              service: _service,
              status: _status,
              settingsOpen: _showSettings,
              collapsed: _collapsed,
              showMouse: _showMouse,
              allMonitors: _allMonitors,
              onRecord: _onRecord,
              onPause: _onPause,
              onToggleSettings: _onToggleSettings,
              onToggleMouse: _onToggleMouse,
              onToggleAllMonitors: _onToggleAllMonitors,
              onClose: () async {
                if (_closing) return;
                _closing = true;

                if (_status == RecordingStatus.recording ||
                    _status == RecordingStatus.paused) {
                  await _service.stop();
                }

                // Notify main process so overlay is destroyed immediately.
                _ipc.notifyClose();

                try { await windowManager.close(); } catch (_) {}
              },
              showFileBar: _showFileBar,
              savedFilePath: _service.outputPath,
              fileSize: _fileSize,
              onOpenFolder: _onOpenFolder,
              onDeleteFile: _onDeleteFile,
              onDismissFileBar: _onDismissFileBar,
            ),
            if (_showSettings && !_collapsed)
              RecordingSettingsPanel(
                encoder: _encoder,
                fps: _fps,
                crf: _crf,
                audioDevices: _audioDevices,
                audioBitrate: _audioBitrate,
                ffmpegPath: widget.data.ffmpegPath,
                onEncoderChanged: (v) => setState(() => _encoder = v),
                onFpsChanged: (v) => setState(() => _fps = v),
                onCrfChanged: (v) => setState(() => _crf = v),
                onAudioDevicesChanged: (v) { setState(() => _audioDevices = v.toList());
                  SettingsService().set('screenrecording.audioDevices', v); },
                onAudioBitrateChanged: (v) { setState(() => _audioBitrate = v);
                  SettingsService().set('screenrecording.audioBitrate', v); },
              ),
          ],
        ),
          ]), // Stack children, Stack
        ),
      ),
      ),
    );
  }
}

Future<SrData> loadSrDataFromNative() async {
  const channel = MethodChannel('com.xmate/app');
  final jsonStr = await channel.invokeMethod<String>('getScreenRecordingData');
  if (jsonStr == null || jsonStr.isEmpty) {
    throw Exception('No screen recording data from native layer');
  }
  final map = jsonDecode(jsonStr) as Map<String, dynamic>;
  return SrData.fromJson(map);
}
