#!/usr/bin/env python3
"""Apply remaining QL PDF viewer changes."""
import sys

path = r'e:\AI\XMate\lib\plugins\quicklook\views\quicklook_pdf_view.dart'
with open(path, 'r', encoding='utf-8') as f:
    data = f.read()

# === 1. Add rotate/delete/extract/info operations (after _cleanFile, before _onTranslate) ===
marker = '\n  void _onTranslate() async {'
ops = r'''
  // ── Rotate selected pages ──
  Future<void> _onRotate({bool ccw = false}) async {
    final pages = _selectedPages.isNotEmpty ? _selectedPages : {_currentPage + 1};
    final label = pages.length == 1 ? 'page ${pages.first}' : '${pages.length} pages';
    final dir = ccw ? '-90' : '+90';
    _showSnack('Rotating $label $dir°…');
    _doc?.dispose(); _doc = null; _pageCache.clear(); _currentImage = null; _thumbs.clear();
    final pageSpec = (pages.toList()..sort()).join(',');
    final ok = await rotatePages(widget.filePath, dir, pages: pageSpec);
    _selectedPages.clear();
    await _tryOpen(widget.filePath);
    _showSnack(ok ? 'Rotated $label $dir°' : 'Rotate failed');
  }

  // ── Delete selected pages ──
  Future<void> _onDeletePages() async {
    final pages = _selectedPages.isNotEmpty ? _selectedPages : {_currentPage + 1};
    final label = pages.length == 1 ? 'page ${pages.first}' : '${pages.length} pages';
    final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text('Delete $label?'), content: const Text('This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
      ],
    ));
    if (confirm != true) return;
    _showSnack('Deleting $label…');
    _doc?.dispose(); _doc = null; _pageCache.clear(); _currentImage = null; _thumbs.clear();
    final ok = await deletePages(widget.filePath, pages);
    _selectedPages.clear();
    await _tryOpen(widget.filePath);
    _showSnack(ok ? 'Deleted $label' : 'Delete failed');
  }

  // ── Extract selected pages ──
  Future<void> _onExtractPages() async {
    final pages = _selectedPages.isNotEmpty ? _selectedPages : {_currentPage + 1};
    String? dirPath;
    try { dirPath = await const MethodChannel('com.xmate/picker').invokeMethod<String>('pickFolder'); } catch (_) {}
    if (dirPath == null || dirPath.isEmpty) return;
    final pdfName = widget.filePath.split(RegExp(r'[/\\]')).last.replaceAll('.pdf', '');
    final outPath = '$dirPath\\${pdfName}_extracted.pdf';
    _showSnack('Extracting…');
    final ok = await extractPages(widget.filePath, pages, outPath);
    if (ok) { _selectedPages.clear(); if (mounted) setState(() {}); _showSnack('Saved: ${pdfName}_extracted.pdf'); }
    else { _showSnack('Extract failed'); }
  }

  // ── Info panel ──
  Future<void> _onShowInfo() async {
    final cs = Theme.of(context).colorScheme;
    final fileSize = File(widget.filePath).lengthSync();
    final sizeStr = _fmtBytes(fileSize);
    Map<String, dynamic>? info;
    try { info = await getPdfInfo(widget.filePath); } catch (_) {}
    if (!mounted) return;
    final result = await showDialog<Map<String, String>>(
      context: context, barrierColor: Colors.transparent,
      builder: (ctx) => _PdfInfoDialog(
        cs: cs, info: info, sizeStr: sizeStr, pages: _totalPages, filePath: widget.filePath),
    );
    if (result == null) return;
    _doc?.dispose(); _doc = null; _pageCache.clear(); _currentImage = null; _thumbs.clear();
    _selectedPages.clear();
    if (result.containsKey('_optimize')) {
      await _tryOpen(widget.filePath);
    } else {
      final ok = await setPdfMetadata(widget.filePath,
          title: result['title'], author: result['author'],
          subject: result['subject'], keywords: result['keywords']);
      _showSnack(ok ? 'Metadata updated' : 'Metadata update failed');
      await _tryOpen(widget.filePath);
    }
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
'''
data = data.replace(marker, ops + marker)

# === 2. Replace bottom bar ===
old_bar = '''      Positioned(bottom: 8, right: 8, child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(color: cs.onSurface.withAlpha(54), borderRadius: BorderRadius.circular(4)),
          child: Text('${_currentPage + 1} / $_totalPages', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withAlpha(179), fontSize: 12)))),
    ]));
  });'''

new_bar = r'''      Positioned(bottom: 8, right: 8, child: Row(mainAxisSize: MainAxisSize.min, children: [
        _qlBtn(cs, Icons.file_copy, 'Extract', _onExtractPages), const SizedBox(width: 6),
        _qlBtn(cs, Icons.delete_outline, 'Delete', _onDeletePages), const SizedBox(width: 6),
        _qlBtn(cs, Icons.rotate_right, 'L=+90° / R=-90°', () => _onRotate(), onSecondaryTap: () => _onRotate(ccw: true)), const SizedBox(width: 6),
        _qlBtn(cs, Icons.info_outline, 'Info', _onShowInfo), const SizedBox(width: 6),
        if (_selectedPages.isNotEmpty)
          Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(color: cs.primary.withAlpha(40), borderRadius: BorderRadius.circular(4)),
            child: Text('${_selectedPages.length} sel', style: TextStyle(color: cs.primary, fontSize: 11, fontWeight: FontWeight.w600))),
        const SizedBox(width: 6),
        Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(color: cs.onSurface.withAlpha(54), borderRadius: BorderRadius.circular(4)),
          child: Text('${_currentPage + 1} / $_totalPages', style: TextStyle(color: cs.onSurface.withAlpha(179), fontSize: 12))),
      ])),
    ]));
  });

  Widget _qlBtn(ColorScheme cs, IconData icon, String tooltip, VoidCallback onTap, {VoidCallback? onSecondaryTap}) {
    return GestureDetector(
      onTap: onTap, onSecondaryTap: onSecondaryTap,
      child: Tooltip(message: tooltip, child: Container(width: 32, height: 32,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), color: cs.onSurface.withAlpha(12)),
        alignment: Alignment.center,
        child: Icon(icon, size: 18, color: cs.onSurface.withAlpha(179)))),
    );
  }'''

assert old_bar in data, 'Bottom bar not found'
data = data.replace(old_bar, new_bar)

# === 3. Replace _buildThumb with multi-select version ===
old_thumb = '''  Widget _buildThumb(int page) {
    final cs = Theme.of(context).colorScheme;
    final cur = page == _currentPage, t = _thumbs[page];
    return GestureDetector(onTap: () => _goToPage(page),
        child: Container(margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(border: Border.all(color: cur ? cs.primary : cs.onSurface.withAlpha(61), width: cur ? 2.0 : 1.0),
                borderRadius: BorderRadius.circular(4), color: cs.onSurface.withAlpha(26)),
            child: Stack(children: [
              if (t != null) ClipRRect(borderRadius: BorderRadius.circular(3), child: Image.memory(t, fit: BoxFit.contain, width: _thumbW - 14))
              else Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.5, color: cs.onSurface.withAlpha(61)))),
              Positioned(bottom: 0, right: 0, child: Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(color: cur ? cs.primary : cs.onSurface.withAlpha(54), borderRadius: const BorderRadius.only(topLeft: Radius.circular(4))),
                  child: Text('${page + 1}', style: TextStyle(fontSize: 10, color: cur ? cs.onPrimary : cs.onSurface.withAlpha(179), fontWeight: FontWeight.bold)))),
            ])));'''

new_thumb = r'''  Widget _buildThumb(int page) {
    final cs = Theme.of(context).colorScheme;
    final cur = page == _currentPage, t = _thumbs[page];
    final sel = _selectedPages.contains(page + 1);
    final borderColor = sel ? cs.primary : cur ? cs.primary.withAlpha(200) : cs.onSurface.withAlpha(61);
    final borderWidth = (sel || cur) ? 2.0 : 1.0;
    return GestureDetector(
      onTap: () {
        final keys = HardwareKeyboard.instance.logicalKeysPressed;
        if (keys.contains(LogicalKeyboardKey.controlLeft) || keys.contains(LogicalKeyboardKey.controlRight)) {
          setState(() { final p = page + 1; if (_selectedPages.contains(p)) _selectedPages.remove(p); else _selectedPages.add(p); });
        } else if (keys.contains(LogicalKeyboardKey.shiftLeft) || keys.contains(LogicalKeyboardKey.shiftRight)) {
          setState(() { final s = (_currentPage + 1).clamp(1, _totalPages), e = (page + 1).clamp(1, _totalPages);
            for (int i = s < e ? s : e; i <= (s < e ? e : s); i++) _selectedPages.add(i); });
        } else { setState(() => _selectedPages.clear()); _goToPage(page); }
      },
      child: Container(margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(border: Border.all(color: borderColor, width: borderWidth),
          borderRadius: BorderRadius.circular(4), color: sel ? cs.primary.withAlpha(20) : cs.onSurface.withAlpha(26)),
        child: Stack(children: [
          if (t != null) ClipRRect(borderRadius: BorderRadius.circular(3), child: Image.memory(t, fit: BoxFit.contain, width: _thumbW - 14))
          else Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.5, color: cs.onSurface.withAlpha(61)))),
          if (sel) Positioned(top: 2, right: 2, child: Container(width: 16, height: 16,
            decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
            child: Icon(Icons.check, size: 10, color: cs.onPrimary))),
          Positioned(bottom: 0, right: 0, child: Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(color: (cur || sel) ? cs.primary : cs.onSurface.withAlpha(54), borderRadius: const BorderRadius.only(topLeft: Radius.circular(4))),
            child: Text('${page + 1}', style: TextStyle(fontSize: 10, color: (cur || sel) ? cs.onPrimary : cs.onSurface.withAlpha(179), fontWeight: FontWeight.bold)))),
        ])));'''

assert old_thumb in data, 'Thumb method not found'
data = data.replace(old_thumb, new_thumb)

# === 4. Replace _toolbarH to accommodate new bottom bar ===
# (no change needed — _toolbarH is just the toolbar)

# === 5. Add _PdfInfoDialog class before _Hk ===
old_hk = '\nclass _Hk extends StatelessWidget {'
dialog = r'''

// ================================================================
// Info dialog
// ================================================================

class _PdfInfoDialog extends StatefulWidget {
  final ColorScheme cs;
  final Map<String, dynamic>? info;
  final String sizeStr;
  final int pages;
  final String filePath;
  const _PdfInfoDialog({required this.cs, this.info, required this.sizeStr,
    required this.pages, required this.filePath});
  @override State<_PdfInfoDialog> createState() => _PdfInfoDialogState();
}

class _PdfInfoDialogState extends State<_PdfInfoDialog> {
  late final TextEditingController _titleC, _authorC, _subjectC, _kwC;
  bool _optimizing = false, _saving = false;

  @override void initState() {
    super.initState();
    final i = widget.info;
    _titleC   = TextEditingController(text: i?['title'] as String? ?? '');
    _authorC  = TextEditingController(text: i?['author'] as String? ?? '');
    _subjectC = TextEditingController(text: i?['subject'] as String? ?? '');
    _kwC      = TextEditingController(text: i?['keywords'] as String? ?? '');
  }
  @override void dispose() { _titleC.dispose(); _authorC.dispose(); _subjectC.dispose(); _kwC.dispose(); super.dispose(); }

  @override Widget build(BuildContext ctx) {
    final cs = widget.cs;
    return AlertDialog(
      backgroundColor: cs.surface, surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.primary.withAlpha(80), width: 1)),
      title: Row(children: [
        Text('PDF Info', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const Spacer(),
        IconButton(icon: Icon(Icons.close, size: 20, color: cs.onSurface.withAlpha(150)), onPressed: () => Navigator.pop(context), padding: EdgeInsets.zero, constraints: const BoxConstraints()),
      ]),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        _row(cs, 'Pages', '${widget.pages}'), _row(cs, 'Size', widget.sizeStr),
        if (widget.info?['version'] != null) _row(cs, 'Version', '${widget.info!['version']}'),
        if (widget.info?['encrypted'] != null) _row(cs, 'Encrypted', '${widget.info!['encrypted']}'),
        const SizedBox(height: 12),
        Text('Metadata', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface)), const SizedBox(height: 4),
        _field(cs, 'Title', _titleC), _field(cs, 'Author', _authorC),
        _field(cs, 'Subject', _subjectC), _field(cs, 'Keywords', _kwC),
      ])),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      actions: [Row(children: [
        OutlinedButton.icon(
          icon: _optimizing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.compress, size: 18),
          label: Text(_optimizing ? '...' : 'Optimize'), onPressed: _optimizing ? null : () => _doOptimize()),
        const SizedBox(width: 8),
        TextButton(onPressed: _saving ? null : () => _doSaveMetadata(), child: Text(_saving ? '...' : 'Save Metadata')),
        const Spacer(),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ])],
    );
  }

  Future<void> _doOptimize() async {
    final fp = widget.filePath; setState(() => _optimizing = true);
    final oldSize = File(fp).lengthSync();
    Navigator.pop(context, {'_optimize': '1'});
    try {
      final tmp = '${fp}_opt_tmp';
      final r = await runQpdf(['--object-streams=generate', '--recompress-flate', '--remove-unreferenced-resources=auto', fp, tmp]);
      if (r.success) {
        try { File(fp).deleteSync(); File(tmp).renameSync(fp); } catch (_) { File(tmp).copySync(fp); File(tmp).deleteSync(); }
        _snack('Optimized: ${_fmtBytes2(oldSize)} -> ${_fmtBytes2(File(fp).lengthSync())} (${((1 - File(fp).lengthSync() / oldSize) * 100).round()}%)');
      } else { _snack('Optimize failed: ${r.errorMessage}'); }
    } catch (e) { _snack('Optimize error: $e'); }
  }

  Future<void> _doSaveMetadata() async {
    setState(() => _saving = true);
    Navigator.pop(context, {'title': _titleC.text, 'author': _authorC.text,
      'subject': _subjectC.text, 'keywords': _kwC.text});
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg),
      duration: const Duration(milliseconds: 1200), behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.only(left: 16, bottom: 8, right: 500)));
  }

  Widget _row(ColorScheme cs, String label, String value) =>
      Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(children: [
        SizedBox(width: 72, child: Text(label, style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(160)))),
        Expanded(child: Text(value, style: TextStyle(fontSize: 12, color: cs.onSurface)))]));

  Widget _field(ColorScheme cs, String label, TextEditingController ctrl) =>
      Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(children: [
        SizedBox(width: 72, child: Text(label, style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(160)))),
        Expanded(child: SizedBox(height: 32, child: TextField(controller: ctrl,
          style: TextStyle(fontSize: 12, color: cs.onSurface),
          decoration: InputDecoration(contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(4))))))]));

  static String _fmtBytes2(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
'''
data = data.replace(old_hk, dialog + old_hk)

with open(path, 'w', encoding='utf-8') as f:
    f.write(data)
print('All changes applied successfully')
