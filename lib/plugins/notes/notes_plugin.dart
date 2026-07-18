/// 便签插件 —— 独立进程多开的桌面便签
///
/// 入口：命令面板 `@ + 空格`（记录/追加），命令 "便签" 新建空白便签。
/// 每个便签是一个 `xmate.exe --note <id>` 独立进程窗口。
library;

import 'package:flutter/material.dart';

import '../../core/plugin/plugin_base.dart';
import '../../core/stats/usage_stats_service.dart';
import 'note_store.dart';
import 'notes_settings.dart';

class NotesPlugin extends XMatePlugin {
  @override
  String get id => 'notes';
  @override
  String get name => 'Notes';
  @override
  String get description => 'Sticky notes with markdown blocks and reminders';
  @override
  IconData get icon => Icons.sticky_note_2_outlined;

  @override
  Map<String, HotKeyDef> get defaultHotKeys => const {};

  @override
  List<CommandItem> get commands => [
        CommandItem(
          id: 'notes.create',
          text: 'Notes',
          aliases: const ['note', 'notes', '便签', 'bq', 'sticky'],
          description: 'Create a new sticky note',
          icon: Icons.sticky_note_2_outlined,
          onExecute: () {
            UsageStatsService().record('notes.create');
            NoteLauncher.createAndOpen('');
          },
        ),
      ];

  @override
  Widget? get settingsPage => const NotesSettings();

  @override
  Future<void> onInit(PluginContext context) async {}

  @override
  Future<void> onDispose() async {}
}
