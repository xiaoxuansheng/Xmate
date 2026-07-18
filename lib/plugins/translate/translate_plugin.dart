import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/plugin/plugin_base.dart';
import 'translate_settings.dart';
import 'server_manager.dart';
import 'model_manager.dart';

class TranslatePlugin extends XMatePlugin {
  PluginContext? _context;

  @override
  String get id => 'translate';

  @override
  String get name => 'Translate & Dict';

  @override
  String get description => 'Text translation via LibreTranslate';

  @override
  IconData get icon => Icons.translate;

  @override
  List<CommandItem> get commands => [
        CommandItem(
          id: 'translate.open',
          text: 'Translate',
          aliases: ['translate', 'translation', '翻译', 'fanyi', 'fy'],
          description: 'Open translation window',
          icon: Icons.translate,
          onExecute: () => appKey.currentState?.showTranslate(),
        ),
      ];

  @override
  Map<String, HotKeyDef> get defaultHotKeys => {};

  @override
  Widget? get settingsPage => TranslateSettings(
        onSettingChanged: (k, v) => _context?.setSetting(k, v),
        getSetting: (k) => _context?.getSetting(k),
      );

  @override
  Future<void> onInit(PluginContext context) async {
    _context = context;
    // Auto-start server in background (best-effort, non-blocking)
    _autoStart();
  }

  Future<void> _autoStart() async {
    try {
      // Only start if models are installed — avoid unnecessary errors
      final installed = await ModelManager().listInstalledPairs();
      if (installed.isEmpty) return;
      final codes = <String>{'en'};
      for (final m in installed) {
        codes.add(m.code1);
        codes.add(m.code2);
      }
      await ServerManager().start(loadOnly: codes.join(','));
    } catch (_) {
      // Silently ignore — server start is best-effort
    }
  }

  @override
  Future<void> onDispose() async {
    _context = null;
  }
}
