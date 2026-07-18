library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'core/plugin/plugin_registry.dart';
import 'core/command/command_palette.dart';
import 'core/command/user_command_service.dart';
import 'core/window/window_manager.dart';
import 'core/quicklook/quicklook_palette_state.dart';
import 'core/theme/theme_service.dart';
import 'ui/settings/settings_page.dart';


final appKey = GlobalKey<XMateAppState>();
final navigatorKey = GlobalKey<NavigatorState>();

class XMateApp extends StatefulWidget {
  final PluginRegistry registry;
  const XMateApp({super.key, required this.registry});
  @override State<XMateApp> createState() => XMateAppState();
}

class XMateAppState extends State<XMateApp> {
  Widget? _overlay;
  final _contentKey = GlobalKey();
  final _dropdownMeasureKey = GlobalKey();   // measures dropdown at generous height (offstage)
  Size? _lastContentSize;                    // skip no-op resizes (settings page only)

  double? _cachedEmptyH;                     // input-field-only height, measured once
  int _windowGeneration = 0;                  // invalidates stale refitWindow callbacks
  int _paletteSession = 0;                    // force fresh State each open (see V2.2.13)

  /// Bump the generation token so every in-flight refitWindow callback
  /// becomes a no-op at its next async gap.  Call this before starting
  /// any non-palette overlay (screenshot / settings) and on overlay exit.
  void invalidateWindowOps() => _windowGeneration++;

  // ── Palette position (always anchored at screenW/2−270, screenH/3) ──

  static double _paletteX(double screenW) => (screenW - 540) / 2;
  static double _paletteY(double screenH) => screenH / 3;

  void showPalette({String? initialText}) {
    _paletteSession++;
    setState(() => _overlay = XMatePanel(
      key: ValueKey('palette_$_paletteSession'),
      registry: widget.registry,
      contentKey: _contentKey,
      dropdownMeasureKey: _dropdownMeasureKey,
      initialText: initialText,
    ));
    _showPaletteWindow();
  }

  Future<void> _showPaletteWindow() async {
    final display = ui.PlatformDispatcher.instance.displays.first;
    final screenW = display.size.width / display.devicePixelRatio;
    final screenH = display.size.height / display.devicePixelRatio;
    final x = _paletteX(screenW);
    final y = _paletteY(screenH);

    if (_cachedEmptyH == null) {
      await WindowService().setBounds(x: x, y: y, width: 540, height: 420);
      await _waitFrames(2);
      final h = _measureContentHeight();
      _cachedEmptyH = (h != null && h > 40) ? h : 60.0;
    }

    await WindowService().setBounds(x: x, y: y, width: 540, height: _cachedEmptyH!.ceilToDouble() + 1);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.show();
    await windowManager.focus();
  }

  void _refreshUserCommands() {
    final ucs = UserCommandService();
    final commands = ucs.loadCommands();
    widget.registry.unregisterCommandsByPrefix('user_command.');
    for (final cmd in commands.where((c) => c.enabled)) {
      final isScript = cmd.type == 'script';
      widget.registry.registerRawCommand(
        'user_command.${cmd.id}',
        cmd.name,
        icon: isScript ? Icons.code : Icons.terminal,
        description: cmd.path,
        aliases: [cmd.keyword],
        onExecute: isScript
            ? (UserCommandService.getScriptCallback(cmd.id) ?? () => ucs.execute(cmd))
            : () => ucs.execute(cmd),
      );
    }
  }

  void showOverlay(Widget w) {
    if (w is! XMatePanel) invalidateWindowOps();
    setState(() => _overlay = w);
  }

  void clearOverlay() {
    invalidateWindowOps();
    setState(() => _overlay = null);
  }

  void showSettings({HotkeyChangedCallback? onHotkeyChanged, void Function(String, bool)? onCaptureStateChanged, VoidCallback? onCommandsChanged}) {
    setState(() => _overlay = SettingsPage(
      registry: widget.registry,
      contentKey: _contentKey,
      onClose: () {
        _refreshUserCommands();
        onCommandsChanged?.call();
        WindowService().hideWindow();
        clearOverlay();
      },
      onHotkeyChanged: onHotkeyChanged,
      onCaptureStateChanged: onCaptureStateChanged,
      onCommandsChanged: _refreshUserCommands,
    ));
    _fitAfterNextFrame();
  }

  void showTranslate({String? initialText, List<String>? initialFiles}) {
    _spawnTranslateProcess(initialText: initialText, initialFiles: initialFiles);
  }

  /// Spawn a stand-alone dictionary window process.
  void showDictionary({String? initialText}) {
    _spawnDictionaryProcess(initialText: initialText);
  }

  /// Spawn a stand-alone translation window process.
  /// Single-instance: closes existing window before spawning.
  Future<void> _spawnTranslateProcess({String? initialText, List<String>? initialFiles}) async {
    // Close any existing translate window (single-instance).
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

  /// Spawn a stand-alone dictionary window process.
  Future<void> _spawnDictionaryProcess({String? initialText}) async {
    // Write initial text to a temp JSON file (same pattern as translate).
    String? dataPath;
    if (initialText != null) {
      try {
        final dir = await io.Directory.systemTemp.createTemp('xmate_dc_');
        final file = io.File('${dir.path}/dict_data.json');
        await file.writeAsString(jsonEncode({'text': initialText}));
        dataPath = file.path;
      } catch (_) {}
    }

    try {
      final exe = io.Platform.resolvedExecutable;
      final args = <String>['--dictionary'];
      if (dataPath != null) args.add(dataPath);
      await io.Process.start(
          exe, args, mode: io.ProcessStartMode.detached);
    } catch (_) {}
  }

  // QuickLook now runs in its own process (xmate.exe --quicklook <path>).
  // Spawned in main.dart's _showQuickLook — no overlay slot needed here.

  @override
  void initState() {
    super.initState();
    ThemeService().init();
  }

  @override
  void dispose() {
    super.dispose();
  }

  // ── Content-driven window sizing (settings page) ──

  void _fitAfterNextFrame({bool centerWindow = true}) {
    _lastContentSize = null;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (centerWindow) {
        await windowManager.setSize(const Size(900, 700));
        await _afterNextFrame();
      }
      await _measureAndFit(centerWindow: centerWindow);
    });
  }

  Future<void> _measureAndFit({bool centerWindow = true}) async {
    final ctx = _contentKey.currentContext;
    if (ctx == null || !mounted) return;
    final rb = ctx.findRenderObject() as RenderBox?;
    if (rb == null || !rb.hasSize) return;
    final size = rb.size;
    if (size.width < 2 || size.height < 2) return;

    final target = Size(
      size.width.clamp(200, 2000).ceilToDouble(),
      size.height.clamp(60, 4000).ceilToDouble() + 1,
    );

    if (_lastContentSize != null &&
        (target.width - _lastContentSize!.width).abs() < 2 &&
        (target.height - _lastContentSize!.height).abs() < 2) {
      return;
    }
    _lastContentSize = target;

    await windowManager.setSize(target);
    await windowManager.center();
    await windowManager.setAlwaysOnTop(false);
    await windowManager.show();
    await windowManager.focus();
  }

  // ── Palette content-driven resize ──

  void refitWindow(VoidCallback? onDone) {
    final gen = _windowGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (gen != _windowGeneration) return;
      if (_cachedEmptyH == null) return;

      await _afterNextFrame();
      if (gen != _windowGeneration) return;

      double finalH;
      final ctx = _dropdownMeasureKey.currentContext;
      if (ctx != null) {
        final rb = ctx.findRenderObject() as RenderBox?;
        if (rb == null || !rb.hasSize || rb.size.height < 2) return;
        final dropdownH = rb.size.height;
        finalH = (_cachedEmptyH! + dropdownH).clamp(60.0, 800.0).ceilToDouble() + 1;
      } else {
        finalH = _cachedEmptyH!.ceilToDouble() + 1;
      }

      if (gen != _windowGeneration) return;

      await windowManager.setSize(Size(540, finalH));

      if (gen != _windowGeneration) return;
      onDone?.call();

      if (gen != _windowGeneration) return;
      await windowManager.focus();
    });
  }

  // ── Helpers ──

  double? _measureContentHeight() {
    final ctx = _contentKey.currentContext;
    if (ctx == null) return null;
    final rb = ctx.findRenderObject() as RenderBox?;
    if (rb == null || !rb.hasSize || rb.size.height < 2) return null;
    return rb.size.height;
  }

  static Future<void> _afterNextFrame() {
    final c = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) => c.complete());
    return c.future;
  }

  static Future<void> _waitFrames(int count) async {
    for (int i = 0; i < count; i++) {
      await _afterNextFrame();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeService(),
      builder: (context, _) {
        final ts = ThemeService();
        return MaterialApp(
          navigatorKey: navigatorKey,
          title: 'XMate',
          debugShowCheckedModeBanner: false,
          themeMode: ts.themeMode,
          theme: ts.lightTheme,
          darkTheme: ts.darkTheme,
          home: ExcludeSemantics(
            child: _overlay ?? const Scaffold(
              backgroundColor: Colors.transparent,
              body: SizedBox.shrink(),
            ),
          ),
        );
      },
    );
  }
}

class XMatePanel extends StatelessWidget {
  final PluginRegistry registry;
  final GlobalKey contentKey;
  final GlobalKey dropdownMeasureKey;
  final String? initialText;
  const XMatePanel({super.key, required this.registry, required this.contentKey, required this.dropdownMeasureKey, this.initialText});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Align(
        alignment: Alignment.center,
        child: CommandPalette(
          registry: registry,
          onClose: _close,
          contentKey: contentKey,
          dropdownMeasureKey: dropdownMeasureKey,
          initialText: initialText,
        ),
      ),
    );
  }

  void _close() {
    WindowService().hideWindow();
    appKey.currentState?.clearOverlay();
    // Clear palette state so QuickLook falls back to Explorer polling
    // immediately after the palette is dismissed (exec / hide / Escape).
    QuickLookPaletteState.clear();
  }
}
