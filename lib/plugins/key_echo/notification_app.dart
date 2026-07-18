/// Notification process: top-right overlay showing lock-key states
/// (Status panel) and key-echo combos (Hotkey panel, auto-dismiss 1s).
///
/// Window starts at 1×1 (hidden).  Widget state is committed immediately
/// (no pending buffer).  _syncWindow() compares the last-synced count
/// against the current widget count and resizes directionally:
///   ADDING  → resizeContent (fire-and-forget), show on next frame
///   SHRINKING → wait for Flutter to render smaller content, then shrink
///
/// No debounce, no _resizing guard — events always process; stale async
/// operations are cancelled via _resizeGen token.
/// TOPMOST, no focus, no Alt+Tab.
library;

import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/settings/settings_service.dart';
import '../../core/theme/theme_service.dart';
import 'key_classifier.dart';
import 'key_echo_widget.dart';

class NotificationApp extends StatefulWidget {
  const NotificationApp({super.key});

  @override
  State<NotificationApp> createState() => _NotificationAppState();
}

class _NotificationAppState extends State<NotificationApp> {
  static const _channel = MethodChannel('com.xmate/keyecho');

  final _hotkeyKey = GlobalKey<KeyEchoHotkeyPanelState>();
  final _statusKey = GlobalKey<KeyEchoStatusPanelState>();

  bool _hotkeyEnabled = true;
  bool _statusEnabled = true;
  bool _ready = false;

  int _resizeGen = 0;
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Load initial lock-key state.
    try {
      final state = await _channel.invokeMethod('getInitialState');
      if (state is Map) {
        _statusKey.currentState?.updateLockStates(
          caps: state['capsLock'] == true,
          num: state['numLock'] == true,
          scroll: state['scrollLock'] == true,
          insert: state['insertLock'] == true,
        );
      }
    } catch (_) {}

    // Load initial settings from disk (one-shot). After this, the main
    // process pushes changes via WM_XMATE_KEYECHO_SETTINGS → onSettingsChanged.
    final s = SettingsService();
    try { await s.init(); } catch (_) {}
    try { await s.reload(); } catch (_) {}
    setState(() {
      _hotkeyEnabled =
          s.getWithDefault<bool>('notification.keyEcho.hotkey', true);
      _statusEnabled =
          s.getWithDefault<bool>('notification.keyEcho.status', true);
    });

    try { await _channel.invokeMethod('startHook'); } catch (_) {}
    _channel.setMethodCallHandler(_onMethodCall);

    _ready = true;

    // Show window if initial state has visible items.
    _syncWindow();
  }

  // ── Count tracking ───────────────────────────────────────────────

  int _totalCount() {
    int c = 0;
    if (_statusEnabled) c += _statusKey.currentState?.visibleCount ?? 0;
    if (_hotkeyEnabled) c += _hotkeyKey.currentState?.entryCount ?? 0;
    return c;
  }

  void _onWidgetChanged() => _syncWindow();

  void _syncWindow() {
    if (!_ready) return;
    final newCount = _totalCount();
    _applyWindowSize(_lastCount, newCount);
    _lastCount = newCount;
  }

  // ── Geometry ─────────────────────────────────────────────────────

  double get _itemH {
    final screen = ui.PlatformDispatcher.instance.displays.first;
    return screen.size.height / screen.devicePixelRatio * 0.03;
  }

  double get _fontSize => _itemH * 0.6;

  Future<void> _applyWindowSize(int oldCount, int newCount) async {
    if (!_ready) return;
    if (oldCount == 0 && newCount == 0) return;

    final gen = ++_resizeGen;
    final adding = newCount > oldCount;

    final screen = ui.PlatformDispatcher.instance.displays.first;
    final screenW = screen.size.width / screen.devicePixelRatio;
    final screenH = screen.size.height / screen.devicePixelRatio;
    final itemH = screenH * 0.03;
    final gap = itemH * 0.15;
    final w = screenW * 0.10;
    final x = screenW - screenW * 0.05 - w;
    final y = screenH * 0.05;

    int hFor(int n) => (n * (itemH + gap)).ceil() + 1;

    if (adding) {
      // Fire resizeContent without await — SetWindowPos completes in
      // <1ms on the platform thread, before the next VSync.
      _channel.invokeMethod('resizeContent', {
        'x': x.floor(), 'y': y.floor(),
        'w': w.ceil(), 'h': hFor(newCount),
      }); // fire-and-forget

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || gen != _resizeGen) return;
        try { _channel.invokeMethod('showContent'); } catch (_) {}
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || gen != _resizeGen) return;

        if (newCount == 0) {
          try { await _channel.invokeMethod('hideContent'); } catch (_) {}
          return;
        }

        try {
          await _channel.invokeMethod('resizeContent', {
            'x': x.floor(), 'y': y.floor(),
            'w': w.ceil(), 'h': hFor(newCount),
          });
        } catch (_) { return; }

        if (!mounted || gen != _resizeGen) return;
        try { _channel.invokeMethod('showContent'); } catch (_) {}
      });
    }
  }

  // ── Method call handler ──────────────────────────────────────────

  Future<void> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onSettingsChanged':
        final args = call.arguments as Map<dynamic, dynamic>?;
        if (args == null) return;
        setState(() {
          _hotkeyEnabled = args['hotkey'] == true;
          _statusEnabled = args['status'] == true;
        });
      case 'onThemeChanged':
        final args = call.arguments as Map<dynamic, dynamic>?;
        if (args == null) return;
        final mode = (args['mode'] as num?)?.toInt() ?? 0;
        final accent = Color((args['accent'] as num?)?.toInt() ?? 0xFF5AAAC2);
        final ts = ThemeService();
        switch (mode) {
          case 1: ts.setThemeMode(ThemeMode.light); break;
          case 2: ts.setThemeMode(ThemeMode.system); break;
          default: ts.setThemeMode(ThemeMode.dark); break;
        }
        ts.setAccentColor(accent);
        setState(() {}); // rebuild MaterialApp with new theme
      case 'onKeyEvent':
        final args = call.arguments as Map<dynamic, dynamic>?;
        if (args == null) return;
        final vk = (args['vkCode'] as num?)?.toInt() ?? 0;
        final mods = (args['modifiers'] as num?)?.toInt() ?? 0;

        if (_statusEnabled) {
          _statusKey.currentState?.updateLockStates(
            caps: args['capsLock'] == true,
            num: args['numLock'] == true,
            scroll: args['scrollLock'] == true,
            insert: args['insertLock'] == true,
          );
        }

        if (_hotkeyEnabled) {
          final label = KeyClassifier.toDisplayLabel(vk, mods);
          if (label != null) {
            int? volume;
            if (vk == 0xAF || vk == 0xAE) { // Vol Up / Vol Down
              try {
                final v = await _channel.invokeMethod('getSystemVolume');
                if (v is int) volume = v;
              } catch (_) {}
            }
            if (mounted) {
              _hotkeyKey.currentState?.addKey(label, volume: volume);
            }
          }
        }
    }
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final itemH = _itemH;
    final fontSize = _fontSize;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: ThemeService().themeMode,
      theme: ThemeService().lightTheme,
      darkTheme: ThemeService().darkTheme,
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            KeyEchoStatusPanel(
              key: _statusKey,
              itemH: itemH,
              fontSize: fontSize,
              onChanged: _onWidgetChanged,
            ),
            if (_hotkeyEnabled)
              KeyEchoHotkeyPanel(
                key: _hotkeyKey,
                itemH: itemH,
                fontSize: fontSize,
                onChanged: _onWidgetChanged,
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    try { _channel.invokeMethod('stopHook'); } catch (_) {}
    super.dispose();
  }
}
