/// Dictionary plugin — English-Chinese dictionary based on ECDICT.
///
/// Provides word lookup commands and settings for importing/managing
/// dictionary databases.
library;

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/plugin/plugin_base.dart';
import 'dictionary_service.dart';

class DictionaryPlugin extends XMatePlugin {
  @override
  String get id => 'dictionary';

  @override
  String get name => 'Dictionary';

  @override
  String get description => 'English-Chinese dictionary (ECDICT, 770K+ entries)';

  @override
  IconData get icon => Icons.menu_book;

  @override
  List<CommandItem> get commands => [
        CommandItem(
          id: 'dictionary.lookup',
          text: 'Dictionary',
          aliases: const ['dict', 'dictionary', '词典', 'cidian', 'cd'],
          description: 'Search English-Chinese dictionary',
          icon: Icons.menu_book,
          onExecute: () => appKey.currentState?.showDictionary(),
        ),
      ];

  @override
  Map<String, HotKeyDef> get defaultHotKeys => {};

  @override
  Future<void> onInit(PluginContext context) async {
    await DictionaryService().init();

    // Auto-open saved DB if path exists in settings.
    final savedPath = context.getSetting('dbPath') as String?;
    if (savedPath != null && savedPath.isNotEmpty) {
      try {
        await DictionaryService().openDatabase(savedPath);
      } catch (_) {
        // DB file may have been moved — ignore, user can re-select in debug tab.
      }
    }
  }

  @override
  Future<void> onDispose() async {
    await DictionaryService().dispose();
  }
}
