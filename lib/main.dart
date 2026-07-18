import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:hotkey_manager/hotkey_manager.dart' as hk;

import 'app.dart';
import 'core/plugin/plugin_registry.dart';
import 'core/settings/settings_service.dart';
import 'core/event/event_bus.dart';
import 'core/hotkey/hotkey_manager.dart';
import 'package:fvp/fvp.dart';
import 'core/command/timezone_service.dart';
import 'core/command/user_command_service.dart';
import 'core/tray/tray_manager.dart';
import 'core/window/window_manager.dart';
import 'core/search/file_search_service.dart';
import 'core/theme/theme_service.dart';
import 'plugins/screenshot/screenshot_plugin.dart';
import 'plugins/translate/translate_plugin.dart';
import 'plugins/translate/translate_page.dart';
import 'plugins/translate/server_manager.dart';
import 'plugins/dictionary/dictionary_plugin.dart';
import 'plugins/dictionary/dictionary_page.dart';
import 'plugins/quicklook/quicklook_page.dart';
import 'plugins/quicklook/quicklook_plugin.dart';
import 'plugins/screenrecording/screenrecording_plugin.dart';
import 'plugins/screenrecording/screenrecording_app.dart';
import 'plugins/file_converter/file_converter_plugin.dart';
import 'plugins/file_converter/models/output_type.dart';
import 'plugins/file_converter/ui/converter_page.dart';
import 'core/quicklook/quicklook_palette_state.dart';
import 'core/quicklook/quicklook_utils.dart';
import 'core/stats/usage_stats_service.dart';
import 'plugins/key_echo/notification_app.dart';
import 'plugins/notes/note_app.dart';
import 'plugins/notes/note_store.dart';
import 'plugins/notes/notes_plugin.dart';

final windowService = WindowService();

// ─── Hotkey persistence keys ───

const _kHotkeyPalette = 'app.hotkey.palette';

// ─── Live state for hotkeys ───

int _paletteMods = 1;   // Alt
int _paletteKeyId = LogicalKeyboardKey.space.keyId; // Space
int? _ssMods;
int? _ssKeyId;
int? _qlMods;
int? _qlKeyId;
int? _srMods;
int? _srKeyId;
ScreenshotPlugin? _ssPlugin;
ScreenRecordingPlugin? _srPlugin;

// ─── Dictionary standalone app ─────────────────────────────────────

/// Persisted dictionary window state (position + topmost + miniMode).
class DictionaryWindowState {
  final double? x, y;
  final bool topmost;
  final bool miniMode;
  const DictionaryWindowState(
      {this.x, this.y, this.topmost = false, this.miniMode = false});

  static Future<String> get _path async {
    final dir = '${io.Platform.environment['APPDATA']}\\XMate';
    await io.Directory(dir).create(recursive: true);
    return '$dir\\dict_state.json';
  }

  static Future<void> save({
    double? x,
    double? y,
    bool topmost = false,
    bool miniMode = false,
  }) async {
    try {
      await io.File(await _path).writeAsString(
          jsonEncode({'x': x, 'y': y, 'topmost': topmost, 'miniMode': miniMode}));
    } catch (_) {}
  }

  static Future<DictionaryWindowState> load() async {
    try {
      final f = io.File(await _path);
      if (!await f.exists()) return const DictionaryWindowState();
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return DictionaryWindowState(
        x: (m['x'] as num?)?.toDouble(),
        y: (m['y'] as num?)?.toDouble(),
        topmost: m['topmost'] as bool? ?? false,
        miniMode: m['miniMode'] as bool? ?? false,
      );
    } catch (_) {
      return const DictionaryWindowState();
    }
  }
}

class DictionaryApp extends StatefulWidget {
  final double? savedX;
  final double? savedY;
  final bool initialTopmost;
  final bool initialMiniMode;
  final String? initialText;
  const DictionaryApp({
    super.key,
    this.savedX,
    this.savedY,
    this.initialTopmost = false,
    this.initialMiniMode = false,
    this.initialText,
  });
  @override State<DictionaryApp> createState() => _DictionaryAppState();
}

class _DictionaryAppState extends State<DictionaryApp> {
  final _dictKey = GlobalKey<DictionaryPageState>();
  static const _appChannel = MethodChannel('com.xmate/app');
  bool _firstShow = true;

  @override
  void initState() {
    super.initState();
    // Listen for data forwarded from a second --dictionary process.
    _appChannel.setMethodCallHandler((call) async {
      if (call.method == 'dictionaryDataRequest') {
        final dataPath = call.arguments as String?;
        if (dataPath != null && dataPath.isNotEmpty) {
          try {
            final file = io.File(dataPath);
            if (await file.exists()) {
              final json = jsonDecode(await file.readAsString());
              final text = json['text'] as String?;
              await file.delete();
              if (text != null && text.isNotEmpty && mounted) {
                _dictKey.currentState?.searchText(text);
              }
            }
          } catch (_) {}
        }
        await _showAndFocus();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _showAndFocus());
  }

  Future<void> _showAndFocus() async {
    final screen = WidgetsBinding.instance.platformDispatcher.displays.first;
    final ss = screen.size / screen.devicePixelRatio;

    const w = 580.0;
    final h = widget.initialMiniMode ? 360.0 : 600.0;
    final margin = ss.width * 0.02;

    double x, y;
    if (widget.savedX != null && widget.savedY != null) {
      x = widget.savedX!;
      y = widget.savedY!;
    } else {
      x = (ss.width - w) / 2;
      y = (ss.height - h) / 3;
    }
    x = x.clamp(margin, (ss.width - w - margin).clamp(margin, ss.width));
    y = y.clamp(margin, (ss.height - h - margin).clamp(margin, ss.height));

    if (_firstShow) {
      _firstShow = false;
      await WindowService().setBounds(x: x, y: y, width: w, height: h);
      await WindowService().forceChildRefresh();
      if (widget.initialTopmost) {
        await windowManager.setAlwaysOnTop(true);
      }
    }
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: ts.themeMode,
      theme: ts.lightTheme,
      darkTheme: ts.darkTheme,
      home: ExcludeSemantics(
        child: DictionaryPage(
          key: _dictKey,
          initialTopmost: widget.initialTopmost,
          initialMiniMode: widget.initialMiniMode,
          initialText: widget.initialText,
          onClose: () async {
            try {
              final bounds = await windowManager.getBounds();
              await DictionaryWindowState.save(
                x: bounds.left,
                y: bounds.top,
                topmost: SettingsService()
                    .getWithDefault('dictionary.topmost', false),
                miniMode: SettingsService()
                    .getWithDefault('dictionary.miniMode', false),
              );
            } catch (_) {}
            _dictKey.currentState?.resetState();
            await windowManager.hide();
          },
        ),
      ),
    );
  }
}

// ─── QuickLook standalone app ───

class QuickLookApp extends StatefulWidget {
  final String filePath;
  final int restoreHwnd;
  final double? savedX, savedY;
  final bool initialTopmost;
  const QuickLookApp({
    super.key,
    required this.filePath,
    this.restoreHwnd = 0,
    this.savedX,
    this.savedY,
    this.initialTopmost = false,
  });
  @override State<QuickLookApp> createState() => _QuickLookAppState();
}

class _QuickLookAppState extends State<QuickLookApp> {
  bool _restored = false;

  Future<void> _onReady(Size size) async {
    final screen = WidgetsBinding.instance.platformDispatcher.displays.first;
    final ss = screen.size / screen.devicePixelRatio;

    // Clamp size — never exceed screen.  Keep 1% margin so the window
    // doesn't sit flush against the screen edges.
    final marginW = ss.width * 0.01;
    final marginH = ss.height * 0.01;
    final w = size.width.clamp(0.0, ss.width - marginW * 2);
    final h = size.height.clamp(0.0, ss.height - marginH * 2);

    double x, y;
    final savedX = widget.savedX;
    final savedY = widget.savedY;
    if (savedX != null && savedY != null && !_restored) {
      x = savedX;
      y = savedY;
    } else {
      // On first show without saved position, center.  On file switch (_restored
      // is true), resize at current position.
      try {
        final current = await windowManager.getBounds();
        x = current.left;
        y = current.top;
      } catch (_) {
        // Default: right of the command palette (540×420, centered, at screenH/3).
        const pw = 540.0, ph = 420.0, gap = 8.0;
        final px = (ss.width - pw) / 2;
        final py = ss.height / 3;
        x = px + pw + gap;
        y = py + (ph - h) / 2;
      }
    }

    // Clamp position so the window stays on-screen with 1% margin.
    final minX = marginW;
    final minY = marginH;
    final maxX = (ss.width - w - marginW).clamp(minX, ss.width);
    final maxY = (ss.height - h - marginH).clamp(minY, ss.height);
    x = x.clamp(minX, maxX);
    y = y.clamp(minY, maxY);

    await WindowService().showNoActivate(
      x: x, y: y, width: w, height: h,
    );

    // V2.5.9: force swapchain rebuild after resize from 1×1.
    await WindowService().forceChildRefresh();

    // Restore focus once on first load.
    if (!_restored) {
      _restored = true;
      if (widget.restoreHwnd != 0) {
        try {
          await const MethodChannel('com.xmate/window').invokeMethod(
            'restoreForeground', {'hwnd': widget.restoreHwnd},
          );
        } catch (_) {}
      }
    }
  }

  @override Widget build(BuildContext context) {
    final ts = ThemeService();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: ts.themeMode,
      theme: ts.lightTheme,
      darkTheme: ts.darkTheme,
      home: ExcludeSemantics(
        child: QuickLookPage(
        filePath: widget.filePath,
        onReady: _onReady,
        onClose: () async {
          await windowManager.close();
        },
        initialTopmost: widget.initialTopmost,
      ),
      ),
    );
  }
}

// ─── Translate standalone app ───────────────────────────────────────

/// Persisted translate window state (position + topmost).
class TranslateWindowState {
  final double? x, y;
  final bool topmost;
  const TranslateWindowState({this.x, this.y, this.topmost = false});

  static Future<String> get _path async {
    final dir = '${io.Platform.environment['APPDATA']}\\XMate';
    await io.Directory(dir).create(recursive: true);
    return '$dir\\translate_state.json';
  }

  static Future<void> save({double? x, double? y, bool topmost = false}) async {
    try {
      await io.File(await _path)
          .writeAsString(jsonEncode({'x': x, 'y': y, 'topmost': topmost}));
    } catch (_) {}
  }

  static Future<TranslateWindowState> load() async {
    try {
      final f = io.File(await _path);
      if (!await f.exists()) return const TranslateWindowState();
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return TranslateWindowState(
        x: (m['x'] as num?)?.toDouble(),
        y: (m['y'] as num?)?.toDouble(),
        topmost: m['topmost'] as bool? ?? false,
      );
    } catch (_) {
      return const TranslateWindowState();
    }
  }
}

class TranslateApp extends StatefulWidget {
  final String? initialText;
  final List<String>? initialFiles;
  final double? savedX;
  final double? savedY;
  final bool initialTopmost;
  const TranslateApp({
    super.key,
    this.initialText,
    this.initialFiles,
    this.savedX,
    this.savedY,
    this.initialTopmost = false,
  });
  @override State<TranslateApp> createState() => _TranslateAppState();
}

class _TranslateAppState extends State<TranslateApp> {
  @override
  void initState() {
    super.initState();
    // Same pattern as QuickLook: the window is already visible at 1×1
    // (invisible to the user).  Use setBounds to atomically position+size,
    // then show + forceChildRefresh to rebuild the swapchain.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final screen = WidgetsBinding.instance.platformDispatcher.displays.first;
      final ss = screen.size / screen.devicePixelRatio;

      const w = 800.0, h = 560.0;
      final marginW = ss.width * 0.02;
      final marginH = ss.height * 0.02;

      double x, y;
      if (widget.savedX != null && widget.savedY != null) {
        x = widget.savedX!;
        y = widget.savedY!;
      } else {
        x = (ss.width - w) / 2;
        y = (ss.height - h) / 3;
      }

      // Clamp on-screen.
      x = x.clamp(marginW, (ss.width - w - marginW).clamp(marginW, ss.width));
      y = y.clamp(marginH, (ss.height - h - marginH).clamp(marginH, ss.height));

      // Atomic position+size via native SetWindowPos (the window is already
      // shown at 1×1 — this call resizes it to 800×560 in place).
      await WindowService().setBounds(x: x, y: y, width: w, height: h);
      // Force swapchain rebuild after resize from 1×1 to 800×560.
      await WindowService().forceChildRefresh();

      // Topmost must be set AFTER the window is visible (window_manager
      // internally short-circuits setAlwaysOnTop when _isWindowVisible
      // is false).
      if (widget.initialTopmost) {
        await windowManager.setAlwaysOnTop(true);
      }
      await windowManager.show();
      await windowManager.focus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: ts.themeMode,
      theme: ts.lightTheme,
      darkTheme: ts.darkTheme,
      home: ExcludeSemantics(
        child: TranslatePage(
          initialText: widget.initialText,
          initialFiles: widget.initialFiles,
          onClose: () async {
            // Save position and topmost before closing.
            try {
              final bounds = await windowManager.getBounds();
              final topmost = SettingsService()
                  .getWithDefault('translate.topmost', false);
              await TranslateWindowState.save(
                x: bounds.left,
                y: bounds.top,
                topmost: topmost,
              );
            } catch (_) {}
            await windowManager.close();
          },
        ),
      ),
    );
  }
}

// ─── Hotkey capture guard ───

final _activeCaptures = <String>{};

bool _paletteConflict(int mods, int keyId) =>
    keyId == _paletteKeyId && (mods == _paletteMods || mods == (_paletteMods | 4));

void _onCaptureStateChanged(String source, bool active) {
  if (active) {
    _activeCaptures.add(source);
  } else {
    _activeCaptures.remove(source);
  }
}

// ─── Convert settings hotkey → hk.HotKey ───

hk.HotKey _toHotKey(int modsMask, int keyId) {
  final mods = <hk.HotKeyModifier>[];
  if (modsMask & 1 != 0) mods.add(hk.HotKeyModifier.alt);
  if (modsMask & 2 != 0) mods.add(hk.HotKeyModifier.control);
  if (modsMask & 4 != 0) mods.add(hk.HotKeyModifier.shift);
  if (modsMask & 8 != 0) mods.add(hk.HotKeyModifier.meta);
  // keyId is either:
  //   a) USB HID keyboard-page usage (plugin defaults: 0x15=R, 0x16=S)
  //      → must use PhysicalKeyboardKey with full 0x0007xxxx prefix,
  //        because bare 0x15 resolves to consumer-page "Resume" (wrong).
  //   b) Flutter LogicalKeyboardKey.keyId (from KeyEvent capture in settings)
  //      → LogicalKeyboardKey.findKeyByKeyId matches these.
  final key = LogicalKeyboardKey.findKeyByKeyId(keyId) ??
              PhysicalKeyboardKey.findKeyByCode(0x00070000 | keyId) ??
              LogicalKeyboardKey.space;
  return hk.HotKey(key: key, modifiers: mods, scope: hk.HotKeyScope.system);
}

(int mods, int keyId)? _parseShortcut(String shortcut) {
  final parts = shortcut.split('+');
  if (parts.isEmpty) return null;
  int mods = 0;
  LogicalKeyboardKey? key;
  for (final p in parts) {
    switch (p.trim()) {
      case 'Ctrl':  mods |= 2; break;
      case 'Alt':   mods |= 1; break;
      case 'Shift': mods |= 4; break;
      case 'Win':   mods |= 8; break;
      default:
        for (final k in LogicalKeyboardKey.knownLogicalKeys) {
          if (k.keyLabel == p.trim()) { key = k; break; }
        }
    }
  }
  if (key == null) return null;
  return (mods, key.keyId);
}

// ─── Register all hotkeys at once ───

Future<void> _registerAllHotkeys() async {
  try { await hk.hotKeyManager.unregisterAll(); } catch (_) {}

  // Palette hotkey — Alt+Space: just show/hide.
  try {
    await hk.hotKeyManager.register(
      _toHotKey(_paletteMods, _paletteKeyId),
      keyDownHandler: (_) => _toggle(),
    );
  } catch (_) {}

  // Palette hotkey + Shift — Alt+Shift+Space: grab text selection + show.
  // Derived from the user-configured palette hotkey by OR-ing the Shift bit.
  try {
    await hk.hotKeyManager.register(
      _toHotKey(_paletteMods | 4, _paletteKeyId),
      keyDownHandler: (_) => _toggleWithSelection(),
    );
  } catch (_) {}

  // Screenshot hotkey.
  if (_ssMods != null && _ssKeyId != null) {
    try {
      await hk.hotKeyManager.register(
        _toHotKey(_ssMods!, _ssKeyId!),
        keyDownHandler: (_) {
          if (_activeCaptures.isNotEmpty) return;
          UsageStatsService().record('screenshot.hotkey');
          _ssPlugin?.activateFromHotkey();
        },
      );
    } catch (_) {}
  }

  // QuickLook hotkey.
  if (_qlMods != null && _qlKeyId != null) {
    try {
      await hk.hotKeyManager.register(
        _toHotKey(_qlMods!, _qlKeyId!),
        keyDownHandler: (_) {
          UsageStatsService().record('quicklook.hotkey');
          _showQuickLook();
        },
      );
    } catch (_) {}
  }

  // Screen Recording hotkey.
  if (_srMods != null && _srKeyId != null) {
    try {
      await hk.hotKeyManager.register(
        _toHotKey(_srMods!, _srKeyId!),
        keyDownHandler: (_) {
          if (_activeCaptures.isNotEmpty) return;
          UsageStatsService().record('screenrecording.hotkey');
          _srPlugin?.toggleRecording();
        },
      );
    } catch (_) {}
  }

  // User-defined command hotkeys.
  final ucs = UserCommandService();
  final commands = ucs.loadCommands();
  for (final cmd in commands.where((c) => c.enabled && c.shortcut.isNotEmpty)) {
    final parsed = _parseShortcut(cmd.shortcut);
    if (parsed == null) continue;
    final (mods, keyId) = parsed;
    try {
      await hk.hotKeyManager.register(
        _toHotKey(mods, keyId),
        keyDownHandler: (_) {
          if (_activeCaptures.isNotEmpty) return;
          UsageStatsService().record('user_command.${cmd.id}');
          if (cmd.type == 'script') {
            UserCommandService.getScriptCallback(cmd.id)?.call();
          } else {
            ucs.execute(cmd);
          }
        },
      );
    } catch (_) {}
  }
}

Future<void> _onPaletteHotkeyChanged(int mods, int keyId) async {
  _paletteMods = mods;
  _paletteKeyId = keyId;
  await _registerAllHotkeys();
}

bool _onScreenshotHotkeyChanged(int mods, int keyId, String _) {
  if (_paletteConflict(mods, keyId)) return false;
  _ssMods = mods;
  _ssKeyId = keyId;
  _registerAllHotkeys();
  return true;
}

bool _onQuickLookHotkeyChanged(int mods, int keyId, String _) {
  if (_paletteConflict(mods, keyId)) return false;
  _qlMods = mods;
  _qlKeyId = keyId;
  _registerAllHotkeys();
  return true;
}

bool _onSrHotkeyChanged(int mods, int keyId, String _) {
  if (_paletteConflict(mods, keyId)) return false;
  _srMods = mods;
  _srKeyId = keyId;
  _registerAllHotkeys();
  return true;
}

// ─── File converter standalone app ──────────────────────────────

class FileConverterStandaloneApp extends StatefulWidget {
  const FileConverterStandaloneApp({super.key});
  @override
  State<FileConverterStandaloneApp> createState() =>
      _FileConverterStandaloneAppState();
}

class _FileConverterStandaloneAppState
    extends State<FileConverterStandaloneApp> {
  late String _ffmpegPath;
  late String _qpdfPath;

  @override
  void initState() {
    super.initState();
    final s = SettingsService();
    _ffmpegPath = _resolveFfmpegPath(s);
    _qpdfPath = _resolveQpdfPath();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final screen = WidgetsBinding.instance.platformDispatcher.displays.first;
      final ss = screen.size / screen.devicePixelRatio;

      const w = 800.0, h = 600.0;
      final marginW = ss.width * 0.02;
      final marginH = ss.height * 0.02;
      final x = ((ss.width - w) / 2).clamp(marginW, ss.width - w - marginW);
      final y = ((ss.height - h) / 3).clamp(marginH, ss.height - h - marginH);

      await WindowService().setBounds(x: x, y: y, width: w, height: h);
      await WindowService().forceChildRefresh();
      await windowManager.show();
      await windowManager.setAlwaysOnTop(false);
      await windowManager.focus();
    });
  }

  String _resolveFfmpegPath(SettingsService s) {
    // File Converter's own FFmpeg path (primary)
    final own = s.get('file_converter.ffmpegPath');
    if (own is String && own.isNotEmpty && io.File(own).existsSync()) return own;
    // Fall back to screenrecording's FFmpeg path (backward compat)
    final sr = s.get('screenrecording.ffmpegPath');
    if (sr is String && sr.isNotEmpty && io.File(sr).existsSync()) return sr;
    // Fall back: same directory as the executable (mirrors C# behaviour)
    final exeDir = io.File(io.Platform.resolvedExecutable).parent.path;
    final bundled = '$exeDir\\ffmpeg.exe';
    if (io.File(bundled).existsSync()) return bundled;
    return 'ffmpeg.exe';
  }

  String _resolveQpdfPath() {
    // qpdf is bundled alongside the executable (same dir as ffmpeg.exe)
    final exeDir = io.File(io.Platform.resolvedExecutable).parent.path;
    final bundled = '$exeDir\\qpdf.exe';
    if (io.File(bundled).existsSync()) return bundled;
    return 'qpdf.exe'; // PATH fallback (dev)
  }

  @override
  Widget build(BuildContext context) {
    final s = SettingsService();
    final outDir = s.get('file_converter.defaultOutputDir') as String? ?? '';
    final maxParallel = s.get('file_converter.maxParallel') as int? ?? 1;
    final hwStr = s.get('file_converter.hwAccel') as String? ?? 'off';
    final hwAccel = switch (hwStr) {
      'cuda' => HardwareAcceleration.cuda,
      'amf' => HardwareAcceleration.amf,
      _ => HardwareAcceleration.off,
    };
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: ThemeService().themeMode,
      theme: ThemeService().lightTheme,
      darkTheme: ThemeService().darkTheme,
      home: ConverterPage(
        ffmpegPath: _ffmpegPath,
        qpdfPath: _qpdfPath,
        defaultOutputDir: outDir,
        maxParallel: maxParallel,
        hwAccel: hwAccel,
        onClose: () async => await windowManager.close(),
      ),
    );
  }
}

// ─── Entry ───
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize IANA timezone database (pure Dart, no network required).
  TimezoneService.ensureInitialized();

  // Disable the Windows accessibility bridge to eliminate AXTree error 262
  // spam. XMate uses WS_POPUP windows with rapid overlay swaps — the engine's
  // UIA bridge cannot keep up. XMate is keyboard-driven and does not rely on
  // screen readers, so this has no functional impact.
  try {
    (WidgetsBinding.instance as dynamic).semanticsEnabled = false;
  } catch (_) {}

  // Register fvp as the video_player platform implementation (all platforms).
  registerWith(options: {'platforms': ['windows', 'linux', 'macos']});

  final appChannel = const MethodChannel('com.xmate/app');
  String? startupMode;
  try { startupMode = await appChannel.invokeMethod<String>('getStartupMode'); } catch (_) {}

  // ── QuickLook standalone ──
  if (startupMode == 'quicklook') {
    final rawPath = await appChannel.invokeMethod<String>('getQuickLookPath') ?? '';
    final path = rawPath.trim().replaceAll('/', '\\');
    final restoreHwndStr = await appChannel.invokeMethod<String>('getQlRestoreHwnd') ?? '';
    int restoreHwnd = 0;
    if (restoreHwndStr.isNotEmpty) {
      restoreHwnd = int.tryParse(restoreHwndStr, radix: 16) ?? 0;
    }
    // Init settings + theme so QuickLook reads user preferences.
    await SettingsService().init();
    ThemeService().init();
    final saved = await QlWindowState.load();
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        skipTaskbar: true,
        backgroundColor: Colors.transparent,
      ),
      () async {},
    );
    runApp(QuickLookApp(
      filePath: path,
      restoreHwnd: restoreHwnd,
      savedX: saved.x,
      savedY: saved.y,
      initialTopmost: saved.topmost,
    ));
    return;
  }

  // ── Screen Recording standalone ──
  if (startupMode == 'screenrecording') {
    final srData = await loadSrDataFromNative();
    await SettingsService().init();
    ThemeService().init();
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        skipTaskbar: true,
        backgroundColor: Colors.transparent,
        titleBarStyle: TitleBarStyle.hidden,
      ),
      () async {},
    );
    runApp(ScreenRecordingApp(data: srData));
    return;
  }

  // ── Translate standalone ─────────────────────────────────────────
  if (startupMode == 'translate') {
    final dataPath = await appChannel.invokeMethod<String>('getQuickLookPath') ?? '';
    String? initialText;
    List<String>? initialFiles;
    if (dataPath.isNotEmpty) {
      try {
        final file = io.File(dataPath);
        if (await file.exists()) {
          final json = jsonDecode(await file.readAsString());
          initialText = json['text'] as String?;
          initialFiles = (json['files'] as List<dynamic>?)?.cast<String>();
          await file.delete(); // cleanup temp file
        }
      } catch (_) {}
    }
    await SettingsService().init();
    ThemeService().init();
    final saved = await TranslateWindowState.load();
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        skipTaskbar: false,
        backgroundColor: Colors.transparent,
      ),
      () async {
        // Keep window visible (1×1 engine-init surface — imperceptible).
        // TranslateApp will atomically resize+position on first frame.
      },
    );
    runApp(TranslateApp(
      initialText: initialText,
      initialFiles: initialFiles,
      savedX: saved.x,
      savedY: saved.y,
      initialTopmost: saved.topmost,
    ));
    return;
  }

  // ── Dictionary standalone ────────────────────────────────────────
  if (startupMode == 'dictionary') {
    final dataPath =
        await appChannel.invokeMethod<String>('getQuickLookPath') ?? '';
    String? initialText;
    if (dataPath.isNotEmpty) {
      try {
        final file = io.File(dataPath);
        if (await file.exists()) {
          final json = jsonDecode(await file.readAsString());
          initialText = json['text'] as String?;
          await file.delete();
        }
      } catch (_) {}
    }
    await SettingsService().init();
    ThemeService().init();
    final saved = await DictionaryWindowState.load();
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        skipTaskbar: false,
        backgroundColor: Colors.transparent,
      ),
      () async {},
    );
    runApp(DictionaryApp(
      savedX: saved.x,
      savedY: saved.y,
      initialTopmost: saved.topmost,
      initialMiniMode: saved.miniMode,
      initialText: initialText,
    ));
    return;
  }

  // ── Sticky note standalone ────────────────────────────────────
  if (startupMode == 'note') {
    var noteId =
        await appChannel.invokeMethod<String>('getQuickLookPath') ?? '';
    if (noteId.isEmpty) {
      noteId = 'n${DateTime.now().millisecondsSinceEpoch}';
    }
    await SettingsService().init();
    ThemeService().init();
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        skipTaskbar: true,
        backgroundColor: Colors.transparent,
      ),
      () async {
        // Keep window visible (1×1 engine-init surface — imperceptible).
        // NoteApp positions + resizes on first frame.
      },
    );
    runApp(NoteApp(noteId: noteId));
    return;
  }

  // ── Notification standalone (key-echo overlay, top-right) ──
  if (startupMode == 'notification') {
    await SettingsService().init();
    ThemeService().init();
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        skipTaskbar: true,
        backgroundColor: Colors.transparent,
      ),
      () async {},
    );
    runApp(const NotificationApp());
    return;
  }


  // ── File converter standalone ─────────────────────────────────
  if (startupMode == 'fileconverter') {
    await SettingsService().init();
    ThemeService().init();
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        skipTaskbar: false,
        alwaysOnTop: false,
        backgroundColor: Colors.transparent,
      ),
      () async {},
    );
    runApp(const FileConverterStandaloneApp());
    return;
  }

  // ── Main process ──
  final settings = SettingsService();
  await settings.init();
  ThemeService().init();
  await UsageStatsService().init();
  await windowService.initMainWindow();

  final registry = PluginRegistry(eventBus: EventBus(), settings: settings);
  final ssPlugin = ScreenshotPlugin();
  _ssPlugin = ssPlugin;
  await registry.register(ssPlugin);
  final trPlugin = TranslatePlugin();
  await registry.register(trPlugin);
  final qlPlugin = QuickLookPlugin();
  await registry.register(qlPlugin);
  final srPlugin = ScreenRecordingPlugin();
  _srPlugin = srPlugin;
  await registry.register(srPlugin);
  final dictPlugin = DictionaryPlugin();
  await registry.register(dictPlugin);
  final fcPlugin = FileConverterPlugin();
  await registry.register(fcPlugin);
  final notesPlugin = NotesPlugin();
  await registry.register(notesPlugin);
  await HotkeyManager().init();

  // ── Load palette hotkey ──
  final saved = settings.get(_kHotkeyPalette);
  if (saved is Map) {
    _paletteMods = saved['modifiers'] ?? 1;
    _paletteKeyId = saved['key'] ?? 62;
  }

  // ── Load screenshot hotkey ──
  final ssMods = settings.get('screenshot.hotkeyMods');
  final ssKeyId = settings.get('screenshot.hotkeyKeyId');
  if (ssMods is int && ssKeyId is int) {
    if (!_paletteConflict(ssMods, ssKeyId)) {
      _ssMods = ssMods;
      _ssKeyId = ssKeyId;
    }
  } else {
    final dMods = ssPlugin.hotkeyMods;
    final dKeyId = ssPlugin.hotkeyKeyId;
    if (!_paletteConflict(dMods, dKeyId)) {
      _ssMods = dMods;
      _ssKeyId = dKeyId;
    }
  }

  // ── Load QuickLook hotkey ──
  final qlMods = settings.get('quicklook.hotkeyMods');
  final qlKeyId = settings.get('quicklook.hotkeyKeyId');
  if (qlMods is int && qlKeyId is int) {
    if (!_paletteConflict(qlMods, qlKeyId)) {
      _qlMods = qlMods;
      _qlKeyId = qlKeyId;
    }
  } else {
    final dMods = qlPlugin.hotkeyMods;
    final dKeyId = qlPlugin.hotkeyKeyId;
    if (!_paletteConflict(dMods, dKeyId)) {
      _qlMods = dMods;
      _qlKeyId = dKeyId;
    }
  }

  // ── Load screen recording hotkey ──
  final srModsSaved = settings.get('screenrecording.hotkeyMods');
  final srKeyIdSaved = settings.get('screenrecording.hotkeyKeyId');
  if (srModsSaved is int && srKeyIdSaved is int) {
    if (!_paletteConflict(srModsSaved, srKeyIdSaved)) {
      _srMods = srModsSaved;
      _srKeyId = srKeyIdSaved;
    }
  } else {
    final dMods = srPlugin.hotkeyMods;
    final dKeyId = srPlugin.hotkeyKeyId;
    if (!_paletteConflict(dMods, dKeyId)) {
      _srMods = dMods;
      _srKeyId = dKeyId;
      // Persist defaults so subsequent runs use the `if` branch.
      settings.set('screenrecording.hotkeyMods', dMods);
      settings.set('screenrecording.hotkeyKeyId', dKeyId);
      srPlugin.setRecHotkeyMods(dMods);
      srPlugin.setRecHotkeyKeyId(dKeyId);
    }
  }

  // ── Wire callbacks ──
  ssPlugin.onScreenshotHotkeyChanged = _onScreenshotHotkeyChanged;
  ssPlugin.onCaptureStateChanged = _onCaptureStateChanged;

  qlPlugin.onQuickLookHotkeyChanged = _onQuickLookHotkeyChanged;
  qlPlugin.onCaptureStateChanged = _onCaptureStateChanged;
  qlPlugin.onTriggerOpen = _showQuickLook;

  srPlugin.onHotkeyChanged = _onSrHotkeyChanged;
  srPlugin.onCaptureStateChanged = _onCaptureStateChanged;

  // Screenshot → recording toolbar integration.
  ssPlugin.onScreenshotDoneOpenRecording = (selRect, dpr, monRect, overlayPng) =>
      srPlugin.startWindowRecording(selRect, dpr, monRect, overlayPng);
  ssPlugin.onScreenshotCancelCloseRecording = () => srPlugin.closeToolbarIfNotRecording();

  // Wire recording settings through ScreenshotPlugin for unified settings UI.
  ssPlugin.recSavePathFn = () => srPlugin.savePath;
  ssPlugin.recOnSavePathChangedFn = (v) => srPlugin.setRecSavePath(v);
  ssPlugin.recFfmpegPathFn = () => srPlugin.ffmpegPath;
  ssPlugin.recOnFfmpegPathChangedFn = (v) => srPlugin.setRecFfmpegPath(v);
  ssPlugin.recEncoderFn = () => srPlugin.encoder;
  ssPlugin.recOnEncoderChangedFn = (v) => srPlugin.setRecEncoder(v);
  ssPlugin.recFpsFn = () => srPlugin.fps;
  ssPlugin.recOnFpsChangedFn = (v) => srPlugin.setRecFps(v);
  ssPlugin.recCrfFn = () => srPlugin.crf;
  ssPlugin.recOnCrfChangedFn = (v) => srPlugin.setRecCrf(v);
  ssPlugin.recAudioDevicesFn = () => srPlugin.audioDevices;
  ssPlugin.recOnAudioDevicesChangedFn = (v) => srPlugin.setRecAudioDevices(v);
  ssPlugin.recAudioBitrateFn = () => srPlugin.audioBitrate;
  ssPlugin.recOnAudioBitrateChangedFn = (v) => srPlugin.setRecAudioBitrate(v);
  ssPlugin.recShowMouseFn = () => srPlugin.showMouse;
  ssPlugin.recOnShowMouseChangedFn = (v) => srPlugin.setRecShowMouse(v);
  ssPlugin.recFilenameTemplateFn = () => srPlugin.filenameTemplate;
  ssPlugin.recOnFilenameTemplateChangedFn = (v) => srPlugin.setRecFilenameTemplate(v);
  ssPlugin.recHotkeyLabelFn = () => srPlugin.hotkeyLabel;
  ssPlugin.onRecHotkeyChangedFn = _onSrHotkeyChanged;
  ssPlugin.onRecCaptureStateChangedFn = _onCaptureStateChanged;

  // Register immediately (sets up internal state).
  await _registerAllHotkeys();
  // Cascade retries: the native HWND is not guaranteed to be settled
  // at the first frame.  Retry at increasing intervals so that even on
  // slow machines the hotkey registration eventually succeeds.
  // Only the first call (above) does unregisterAll → registerAll.
  // Retries only re-register without unregistering first, so a
  // partial success is never undone.
  for (final delayMs in const [800, 2000, 5000]) {
    Timer(Duration(milliseconds: delayMs), () {
      if (_srMods != null && _srKeyId != null) {
        try {
          hk.hotKeyManager.register(
            _toHotKey(_srMods!, _srKeyId!),
            keyDownHandler: (_) {
              if (_activeCaptures.isNotEmpty) return;
              UsageStatsService().record('screenrecording.hotkey');
              _srPlugin?.toggleRecording();
            },
          );
        } catch (_) {}
      }
      if (_ssMods != null && _ssKeyId != null) {
        try {
          hk.hotKeyManager.register(
            _toHotKey(_ssMods!, _ssKeyId!),
            keyDownHandler: (_) {
              if (_activeCaptures.isNotEmpty) return;
              UsageStatsService().record('screenshot.hotkey');
              _ssPlugin?.activateFromHotkey();
            },
          );
        } catch (_) {}
      }
    });
  }

  scheduleMicrotask(() => FileSearchService().init());

  registry.registerRawCommand(
    'settings.open',
    'Settings',
    icon: Icons.settings,
    description: 'Open settings page',
    aliases: const ['settings', '设置', 'config'],
    onExecute: () {
      UsageStatsService().record('settings.open');
      _openSettings();
    },
  );

  // Register built-in script handlers
  UserCommandService.registerScriptHandler('script_swap_monitors', () async {
    final result = await WindowService().swapMonitors();
    if (result != null && result.containsKey('error')) {
      debugPrint('[swapMonitors] error: ${result['error']}');
    } else {
      debugPrint(
          '[swapMonitors] done: moved=${result?['moved'] ?? 0} skipped=${result?['skipped'] ?? 0}');
    }
  });

  final userCommandService = UserCommandService();
  final userCommands = userCommandService.loadCommands();
  for (final cmd in userCommands.where((c) => c.enabled)) {
    final isScript = cmd.type == 'script';
    registry.registerRawCommand(
      'user_command.${cmd.id}',
      cmd.name,
      icon: isScript ? Icons.code : Icons.terminal,
      description: cmd.path,
      aliases: [cmd.keyword],
      onExecute: isScript
          ? (UserCommandService.getScriptCallback(cmd.id) ?? (() => userCommandService.execute(cmd)))
          : () => userCommandService.execute(cmd),
    );
  }

  final tray = TrayService();
  try {
    await tray.init(
      onOpenCommandPalette: _open,
      onScreenshot: () {
        UsageStatsService().record('screenshot.tray');
        registry.findCommand('screenshot.activate')?.onExecute();
      },
      onSettings: _openSettings,
      onExit: () async {
        // 1. Stop recording (in-process — writes IPC stop command).
        srPlugin.stopRecording();
        // 2. Dispose Dart-side resources.
        await registry.disposeAll();
        await tray.dispose();
        await FileSearchService().dispose();
        ServerManager().dispose();
        // 3. Hide main window → message loop exits → C++ cleanup
        //    closes all subprocess windows (sequential PID-wait, 3 s each).
        await windowManager.hide();
        await windowService.dispose();
      },
    );
  } catch (_) {}

  runApp(ProviderScope(child: XMateApp(key: appKey, registry: registry)));

  // Spawn the notification process (key-echo overlay) in the background.
  // It runs independently — we fire-and-forget via detached mode.
  _spawnNotificationProcess();

  // Restore sticky notes that were open at last exit (staggered spawn to
  // avoid multiple Flutter engines initializing simultaneously).
  scheduleMicrotask(() async {
    try {
      final openNotes = NoteStore.list().where((n) => !n.closed).toList();
      for (final n in openNotes) {
        await NoteLauncher.spawn(n.id);
        await Future.delayed(const Duration(milliseconds: 250));
      }
    } catch (_) {}
  });

  // Cross-process translate-file request from QuickLook subprocess.
  appChannel.setMethodCallHandler((call) async {
    if (call.method == 'translateFileRequest') {
      final path = call.arguments as String?;
      if (path != null && path.isNotEmpty) {
        _spawnTranslateProcess(initialFiles: [path]);
      }
    }
  });
}

// ─── Window toggle ───

void _toggle() async {
  if (_activeCaptures.isNotEmpty) return;
  final visible = await windowManager.isVisible();
  visible ? _close() : _open();
}

/// Alt+Space: just show/hide the palette (no text selection).
void _open() {
  UsageStatsService().record('palette.open');
  appKey.currentState?.showPalette();
  QuickLookPaletteState.update(active: true);
}

/// Alt+Shift+Space: grab text selection from foreground app, then show.
void _toggleWithSelection() async {
  if (_activeCaptures.isNotEmpty) return;
  final visible = await windowManager.isVisible();
  if (visible) { _close(); return; }

  String? initialText;
  try {
    final text = await const MethodChannel('com.xmate/app')
        .invokeMethod<String>('getSelectedText');
    if (text != null && text.isNotEmpty) {
      final sanitized = text
          .replaceAll(RegExp(r'[\r\n]+'), ' ')
          .trim();
      if (sanitized.isNotEmpty && sanitized.length <= 200) {
        initialText = sanitized;
      }
    }
  } catch (_) {}

  UsageStatsService().record('palette.open_with_selection');
  appKey.currentState?.showPalette(initialText: initialText);
  QuickLookPaletteState.update(active: true);
}

void _close() {
  windowService.hideWindow();
  appKey.currentState?.clearOverlay();
  QuickLookPaletteState.clear();
}

// ─── Notification process ───

Future<void> _spawnNotificationProcess() async {
  try {
    final exe = io.Platform.resolvedExecutable;
    await io.Process.start(exe, ['--notification'],
        mode: io.ProcessStartMode.detached);
  } catch (_) {}
}

/// Spawn a stand-alone translation window process.
/// Single-instance: closes any existing translate window first.
Future<void> _spawnTranslateProcess({String? initialText, List<String>? initialFiles}) async {
  // Single-instance: close any existing translate window.
  try {
    await const MethodChannel('com.xmate/app')
        .invokeMethod('closeTranslateWindows');
    // Small delay to let the old process finish WM_CLOSE → DestroyWindow.
    await Future.delayed(const Duration(milliseconds: 150));
  } catch (_) {}

  // Write initial data to a temp JSON file (avoids command-line length limits).
  String? dataPath;
  if (initialText != null || (initialFiles != null && initialFiles.isNotEmpty)) {
    try {
      final dir = await io.Directory.systemTemp.createTemp('xmate_tr_');
      final file = io.File('${dir.path}/translate_data.json');
      final data = <String, dynamic>{};
      if (initialText != null) data['text'] = initialText;
      if (initialFiles != null && initialFiles.isNotEmpty) data['files'] = initialFiles;
      await file.writeAsString(jsonEncode(data));
      dataPath = file.path;
    } catch (_) {}
  }

  try {
    final exe = io.Platform.resolvedExecutable;
    final args = <String>['--translate'];
    if (dataPath != null) args.add(dataPath);
    await io.Process.start(exe, args, mode: io.ProcessStartMode.detached);
  } catch (_) {}
}

// ─── QuickLook ───

Future<void> _showQuickLook() async {
  int closed = 0;
  try {
    final result = await const MethodChannel('com.xmate/quicklook')
        .invokeMethod('closeQuickLookWindows', {'includePinned': false});
    closed = (result as int?) ?? 0;
  } catch (_) {}

  if (closed > 0) return;

  String? filePath = await getSelectedFilePath();

  final args = <String>['--quicklook'];
  if (filePath != null && filePath.isNotEmpty) {
    args.add(filePath);
  }
  try {
    final fgHwnd = await const MethodChannel('com.xmate/app')
        .invokeMethod<int>('getForegroundHwnd');
    if (fgHwnd != null && fgHwnd != 0) {
      args.add('--ql-restore');
      args.add(fgHwnd.toRadixString(16));
    }
  } catch (_) {}
  try {
    final exe = io.Platform.resolvedExecutable;
    await io.Process.start(exe, args, mode: io.ProcessStartMode.detached);
  } catch (_) {}
}

// ─── Open settings overlay ───

void _openSettings() {
  appKey.currentState?.showSettings(
    onHotkeyChanged: (newMods, newKeyId, label) async {
      await _onPaletteHotkeyChanged(newMods, newKeyId);
    },
    onCaptureStateChanged: _onCaptureStateChanged,
    onCommandsChanged: _registerAllHotkeys,
  );
}

// ─── Script command handler registration ───
// Script handlers are registered before loading user commands,
// so both main.dart and app.dart's _refreshUserCommands can dispatch them.
