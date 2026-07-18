/// 便签插件设置页 —— 浏览所有便签（含已关闭），可打开/删除/清空
library;

import 'package:flutter/material.dart';

import '../../core/theme/theme_colors.dart';
import 'note_editor.dart' show RenderedSpans, buildNoteSpans;
import 'note_model.dart';
import 'note_store.dart';

class NotesSettings extends StatefulWidget {
  const NotesSettings({super.key});
  @override
  State<NotesSettings> createState() => _NotesSettingsState();
}

class _NotesSettingsState extends State<NotesSettings> {
  List<NoteData> _notes = [];
  Set<String> _openIds = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final notes = NoteStore.list();
    final open = await NoteLauncher.openNoteIds();
    if (!mounted) return;
    setState(() {
      _notes = notes;
      _openIds = open;
    });
  }

  Future<void> _create() async {
    await NoteLauncher.createAndOpen('');
    await Future.delayed(const Duration(milliseconds: 400));
    _refresh();
  }

  Future<void> _open(NoteData n) async {
    if (_openIds.contains(n.id)) {
      await NoteLauncher.focusWindow(n.id);
    } else {
      await NoteLauncher.spawn(n.id);
      await Future.delayed(const Duration(milliseconds: 400));
    }
    _refresh();
  }

  Future<void> _delete(NoteData n) async {
    if (n.locked) return; // 锁定（折叠）便签需先在便签内解锁
    if (_openIds.contains(n.id)) {
      await NoteLauncher.closeWindow(n.id);
      await Future.delayed(const Duration(milliseconds: 250));
    }
    NoteStore.delete(n.id);
    _refresh();
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          backgroundColor: XMateColors.dialogBg(ctx),
          title: Text('Clear all notes',
              style: TextStyle(fontSize: 16, color: cs.onSurface)),
          content: Text(
              'Close and delete all ${_notes.length} notes. This cannot be undone.',
              style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(179))),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('Clear', style: TextStyle(color: cs.error)),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    for (final id in _openIds) {
      await NoteLauncher.closeWindow(id);
    }
    await Future.delayed(const Duration(milliseconds: 300));
    NoteStore.deleteAll();
    _refresh();
  }

  String _fmtTime(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return '${two(t.hour)}:${two(t.minute)}';
    }
    return '${t.month}-${t.day}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Section 1: Note management ──
        _sectionHeader('Notes', Icons.sticky_note_2_outlined, cs),
        _sectionBody(context, [
          _buildToolbar(cs),
          Divider(color: XMateColors.divider(context), height: 1),
          if (_notes.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: Text('No notes yet',
                    style: TextStyle(
                        fontSize: 12.5, color: cs.onSurface.withAlpha(110))),
              ),
            )
          else
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorderItem: _onReorder,
              children: [
                for (int i = 0; i < _notes.length; i++)
                  KeyedSubtree(
                    key: ValueKey(_notes[i].id),
                    child: _buildRow(i, _notes[i], brightness, cs),
                  ),
              ],
            ),
        ]),
        const SizedBox(height: 20),
        // ── Section 2: Input Rules ──
        _sectionHeader('Input Rules', Icons.info_outline, cs),
        _sectionBody(context, [
          ..._buildRules(),
        ]),
      ],
    );
  }

  Widget _sectionHeader(String title, IconData icon, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Icon(icon, size: 16, color: cs.primary),
        const SizedBox(width: 6),
        Text(title,
            style: TextStyle(
                fontSize: 13, color: cs.primary, fontWeight: FontWeight.w500)),
      ]),
    );
  }

  Widget _sectionBody(BuildContext context, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: XMateColors.cardFill(context),
        borderRadius: BorderRadius.circular(10),
      ),
      child:
          Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  Widget _buildToolbar(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(children: [
        Text('${_notes.length} notes',
            style: TextStyle(
                fontSize: 11.5, color: cs.onSurface.withAlpha(110))),
        const Spacer(),
        _ActionChip(icon: Icons.add, label: 'New', onTap: _create),
        const SizedBox(width: 8),
        _ActionChip(icon: Icons.refresh, label: 'Refresh', onTap: _refresh),
        const SizedBox(width: 8),
        _ActionChip(
          icon: Icons.delete_sweep_outlined,
          label: 'Clear',
          color: cs.error,
          onTap: _notes.isEmpty ? null : _clearAll,
        ),
      ]),
    );
  }

  /// Input rules rows
  List<Widget> _buildRules() {
    const rules = <(String, String)>[
      ('@ + Space', 'Jot text into a new / existing note via the command palette'),
      ('#  ##  ###', 'Type marker + Space at line start for headings'),
      ('[]   *   1.   ---', 'Todo / bullet / numbered list / divider'),
      ('Enter / Shift+Enter', 'Next block / new line within the block'),
      ('Ctrl+B / U / I', 'Bold / underline / italic — marks visible while typing, hidden on Enter'),
      ('@time', 'Reminder: @30s @5min @18:30 @tomorrow 9:00 @2026-07-20 18:30 UTC+8 — multiple, nearest shows in title bar'),
      ('Drag & drop', 'Drop files/images in; drag image/file blocks out; drop one note onto another to merge'),
      ('Pin / corner', 'Pin keeps the note on top; click the folded corner to tear it off'),
    ];
    final cs = Theme.of(context).colorScheme;
    return [
      const SizedBox(height: 8),
      for (final (key, desc) in rules)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 130,
                child: Text(key,
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: cs.primary.withAlpha(220))),
              ),
              Expanded(
                child: Text(desc,
                    style: TextStyle(
                        fontSize: 11.5, color: cs.onSurface.withAlpha(150))),
              ),
            ],
          ),
        ),
      const SizedBox(height: 8),
    ];
  }

  /// 拖拽排序 → 持久化自定义顺序（onReorderItem 的 newIndex 已修正移除偏移）
  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      final n = _notes.removeAt(oldIndex);
      _notes.insert(newIndex, n);
    });
    NoteStore.saveOrder(_notes.map((e) => e.id).toList());
  }

  Widget _buildRow(int index, NoteData n, Brightness brightness, ColorScheme cs) {
    final isOpen = _openIds.contains(n.id);
    final hasReminder = n.nextReminder != null;
    // 标题渲染态：内联标记（**粗** *斜* <u>下划线</u> / URL / @token）按样式渲染
    // 锁定便签不泄露内容预览
    final titleStyle = TextStyle(
      fontSize: 12.5,
      color: cs.onSurface.withAlpha(n.closed ? 140 : 220),
    );
    final rendered = n.locked
        ? RenderedSpans(
            [TextSpan(text: 'Locked note', style: titleStyle)], const [])
        : buildNoteSpans(n.preview, titleStyle, cs.primary, hideMarkers: true);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      child: Row(children: [
        // 拖拽排序手柄
        ReorderableDragStartListener(
          index: index,
          child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(Icons.drag_indicator,
                  size: 14, color: cs.onSurface.withAlpha(90)),
            ),
          ),
        ),
        // 便签色块
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: n.color.body(brightness),
            borderRadius: BorderRadius.circular(3.5),
            border: Border.all(color: n.color.title(brightness), width: 1.6),
          ),
          child: n.locked
              ? Icon(Icons.lock, size: 9, color: n.color.title(brightness))
              : null,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(
            TextSpan(children: rendered.spans),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (n.locked) ...[
          Icon(Icons.lock, size: 12, color: cs.onSurface.withAlpha(130)),
          const SizedBox(width: 6),
        ],
        if (hasReminder) ...[
          Icon(Icons.alarm, size: 12, color: cs.primary),
          const SizedBox(width: 6),
        ],
        if (isOpen)
          Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
            decoration: BoxDecoration(
              color: cs.primary.withAlpha(36),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('Active',
                style: TextStyle(fontSize: 10, color: cs.primary)),
          ),
        Text(_fmtTime(n.updatedAt),
            style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(110))),
        const SizedBox(width: 6),
        _IconBtn(
          icon: Icons.open_in_new,
          tooltip: 'Open',
          onTap: () => _open(n),
        ),
        _IconBtn(
          icon: n.locked ? Icons.lock_outline : Icons.delete_outline,
          tooltip: n.locked ? 'Unlock in the note first' : 'Delete',
          color: n.locked
              ? cs.onSurface.withAlpha(80)
              : cs.error.withAlpha(200),
          onTap: () => _delete(n),
        ),
      ]),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback? onTap;
  const _ActionChip(
      {required this.icon, required this.label, this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = onTap == null
        ? cs.onSurface.withAlpha(70)
        : (color ?? cs.onSurface.withAlpha(179));
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: cs.onSurface.withAlpha(12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: c),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11.5, color: c)),
        ]),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color? color;
  final VoidCallback onTap;
  const _IconBtn(
      {required this.icon,
      required this.tooltip,
      this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child:
              Icon(icon, size: 15, color: color ?? cs.onSurface.withAlpha(150)),
        ),
      ),
    );
  }
}
