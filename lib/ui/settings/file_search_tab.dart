/// XMate Settings — File Search tab.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/search/file_index_config.dart';
import '../../core/search/file_search_service.dart';
import '../../core/search/file_search_filter.dart';
import '../../core/search/file_search_priority.dart';
import '../../core/command/file_submenu_service.dart';
import '../../core/command/file_submenu_item.dart';
import '../../core/search/file_search_channel.dart';
import '../../core/theme/theme_colors.dart';

class FileSearchTab extends StatefulWidget {
  const FileSearchTab({super.key});
  @override State<FileSearchTab> createState() => _FileSearchTabState();
}

class _FileSearchTabState extends State<FileSearchTab> with SingleTickerProviderStateMixin {
  final _service = FileSearchService();
  final _channel = FileSearchChannel();
  final Map<String, TextEditingController> _customCtrls = {};
  List<FileSearchFilter> _customFilters = [];
  List<PriorityRule> _priorityRules = [];
  List<SegmentInfo> _segments = [];
  bool _loading = false;
  String _statusText = '';
  bool _showLog = false;
  bool _showRules = false;
  bool _svcInstalled = false;
  bool _svcRunning = false;
  late final _tabCtrl = TabController(length: 4, vsync: this);

  @override void initState() {
    super.initState();
    _customFilters = _service.getActiveFilters().toList();
    _priorityRules = _service.getActivePriorityRules().toList();
    _refresh();
  }
  @override void dispose() {
    for (final c in _customCtrls.values) { c.dispose(); }
    _tabCtrl.dispose();
    super.dispose();
  }

  void _refresh() {
    setState(() => _segments = _service.getSegmentInfos());
    _refreshSvcStatus();
  }

  Future<void> _refreshSvcStatus() async {
    final installed = await _channel.isIndexerServiceInstalled();
    final running = installed ? await _channel.isIndexerServiceRunning() : false;
    if (mounted) setState(() { _svcInstalled = installed; _svcRunning = running; });
  }

  Future<void> _pickFolder() async {
    try {
      const ch = MethodChannel('com.xmate/filesearch');
      final p = await ch.invokeMethod<String>('pickFolder');
      if (p != null && p.isNotEmpty) { _service.addIndexPath(p); _refresh(); }
    } catch (_) {}
  }
  Future<void> _removePath(String p) async { await _service.removeIndexPath(p); _refresh(); }

  Future<void> _rebuildPath(String p) async {
    setState(() => _loading = true); final msgs = <String>[];
    await for (final m in _service.rebuildPath(p)) { msgs.add(m); setState(() => _statusText = msgs.join('\n')); }
    setState(() => _loading = false); _refresh();
  }
  Future<void> _updatePath(String p) async {
    setState(() => _loading = true); final msgs = <String>[];
    await for (final m in _service.manualUpdatePath(p)) { msgs.add(m); setState(() => _statusText = msgs.join('\n')); }
    setState(() => _loading = false); _refresh();
  }
  Future<void> _rebuildAll() async {
    setState(() => _loading = true); final msgs = <String>[];
    await for (final m in _service.rebuildAll()) { msgs.add(m); setState(() => _statusText = msgs.join('\n')); }
    setState(() => _loading = false); _refresh();
  }
  Future<void> _updateAll() async {
    setState(() => _loading = true); final msgs = <String>[];
    await for (final m in _service.updateAll()) { msgs.add(m); setState(() => _statusText = msgs.join('\n')); }
    setState(() => _loading = false); _refresh();
  }

  Future<void> _svcAction(String action) async {
    setState(() => _loading = true);
    bool ok = false;
    String msg = '';
    switch (action) {
      case 'install':
        ok = await _channel.installIndexerService();
        msg = ok ? 'Installing (UAC prompted)...' : 'Install failed.';
        break;
      case 'uninstall':
        ok = await _channel.uninstallIndexerService();
        msg = ok ? 'Uninstalling (UAC prompted)...' : 'Uninstall failed.';
        break;
    }
    setState(() => _loading = false);
    if (mounted) setState(() => _statusText = msg);
    // Install/uninstall launch an elevated helper that runs async.
    // Poll until the status actually changes (up to 15 seconds).
    if (action == 'install' || action == 'uninstall') {
      final target = action == 'install';
      for (int i = 0; i < 30 && mounted; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        await _refreshSvcStatus();
        if (mounted && (target ? _svcInstalled : !_svcInstalled)) {
          setState(() => _statusText = target ? 'Service installed.' : 'Service uninstalled.');
          break;
        }
      }
    } else {
      _refreshSvcStatus();
    }
  }

  void _setInterval(String rp, String mode, [String? customVal]) {
    int mins;
    switch (mode) {
      case 'auto': mins = -1; break;
      case 'off': mins = 0; break;
      case 'custom':
        final v = (customVal ?? '').trim().toLowerCase();
        if (v.isEmpty) { mins = 0; break; }
        if (v.endsWith('h')) {
          mins = (double.tryParse(v.substring(0, v.length - 1)) ?? 0).round() * 60;
        } else if (v.endsWith('m')) {
          mins = (double.tryParse(v.substring(0, v.length - 1)) ?? 0).round();
        } else {
          mins = int.tryParse(v) ?? 0;
        }
        if (mins <= 0) mins = 0;
        break;
      default: mins = 0;
    }
    _service.setPerPathInterval(rp, mins);
    _refresh();
  }

  String _modeForInterval(int v) => v == -1 ? 'auto' : v == 0 ? 'off' : 'custom';
  String _customValForInterval(int v) {
    if (v <= 0) return '';
    if (v >= 60 && v % 60 == 0) return '${v ~/ 60}h';
    return '${v}m';
  }

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      // Sub-tab bar — use our own TabController, not the ancestor DefaultTabController
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
        child: TabBar(
          controller: _tabCtrl,
          isScrollable: false,
          labelColor: cs.primary,
          unselectedLabelColor: cs.onSurface.withAlpha(138),
          indicatorColor: cs.primary,
          indicatorSize: TabBarIndicatorSize.label,
          labelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          unselectedLabelStyle: const TextStyle(fontSize: 11),
          tabs: const [
            Tab(text: 'Index'),
            Tab(text: 'Filters'),
            Tab(text: 'Priority'),
            Tab(text: 'Submenu'),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: TabBarView(
          controller: _tabCtrl,
          children: [
            _buildIndexPane(),
            _buildFiltersPane(),
            _buildPriorityPane(),
            _buildSubmenuPane(),
          ],
        ),
      ),
    ]);
  }

  Widget _buildIndexPane() {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _SectionLabel('Index Directories', icon: Icons.folder),
        Row(children: [
          _MiniBtn('Rebuild All', _rebuildAll, loading: _loading), const SizedBox(width: 8),
          _MiniBtn('Update All', _updateAll, loading: _loading), const SizedBox(width: 8),
          _MiniBtn(_showLog ? 'Hide Log' : 'Show Log', () => setState(() => _showLog = !_showLog)),
          const Spacer(),
          IconButton(
            icon: Icon(Icons.add, color: cs.primary, size: 22),
            tooltip: 'Add directory',
            onPressed: _pickFolder,
          ),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _svcRunning ? const Color(0x3366CC66) : const Color(0x33FFFFFF),
              borderRadius: BorderRadius.circular(4)),
            child: Text(
              _svcRunning ? 'Index Update Service: Running' : _svcInstalled ? 'Index Update Service: Stopped' : 'Index Update Service: Not Installed',
              style: TextStyle(fontSize: 11,
                color: _svcRunning ? const Color(0xFF66CC66) : _svcInstalled ? cs.onSurface.withAlpha(138) : cs.onSurface.withAlpha(97))),
          ),
          const Spacer(),
          if (!_svcInstalled)
            _MiniBtn('Install', () => _svcAction('install'), loading: _loading)
          else
            _MiniBtn('Uninstall', () => _svcAction('uninstall'), loading: _loading),
        ]),
        const SizedBox(height: 10),
        if (_segments.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('No directories configured.',
                style: TextStyle(color: cs.onSurface.withAlpha(97), fontSize: 12))),
        for (final seg in _segments)
          _SegmentCard(
            seg: seg, loading: _loading,
            interval: _service.getPerPathInterval(seg.rootPath),
            mode: _modeForInterval(_service.getPerPathInterval(seg.rootPath)),
            customVal: _customValForInterval(_service.getPerPathInterval(seg.rootPath)),
            customCtrl: _getCustomCtrl(seg.rootPath),
            onRebuild: () => _rebuildPath(seg.rootPath),
            onUpdate: () => _updatePath(seg.rootPath),
            onRemove: () => _removePath(seg.rootPath),
            onModeChanged: (m, [v]) => _setInterval(seg.rootPath, m, v),
          ),
        if (_showLog) ...[
          const SizedBox(height: 8),
          Container(width: double.infinity, padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.black.withAlpha(80), borderRadius: BorderRadius.circular(6)),
            child: _buildLogContent()),
        ],
      ]),
    );
  }

  Widget _buildFiltersPane() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _SectionLabel('Search Filters', icon: Icons.filter_list),
        _buildFilterSection(),
      ]),
    );
  }

  Widget _buildPriorityPane() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _SectionLabel('Priority Rules', icon: Icons.low_priority),
        _buildPrioritySection(),
      ]),
    );
  }

  Widget _buildSubmenuPane() {
    final cs = Theme.of(context).colorScheme;
    final fsService = FileSubmenuService();
    final allItems = fsService.loadAllItems();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _SectionLabel('Actions', icon: Icons.playlist_play),
        if (allItems.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('No actions configured.',
                style: TextStyle(color: cs.onSurface.withAlpha(97), fontSize: 12))),
        ExcludeSemantics(child: ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: allItems.length,
          onReorderItem: (oldIdx, newIdx) {
            setState(() {
              final item = allItems.removeAt(oldIdx);
              allItems.insert(newIdx, item);
              for (int i = 0; i < allItems.length; i++) {
                allItems[i] = _copyWithSortOrder(allItems[i], i);
              }
              fsService.saveItems(allItems);
            });
          },
          itemBuilder: (_, i) => _buildSubmenuRow(allItems[i], i, fsService, allItems, cs),
        ),
        ),
        const SizedBox(height: 8),
        _MiniBtn('Add Custom Action', () => _editFileSubmenuItem(null, cs)),
      ]),
    );
  }

  static FileSubMenuItem _copyWithSortOrder(FileSubMenuItem item, int order) {
    return switch (item) {
      BuiltinFileAction b => b.copyWith(sortOrder: order),
      CustomFileAction c => CustomFileAction(
          id: c.id, title: c.title, shortcut: c.shortcut,
          path: c.path, args: c.args, workingDirectory: c.workingDirectory,
          runAsAdmin: c.runAsAdmin, runSilently: c.runSilently, sortOrder: order),
    };
  }

  Widget _buildSubmenuRow(FileSubMenuItem item, int index,
      FileSubmenuService fsService, List<FileSubMenuItem> allItems, ColorScheme cs) {
    final isBuiltin = item is BuiltinFileAction;
    final b = item is BuiltinFileAction ? item : null;
    return Container(
      key: ValueKey(isBuiltin ? b!.kind.name : (item as CustomFileAction).id),
      margin: const EdgeInsets.only(bottom: 3),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(color: isBuiltin && !b!.enabled
          ? XMateColors.cardFill(context).withAlpha(3)
          : XMateColors.cardFill(context),
          borderRadius: BorderRadius.circular(6)),
      child: Row(children: [
        ReorderableDragStartListener(index: index,
          child: Icon(Icons.drag_handle, size: 16, color: cs.onSurface.withAlpha(61))),
        const SizedBox(width: 4),
        // Builtin: enable/disable toggle
        if (isBuiltin)
          GestureDetector(
            onTap: () {
              b.enabled = !b.enabled;
              setState(() {});
              fsService.saveItems(allItems);
            },
            child: Icon(
              b!.enabled ? Icons.toggle_on : Icons.toggle_off, size: 18,
              color: b.enabled ? cs.primary : cs.onSurface.withAlpha(61),
            ),
          ),
        const SizedBox(width: 4),
        Icon(item.icon, size: 14,
            color: isBuiltin ? (b!.enabled ? cs.primary : cs.onSurface.withAlpha(61)) : cs.onSurface.withAlpha(138)),
        const SizedBox(width: 6),
        Expanded(child: Text(item.title, style: TextStyle(fontSize: 11,
            color: isBuiltin ? (b!.enabled ? cs.primary : cs.onSurface.withAlpha(61)) : cs.onSurface))),
        if (item.shortcut.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(right: 4),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(color: cs.primary.withAlpha(isBuiltin && !b!.enabled ? 10 : 30),
                borderRadius: BorderRadius.circular(3)),
            child: Text(item.shortcut, style: TextStyle(fontSize: 9,
                color: isBuiltin && !b!.enabled ? cs.primary.withAlpha(100) : cs.primary)),
          ),
        SizedBox(width: 24, height: 24,
          child: IconButton(icon: const Icon(Icons.edit, size: 13),
              color: cs.primary, onPressed: () => _editFileSubmenuItem(item, cs), padding: EdgeInsets.zero)),
        if (!isBuiltin)
          SizedBox(width: 24, height: 24,
            child: IconButton(icon: const Icon(Icons.close, size: 14),
                color: Colors.redAccent.withAlpha(180), onPressed: () {
              setState(() {
                allItems.removeAt(index);
                fsService.saveItems(allItems);
              });
            }, padding: EdgeInsets.zero)),
      ]),
    );
  }

  Future<void> _editFileSubmenuItem(FileSubMenuItem? item, ColorScheme cs) async {
    final fsService = FileSubmenuService();
    if (item is CustomFileAction || item == null) {
      final result = await showDialog<CustomFileAction>(
        context: context, barrierColor: Colors.transparent,
        builder: (_) => _CustomActionEditorDialog(existing: item as CustomFileAction?),
      );
      if (result == null) return;
      final allItems = fsService.loadAllItems();
      if (item != null) {
        final cItem = item as CustomFileAction;
        final idx = allItems.indexWhere((i) => i is CustomFileAction && i.id == cItem.id);
        if (idx >= 0) allItems[idx] = result;
      } else {
        allItems.add(result);
      }
      await fsService.saveItems(allItems);
      setState(() {});
    } else {
      final builtin = item as BuiltinFileAction;
      final ctrl = TextEditingController(text: builtin.shortcut);
      final node = FocusNode();
      bool capturing = true;
      // Use a StatefulWidget dialog to handle capture state properly
      final newShortcut = await showDialog<String>(
        context: context, barrierColor: Colors.transparent,
        builder: (ctx) => StatefulBuilder(builder: (ctx2, setDialog) {
          final dlgCs = Theme.of(ctx).colorScheme;
          return AlertDialog(
            backgroundColor: XMateColors.toolbarBg(ctx),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: dlgCs.primary.withAlpha(40))),
            title: Text('Edit shortcut — ${builtin.title}',
                style: TextStyle(color: dlgCs.onSurface, fontSize: 16)),
            content: SizedBox(width: 300, child: Focus(
              focusNode: node,
              onKeyEvent: (_, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                if (!capturing) return KeyEventResult.ignored;
                final k = event.logicalKey;
                if (k == LogicalKeyboardKey.escape) { Navigator.of(ctx).pop(); return KeyEventResult.handled; }
                if (k == LogicalKeyboardKey.enter) { capturing = false; node.unfocus(); return KeyEventResult.handled; }
                if (k == LogicalKeyboardKey.controlLeft || k == LogicalKeyboardKey.controlRight ||
                    k == LogicalKeyboardKey.shiftLeft || k == LogicalKeyboardKey.shiftRight ||
                    k == LogicalKeyboardKey.altLeft || k == LogicalKeyboardKey.altRight ||
                    k == LogicalKeyboardKey.metaLeft || k == LogicalKeyboardKey.metaRight) {
                  return KeyEventResult.ignored;
                }
                final parts = <String>[];
                if (HardwareKeyboard.instance.isControlPressed) parts.add('Ctrl');
                if (HardwareKeyboard.instance.isShiftPressed) parts.add('Shift');
                if (HardwareKeyboard.instance.isAltPressed) parts.add('Alt');
                if (HardwareKeyboard.instance.isMetaPressed) parts.add('Win');
                parts.add(k.keyLabel);
                ctrl.text = parts.join('+');
                return KeyEventResult.handled;
              },
              child: TextField(
                controller: ctrl, autofocus: true, readOnly: true,
                style: TextStyle(color: dlgCs.onSurface, fontSize: 14, fontFamily: 'monospace'),
                decoration: InputDecoration(
                    hintText: 'Press keys...',
                    hintStyle: TextStyle(color: dlgCs.primary, fontSize: 14),
                    filled: true, fillColor: dlgCs.primary.withAlpha(20),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: dlgCs.primary))),
              ),
            )),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(),
                  child: Text('Cancel', style: TextStyle(color: dlgCs.onSurface.withAlpha(97)))),
              TextButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
                  child: Text('Save', style: TextStyle(color: dlgCs.primary))),
            ],
          );
        }),
      );
      node.dispose();
      ctrl.dispose();
      if (newShortcut == null) return;
      final allItems = fsService.loadAllItems();
      final idx = allItems.indexWhere((i) => i is BuiltinFileAction && i.kind == builtin.kind);
      if (idx >= 0) {
        final b = allItems[idx] as BuiltinFileAction;
        allItems[idx] = b.copyWith(shortcut: newShortcut);
      }
      await fsService.saveItems(allItems);
      setState(() {});
    }
  }

  /// Combined log: manual operation output + auto background events.
  Widget _buildLogContent() {
    final cs = Theme.of(context).colorScheme;
    final logEntries = _service.autoLog;
    final children = <Widget>[];
    // Manual operation output
    if (_statusText.isNotEmpty) {
      for (final line in _statusText.split('\n')) {
        children.add(Text(line, style: TextStyle(color: cs.onSurface.withAlpha(138), fontSize: 11, fontFamily: 'monospace')));
      }
      if (logEntries.isNotEmpty) {
        children.add(const SizedBox(height: 4));
        children.add(Divider(color: XMateColors.divider(context), height: 1));
        children.add(const SizedBox(height: 4));
      }
    }
    // Auto log (newest first)
    for (int i = logEntries.length - 1; i >= 0; i--) {
      final e = logEntries[i];
      final ts = '${e.time.hour.toString().padLeft(2, '0')}:'
          '${e.time.minute.toString().padLeft(2, '0')}:'
          '${e.time.second.toString().padLeft(2, '0')}';
      children.add(Text(
        '[$ts] ${e.message}',
        style: TextStyle(color: cs.primary, fontSize: 10, fontFamily: 'monospace'),
      ));
    }
    if (children.isEmpty) {
      children.add(Text('Log will appear here...',
          style: TextStyle(color: cs.onSurface.withAlpha(77), fontSize: 11)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  TextEditingController _getCustomCtrl(String rp) {
    final v = _customValForInterval(_service.getPerPathInterval(rp));
    return _customCtrls.putIfAbsent(rp, () => TextEditingController(text: v));
  }

  // ── Filter management ──

  Widget _buildFilterSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (int i = 0; i < _customFilters.length; i++)
        _buildFilterRow(_customFilters[i],
          onEdit: () => _editFilter(i),
          onDelete: (_customFilters[i].isBuiltin &&
              (_customFilters[i].keyword == 'folder' || _customFilters[i].keyword == 'map'))
              ? null
              : () => _deleteFilter(i),
        ),
      const SizedBox(height: 6),
      _MiniBtn('Add Filter', () => _editFilter(-1)),
    ]);
  }

  Widget _buildFilterRow(FileSearchFilter f, {
    required VoidCallback onEdit,
    required VoidCallback? onDelete,
  }) {
    final cs = Theme.of(context).colorScheme;
    final undeletable = onDelete == null;
    return Container(
      margin: const EdgeInsets.only(bottom: 4), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(color: XMateColors.cardFill(context), borderRadius: BorderRadius.circular(6)),
      child: Row(children: [
        if (undeletable)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(Icons.lock, size: 12, color: cs.onSurface.withAlpha(97)),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color: cs.primary.withAlpha(40),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(f.keyword,
              style: TextStyle(fontSize: 10, color: cs.primary)),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(f.name, style: TextStyle(fontSize: 11, color: cs.onSurface))),
        if (f.extensions.isNotEmpty)
          Text('${f.extensions.length} exts', style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(97))),
        if (f.path != null && f.path!.isNotEmpty)
          Icon(Icons.folder, size: 12, color: cs.onSurface.withAlpha(97)),
        if (f.regex != null && f.regex!.isNotEmpty)
          Icon(Icons.code, size: 12, color: cs.onSurface.withAlpha(97)),
        const SizedBox(width: 4),
        SizedBox(width: 24, height: 24,
          child: IconButton(icon: const Icon(Icons.edit, size: 13),
              color: cs.primary, onPressed: onEdit, padding: EdgeInsets.zero)),
        if (onDelete != null)
          SizedBox(width: 24, height: 24,
            child: IconButton(icon: const Icon(Icons.close, size: 14),
                color: Colors.redAccent.withAlpha(180), onPressed: onDelete, padding: EdgeInsets.zero))
        else
          const SizedBox(width: 24, height: 24),
      ]),
    );
  }

  Future<void> _editFilter(int index) async {
    final existing = index >= 0 && index < _customFilters.length ? _customFilters[index] : null;
    final result = await showDialog<FileSearchFilter>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (_) => _FilterEditorDialog(existing: existing),
    );
    if (result == null) return;
    // Validate keyword uniqueness (excluding self)
    final keyword = result.keyword;
    if (_customFilters.asMap().entries.any((e) => e.value.keyword == keyword && e.key != index)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Keyword "$keyword" already in use. Pick a different one.'),
              backgroundColor: Colors.redAccent),
        );
      }
      return;
    }
    // Preserve isBuiltin flag when editing a builtin filter
    final saved = existing != null && existing.isBuiltin
        ? FileSearchFilter(
            keyword: result.keyword,
            name: result.name,
            path: result.path,
            extensions: result.extensions,
            regex: result.regex,
            isBuiltin: true,
          )
        : result;
    setState(() {
      if (existing != null) {
        _customFilters[index] = saved;
      } else {
        _customFilters.add(saved);
      }
      _service.saveFilters(_customFilters);
    });
  }

  void _deleteFilter(int index) {
    setState(() {
      _customFilters.removeAt(index);
      _service.saveFilters(_customFilters);
    });
  }

  // ── Priority rule management ──

  Widget _buildPrioritySection() {
    final groups = <PriorityLevel, List<int>>{};
    for (int i = 0; i < _priorityRules.length; i++) {
      final r = _priorityRules[i];
      groups.putIfAbsent(r.level, () => []).add(i);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final level in PriorityLevel.values)
        _buildPriorityGroup(level, groups[level] ?? []),
      const SizedBox(height: 6),
      Row(children: [
        _MiniBtn('Add Rule', () => _editPriorityRule(-1)),
        const SizedBox(width: 8),
        _MiniBtn('Rules', () => setState(() => _showRules = !_showRules)),
      ]),
      if (_showRules) _buildRulesPanel(),
    ]);
  }

  Widget _buildRulesPanel() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: XMateColors.cardFill(context),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header
        Text('How Search Results Are Ranked',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.primary)),
        const SizedBox(height: 10),

        // Base score
        _rulesSection('Base Score',
          'Each file gets a base score from four things:\n'
          '  • Search keyword match — how well the filename matches what you typed.\n'
          '  • Pinyin match — if you type Chinese, matches pinyin initials too.\n'
          '  • Depth bonus — files closer to the index root rank higher.\n'
          '  • Recent opens — files you\'ve opened recently get a boost.',
        ),
        const SizedBox(height: 10),

        // Priority rules
        _rulesSection('Priority Rules',
          'After the base score, priority rules can adjust it:\n'
          '  • Prefer — adds +0.50 to the score. Use for folders you want higher.\n'
          '  • Uncommon — multiplies score by 0.3. Use for system folders.\n'
          '  • Exclude — removes the file from results completely.\n'
          '\n'
          'Multiple rules can apply to the same file. For example,\n'
          'a file in both a Prefer and an Uncommon folder gets:\n'
          '    final score = baseScore × 0.3 + 0.50',
        ),
        const SizedBox(height: 10),

        // Depth explanation
        _rulesSection('Depth Lookup',
          'Depth means how many subfolders deep from the index root.\n'
          'Contribution by level: root=0.050, L1=0.029, L2=0.024,\n'
          'L3=0.021, L4=0.019, L5+=0.018 (capped).',
        ),
      ]),
    );
  }

  Widget _rulesSection(String title, String body) {
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
          color: cs.primary)),
      const SizedBox(height: 4),
      Text(body, style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(153), height: 1.55)),
    ]);
  }

  Widget _buildPriorityGroup(PriorityLevel level, List<int> indices) {
    final cs = Theme.of(context).colorScheme;
    if (indices.isEmpty) return const SizedBox.shrink();
    final (label, color) = switch (level) {
      PriorityLevel.prefer => ('Prefer', cs.primary),
      PriorityLevel.uncommon => ('Uncommon', Colors.orangeAccent),
      PriorityLevel.exclude => ('Exclude', Colors.redAccent),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 8),
      Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      for (final i in indices)
        _buildPriorityRow(_priorityRules[i], i),
    ]);
  }

  Widget _buildPriorityRow(PriorityRule rule, int index) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 3), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(color: XMateColors.cardFill(context), borderRadius: BorderRadius.circular(6)),
      child: Row(children: [
        if (rule.hasPath) ...[
          Icon(Icons.folder, size: 13, color: cs.onSurface.withAlpha(97)), const SizedBox(width: 4),
          Expanded(child: Text(rule.path!, style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(179)),
              maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
        if (rule.hasPath && rule.hasRegex) const SizedBox(width: 8),
        if (rule.hasRegex) ...[
          Icon(Icons.code, size: 13, color: cs.onSurface.withAlpha(97)), const SizedBox(width: 4),
          Text(rule.regex!, style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(138))),
          const Spacer(),
        ],
        if (!rule.hasPath && !rule.hasRegex)
          Expanded(child: Text('(empty)', style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(61)))),
        if (!rule.hasPath) const Spacer(),
        SizedBox(width: 24, height: 24,
          child: IconButton(icon: const Icon(Icons.edit, size: 13),
              color: cs.primary, onPressed: () => _editPriorityRule(index), padding: EdgeInsets.zero)),
        SizedBox(width: 24, height: 24,
          child: IconButton(icon: const Icon(Icons.close, size: 14),
              color: Colors.redAccent.withAlpha(180), onPressed: () => _deletePriorityRule(index), padding: EdgeInsets.zero)),
      ]),
    );
  }

  Future<void> _editPriorityRule(int index) async {
    final existing = index >= 0 && index < _priorityRules.length ? _priorityRules[index] : null;
    final result = await showDialog<PriorityRule>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (_) => _PriorityEditorDialog(existing: existing),
    );
    if (result == null) return;
    setState(() {
      if (existing != null) {
        _priorityRules[index] = result;
      } else {
        _priorityRules.add(result);
      }
      _service.savePriorityRules(_priorityRules);
    });
  }

  void _deletePriorityRule(int index) {
    setState(() {
      _priorityRules.removeAt(index);
      _service.savePriorityRules(_priorityRules);
    });
  }

}

// ── Filter editor dialog ──

class _FilterEditorDialog extends StatefulWidget {
  final FileSearchFilter? existing;
  const _FilterEditorDialog({this.existing});
  @override State<_FilterEditorDialog> createState() => _FilterEditorDialogState();
}

class _FilterEditorDialogState extends State<_FilterEditorDialog> {
  late final _kw = TextEditingController(text: widget.existing?.keyword ?? '');
  late final _nm = TextEditingController(text: widget.existing?.name ?? '');
  late final _path = TextEditingController(text: widget.existing?.path ?? '');
  late final _exts = TextEditingController(
      text: widget.existing?.extensions.join(';') ?? '');
  late final _re = TextEditingController(text: widget.existing?.regex ?? '');

  @override void dispose() {
    _kw.dispose(); _nm.dispose(); _path.dispose();
    _exts.dispose(); _re.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    const ch = MethodChannel('com.xmate/filesearch');
    final p = await ch.invokeMethod<String>('pickFolder');
    if (p != null && p.isNotEmpty) _path.text = p.replaceAll('\\', '/');
  }

  void _save() {
    final kw = _kw.text.trim();
    final nm = _nm.text.trim();
    if (kw.isEmpty || nm.isEmpty) return;
    Navigator.of(context).pop(FileSearchFilter(
      keyword: kw,
      name: nm,
      path: _path.text.trim().isEmpty ? null : _path.text.trim().replaceAll('\\', '/'),
      extensions: _exts.text.trim().isEmpty
          ? []
          : _exts.text.split(';').map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toList(),
      regex: _re.text.trim().isEmpty ? null : _re.text.trim(),
    ));
  }

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isEdit = widget.existing != null;
    return AlertDialog(
      backgroundColor: XMateColors.toolbarBg(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: cs.primary.withAlpha(40))),
      title: Text(isEdit ? 'Edit Filter' : 'Add Filter',
          style: TextStyle(color: cs.onSurface, fontSize: 16)),
      content: SizedBox(width: 400, child: Column(mainAxisSize: MainAxisSize.min, children: [
        _field('Keyword', _kw, 'e.g. project', cs),
        const SizedBox(height: 8),
        _field('Name', _nm, 'e.g. Project Files', cs),
        const SizedBox(height: 8),
        _field('Path', _path, 'folder path (optional)', cs,
            suffix: IconButton(icon: Icon(Icons.folder_open, size: 18, color: cs.primary),
                onPressed: _pickFolder, padding: EdgeInsets.zero)),
        const SizedBox(height: 8),
        _field('Extensions', _exts, 'e.g. dart;yaml;json', cs),
        const SizedBox(height: 8),
        _field('Regex', _re, 'name regex (optional)', cs),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel', style: TextStyle(color: cs.onSurface.withAlpha(97)))),
        TextButton(onPressed: _save,
            child: Text('Save', style: TextStyle(color: cs.primary))),
      ],
    );
  }

  Widget _field(String label, TextEditingController ctrl, String hint, ColorScheme cs, {Widget? suffix}) {
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      SizedBox(width: 90, child: Text(label,
          style: TextStyle(color: cs.onSurface.withAlpha(138), fontSize: 12))),
      Expanded(child: SizedBox(height: 30, child: TextField(
        controller: ctrl, style: TextStyle(color: cs.onSurface, fontSize: 12),
        decoration: InputDecoration(hintText: hint,
            hintStyle: TextStyle(color: cs.onSurface.withAlpha(61), fontSize: 12),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            filled: true, fillColor: XMateColors.inputFill(context),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide.none),
            isDense: true, isCollapsed: true),
      ))),
      ?suffix,
    ]);
  }
}

// ── Priority rule editor dialog ──

class _PriorityEditorDialog extends StatefulWidget {
  final PriorityRule? existing;
  const _PriorityEditorDialog({this.existing});
  @override State<_PriorityEditorDialog> createState() => _PriorityEditorDialogState();
}

class _PriorityEditorDialogState extends State<_PriorityEditorDialog> {
  late final _pathCtrl = TextEditingController(text: widget.existing?.path ?? '');
  late final _reCtrl = TextEditingController(text: widget.existing?.regex ?? '');
  late PriorityLevel _level = widget.existing?.level ?? PriorityLevel.uncommon;

  @override void dispose() {
    _pathCtrl.dispose(); _reCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    const ch = MethodChannel('com.xmate/filesearch');
    final p = await ch.invokeMethod<String>('pickFolder');
    if (p != null && p.isNotEmpty) {
      // Normalize to forward slashes so paths match search results consistently.
      _pathCtrl.text = p.replaceAll('\\', '/');
    }
  }

  void _save() {
    final path = _pathCtrl.text.trim().replaceAll('\\', '/');
    final re = _reCtrl.text.trim();
    if (path.isEmpty && re.isEmpty) return;
    Navigator.of(context).pop(PriorityRule(
      path: path.isEmpty ? null : path,
      regex: re.isEmpty ? null : re,
      level: _level,
    ));
  }

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isEdit = widget.existing != null;
    return AlertDialog(
      backgroundColor: XMateColors.toolbarBg(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: cs.primary.withAlpha(40))),
      title: Text(isEdit ? 'Edit Rule' : 'Add Rule',
          style: TextStyle(color: cs.onSurface, fontSize: 16)),
      content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
        _field('Path', _pathCtrl, 'directory (optional)', cs,
            suffix: IconButton(icon: Icon(Icons.folder_open, size: 18, color: cs.primary),
                onPressed: _pickFolder, padding: EdgeInsets.zero)),
        const SizedBox(height: 8),
        _field('Regex', _reCtrl, r'e.g. ^\. or ^~', cs),
        const SizedBox(height: 10),
        Row(children: [
          SizedBox(width: 90, child: Text('Priority',
              style: TextStyle(color: cs.onSurface.withAlpha(138), fontSize: 12))),
          for (final l in PriorityLevel.values) ...[
            _radioChip(l, cs), const SizedBox(width: 4),
          ],
        ]),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel', style: TextStyle(color: cs.onSurface.withAlpha(97)))),
        TextButton(onPressed: _save,
            child: Text('Save', style: TextStyle(color: cs.primary))),
      ],
    );
  }

  Widget _field(String label, TextEditingController ctrl, String hint, ColorScheme cs, {Widget? suffix}) {
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      SizedBox(width: 90, child: Text(label,
          style: TextStyle(color: cs.onSurface.withAlpha(138), fontSize: 12))),
      Expanded(child: SizedBox(height: 30, child: TextField(
        controller: ctrl, style: TextStyle(color: cs.onSurface, fontSize: 12),
        decoration: InputDecoration(hintText: hint,
            hintStyle: TextStyle(color: cs.onSurface.withAlpha(61), fontSize: 12),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            filled: true, fillColor: XMateColors.inputFill(context),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
            isDense: true, isCollapsed: true),
      ))),
      ?suffix,
    ]);
  }

  Widget _radioChip(PriorityLevel l, ColorScheme cs) {
    final selected = _level == l;
    final (label, color) = switch (l) {
      PriorityLevel.prefer => ('Prefer', cs.primary),
      PriorityLevel.uncommon => ('Uncommon', Colors.orangeAccent),
      PriorityLevel.exclude => ('Exclude', Colors.redAccent),
    };
    return GestureDetector(
      onTap: () => setState(() => _level = l),
      child: Container(
        height: 24, padding: const EdgeInsets.symmetric(horizontal: 8), alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? color.withAlpha(60) : XMateColors.cardFill(context),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label, style: TextStyle(fontSize: 10,
            color: selected ? color : cs.onSurface.withAlpha(138),
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal)),
      ),
    );
  }
}

// ── Custom action editor dialog ──

class _CustomActionEditorDialog extends StatefulWidget {
  final CustomFileAction? existing;
  const _CustomActionEditorDialog({this.existing});
  @override State<_CustomActionEditorDialog> createState() => _CustomActionEditorDialogState();
}

class _CustomActionEditorDialogState extends State<_CustomActionEditorDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _shortcutCtrl;
  late final TextEditingController _pathCtrl;
  late final TextEditingController _argsCtrl;
  late bool _admin;
  late bool _silent;
  final _shortcutFocus = FocusNode();
  bool _captureShortcut = false;

  @override void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.existing?.title ?? '');
    _shortcutCtrl = TextEditingController(text: widget.existing?.shortcut ?? '');
    _pathCtrl = TextEditingController(text: widget.existing?.path ?? '');
    _argsCtrl = TextEditingController(text: widget.existing?.args ?? '');
    _admin = widget.existing?.runAsAdmin ?? false;
    _silent = widget.existing?.runSilently ?? false;
  }

  @override void dispose() {
    _titleCtrl.dispose(); _shortcutCtrl.dispose();
    _pathCtrl.dispose(); _argsCtrl.dispose();
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
    // Only record modifier + non-modifier combos
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
    final text = parts.join('+');
    _shortcutCtrl.text = text;
    _shortcutCtrl.selection = TextSelection.collapsed(offset: text.length);
  }

  void _save() {
    final title = _titleCtrl.text.trim();
    final path = _pathCtrl.text.trim();
    if (title.isEmpty || path.isEmpty) return;
    Navigator.of(context).pop(CustomFileAction(
      id: widget.existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      title: title,
      shortcut: _shortcutCtrl.text.trim(),
      path: path,
      args: _argsCtrl.text.trim(),
      runAsAdmin: _admin,
      runSilently: _silent,
      sortOrder: widget.existing?.sortOrder ?? 100,
    ));
  }

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isEdit = widget.existing != null;
    return AlertDialog(
      backgroundColor: XMateColors.toolbarBg(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: cs.primary.withAlpha(40))),
      title: Text(isEdit ? 'Edit Action' : 'Add Action',
          style: TextStyle(color: cs.onSurface, fontSize: 16)),
      content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
        _field('Title', _titleCtrl, 'action name', cs), const SizedBox(height: 8),
        _shortcutField(cs), const SizedBox(height: 8),
        _field('Path', _pathCtrl, 'executable (required)', cs,
            suffix: IconButton(icon: Icon(Icons.folder_open, size: 18, color: cs.primary),
                onPressed: () async {
                  final ch = FileSearchChannel();
                  final p = await ch.pickFile();
                  if (p != null && p.isNotEmpty) _pathCtrl.text = p;
                }, padding: EdgeInsets.zero)), const SizedBox(height: 8),
        _field('Args', _argsCtrl, '{file} = selected file path', cs), const SizedBox(height: 10),
        Row(children: [
          _toggle(label: 'Admin', value: _admin, onChanged: (v) => setState(() => _admin = v), cs: cs),
          const SizedBox(width: 12),
          _toggle(label: 'Silent', value: _silent, onChanged: (v) => setState(() => _silent = v), cs: cs),
        ]),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel', style: TextStyle(color: cs.onSurface.withAlpha(97)))),
        TextButton(onPressed: _save,
            child: Text('Save', style: TextStyle(color: cs.primary))),
      ],
    );
  }

  Widget _shortcutField(ColorScheme cs) {
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      SizedBox(width: 70, child: Text('Shortcut',
          style: TextStyle(color: cs.onSurface.withAlpha(138), fontSize: 12))),
      Expanded(child: SizedBox(height: 30, child: Focus(
        focusNode: _shortcutFocus,
        onFocusChange: (focused) { if (focused) setState(() => _captureShortcut = true); },
        onKeyEvent: (_, event) { _onShortcutKey(event); return KeyEventResult.handled; },
        child: TextField(
          controller: _shortcutCtrl, readOnly: true,
          style: TextStyle(color: cs.onSurface, fontSize: 12, fontFamily: 'monospace'),
          decoration: InputDecoration(
            hintText: _captureShortcut ? 'Press keys...' : 'click to capture',
            hintStyle: TextStyle(color: _captureShortcut ? cs.primary : cs.onSurface.withAlpha(61), fontSize: 12),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            filled: true,
            fillColor: _captureShortcut ? cs.primary.withAlpha(20) : XMateColors.inputFill(context),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: _captureShortcut ? cs.primary : Colors.transparent)),
            isDense: true, isCollapsed: true,
          ),
        ),
      ))),
    ]);
  }

  Widget _field(String label, TextEditingController ctrl, String hint, ColorScheme cs, {Widget? suffix}) {
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      SizedBox(width: 70, child: Text(label,
          style: TextStyle(color: cs.onSurface.withAlpha(138), fontSize: 12))),
      Expanded(child: SizedBox(height: 30, child: TextField(
        controller: ctrl,
        style: TextStyle(color: cs.onSurface, fontSize: 12),
        decoration: InputDecoration(hintText: hint,
            hintStyle: TextStyle(color: cs.onSurface.withAlpha(61), fontSize: 12),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            filled: true, fillColor: XMateColors.inputFill(context),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
            isDense: true, isCollapsed: true),
      ))),
      ?suffix,
    ]);
  }

  Widget _toggle({required String label, required bool value, required ValueChanged<bool> onChanged, required ColorScheme cs}) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(value ? Icons.toggle_on : Icons.toggle_off, size: 20,
            color: value ? cs.primary : cs.onSurface.withAlpha(97)),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, color: value ? cs.onSurface : cs.onSurface.withAlpha(138))),
      ]),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String t;
  const _SectionLabel(this.t, {this.icon = Icons.settings});
  @override Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    return Padding(padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Icon(icon, size: 16, color: cs.primary),
        const SizedBox(width: 6),
        Text(t, style: TextStyle(color: cs.primary, fontSize: 13, fontWeight: FontWeight.w500)),
      ]));
  }
}

class _SegmentCard extends StatefulWidget {
  final SegmentInfo seg; final bool loading; final int interval;
  final String mode, customVal;
  final TextEditingController customCtrl;
  final VoidCallback onRebuild, onUpdate, onRemove;
  final void Function(String mode, [String? val]) onModeChanged;

  const _SegmentCard({required this.seg, required this.loading, required this.interval,
    required this.mode, required this.customVal, required this.customCtrl,
    required this.onRebuild, required this.onUpdate, required this.onRemove,
    required this.onModeChanged});

  @override State<_SegmentCard> createState() => _SegmentCardState();
}

class _SegmentCardState extends State<_SegmentCard> {
  bool _showCustomInput = false;
  final _cFocus = FocusNode();

  @override void initState() {
    super.initState();
    _showCustomInput = widget.mode == 'custom';
  }

  @override void didUpdateWidget(covariant _SegmentCard old) {
    super.didUpdateWidget(old);
    if (widget.mode != 'custom') _showCustomInput = false;
    if (_showCustomInput && widget.mode != old.mode) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _cFocus.requestFocus());
    }
  }

  @override void dispose() {
    _cFocus.dispose();
    super.dispose();
  }

  @override Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    final inCustom = _showCustomInput || widget.mode == 'custom';
    final seg = widget.seg; final color = switch (seg.status) {
      SegmentStatus.ready => cs.primary,
      SegmentStatus.failed => Colors.redAccent,
      SegmentStatus.building => Colors.orangeAccent,
      SegmentStatus.notBuilt => cs.onSurface.withAlpha(97),
    };
    final st = switch (seg.status) {
      SegmentStatus.ready => '✓ Indexed',
      SegmentStatus.failed => '⚠ ${seg.errorReason ?? "Failed"}',
      SegmentStatus.building => 'Building...',
      SegmentStatus.notBuilt => 'Not indexed',
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 6), padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: XMateColors.cardFill(c), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.folder, size: 14, color: cs.onSurface.withAlpha(138)), const SizedBox(width: 6),
          Expanded(child: Text(seg.rootPath, style: TextStyle(color: cs.onSurface, fontSize: 12),
              overflow: TextOverflow.ellipsis)),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          const SizedBox(width: 6),
          Text(st, style: TextStyle(color: color, fontSize: 11)),
          if (seg.status == SegmentStatus.ready) ...[
            const SizedBox(width: 12),
            Text('Files: ${seg.fileCount}', style: TextStyle(color: cs.onSurface.withAlpha(138), fontSize: 11)),
            if (seg.segmentCount > 1)
              Text(' (${seg.segmentCount} segs)',
                  style: const TextStyle(color: Colors.orangeAccent, fontSize: 10)),
            if (seg.dirty)
              Container(margin: const EdgeInsets.only(left: 4),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(color: Colors.orangeAccent.withAlpha(30), borderRadius: BorderRadius.circular(3)),
                child: const Text('dirty', style: TextStyle(color: Colors.orangeAccent, fontSize: 9))),
            const SizedBox(width: 12),
            Flexible(child: Text(seg.lastUpdated != null ? 'Updated: ${_relativeTime(seg.lastUpdated!)}' : '',
                style: TextStyle(color: cs.onSurface.withAlpha(138), fontSize: 11), overflow: TextOverflow.ellipsis)),
          ],
        ]),
        const SizedBox(height: 6),
        // Single row: Rebuild | Update | Interval chips | Spacer | Remove
        // Wrap in IntrinsicHeight + Align so TextField stays vertically centered.
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          _MiniBtn('Rebuild', widget.onRebuild, loading: widget.loading), const SizedBox(width: 6),
          _MiniBtn('Update', widget.onUpdate, loading: widget.loading), const SizedBox(width: 10),
          _chip('Auto', widget.mode == 'auto', () {
            setState(() => _showCustomInput = false);
            widget.onModeChanged('auto');
          }),
          const SizedBox(width: 4),
          _chip('Off', widget.mode == 'off', () {
            setState(() => _showCustomInput = false);
            widget.onModeChanged('off');
          }),
          const SizedBox(width: 4),
          _chip('Cust.', inCustom, () {
            if (inCustom) {
              // Tap already-selected Cust. → close input, revert to Off
              setState(() => _showCustomInput = false);
              widget.onModeChanged('off');
              return;
            }
            setState(() => _showCustomInput = true);
            WidgetsBinding.instance.addPostFrameCallback((_) => _cFocus.requestFocus());
          }),
          if (inCustom) ...[
            const SizedBox(width: 4),
            SizedBox(width: 56, height: 20,
              child: TextField(
                controller: widget.customCtrl,
                focusNode: _cFocus,
                style: TextStyle(color: cs.onSurface, fontSize: 12),
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  hintText: '30m', hintStyle: TextStyle(color: cs.onSurface.withAlpha(61), fontSize: 12),
                  contentPadding: EdgeInsets.zero,
                  filled: true, fillColor: XMateColors.inputFill(context),
                  border: InputBorder.none,
                  isDense: true,
                  isCollapsed: true,
                ),
                onSubmitted: (v) => widget.onModeChanged('custom', v),
              ),
            ),
          ],
          const Spacer(),
          _MiniBtn('Remove', widget.onRemove, warn: true),
        ]),
      ]),
    );
  }

  /// Friendly relative time: "3 min ago", "2 hours ago", "5 days ago".
  static String _relativeTime(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}mo ago';
    return '${(diff.inDays / 365).floor()}y ago';
  }

  /// Radio-style chip: highlight only, no checkmark.
  Widget _chip(String label, bool selected, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? cs.primary.withAlpha(60) : XMateColors.cardFill(context),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label, style: TextStyle(
          fontSize: 9,
          color: selected ? cs.onSurface : cs.onSurface.withAlpha(138),
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        )),
      ),
    );
  }
}

class _MiniBtn extends StatelessWidget {
  final String label; final VoidCallback onTap; final bool loading, warn;
  const _MiniBtn(this.label, this.onTap, {this.loading = false, this.warn = false});
  @override Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    return SizedBox(height: 28, child: TextButton(
      onPressed: loading ? null : onTap,
      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10),
        foregroundColor: warn ? Colors.redAccent.withAlpha(180) : cs.primary,
        textStyle: const TextStyle(fontSize: 11), minimumSize: Size.zero),
      child: loading ? SizedBox(width: 12, height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: cs.primary)) : Text(label),
    ));
  }
}
