library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/command/user_command_service.dart';
import '../../core/picker/picker_service.dart';
import '../../core/theme/theme_colors.dart';

/// Tab content: user command management with drag-to-reorder,
/// enable/disable toggle, edit, delete, and add.
class CommandsTab extends StatefulWidget {
  final UserCommandService service;
  final List<UserCommand> commands;
  final VoidCallback onChanged;
  const CommandsTab({
    super.key,
    required this.service,
    required this.commands,
    required this.onChanged,
  });
  @override State<CommandsTab> createState() => _CommandsTabState();
}

class _CommandsTabState extends State<CommandsTab> {
  late List<UserCommand> _list;

  @override void initState() {
    super.initState();
    _list = _sortCommands(widget.commands.map((c) => c.copy()).toList());
  }

  @override void didUpdateWidget(covariant CommandsTab old) {
    super.didUpdateWidget(old);
    if (widget.commands != old.commands) {
      _list = _sortCommands(widget.commands.map((c) => c.copy()).toList());
    }
  }

  /// Script commands always appear before regular commands.
  static List<UserCommand> _sortCommands(List<UserCommand> list) {
    list.sort((a, b) {
      if (a.type == 'script' && b.type != 'script') return -1;
      if (a.type != 'script' && b.type == 'script') return 1;
      return 0;
    });
    return list;
  }

  Future<void> _toggle(int i) async {
    setState(() => _list[i].enabled = !_list[i].enabled);
    await widget.service.saveCommands(_list);
    widget.onChanged();
  }

  Future<void> _delete(int i) async {
    final cs = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => AlertDialog(
        backgroundColor: XMateColors.dialogBg(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: cs.primary.withAlpha(40))),
        title: Text('Delete command', style: TextStyle(color: cs.onSurface)),
        content: Text('Remove "${_list[i].name}"?', style: TextStyle(color: cs.onSurface.withAlpha(179))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok == true) {
      setState(() => _list.removeAt(i));
      await widget.service.saveCommands(_list);
      widget.onChanged();
    }
  }

  Future<void> _edit(int? index) async {
    final cmd = index != null ? _list[index].copy() : UserCommand(
      id: 'user_${DateTime.now().millisecondsSinceEpoch}',
      keyword: '',
      name: '',
      path: '',
    );
    final result = await showDialog<UserCommand>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => _CommandEditorDialog(command: cmd),
    );
    if (result != null) {
      setState(() {
        if (index != null) {
          _list[index] = result;
        } else {
          _list.add(result);
        }
      });
      await widget.service.saveCommands(_list);
      widget.onChanged();
    }
  }

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(children: [
          Text('No commands configured', style: TextStyle(color: cs.onSurface.withAlpha(138), fontSize: 13)),
          const SizedBox(height: 12),
          _buildAddButton(),
        ]),
      );
    }

    return Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 10, 4),
        child: Row(children: [
          const Spacer(),
          _buildAddButton(),
        ]),
      ),
      Flexible(
        child: ExcludeSemantics(child: ReorderableListView.builder(
          shrinkWrap: true,
          itemCount: _list.length,
          buildDefaultDragHandles: false,
          onReorderItem: (oldIdx, newIdx) {
            setState(() {
              final item = _list.removeAt(oldIdx);
              _list.insert(newIdx, item);
            });
            widget.service.saveCommands(_list);
            widget.onChanged();
          },
          itemBuilder: (_, i) {
            final c = _list[i];
            final isScript = c.type == 'script';
            return Padding(
              key: ValueKey('cmd_${c.id}'),
              padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
              child: Container(
                decoration: BoxDecoration(
                  color: isScript
                      ? cs.primary.withAlpha(15)
                      : XMateColors.cardFill(context),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.only(left: 8, right: 4, top: 10, bottom: 10),
                child: Row(children: [
                  ReorderableDragStartListener(
                    index: i,
                    child: Icon(Icons.drag_indicator, size: 16, color: cs.onSurface.withAlpha(77)),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Text(c.name, style: TextStyle(color: cs.onSurface, fontSize: 14, fontWeight: FontWeight.w500)),
                        if (c.keyword.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Text(c.keyword, style: TextStyle(color: cs.primary, fontSize: 13, fontWeight: FontWeight.w500)),
                        ],
                      ]),
                      const SizedBox(height: 2),
                      Text(
                        c.path + (c.args.isNotEmpty ? ' ${c.args}' : ''),
                        style: TextStyle(color: cs.onSurface.withAlpha(138), fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ]),
                  ),
                  if (c.shortcut.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(right: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: cs.primary.withAlpha(30),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(c.shortcut, style: TextStyle(color: cs.primary, fontSize: 9)),
                    ),
                  if (isScript)
                    Container(
                      margin: const EdgeInsets.only(right: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: cs.primary.withAlpha(40),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('script', style: TextStyle(color: cs.primary, fontSize: 10)),
                    )
                  else ...[
                    if (c.runAsAdmin)
                      Container(
                        margin: const EdgeInsets.only(right: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: cs.primary.withAlpha(40),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('admin', style: TextStyle(color: cs.primary, fontSize: 10)),
                      ),
                    if (c.runSilently)
                      Container(
                        margin: const EdgeInsets.only(right: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: XMateColors.divider(context),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('silent', style: TextStyle(color: cs.onSurface.withAlpha(138), fontSize: 10)),
                      ),
                  ],
                  SizedBox(
                    height: 28,
                    child: Transform.scale(
                      scale: 0.7,
                      child: Switch(
                        value: c.enabled,
                        onChanged: (_) => _toggle(i),
                        activeTrackColor: cs.primary,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.edit, size: 16, color: cs.onSurface.withAlpha(138)),
                    tooltip: 'Edit',
                    onPressed: () => _edit(i),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                  if (!c.builtin)
                    IconButton(
                      icon: Icon(Icons.delete_outline, size: 16, color: cs.onSurface.withAlpha(97)),
                      tooltip: 'Delete',
                      onPressed: () => _delete(i),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                ]),
              ),
            );
          },
        ),
        ),
      ),
    ]);
  }

  Widget _buildAddButton() {
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      icon: Icon(Icons.add, color: cs.primary, size: 22),
      tooltip: 'Add command',
      onPressed: () => _edit(null),
    );
  }
}

// ─── Command Editor Dialog ───

class _CommandEditorDialog extends StatefulWidget {
  final UserCommand command;
  const _CommandEditorDialog({required this.command});
  @override State<_CommandEditorDialog> createState() => _CommandEditorDialogState();
}

class _CommandEditorDialogState extends State<_CommandEditorDialog> {
  late final TextEditingController _keywordCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _shortcutCtrl;
  late final TextEditingController _pathCtrl;
  late final TextEditingController _argsCtrl;
  late final TextEditingController _wdCtrl;
  late bool _runAsAdmin;
  late bool _runSilently;
  final _shortcutFocus = FocusNode();
  bool _captureShortcut = false;

  @override void initState() {
    super.initState();
    _keywordCtrl = TextEditingController(text: widget.command.keyword);
    _nameCtrl = TextEditingController(text: widget.command.name);
    _shortcutCtrl = TextEditingController(text: widget.command.shortcut);
    _pathCtrl = TextEditingController(text: widget.command.path);
    _argsCtrl = TextEditingController(text: widget.command.args);
    _wdCtrl = TextEditingController(text: widget.command.workingDirectory);
    _runAsAdmin = widget.command.runAsAdmin;
    _runSilently = widget.command.runSilently;
  }

  @override void dispose() {
    _keywordCtrl.dispose();
    _nameCtrl.dispose();
    _shortcutCtrl.dispose();
    _pathCtrl.dispose();
    _argsCtrl.dispose();
    _wdCtrl.dispose();
    _shortcutFocus.dispose();
    super.dispose();
  }

  void _onShortcutKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.enter) {
      setState(() => _captureShortcut = false);
      _shortcutFocus.unfocus();
      return;
    }
    if (!_captureShortcut) return;
    if (k == LogicalKeyboardKey.controlLeft || k == LogicalKeyboardKey.controlRight ||
        k == LogicalKeyboardKey.shiftLeft || k == LogicalKeyboardKey.shiftRight ||
        k == LogicalKeyboardKey.altLeft || k == LogicalKeyboardKey.altRight ||
        k == LogicalKeyboardKey.metaLeft || k == LogicalKeyboardKey.metaRight) {
      return;
    }
    final parts = <String>[];
    if (HardwareKeyboard.instance.isControlPressed) parts.add('Ctrl');
    if (HardwareKeyboard.instance.isShiftPressed) parts.add('Shift');
    if (HardwareKeyboard.instance.isAltPressed) parts.add('Alt');
    if (HardwareKeyboard.instance.isMetaPressed) parts.add('Win');
    parts.add(k.keyLabel);
    _shortcutCtrl.text = parts.join('+');
    _shortcutCtrl.selection = TextSelection.collapsed(offset: _shortcutCtrl.text.length);
  }

  Future<void> _pickFolder() async {
    final path = await PickerService().pickFolder();
    if (path != null && path.isNotEmpty) {
      _wdCtrl.text = path;
    }
  }

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isScript = widget.command.type == 'script';
    return AlertDialog(
      backgroundColor: XMateColors.dialogBg(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: cs.primary.withAlpha(40))),
      title: Text(
        widget.command.name.isEmpty ? 'Add Command' : 'Edit Command',
        style: TextStyle(color: cs.onSurface, fontSize: 16),
      ),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _compactField('Keyword', _keywordCtrl, cs, required: true),
          const SizedBox(height: 8),
          _compactField('Name', _nameCtrl, cs, required: true),
          const SizedBox(height: 8),
          _compactShortcutField(cs),
          if (!isScript) ...[
            const SizedBox(height: 8),
            _compactField('Path / URL', _pathCtrl, cs, required: true),
            const SizedBox(height: 8),
            _compactField('Arguments', _argsCtrl, cs),
            const SizedBox(height: 8),
            _compactField('Working directory', _wdCtrl, cs, showFolderPicker: true),
            const SizedBox(height: 12),
            Row(children: [
              Text('Run as administrator', style: TextStyle(color: cs.onSurface, fontSize: 12)),
              const Spacer(),
              SizedBox(
                height: 28,
                child: Transform.scale(
                  scale: 0.7,
                  child: Switch(
                    value: _runAsAdmin,
                    onChanged: (v) => setState(() => _runAsAdmin = v),
                    activeTrackColor: cs.primary,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              Text('Run silently', style: TextStyle(color: cs.onSurface, fontSize: 12)),
              const Spacer(),
              SizedBox(
                height: 28,
                child: Transform.scale(
                  scale: 0.7,
                  child: Switch(
                    value: _runSilently,
                    onChanged: (v) => setState(() => _runSilently = v),
                    activeTrackColor: cs.primary,
                  ),
                ),
              ),
            ]),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel', style: TextStyle(color: cs.onSurface.withAlpha(97)))),
        TextButton(
          onPressed: () {
            final keyword = _keywordCtrl.text.trim();
            final path = isScript ? widget.command.path : _pathCtrl.text.trim();
            if (keyword.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Keyword is required'),
                  backgroundColor: Colors.redAccent,
                ),
              );
              return;
            }
            if (!isScript && path.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Keyword and Path are required'),
                  backgroundColor: Colors.redAccent,
                ),
              );
              return;
            }
            Navigator.pop(context, widget.command.copy()
              ..keyword = keyword
              ..name = _nameCtrl.text.trim()
              ..shortcut = _shortcutCtrl.text.trim()
              ..path = path
              ..args = isScript ? widget.command.args : _argsCtrl.text.trim()
              ..workingDirectory = isScript ? widget.command.workingDirectory : _wdCtrl.text.trim()
              ..runAsAdmin = isScript ? widget.command.runAsAdmin : _runAsAdmin
              ..runSilently = isScript ? widget.command.runSilently : _runSilently);
          },
          child: Text('OK', style: TextStyle(color: cs.primary)),
        ),
      ],
    );
  }

  Widget _compactShortcutField(ColorScheme cs) {
    return Focus(
      focusNode: _shortcutFocus,
      onFocusChange: (focused) { if (focused) setState(() => _captureShortcut = true); },
      onKeyEvent: (_, event) { _onShortcutKey(event); return KeyEventResult.handled; },
      child: Row(children: [
        SizedBox(width: 90, child: Text('Shortcut', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(138)))),
        Expanded(
          child: SizedBox(
            height: 30,
            child: TextField(
              controller: _shortcutCtrl, readOnly: true,
              style: TextStyle(color: cs.onSurface, fontSize: 12),
              decoration: InputDecoration(
                hintText: _captureShortcut ? 'Press keys...' : 'Click to capture',
                hintStyle: TextStyle(color: _captureShortcut ? cs.primary : cs.onSurface.withAlpha(61), fontSize: 11),
                filled: true,
                fillColor: XMateColors.inputFill(context),
                border: const OutlineInputBorder(),
                isDense: true, isCollapsed: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _compactField(String label, TextEditingController ctrl, ColorScheme cs, {bool required = false, bool showFolderPicker = false}) {
    return Row(children: [
      SizedBox(width: 90, child: Text(required ? '$label *' : label, style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(138)))),
      Expanded(
        child: SizedBox(
          height: 30,
          child: TextField(
            controller: ctrl,
            style: TextStyle(color: cs.onSurface, fontSize: 12),
            decoration: InputDecoration(
              filled: true,
              fillColor: XMateColors.inputFill(context),
              border: const OutlineInputBorder(),
              isDense: true, isCollapsed: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              suffixIcon: showFolderPicker
                  ? GestureDetector(
                      onTap: _pickFolder,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.folder_open, size: 16, color: cs.primary),
                      ),
                    )
                  : null,
            ),
          ),
        ),
      ),
    ]);
  }

}
