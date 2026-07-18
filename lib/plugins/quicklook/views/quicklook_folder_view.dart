import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/search/file_search_channel.dart';
import '../../../core/command/file_submenu_service.dart';
import '../../../core/command/file_submenu_item.dart';
import '../../../core/quicklook/quicklook_utils.dart';

const _qlChannel = MethodChannel('com.xmate/quicklook');

/// Folder preview: immediate children with icons, names, sizes, dates,
/// types — like a mini Explorer.  Sortable columns, right‑click submenu,
/// parent‑folder navigation.
class QuickLookFolderView extends StatefulWidget {
  final String folderPath;
  final void Function(String path)? onOpenItem;
  final void Function(bool hasSelection)? onSelectionChanged;
  final bool showFileSize;
  final VoidCallback? onToggleShowFileSize;

  const QuickLookFolderView({
    super.key,
    required this.folderPath,
    this.onOpenItem,
    this.onSelectionChanged,
    this.showFileSize = false,
    this.onToggleShowFileSize,
  });

  @override
  State<QuickLookFolderView> createState() => _QuickLookFolderViewState();
}

// ── Sort column enum ─────────────────────────────────────────────

enum _SortCol { name, size, date, type }

// ── Entry model ──────────────────────────────────────────────────

class _FolderEntry {
  final String path, name;
  final bool isDir;
  final int size;
  final DateTime modified;
  final String ext;
  Uint8List? iconPng;

  _FolderEntry({
    required this.path, required this.name, required this.isDir,
    required this.size, required this.modified, required this.ext,
  });

  String get typeLabel =>
      isDir ? 'Folder' : (ext.isNotEmpty ? ext.toUpperCase() : 'File');
}

// ── State ────────────────────────────────────────────────────────

class _QuickLookFolderViewState extends State<QuickLookFolderView> {
  List<_FolderEntry>? _entries;
  String? _errorMsg;
  int _selIndex = -1;
  final _scrollCtrl = ScrollController();
  bool _loading = true;
  int _folderCount = 0, _fileCount = 0, _totalSize = 0;
  Map<String, int> _folderSizes = {};  // path → recursive size (when showFileSize on)
  int _totalFolderSize = 0;            // sum of all folder recursive sizes
  bool _computingSizes = false;        // async folder size computation in progress

  _SortCol _sortCol = _SortCol.name;
  bool _sortAsc = true;

  static const _rowH = 30.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant QuickLookFolderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.folderPath != oldWidget.folderPath) {
      _entries = null; _selIndex = -1; _loading = true;
      _folderSizes = {}; _totalFolderSize = 0; _computingSizes = false;
      _notifySelection(); _load();
    } else if (widget.showFileSize != oldWidget.showFileSize) {
      if (widget.showFileSize && _entries != null) {
        _computeFolderSizes(_entries!);
      } else if (!widget.showFileSize) {
        _folderSizes = {};
        _totalFolderSize = 0;
        _computingSizes = false;
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    _scrollCtrl.dispose(); super.dispose();
  }

  void _notifySelection() {
    widget.onSelectionChanged?.call(
        _selIndex >= 0 && _entries != null && _selIndex < _entries!.length);
  }

  String get _parentPath {
    final p = widget.folderPath.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    final slash = p.lastIndexOf('/');
    if (slash <= 0) return p.substring(0, slash + 1);
    return p.substring(0, slash).replaceAll('/', '\\');
  }

  // ── Load + sort ─────────────────────────────────────────────────

  Future<void> _load() async {
    try {
      final dir = Directory(widget.folderPath);
      // Avoid FileSystemEntity.exists() for directories — use statSync.
      try { dir.statSync(); } catch (_) {
        if (!mounted) return;
        setState(() { _errorMsg = 'Folder not found'; _loading = false; });
        return;
      }

      final list = <_FolderEntry>[];
      final entities = dir.listSync();
      int folders = 0, files = 0, totalSize = 0;

      for (final e in entities) {
        try {
          final stat = e.statSync();
          final isDir = e is Directory;
          // Split path manually — e.uri.pathSegments is unreliable for
          // Windows directories in some Dart SDK versions.
          final segs = e.path.split(RegExp(r'[/\\]'));
          final name = segs.isNotEmpty ? segs.last : e.path;
          String ext = '';
          if (!isDir) {
            final dot = name.lastIndexOf('.');
            ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
          }
          list.add(_FolderEntry(
            path: e.path.replaceAll('\\', '/'),
            name: name, isDir: isDir,
            size: stat.size, modified: stat.modified, ext: ext,
          ));
          if (isDir) { folders++; } else { files++; totalSize += stat.size; }
        } catch (_) {}
      }

      _applySort(list);

      if (!mounted) return;
      setState(() {
        _entries = list; _folderCount = folders;
        _fileCount = files; _totalSize = totalSize; _loading = false;
      });
      if (widget.showFileSize) _computeFolderSizes(list);
    } catch (e) {
      if (!mounted) return;
      setState(() { _errorMsg = 'Failed to read folder'; _loading = false; });
    }
  }

  void _applySort(List<_FolderEntry> list) {
    int cmp(_FolderEntry a, _FolderEntry b) {
      // Folders first when ascending, last when descending.
      if (a.isDir != b.isDir) return _sortAsc ? (a.isDir ? -1 : 1) : (a.isDir ? 1 : -1);
      int c;
      switch (_sortCol) {
        case _SortCol.name:
          c = a.name.toLowerCase().compareTo(b.name.toLowerCase()); break;
        case _SortCol.size:
          c = a.size.compareTo(b.size); break;
        case _SortCol.date:
          c = a.modified.compareTo(b.modified); break;
        case _SortCol.type:
          c = a.typeLabel.compareTo(b.typeLabel); break;
      }
      return _sortAsc ? c : -c;
    }
    list.sort(cmp);
  }

  /// Compute recursive sizes for all folders in [list] asynchronously,
  /// updating the UI incrementally as each folder size is computed.
  Future<void> _computeFolderSizes(List<_FolderEntry> list) async {
    final dirs = list.where((e) => e.isDir).toList();
    if (dirs.isEmpty) return;
    setState(() => _computingSizes = true);
    // Process folders sequentially to avoid blocking the UI thread.
    // Each folder is processed in batches of subdirs to keep UI responsive.
    int totalFolderSize = 0;
    for (final d in dirs) {
      int sz = 0;
      try {
        sz = await _dirSize(d.path);
      } catch (_) { sz = 0; }
      if (!mounted) return;
      _folderSizes[d.path] = sz;
      totalFolderSize += sz;
      // Update UI incrementally so the user sees progress.
      setState(() { _totalFolderSize = totalFolderSize; });
    }
    if (!mounted) return;
    setState(() => _computingSizes = false);
  }

  /// Compute the total size of all files under [path] recursively.
  /// Uses batched synchronous I/O with periodic event-loop yields to avoid jank.
  static Future<int> _dirSize(String path) async {
    int total = 0;
    final List<Directory> pending = [];
    try {
      final d = Directory(path);
      final List<FileSystemEntity> entities;
      try {
        entities = d.listSync();
      } catch (_) { return 0; }
      for (final e in entities) {
        try {
          if (e is File) {
            total += e.statSync().size;
          } else if (e is Directory) {
            pending.add(e);
          }
        } catch (_) {}
      }
    } catch (_) { return 0; }
    // Process subdirectories without recursion (iterative BFS).
    int batch = 0;
    while (pending.isNotEmpty) {
      final dir = pending.removeAt(0);
      try {
        final entities = dir.listSync();
        for (final e in entities) {
          try {
            if (e is File) { total += e.statSync().size; }
            else if (e is Directory) { pending.add(e); }
          } catch (_) {}
        }
      } catch (_) {}
      batch++;
      // Yield to event loop every ~16 entries to keep UI responsive.
      if (batch % 16 == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 0));
      }
    }
    return total;
  }

  void _onSortTap(_SortCol col) {
    if (_sortCol == col) {
      _sortAsc = !_sortAsc;
    } else {
      _sortCol = col; _sortAsc = true;
    }
    if (_entries != null) _applySort(_entries!);
    _selIndex = -1; _notifySelection();
    setState(() {});
  }

  // ── Helpers ─────────────────────────────────────────────────────


  // ── Actions ─────────────────────────────────────────────────────

  void _openSelected() {
    final list = _entries;
    if (list == null || _selIndex < 0 || _selIndex >= list.length) return;
    widget.onOpenItem?.call(list[_selIndex].path);
  }

  void _goUp() => widget.onOpenItem?.call(_parentPath);

  void _selectNext() {
    final list = _entries; if (list == null || list.isEmpty) return;
    setState(() => _selIndex = _selIndex < list.length - 1 ? _selIndex + 1 : 0);
    _scrollToSel(); _notifySelection();
  }

  void _selectPrev() {
    final list = _entries; if (list == null || list.isEmpty) return;
    setState(() => _selIndex = _selIndex > 0 ? _selIndex - 1 : list.length - 1);
    _scrollToSel(); _notifySelection();
  }

  void _scrollToSel() {
    if (!_scrollCtrl.hasClients || _selIndex < 0) return;
    final top = _selIndex * _rowH, bot = top + _rowH;
    final vp = _scrollCtrl.position.viewportDimension;
    final sp = _scrollCtrl.position.pixels;
    if (top < sp) { _scrollCtrl.jumpTo(top); }
    else if (bot > sp + vp) { _scrollCtrl.jumpTo(bot - vp); }
  }

  // ── Right-click submenu ─────────────────────────────────────────

  void _showContextMenu(_FolderEntry entry, Offset pos) async {
    var items = FileSubmenuService().loadItems()
        .where((it) {
          if (entry.isDir && it is BuiltinFileAction) {
            final k = it.kind;
            if (k == FileActionKind.copy || k == FileActionKind.cut ||
                k == FileActionKind.translateFile || k == FileActionKind.pinToStart) {
              return false;
            }
          }
          return true;
        }).toList();

    if (!mounted) return;
    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      color: Theme.of(context).colorScheme.brightness == Brightness.dark
          ? const Color(0xEE252540) : const Color(0xEEFFFFFF),
      items: [
        for (int i = 0; i < items.length; i++)
          PopupMenuItem<String>(
            value: '__$i', height: 32,
            child: Row(children: [
              Icon(items[i].icon, size: 15, color: Theme.of(context).colorScheme.onSurface.withAlpha(179)),
              const SizedBox(width: 8),
              Text(items[i].title, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface)),
              const Spacer(),
              if (items[i].shortcut.isNotEmpty)
                Text(items[i].shortcut, style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurface.withAlpha(97))),
            ]),
          ),
      ],
    );

    if (result == null || !result.startsWith('__') || !mounted) return;
    final idx = int.tryParse(result.substring(2));
    if (idx == null || idx >= items.length) return;
    final item = items[idx];

    // Translate file: QL is a detached process → write a temp file with
    // the file path, then ask the main process via C++ PostMessage to
    // read it and open the translate window.
    if (item is BuiltinFileAction && item.kind == FileActionKind.translateFile) {
      try {
        final appData = Platform.environment['APPDATA'] ?? '';
        final dir = Directory('$appData\\XMate');
        if (!await dir.exists()) await dir.create(recursive: true);
        await File('$appData\\XMate\\ql_translate_req.json')
            .writeAsString(jsonEncode({'path': entry.path}));
        await _qlChannel.invokeMethod('requestTranslate');
      } catch (_) {}
      return;
    }

    FileSubmenuService().execute(item, entry.path);
    _load();
  }

  // ── UI ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) return Center(
      child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary));
    if (_errorMsg != null) return Center(
      child: Text(_errorMsg!, style: const TextStyle(fontSize: 14, color: Colors.redAccent)));

    final list = _entries!;
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) { _selectNext(); return KeyEventResult.handled; }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) { _selectPrev(); return KeyEventResult.handled; }
        if (event.logicalKey == LogicalKeyboardKey.enter) { _openSelected(); return KeyEventResult.handled; }
        if (event.logicalKey == LogicalKeyboardKey.backspace && _parentPath.length > 2) {
          _goUp(); return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(children: [
        _buildHeader(cs),
        Divider(height: 1, color: cs.onSurface.withAlpha(31)),
        Expanded(
          child: list.isEmpty
              ? Center(child: Text('Empty folder', style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(97))))
              : ListView.builder(
                  controller: _scrollCtrl, itemCount: list.length, itemExtent: _rowH,
                  itemBuilder: (_, i) => _buildRow(list[i], i, cs)),
        ),
        Divider(height: 1, color: cs.onSurface.withAlpha(31)),
        _buildFooter(cs),
      ]),
    );
  }

  // ── Header ──

  Widget _buildHeader(ColorScheme cs) {
    return Container(
      height: 26, padding: const EdgeInsets.symmetric(horizontal: 12),
      color: cs.onSurface.withAlpha(8),
      child: Row(children: [
        const SizedBox(width: 26 + 8),
        _hdrBtn('Name', _SortCol.name, cs, flex: 3, align: TextAlign.left),
        _hdrBtn('Size', _SortCol.size, cs, width: 75 + 12),
        _hdrBtn('Date modified', _SortCol.date, cs, width: 145 + 12),
        _hdrBtn('Type', _SortCol.type, cs, width: 52),
      ]),
    );
  }

  Widget _hdrBtn(String label, _SortCol col, ColorScheme cs, {int flex = 1, double? width, TextAlign align = TextAlign.right}) {
    final active = _sortCol == col;
    final arrow = active ? (_sortAsc ? ' ▲' : ' ▼') : '';
    final w = GestureDetector(
      onTap: () => _onSortTap(col),
      behavior: HitTestBehavior.opaque,
      child: Text('$label$arrow',
        textAlign: align,
        style: TextStyle(fontSize: 11, color: active ? cs.primary : cs.onSurface.withAlpha(97), fontWeight: FontWeight.w600)),
    );
    if (width != null) return SizedBox(width: width, child: w);
    return Expanded(flex: flex, child: w);
  }

  // ── Row ──

  Widget _buildRow(_FolderEntry e, int i, ColorScheme cs) {
    final sel = i == _selIndex;
    return GestureDetector(
      onTap: () { setState(() => _selIndex = i); _notifySelection(); },
      onDoubleTap: () { setState(() => _selIndex = i); _notifySelection(); _openSelected(); },
      onSecondaryTapUp: (d) { setState(() => _selIndex = i); _notifySelection(); _showContextMenu(e, d.globalPosition); },
      child: Container(
        height: _rowH, padding: const EdgeInsets.symmetric(horizontal: 12),
        color: sel ? cs.onSurface.withAlpha(20) : Colors.transparent,
        child: Row(children: [
          _EntryIcon(path: e.path, isDir: e.isDir, cachedPng: e.iconPng,
              onLoaded: (png) => e.iconPng = png),
          const SizedBox(width: 8),
          Expanded(flex: 3, child: Text(e.name,
            style: TextStyle(fontSize: 12,
              color: e.isDir ? cs.primary : cs.onSurface,
              fontWeight: sel ? FontWeight.w600 : FontWeight.normal),
            overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 12),
          SizedBox(width: 75, child: Text(
            e.isDir
                ? (widget.showFileSize && _folderSizes.containsKey(e.path)
                    ? fileSizeStr(_folderSizes[e.path]!)
                    : (_computingSizes ? '…' : ''))
                : fileSizeStr(e.size),
            style: TextStyle(fontSize: 11,
              color: _sortCol == _SortCol.size ? cs.primary : cs.onSurface.withAlpha(138)),
            textAlign: TextAlign.right)),
          const SizedBox(width: 12),
          SizedBox(width: 145, child: Text(fileTimeStr(e.modified, showSeconds: false),
            style: TextStyle(fontSize: 11,
              color: _sortCol == _SortCol.date ? cs.primary : cs.onSurface.withAlpha(138)),
            textAlign: TextAlign.right)),
          const SizedBox(width: 12),
          SizedBox(width: 52, child: Text(e.typeLabel,
            style: TextStyle(fontSize: 10,
              color: _sortCol == _SortCol.type ? cs.primary : cs.onSurface.withAlpha(97)),
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis)),
        ]),
      ),
    );
  }

  // ── Footer ──

  Widget _buildFooter(ColorScheme cs) {
    final totalCount = _entries?.length ?? 0;
    // Total size = file sizes + folder recursive sizes (when showFileSize is on).
    final allSize = _totalSize + (_computingSizes ? _totalFolderSize : _totalFolderSize);
    final showTotal = widget.showFileSize;

    return Container(
      height: 24, padding: const EdgeInsets.symmetric(horizontal: 10),
      color: cs.onSurface.withAlpha(8),
      child: Row(children: [
        GestureDetector(
          onTap: _goUp,
          behavior: HitTestBehavior.opaque,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.arrow_upward, size: 12, color: cs.onSurface.withAlpha(138)),
            const SizedBox(width: 4),
            Text('Parent', style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(138))),
          ]),
        ),
        const Spacer(),
        Text('$totalCount items',
            style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(97))),
        if (showTotal)
          Text('  |  ${fileSizeStr(allSize)}${_computingSizes ? "…" : ""} total',
              style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(97))),
        Text('  |  $_folderCount folders  |  $_fileCount files',
            style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(97))),
        if (_fileCount > 0)
          Text('  |  ${fileSizeStr(_totalSize)}',
              style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(97))),
        const SizedBox(width: 4),
        _showFileSizeToggle(cs),
      ]),
    );
  }

  Widget _showFileSizeToggle(ColorScheme cs) {
    final active = widget.showFileSize;
    return GestureDetector(
      onTap: () => widget.onToggleShowFileSize?.call(),
      behavior: HitTestBehavior.opaque,
      child: Tooltip(
        message: active ? 'Hide folder sizes' : 'Show folder sizes (may be slow)',
        child: Icon(
          active ? Icons.storage : Icons.storage_outlined,
          size: 13,
          color: active ? cs.primary : cs.onSurface.withAlpha(61),
        ),
      ),
    );
  }
}

// ── Lazy icon ────────────────────────────────────────────────────

class _EntryIcon extends StatefulWidget {
  final String path; final bool isDir;
  final Uint8List? cachedPng; final void Function(Uint8List)? onLoaded;
  const _EntryIcon({required this.path, required this.isDir, this.cachedPng, this.onLoaded});
  @override State<_EntryIcon> createState() => _EntryIconState();
}

class _EntryIconState extends State<_EntryIcon> {
  Uint8List? _png; bool _loading = false;

  @override void initState() { super.initState(); _png = widget.cachedPng; }

  @override void didUpdateWidget(_EntryIcon old) {
    super.didUpdateWidget(old);
    if (widget.path != old.path) _png = widget.cachedPng;
  }

  @override
  Widget build(BuildContext context) {
    if (_png != null) return Image.memory(_png!, width: 18, height: 18, gaplessPlayback: true);
    if (!_loading) _fetch();
    return Icon(widget.isDir ? Icons.folder : Icons.insert_drive_file,
        size: 18, color: widget.isDir ? const Color(0xFFFFD54F) : Colors.white54);
  }

  Future<void> _fetch() async {
    _loading = true;
    try {
      final png = await FileSearchChannel().getFileIcon(widget.path);
      if (!mounted) return;
      if (png != null) { widget.onLoaded?.call(png); setState(() => _png = png); }
    } catch (_) {}
    _loading = false;
  }
}
