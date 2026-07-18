import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import '../../core/plugin/plugin_base.dart';
import '../../core/settings/settings_service.dart';
import '../../core/quicklook/quicklook_utils.dart';
import 'quicklook_settings.dart';

typedef QuickLookHotkeyChanged = bool Function(int mods, int keyId, String label);

class QuickLookPlugin extends XMatePlugin {
  PluginContext? _context;

  /// Set by main.dart so the plugin can notify main when the QuickLook
  /// hotkey changes.  Returns true if accepted, false if conflict.
  QuickLookHotkeyChanged? onQuickLookHotkeyChanged;

  /// Set by main.dart for hotkey capture session tracking.
  void Function(String source, bool active)? onCaptureStateChanged;

  /// Set by main.dart — called when user triggers QuickLook from any
  /// entry point (hotkey / command palette / tray).
  VoidCallback? onTriggerOpen;

  // Key echo display toggle values & callbacks (set by settings page)
  bool keyEchoHotkey = true;
  bool keyEchoStatus = true;
  ValueChanged<bool>? onKeyEchoHotkeyChanged;
  ValueChanged<bool>? onKeyEchoStatusChanged;

  @override String get id => 'quicklook';
  @override String get name => 'Quick Look';
  @override String get description => 'Preview file content quickly';
  @override IconData get icon => Icons.preview;

  // Default hotkey: Alt+Q
  static const _kDefaultMods = 1;   // Alt
  static final _kDefaultKeyId = LogicalKeyboardKey.keyQ.keyId; // USB HID for Q

  @override Map<String, HotKeyDef> get defaultHotKeys => {
    'activate': HotKeyDef(keyCode: _kDefaultKeyId, modifiers: [1]),
  };

  // QuickLook is triggered by Alt+Q hotkey, not by command palette search.
  // The command is hidden from the palette to avoid confusion.
  @override
  List<CommandItem> get commands => const [];

  // ── Settings ──

  int get hotkeyMods =>
      _context?.getSetting('hotkeyMods') as int? ?? _kDefaultMods;

  int get hotkeyKeyId =>
      _context?.getSetting('hotkeyKeyId') as int? ?? _kDefaultKeyId;

  String get hotkeyLabel => formatHotkey(hotkeyMods, hotkeyKeyId, emptyLabel: 'Not set');

  bool _onHotkeyChanged(int mods, int keyId, String label) {
    _context?.setSetting('hotkeyMods', mods);
    _context?.setSetting('hotkeyKeyId', keyId);
    return onQuickLookHotkeyChanged?.call(mods, keyId, label) ?? true;
  }

  // ── File Converter settings (embedded in QuickLook settings page) ──

  String get fcFfmpegPath => SettingsService().get('file_converter.ffmpegPath') as String? ?? '';
  String get fcDefaultOutputDir => SettingsService().get('file_converter.defaultOutputDir') as String? ?? '';
  int get fcMaxParallel => (SettingsService().get('file_converter.maxParallel') as int?) ?? 1;
  String get fcHwAccel => SettingsService().get('file_converter.hwAccel') as String? ?? 'off';

  void setFcFfmpegPath(String v) => SettingsService().set('file_converter.ffmpegPath', v);
  void setFcDefaultOutputDir(String v) => SettingsService().set('file_converter.defaultOutputDir', v);
  void setFcMaxParallel(int v) => SettingsService().set('file_converter.maxParallel', v);
  void setFcHwAccel(String v) => SettingsService().set('file_converter.hwAccel', v);

  @override Widget? get settingsPage {
    return QuickLookSettings(
      hotkeyLabel: hotkeyLabel,
      onHotkeyChanged: _onHotkeyChanged,
      onCaptureStateChanged: onCaptureStateChanged,
      keyEchoHotkey: keyEchoHotkey,
      keyEchoStatus: keyEchoStatus,
      onKeyEchoHotkeyChanged: onKeyEchoHotkeyChanged,
      onKeyEchoStatusChanged: onKeyEchoStatusChanged,
      // File Converter section
      fcFfmpegPath: fcFfmpegPath,
      fcDefaultOutputDir: fcDefaultOutputDir,
      fcMaxParallel: fcMaxParallel,
      fcHwAccel: fcHwAccel,
      onFcFfmpegPathChanged: setFcFfmpegPath,
      onFcOutputDirChanged: setFcDefaultOutputDir,
      onFcMaxParallelChanged: setFcMaxParallel,
      onFcHwAccelChanged: setFcHwAccel,
    );
  }

  // ── Lifecycle ──

  @override Future<void> onInit(PluginContext context) async {
    _context = context;
  }

  @override Future<void> onDispose() async {
    _context = null;
  }
}
