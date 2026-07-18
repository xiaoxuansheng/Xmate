import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/quicklook/quicklook_utils.dart';
import '../parsers/archive_parser.dart';

/// Archive preview: file listing with sortable columns, modelled on
/// QuickLookFolderView.  Supports ZIP / TAR / GZ (and TAR.GZ via GZ→TAR chain).
class QuickLookArchiveView extends StatefulWidget {
  final String filePath;
  const QuickLookArchiveView({super.key, required this.filePath});

  @override
  State<QuickLookArchiveView> createState() => _QuickLookArchiveViewState();
}

// ── Sort ──────────────────────────────────────────────────────────

enum _SortCol { name, size, date }

// ── State ─────────────────────────────────────────────────────────

class _QuickLookArchiveViewState extends State<QuickLookArchiveView> {
  ArchiveListing? _listing;
  String? _errorMsg;
  bool _loading = true;
  int _selIndex = -1;

  _SortCol _sortCol = _SortCol.name;
  bool _sortAsc = true;

  final _scrollCtrl = ScrollController();

  static const _rowH = 30.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant QuickLookArchiveView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filePath != oldWidget.filePath) {
      _listing = null; _selIndex = -1; _loading = true;
      _load();
    }
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final listing = await parseArchive(widget.filePath);
      if (!mounted) return;
      if (listing == null) {
        setState(() { _errorMsg = 'Not a supported archive'; _loading = false; });
        return;
      }
      _applySort(listing.entries);
      setState(() { _listing = listing; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _errorMsg = 'Failed to read archive: $e'; _loading = false; });
    }
  }

  void _applySort(List<ArchiveEntry> list) {
    int cmp(ArchiveEntry a, ArchiveEntry b) {
      if (a.isDir != b.isDir) return _sortAsc ? (a.isDir ? -1 : 1) : (a.isDir ? 1 : -1);
      int c;
      switch (_sortCol) {
        case _SortCol.name:
          c = a.name.toLowerCase().compareTo(b.name.toLowerCase()); break;
        case _SortCol.size:
          c = a.size.compareTo(b.size); break;
        case _SortCol.date:
          final da = a.modified ?? DateTime(1980);
          final db = b.modified ?? DateTime(1980);
          c = da.compareTo(db); break;
      }
      return _sortAsc ? c : -c;
    }
    list.sort(cmp);
  }

  void _onSortTap(_SortCol col) {
    if (_sortCol == col) {
      _sortAsc = !_sortAsc;
    } else {
      _sortCol = col; _sortAsc = true;
    }
    if (_listing != null) _applySort(_listing!.entries);
    _selIndex = -1;
    setState(() {});
  }

  void _selectNext() {
    final list = _listing?.entries; if (list == null || list.isEmpty) return;
    setState(() => _selIndex = _selIndex < list.length - 1 ? _selIndex + 1 : 0);
    _scrollToSel();
  }

  void _selectPrev() {
    final list = _listing?.entries; if (list == null || list.isEmpty) return;
    setState(() => _selIndex = _selIndex > 0 ? _selIndex - 1 : list.length - 1);
    _scrollToSel();
  }

  void _scrollToSel() {
    if (!_scrollCtrl.hasClients || _selIndex < 0) return;
    final top = _selIndex * _rowH;
    final vp = _scrollCtrl.position.viewportDimension;
    final sp = _scrollCtrl.position.pixels;
    if (top < sp) {
      _scrollCtrl.jumpTo(top);
    } else if (top + _rowH > sp + vp) {
      _scrollCtrl.jumpTo(top + _rowH - vp);
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────


  // ── UI ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) return Center(
      child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary));
    if (_errorMsg != null) return Center(
      child: Text(_errorMsg!, style: const TextStyle(fontSize: 14, color: Colors.redAccent)));

    final listing = _listing!;

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) { _selectNext(); return KeyEventResult.handled; }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) { _selectPrev(); return KeyEventResult.handled; }
        return KeyEventResult.ignored;
      },
      child: Column(children: [
        _buildSummary(listing, cs),
        _buildHeader(cs),
        Divider(height: 1, color: cs.onSurface.withAlpha(31)),
        Expanded(
          child: listing.entries.isEmpty
              ? Center(child: Text('Empty archive', style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(97))))
              : ListView.builder(
                  controller: _scrollCtrl, itemCount: listing.entries.length, itemExtent: _rowH,
                  itemBuilder: (_, i) => _buildRow(listing.entries[i], i, cs)),
        ),
        Divider(height: 1, color: cs.onSurface.withAlpha(31)),
        _buildFooter(listing, cs),
      ]),
    );
  }

  // ── Summary bar ─────────────────────────────────────────────────

  Widget _buildSummary(ArchiveListing listing, ColorScheme cs) {
    final parts = <String>[];
    parts.add(listing.format);
    if (listing.compression != null) parts.add(listing.compression!);
    if (listing.hint != null) parts.add(listing.hint!);
    final info = parts.join('  |  ');

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: cs.primary.withAlpha(26),
      child: Row(children: [
        Icon(_archiveIcon(listing.format), size: 14, color: cs.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(info, style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(179)),
              overflow: TextOverflow.ellipsis),
        ),
        Text('${listing.entries.length} entries  '
             '${fileSizeStr(listing.totalSize)}',
             style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(138))),
      ]),
    );
  }

  // ── Header ──────────────────────────────────────────────────────

  Widget _buildHeader(ColorScheme cs) {
    return Container(
      height: 26, padding: const EdgeInsets.symmetric(horizontal: 12),
      color: cs.onSurface.withAlpha(8),
      child: Row(children: [
        const SizedBox(width: 24 + 8),
        _hdrBtn('Name', _SortCol.name, cs, flex: 3, align: TextAlign.left),
        _hdrBtn('Size', _SortCol.size, cs, width: 80 + 12),
        _hdrBtn('Date modified', _SortCol.date, cs, width: 145 + 12),
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
        style: TextStyle(fontSize: 11, color: active ? cs.onSurface.withAlpha(179) : cs.onSurface.withAlpha(97), fontWeight: FontWeight.w600)),
    );
    if (width != null) return SizedBox(width: width, child: w);
    return Expanded(flex: flex, child: w);
  }

  // ── Row ─────────────────────────────────────────────────────────

  Widget _buildRow(ArchiveEntry e, int i, ColorScheme cs) {
    final sel = i == _selIndex;
    return GestureDetector(
      onTap: () => setState(() => _selIndex = i),
      child: Container(
        height: _rowH, padding: const EdgeInsets.symmetric(horizontal: 12),
        color: sel ? cs.onSurface.withAlpha(20) : Colors.transparent,
        child: Row(children: [
          Icon(e.isDir ? Icons.folder : Icons.insert_drive_file_outlined,
              size: 15, color: e.isDir ? cs.primary : cs.onSurface.withAlpha(138)),
          const SizedBox(width: 8),
          Expanded(flex: 3, child: Text(e.name,
            style: TextStyle(fontSize: 12,
              color: e.isDir ? cs.primary : cs.onSurface,
              fontWeight: sel ? FontWeight.w600 : FontWeight.normal),
            overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 12),
          SizedBox(width: 80, child: Text(
            e.isDir ? '' : fileSizeStr(e.size),
            textAlign: TextAlign.right, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: e.isDir ? cs.onSurface.withAlpha(97) : cs.onSurface.withAlpha(153))),
          ),
          const SizedBox(width: 12),
          SizedBox(width: 145, child: Text(
            e.modified != null ? fileTimeStr(e.modified!, showSeconds: false) : '',
            style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(138)),
            overflow: TextOverflow.ellipsis)),
        ]),
      ),
    );
  }

  // ── Footer ──────────────────────────────────────────────────────

  Widget _buildFooter(ArchiveListing listing, ColorScheme cs) {
    int totalComp = 0;
    for (final e in listing.entries) {
      if (e.compressedSize != null && e.compressedSize! > 0 && e.size > 0) {
        totalComp += e.compressedSize!;
      }
    }
    final ratioStr = totalComp > 0
        ? '${fileSizeStr(totalComp)} / ${fileSizeStr(listing.totalSize)}'
        : fileSizeStr(listing.totalSize);

    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: cs.primary.withAlpha(26),
      child: Row(children: [
        Text('${listing.fileCount} files, ${listing.folderCount} folders',
            style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(138))),
        if (ratioStr.isNotEmpty) ...[
          const Spacer(),
          Text(ratioStr, style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(77))),
        ],
      ]),
    );
  }

  IconData _archiveIcon(String format) {
    if (format.startsWith('ZIP')) return Icons.folder_zip;
    if (format.startsWith('TAR')) return Icons.archive;
    if (format.startsWith('GZIP')) return Icons.archive;
    return Icons.folder_zip;
  }
}
