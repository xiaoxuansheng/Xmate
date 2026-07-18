/// PDF preview with annotations for QuickLook.
///
/// Layout: toolbar (top) → split pane (thumbnails | full page).
/// - 360 DPI rendering, auto fit-zoom display.
/// - Scroll-wheel zoom (no Ctrl), middle-button pan.
/// - Right-click: tool switching; tool options memory per context.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:window_manager/window_manager.dart';
import '../../../core/annotate/annotate_models.dart';
import '../../../core/annotate/annotate_toolbar.dart';
import '../../../core/annotate/annotate_canvas.dart' show
    getAnnBounds, hitTestAnnotation, hitTestAnnHandle,
    drawAnnotation, drawEraserMask, drawArrowHead,
    getOrAssignAnnOrderWithCache, EraserMask, AnnHandle, translateAnn,
    resizeAnn, rotateAnn;
import '../../../core/settings/settings_service.dart';
import '../../../core/search/search_engine_service.dart';
import '../../../core/annotate/magnifier.dart';
import 'pdf_page_cache.dart';
import 'ql_pdf_utils.dart';
import '../../../../core/theme/theme_colors.dart';

// ══════════════════════════════════════════════════════════════════════
// Per-page annotation state
// ══════════════════════════════════════════════════════════════════════

class _PageAnnotations {
  final List<AnnotationShape> shapes = [];
  final List<EraserMask> eraserMasks = [];
  final List<List<AnnotationShape>> undoStack = [];
  final List<List<AnnotationShape>> redoStack = [];
  final Map<String, int> annOrderCache = {};
  int nextId = 1;
  int orderCounter = 0;
  String? selAnnId;

  int assignOrder(AnnotationShape a) =>
      getOrAssignAnnOrderWithCache(a, annOrderCache, () => ++orderCounter);

  void addAnnotation(AnnotationShape a) {
    undoStack.add(shapes.toList());
    redoStack.clear();
    shapes.add(a);
    selAnnId = a.id;
  }

  void deleteAnnotation(String id) {
    final idx = shapes.indexWhere((a) => a.id == id);
    if (idx == -1) return;
    undoStack.add(shapes.toList());
    redoStack.clear();
    shapes.removeAt(idx);
    if (selAnnId == id) selAnnId = null;
  }

  bool get canUndo => undoStack.isNotEmpty;
  bool get canRedo => redoStack.isNotEmpty;

  void undo() {
    if (!canUndo) return;
    redoStack.add(shapes.toList());
    shapes..clear()..addAll(undoStack.removeLast());
    selAnnId = null;
  }

  void redo() {
    if (!canRedo) return;
    undoStack.add(shapes.toList());
    shapes..clear()..addAll(redoStack.removeLast());
    selAnnId = null;
  }

  AnnotationShape? get selected {
    if (selAnnId == null) return null;
    try { return shapes.firstWhere((a) => a.id == selAnnId); }
    catch (_) { return null; }
  }
}

// ══════════════════════════════════════════════════════════════════════
// Options persistence key & helpers
// ══════════════════════════════════════════════════════════════════════

class _ToolOptionsStore {
  static const _prefix = 'pdf.annotate';
  final SettingsService _ss = SettingsService();

  ToolOptions load() {
    try {
      final json = _ss.get('$_prefix.toolOptions');
      if (json is Map) {
        return ToolOptions(
          color: _parseColor(json['color']) ?? Colors.red,
          strokeWidth: (json['strokeWidth'] as num?)?.toDouble() ?? 2.0,
          lineStyle: LineStyle.values.elementAtOrNull(json['lineStyle'] ?? 0) ?? LineStyle.solid,
          shapeKind: ShapeKind.values.elementAtOrNull(json['shapeKind'] ?? 0) ?? ShapeKind.rectangle,
          cornerRadius: (json['cornerRadius'] as num?)?.toDouble() ?? 8.0,
          fillStyle: FillStyle.values.elementAtOrNull(json['fillStyle'] ?? 0) ?? FillStyle.none,
          startHead: ArrowHeadStyle.values.elementAtOrNull(json['startHead'] ?? 0) ?? ArrowHeadStyle.none,
          endHead: ArrowHeadStyle.values.elementAtOrNull(json['endHead'] ?? 0) ?? ArrowHeadStyle.arrow,
          bold: json['bold'] == true,
          italic: json['italic'] == true,
          outline: json['outline'] == true,
          fontSize: (json['fontSize'] as num?)?.toDouble() ?? 18,
          fontFamily: json['fontFamily'] as String?,
          numberTagStyle: NumberTagStyle.values.elementAtOrNull(json['numberTagStyle'] ?? 0) ?? NumberTagStyle.circleOutline,
          numberTagSize: (json['numberTagSize'] as num?)?.toDouble() ?? 16,
          mosaicMode: MosaicMode.values.elementAtOrNull(json['mosaicMode'] ?? 0) ?? MosaicMode.line,
          mosaicCellSize: (json['mosaicCellSize'] as num?)?.toDouble() ?? 10.0,
          mosaicEffect: MosaicEffect.values.elementAtOrNull(json['mosaicEffect'] ?? 0) ?? MosaicEffect.pixelate,
          mosaicBlurAmount: (json['mosaicBlurAmount'] as num?)?.toDouble() ?? 1.0,
          textStyleKind: TextStyleKind.values.elementAtOrNull(json['textStyleKind'] ?? 0) ?? TextStyleKind.plain,
        );
      }
    } catch (_) {}
    return const ToolOptions();
  }

  void save(ToolOptions o) {
    _ss.set('$_prefix.toolOptions', {
      'color': o.color.toARGB32(),
      'strokeWidth': o.strokeWidth,
      'lineStyle': o.lineStyle.index,
      'shapeKind': o.shapeKind.index,
      'cornerRadius': o.cornerRadius,
      'fillStyle': o.fillStyle.index,
      'startHead': o.startHead.index,
      'endHead': o.endHead.index,
      'bold': o.bold,
      'italic': o.italic,
      'outline': o.outline,
      'fontSize': o.fontSize,
      'fontFamily': o.fontFamily,
      'numberTagStyle': o.numberTagStyle.index,
      'numberTagSize': o.numberTagSize,
      'mosaicMode': o.mosaicMode.index,
      'mosaicCellSize': o.mosaicCellSize,
      'mosaicEffect': o.mosaicEffect.index,
      'mosaicBlurAmount': o.mosaicBlurAmount,
      'textStyleKind': o.textStyleKind.index,
    });
  }

  Color? _parseColor(dynamic v) {
    if (v is int) return Color(v);
    return null;
  }
}

// ══════════════════════════════════════════════════════════════════════
// Main widget
// ══════════════════════════════════════════════════════════════════════

class QuickLookPdfView extends StatefulWidget {
  final String filePath;
  final VoidCallback onClose;
  const QuickLookPdfView({super.key, required this.filePath, required this.onClose});
  @override State<QuickLookPdfView> createState() => _QuickLookPdfViewState();
}

class _QuickLookPdfViewState extends State<QuickLookPdfView> {
  // ── PDF ──
  pdfrx.PdfDocument? _doc;
  String? _error;
  int _totalPages = 0, _currentPage = 0;

  // ── Page image cache ──
  late final PdfPageCache _pageCache;
  ui.Image? _currentImage;
  Uint8List? _imageRgba; // for magnifier pixel sampling

  // ── Constants ──
  static const double _renderScale = 360.0 / 72.0;
  static const double _displayZoom = 0.60;
  static const double _overflow = 200.0;
  static const double _toolbarH = 88.0;
  static const double _thumbW = 150.0;

  // ── Options persistence ──
  late final _ToolOptionsStore _optsStore;

  // ── Thumbnails ──
  final ScrollController _thumbScroll = ScrollController();
  final Map<int, Uint8List> _thumbs = {};
  bool _thumbLoading = false;

  // ── Zoom / pan ──
  final TransformationController _tc = TransformationController();
  VoidCallback? _tcListener;
  double _currentZoom = _displayZoom;
  bool _currentZoomApplied = false;
  double _viewportW = 0, _viewportH = 0;

  // ── Middle-button pan ──
  bool _midPanning = false;
  Offset? _midLast;

  // ── Per-page annotation state ──
  final Map<int, _PageAnnotations> _pages = {};
  AnnotationTool _tool = AnnotationTool.mouse;
  ToolOptions _opts = const ToolOptions();

  // ── Editing ──
  AnnHandle? _edDrag;
  Rect? _edBase;
  AnnotationShape? _edBaseObj;
  Offset? _edLastPos;

  // ── Drawing preview ──
  Offset? _drawStart, _drawCurrent;
  final List<Offset> _freehandPts = [];

  // ── Text editing (in-place) ──
  bool _tx = false;
  Offset _tP = Offset.zero;
  final TextEditingController _tC = TextEditingController();
  final FocusNode _tF = FocusNode();

  // ── Magnifier ──
  bool _showMagnifier = false;

  // ── Help ──
  bool _showHelp = false;

  // ── Text selection ──
  pdfrx.PdfPageText? _pageText;
  int _textSelBase = -1;
  int _textSelExt = -1;
  bool _textSelecting = false;

  // ── Text search ──
  bool _searchVisible = false;
  final TextEditingController _searchC = TextEditingController();
  final FocusNode _searchF = FocusNode();
  List<(int, int)> _searchMatches = const [];
  int _searchCur = -1;
  // ── qpdf operations ──
  final Set<int> _selectedPages = {};
  String? _decryptTmp;
  String? _savedPassword; // stored after successful unlock, for "Remove Encryption"

  bool _searchCaseSensitive = false;

  _PageAnnotations get _pa => _pages.putIfAbsent(_currentPage, () => _PageAnnotations());

  /// Handle size scale factor = 1 / zoom so handles stay ~same pixel size.
  /// Capped at 10x to prevent absurdly large handles at extreme zoom-out.
  double get _handleScale => (1.0 / _currentZoom).clamp(1.0, 10.0);

  // ══════════════════════════════════════════════════════════════════
  // Lifecycle
  // ══════════════════════════════════════════════════════════════════

  @override void initState() {
    super.initState();
    _pageCache = PdfPageCache(maxSize: 20);
    _optsStore = _ToolOptionsStore();
    // SettingsService may not be initialised in the QL subprocess —
    // initialise it now so options persistence works.
    SettingsService().init().then((_) {
      if (mounted) setState(() => _opts = _optsStore.load());
    });
    _opts = _optsStore.load(); // synchronous try first (may be empty)
    _tcListener = () { if (mounted) setState(() {}); };
    _tc.addListener(_tcListener!);
    _tF.addListener(() { if (mounted && !_tF.hasFocus) _finishTextEdit(); });
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    _load();
  }

  @override void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    _tc.removeListener(_tcListener!); _tc.dispose();
    _thumbScroll.dispose();
    _tC.dispose(); _tF.dispose();
    _pageCache.clear(); _currentImage = null;
    _doc?.dispose();
    _cleanupDecryptTmp();
    super.dispose();
  }

  void _cleanupDecryptTmp() {
    if (_decryptTmp != null) {
      try { File(_decryptTmp!).deleteSync(); } catch (_) {}
      _decryptTmp = null;
    }
    _savedPassword = null;
  }

  // ══════════════════════════════════════════════════════════════════
  // Load & size
  // ══════════════════════════════════════════════════════════════════

  Future<void> _load() async { _centerWindow(500, 380); await _tryOpen(widget.filePath); }

  Future<void> _tryOpen(String path) async {
    try {
      final doc = await pdfrx.PdfDocument.openFile(path);
      if (!mounted) { doc.dispose(); return; }
      _doc = doc;
      _totalPages = doc.pages.length.clamp(1, 10000);
      _selectedPages.clear();
      setState(() { _currentPage = 0; _error = null; });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _resizeWindowForPage(doc.pages[0].width, doc.pages[0].height);
        _renderCurrentPage(); _renderVisibleThumbs();
      });
    } catch (e) {
      if (!mounted) return;
      final msg = '$e';
      if (msg.toLowerCase().contains('password') || msg.toLowerCase().contains('encrypt')) {
        _promptPassword();
      } else {
        setState(() => _error = msg);
      }
    }
  }

  Future<void> _promptPassword() async {
    final pwdC = TextEditingController();
    final result = await showDialog<String>(
      context: context, barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Password Required'),
        content: TextField(controller: pwdC, obscureText: true, autofocus: true,
          decoration: const InputDecoration(hintText: 'Enter PDF password'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(pwdC.text), child: const Text('Unlock')),
        ],
      ),
    );
    if (result == null || result.isEmpty) {
      if (mounted) setState(() => _error = 'Password required to open this PDF');
      return;
    }
    if (!mounted) return;
    _cleanupDecryptTmp();
    _savedPassword = result;
    final tmpPath = '${Directory.systemTemp.path}\\xmate_ql_decrypt_${DateTime.now().millisecondsSinceEpoch}.pdf';
    final dr = await decryptPdf(widget.filePath, result, tmpPath);
    if (!dr.success) { _savedPassword = null; setState(() => _error = 'Incorrect password or decryption failed'); return; }
    _decryptTmp = tmpPath;
    await _tryOpen(tmpPath);
  }

  void _centerWindow(double w, double h) {
    final display = ui.PlatformDispatcher.instance.displays.first;
    final dpr = display.devicePixelRatio;
    final sw = display.size.width / dpr, sh = display.size.height / dpr;
    windowManager.setBounds(Rect.fromLTWH(
        ((sw - w) / 2).clamp(0.0, sw - w), ((sh - h) / 2).clamp(0.0, sh - h), w, h), animate: false);
  }

  Future<void> _resizeWindowForPage(double ptW, double ptH) async {
    if (ptW <= 0 || ptH <= 0) return;
    final dispW = ptW * _renderScale * _displayZoom;
    final dispH = ptH * _renderScale * _displayZoom;
    final display = ui.PlatformDispatcher.instance.displays.first;
    final dpr = display.devicePixelRatio;
    final screenW = display.size.width / dpr, screenH = display.size.height / dpr;
    const minW = 750.0; // enough for the toolbar to display fully
    _centerWindow((dispW + _thumbW).clamp(minW, screenW * 0.85), (dispH + _toolbarH).clamp(300.0, screenH * 0.85));
  }

  // ══════════════════════════════════════════════════════════════════
  // Page rendering
  // ══════════════════════════════════════════════════════════════════

  Future<void> _renderCurrentPage() async {
    if (_doc == null) return;
    final pi = _currentPage;
    final cached = _pageCache.get(pi);
    if (cached != null) {
      _currentImage = cached; _cacheImageRgba();
      if (mounted) setState(() {});
      _loadPageText(pi);
      _preloadNearbyPages(pi); // start background preload
      return;
    }
    await _renderPage(pi);
    if (pi == _currentPage && mounted) {
      final img = _pageCache.get(pi);
      if (img != null) { _currentImage = img; _cacheImageRgba(); setState(() {}); _loadPageText(pi); }
    }
    _preloadNearbyPages(pi);
  }

  /// Render a single page into [_pageCache] (no UI update).
  Future<void> _renderPage(int pi) async {
    if (_pageCache.contains(pi)) return;
    final page = _doc!.pages[pi];
    final rw = page.width * _renderScale, rh = page.height * _renderScale;
    final raw = await page.render(fullWidth: rw, fullHeight: rh);
    if (raw == null || !mounted) return;
    final img = await raw.createImage(); raw.dispose();
    if (!mounted) { img.dispose(); return; }
    _pageCache.put(pi, img);
  }

  /// Preload pages near [center] in expanding radius (center±1, ±2, …, ±radius).
  /// Runs asynchronously; each page only renders if not already cached.
  bool _preloading = false;
  static const _preloadRadius = 3;

  Future<void> _preloadNearbyPages(int center) async {
    if (_preloading) return; // one preload batch at a time
    _preloading = true;
    try {
      for (int r = 1; r <= _preloadRadius; r++) {
        // Render center+r first (forward direction), then center-r (backward).
        // This prioritizes forward scrolling — the more common direction.
        if (_currentPage != center) break; // user navigated away
        final ahead = center + r, behind = center - r;
        if (ahead >= 0 && ahead < _totalPages) await _renderPage(ahead);
        if (!mounted || _currentPage != center) break;
        if (behind >= 0 && behind < _totalPages) await _renderPage(behind);
      }
    } finally {
      _preloading = false;
    }
  }

  void _cacheImageRgba() {
    if (_currentImage == null) { _imageRgba = null; return; }
    _currentImage!.toByteData(format: ui.ImageByteFormat.rawRgba).then((d) {
      if (mounted) _imageRgba = d?.buffer.asUint8List();
    });
  }

  // ── PDF text extraction ──

  Future<void> _loadPageText(int page) async {
    final doc = _doc; if (doc == null || page != _currentPage) return;
    try {
      final pt = await doc.pages[page].loadStructuredText();
      if (page == _currentPage && mounted) {
        _pageText = pt;
        // Update selection paint if text is already loaded; otherwise clear.
        // _textSelBase / _textSelExt are not automatically cleared here —
        // switching pages clears them in _goToPage.
      }
    } catch (_) {
      // Scanned PDFs or pages without a text layer — ignore silently.
      _pageText = null;
    }
  }

  /// PDF point (1/72 inch) → rendered image pixel coordinate (X only).
  static double _pdfToPixelX(double pdfPt) => pdfPt * _renderScale;

  double get _pageImageH {
    final img = _currentImage;
    if (img != null) return img.height.toDouble();
    // fallback: compute from page dimensions
    if (_doc != null && _currentPage < _doc!.pages.length) {
      return _doc!.pages[_currentPage].height * _renderScale;
    }
    return 0;
  }

  /// Find the character index at [imagePos] in [_pageText].
  /// Uses nearest-character distance matching for robustness at line ends.
  int _findCharAt(Offset imagePos) {
    final pt = _pageText; if (pt == null) return -1;
    final imgH = _pageImageH; if (imgH <= 0) return -1;
    int globalIdx = 0;
    int bestIdx = -1;
    double bestDist = double.infinity;
    for (final frag in pt.fragments) {
      Offset? lastTL, lastBR;
      for (int i = 0; i < frag.charRects.length && i < frag.text.length; i++) {
        final cr = frag.charRects[i];
        final r = Rect.fromLTWH(
          _pdfToPixelX(cr.left),
          imgH - _pdfToPixelX(cr.top),
          math.max(_pdfToPixelX(cr.width), 2.0),
          math.max(_pdfToPixelX(cr.height), 2.0),
        );
        lastTL = r.topLeft; lastBR = r.bottomRight;
        if (r.contains(imagePos)) return globalIdx;
        final d = _rectDist(r, imagePos);
        if (d < bestDist) { bestDist = d; bestIdx = globalIdx; }
        globalIdx++;
      }
      final extra = frag.text.length - frag.charRects.length;
      if (extra > 0 && lastTL != null && lastBR != null) {
        final avgW = (lastBR.dx - lastTL.dx).clamp(2.0, 20.0);
        for (int j = 0; j < extra; j++) {
          final er = Rect.fromLTWH(lastBR.dx + avgW * j, lastTL.dy, avgW, (lastBR.dy - lastTL.dy).abs());
          if (er.contains(imagePos)) return globalIdx;
          final d2 = _rectDist(er, imagePos);
          if (d2 < bestDist) { bestDist = d2; bestIdx = globalIdx; }
          globalIdx++;
        }
      } else {
        globalIdx += extra;
      }
    }
    return bestDist < 24.0 ? bestIdx : -1;
  }

  double _rectDist(Rect r, Offset p) {
    final dx = math.max(0.0, math.max(r.left - p.dx, p.dx - r.right));
    final dy = math.max(0.0, math.max(r.top - p.dy, p.dy - r.bottom));
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Build a list of (globalCharIndex, pixelRect) for all chars in [_pageText].
  List<(int, Rect)> _buildCharRects() {
    final pt = _pageText;
    final result = <(int, Rect)>[];
    if (pt == null) return result;
    final imgH = _pageImageH; if (imgH <= 0) return result;
    int globalIdx = 0;
    for (final frag in pt.fragments) {
      Offset? lastTL, lastBR;
      for (int i = 0; i < frag.charRects.length && i < frag.text.length; i++) {
        final cr = frag.charRects[i];
        final r = Rect.fromLTWH(
          _pdfToPixelX(cr.left),
          imgH - _pdfToPixelX(cr.top),
          math.max(_pdfToPixelX(cr.width), 2.0),
          math.max(_pdfToPixelX(cr.height), 2.0),
        );
        lastTL = r.topLeft; lastBR = r.bottomRight;
        result.add((globalIdx, r));
        globalIdx++;
      }
      // Estimated rects for chars without explicit charRects
      final extra = frag.text.length - frag.charRects.length;
      if (extra > 0 && lastTL != null && lastBR != null) {
        final avgW = (lastBR.dx - lastTL.dx).clamp(2.0, 20.0);
        for (int j = 0; j < extra; j++) {
          result.add((globalIdx, Rect.fromLTWH(lastBR.dx + avgW * j, lastTL.dy, avgW, (lastBR.dy - lastTL.dy).abs())));
          globalIdx++;
        }
      } else {
        globalIdx += extra;
      }
    }
    return result;
  }

  /// Get selected text string from the current selection range.
  String _getSelectedText() {
    final pt = _pageText; if (pt == null) return '';
    final base = _textSelBase, ext = _textSelExt;
    if (base < 0 || ext < 0 || base == ext) return '';
    final start = math.min(base, ext), end = math.max(base, ext);
    if (end > pt.fullText.length) return '';
    return pt.fullText.substring(start, end);
  }

  void _clearTextSelection() {
    _textSelBase = -1; _textSelExt = -1; _textSelecting = false;
  }

  bool get _hasTextSelection => _textSelBase >= 0 && _textSelExt >= 0 && _textSelBase != _textSelExt;

  void _selectAllText() {
    final pt = _pageText; if (pt == null) return;
    _textSelBase = 0;
    _textSelExt = pt.fullText.length;
    _textSelecting = false;
    setState(() {});
  }

  // ── Text search ──

  void _toggleSearch() {
    _searchVisible = !_searchVisible;
    if (_searchVisible) {
      _searchC.clear();
      _searchMatches = const [];
      _searchCur = -1;
      _searchF.requestFocus();
    } else {
      _searchF.unfocus();
      _searchMatches = const [];
      _searchCur = -1;
    }
    setState(() {});
  }

  void _performSearch() {
    final pt = _pageText; if (pt == null) return;
    final q = _searchC.text;
    if (q.isEmpty) { _searchMatches = const []; _searchCur = -1; setState(() {}); return; }
    final matches = <(int, int)>[];
    final fullText = pt.fullText;
    final source = _searchCaseSensitive ? fullText : fullText.toLowerCase();
    final query = _searchCaseSensitive ? q : q.toLowerCase();
    int start = 0;
    while (true) {
      final idx = source.indexOf(query, start);
      if (idx < 0) break;
      matches.add((idx, idx + query.length));
      start = idx + 1;
    }
    _searchMatches = matches;
    _searchCur = matches.isEmpty ? -1 : 0;
    // Select and navigate to first match
    if (_searchCur >= 0) {
      final (s, e) = matches[_searchCur];
      _textSelBase = s; _textSelExt = e;
    }
    setState(() {});
  }

  void _nextSearchMatch() {
    if (_searchMatches.isEmpty) return;
    _searchCur = (_searchCur + 1) % _searchMatches.length;
    final (s, e) = _searchMatches[_searchCur];
    _textSelBase = s; _textSelExt = e;
    setState(() {});
  }

  void _prevSearchMatch() {
    if (_searchMatches.isEmpty) return;
    _searchCur = (_searchCur - 1 + _searchMatches.length) % _searchMatches.length;
    final (s, e) = _searchMatches[_searchCur];
    _textSelBase = s; _textSelExt = e;
    setState(() {});
  }

  // ── Right-click context menu ──

  void _showTextContextMenu(Offset viewportPos) {
    final hasSel = _hasTextSelection;
    final selText = hasSel ? _getSelectedText() : '';
    final cs = Theme.of(context).colorScheme;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(viewportPos.dx + 4, viewportPos.dy + 4, viewportPos.dx + 5, viewportPos.dy + 5),
      color: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xDD1A1A2E) : const Color(0xFFFFFFFF),
      items: [
        PopupMenuItem<String>(value: 'selectAll', child: Text('Select All  Ctrl+A',
            style: TextStyle(color: cs.onSurface, fontSize: 13))),
        if (hasSel)
          PopupMenuItem<String>(value: 'copy', child: Text('Copy  Ctrl+C',
              style: TextStyle(color: cs.onSurface, fontSize: 13))),
        if (hasSel && selText.isNotEmpty)
          PopupMenuItem<String>(value: 'webSearch', child: Text('Web search',
              style: TextStyle(color: cs.onSurface, fontSize: 13))),
        PopupMenuItem<String>(value: 'search', child: Text('Find  Ctrl+F',
            style: TextStyle(color: cs.onSurface, fontSize: 13))),
      ],
    ).then((value) {
      if (value == 'selectAll') _selectAllText();
      if (value == 'copy' && hasSel) _copySelectedText();
      if (value == 'webSearch' && selText.isNotEmpty) _webSearchSelection(selText);
      if (value == 'search') _toggleSearch();
    });
  }

  void _webSearchSelection(String query) {
    final srv = SearchEngineService();
    final engine = srv.getDefaultEngine(SearchEngineCategory.text);
    if (engine == null) return;
    // Trim query to reasonable length for URL
    final q = query.replaceAll(RegExp(r'\s+'), ' ').trim();
    srv.execute(engine, q.length > 500 ? q.substring(0, 500) : q);
  }

  // ══════════════════════════════════════════════════════════════════
  // Thumbnails
  // ══════════════════════════════════════════════════════════════════

  double get _thumbH {
    if (_doc == null) return _thumbW * 1.414 + 8;
    final r = _doc!.pages.first.height / _doc!.pages.first.width;
    return (_thumbW * r + 8).clamp(60.0, 250.0);
  }

  Future<void> _renderVisibleThumbs() async {
    if (_doc == null || _thumbLoading) return;
    _thumbLoading = true;
    try {
      final vf = (_thumbScroll.offset / _thumbH).floor().clamp(0, _totalPages - 1);
      final vl = (_thumbScroll.hasClients
          ? ((_thumbScroll.offset + _thumbScroll.position.viewportDimension) / _thumbH).ceil()
          : 10).clamp(0, _totalPages - 1);
      final lo = (vf - 5).clamp(0, _totalPages - 1);
      final hi = (vl + 5).clamp(0, _totalPages - 1);

      // Render visible range first (expanding from center outward),
      // then fill in the remaining buffer pages.
      final center = ((vf + vl) / 2).round();
      final maxR = ((vf - lo).abs()).clamp((vl - center).abs(), (hi - center).abs()) + 5;
      for (int r = 0; r <= maxR && mounted; r++) {
        for (int sign in [1, -1]) {
          final i = center + sign * r;
          if (i < lo || i > hi || _thumbs.containsKey(i)) continue;
          try {
            final p = _doc!.pages[i];
            final tw = (_thumbW * 2).round(), th = (tw * p.height / p.width).round();
            final raw = await p.render(fullWidth: tw.toDouble(), fullHeight: th.toDouble());
            if (raw == null || !mounted) continue;
            final ti = await raw.createImage(); raw.dispose();
            final data = await ti.toByteData(format: ui.ImageByteFormat.png); ti.dispose();
            if (!mounted || data == null) continue;
            _thumbs[i] = data.buffer.asUint8List();
            if (mounted) setState(() {});
          } catch (_) {}
        }
      }
    } finally { _thumbLoading = false; }
  }

  void _onThumbScroll() { if (mounted) _renderVisibleThumbs(); }

  // ══════════════════════════════════════════════════════════════════
  // Navigation
  // ══════════════════════════════════════════════════════════════════

  void _goToPage(int page) {
    if (page == _currentPage || page < 0 || page >= _totalPages) return;
    _cancelDrawing();
    _clearTextSelection();
    _pageText = null;
    setState(() { _currentPage = page; _currentImage = null; _imageRgba = null; _currentZoomApplied = false; });
    final p = _doc!.pages[page];
    _resizeWindowForPage(p.width, p.height);
    // Scroll the thumbnail sidebar so the current page stays visible.
    if (_thumbScroll.hasClients) {
      final vp = _thumbScroll.position.viewportDimension;
      final top = page * _thumbH;
      final bottom = top + _thumbH;
      if (top < _thumbScroll.offset) {
        _thumbScroll.jumpTo(top.toDouble());
      } else if (bottom > _thumbScroll.offset + vp) {
        _thumbScroll.jumpTo((bottom - vp).toDouble());
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) { _renderCurrentPage(); });
  }

  // ══════════════════════════════════════════════════════════════════
  // Zoom (scroll wheel — no Ctrl)
  // ══════════════════════════════════════════════════════════════════

  void _onPageAreaWheel(PointerScrollEvent e) {
    final ns = (_currentZoom * (1 - e.scrollDelta.dy * 0.001)).clamp(0.2, 5.0);
    _setZoom(ns);
  }

  void _setZoom(double zoom) {
    if (_currentImage == null) return;
    _currentZoom = zoom;
    final iw = _currentImage!.width.toDouble(), ih = _currentImage!.height.toDouble();
    final ox = _overflow * zoom, oy = _overflow * zoom;
    final w = iw * zoom + ox * 2, h = ih * zoom + oy * 2;
    final tx = (_viewportW - w) / 2, ty = (_viewportH - h) / 2;
    final m = Matrix4.diagonal3Values(zoom, zoom, 1);
    m.setTranslationRaw(tx, ty, 0);
    _tc.value = m;
  }

  // ══════════════════════════════════════════════════════════════════
  // Coordinate helpers
  // ══════════════════════════════════════════════════════════════════

  Offset _toImageSpace(Offset viewportPos) {
    final m = Matrix4.inverted(_tc.value);
    final childPos = MatrixUtils.transformPoint(m, viewportPos);
    return childPos - Offset(_overflow, _overflow);
  }

  void _onPointerDownViewport(PointerDownEvent e) => _onPointerDown(e);
  void _onPointerMoveViewport(PointerMoveEvent e) => _onPointerMove(e);
  void _onPointerUpViewport(PointerUpEvent e) => _onPointerUp(e);

  // ══════════════════════════════════════════════════════════════════
  // Annotation helpers
  // ══════════════════════════════════════════════════════════════════

  String _makeId() => 'p${_pa.nextId++}_${DateTime.now().microsecondsSinceEpoch}';

  void _addAnnotation(AnnotationShape a) { _pa.addAnnotation(a); setState(() {}); }

  void _replaceAnn(AnnotationShape old, AnnotationShape updated) {
    final idx = _pa.shapes.indexOf(old);
    if (idx != -1) { _pa.shapes[idx] = updated; if (_pa.selAnnId == old.id) _pa.selAnnId = updated.id; }
    setState(() {});
  }

  void _cancelDrawing() { _drawStart = null; _drawCurrent = null; _freehandPts.clear(); }

  void _deselectAll() { _pa.selAnnId = null; setState(() {}); }

  // ══════════════════════════════════════════════════════════════════
  // Tool options persistence
  // ══════════════════════════════════════════════════════════════════

  void _onOptionsChanged(ToolOptions o) {
    _opts = o;
    _optsStore.save(o);
    _applyOptsToSelected(o);
    setState(() {});
  }

  /// Apply [opts] appearance fields to the currently selected annotation.
  void _applyOptsToSelected(ToolOptions opts) {
    final sel = _pa.selected; if (sel == null) return;
    AnnotationShape updated;
    if (sel is RectAnnotation) {
      updated = RectAnnotation(x: sel.x, y: sel.y, w: sel.w, h: sel.h,
          color: opts.color, strokeWidth: opts.strokeWidth, shapeKind: opts.shapeKind,
          cornerRadius: opts.cornerRadius, fillStyle: opts.fillStyle,
          fillColor: sel.fillColor, lineStyle: opts.lineStyle, id: sel.id)
        ..rotation = sel.rotation;
    } else if (sel is ArrowAnnotation) {
      updated = ArrowAnnotation(fromX: sel.fromX, fromY: sel.fromY, toX: sel.toX, toY: sel.toY,
          color: opts.color, strokeWidth: opts.strokeWidth, startHead: opts.startHead,
          endHead: opts.endHead, lineStyle: opts.lineStyle, id: sel.id)
        ..rotation = sel.rotation;
    } else if (sel is TextAnnotation) {
      updated = TextAnnotation(x: sel.x, y: sel.y, text: sel.text, color: opts.color,
          fontSize: opts.fontSize, bold: opts.bold, italic: opts.italic,
          outline: opts.outline, fontFamily: opts.fontFamily,
          textStyleKind: opts.textStyleKind, id: sel.id)
        ..rotation = sel.rotation;
    } else if (sel is FreehandAnnotation) {
      updated = FreehandAnnotation(points: sel.points, color: opts.color,
          strokeWidth: opts.strokeWidth, lineStyle: opts.lineStyle, id: sel.id)
        ..rotation = sel.rotation;
    } else if (sel is NumberTagAnnotation) {
      updated = NumberTagAnnotation(x: sel.x, y: sel.y, number: sel.number,
          color: opts.color, style: opts.numberTagStyle,
          fontSize: opts.numberTagSize, id: sel.id)
        ..rotation = sel.rotation;
    } else if (sel is MosaicAnnotation) {
      updated = MosaicAnnotation(mode: sel.mode, rect: sel.rect, points: sel.points,
          cellSize: opts.mosaicCellSize, effect: opts.mosaicEffect,
          blurAmount: opts.mosaicBlurAmount, id: sel.id)
        ..rotation = sel.rotation;
    } else { return; }
    _replaceAnn(sel, updated);
  }

  // ══════════════════════════════════════════════════════════════════
  // Text editing
  // ══════════════════════════════════════════════════════════════════

  void _startTextEdit(Offset pos) {
    _tx = true; _tP = pos; _tC.clear(); _tF.requestFocus(); setState(() {});
  }

  void _finishTextEdit() {
    if (!_tx) return; _tx = false;
    final text = _tC.text; _tC.clear();
    if (text.isNotEmpty) {
      _addAnnotation(TextAnnotation(x: _tP.dx, y: _tP.dy, text: text, color: _opts.color,
          fontSize: _opts.fontSize, bold: _opts.bold, italic: _opts.italic,
          outline: _opts.outline, fontFamily: _opts.fontFamily,
          textStyleKind: _opts.textStyleKind, id: _makeId()));
    }
    setState(() {});
  }

  AnnotationTool? _toolForAnnotationType(AnnotationShape a) {
    if (a is RectAnnotation) return AnnotationTool.rectangle;
    if (a is ArrowAnnotation) return AnnotationTool.arrow;
    if (a is TextAnnotation) return AnnotationTool.text;
    if (a is FreehandAnnotation) return AnnotationTool.freehand;
    if (a is MosaicAnnotation) return AnnotationTool.mosaic;
    if (a is NumberTagAnnotation) return AnnotationTool.numberTag;
    return null;
  }

  // ══════════════════════════════════════════════════════════════════
  // Pointer gesture handling
  // ══════════════════════════════════════════════════════════════════

  void _onPointerDown(PointerDownEvent e) {
    if (_currentImage == null) return;

    // Right button
    if (e.buttons == kSecondaryMouseButton) {
      _tF.unfocus();
      if (_tx) { _finishTextEdit(); return; }
      if (_tool != AnnotationTool.mouse) {
        setState(() { _tool = AnnotationTool.mouse; _deselectAll(); _edDrag = null; _edBase = null; _edBaseObj = null; });
      } else if (_pa.selAnnId != null) {
        final sel = _pa.selected;
        if (sel != null) {
          final t = _toolForAnnotationType(sel);
          if (t != null) setState(() => _tool = t);
        }
      } else {
        // Mouse tool, no annotation selected — show text context menu
        _showTextContextMenu(e.localPosition);
      }
      return;
    }

    // Middle button → start panning
    if (e.buttons == kMiddleMouseButton) { _midPanning = true; _midLast = e.localPosition; return; }

    _tF.unfocus();
    if (_tx) { _finishTextEdit(); return; }

    final pos = _toImageSpace(e.localPosition);

    if (_tool == AnnotationTool.mouse) {
      final sel = _pa.selected;
      if (sel != null) {
        final h = hitTestAnnHandle(sel, pos, scale: _handleScale);
        if (h != null) { _edDrag = h; _edBase = getAnnBounds(sel); _edBaseObj = sel; _edLastPos = pos; setState(() {}); return; }
      }
      final hit = hitTestAnnotation(_pa.shapes, pos);
      if (hit != null) { _pa.selAnnId = hit.id; _edDrag = AnnHandle.move; _edBase = getAnnBounds(hit); _edBaseObj = hit; _edLastPos = pos; setState(() {}); return; }
      // Blank area — clear annotation selection and start text selection
      _pa.selAnnId = null;
      _clearTextSelection();
      _textSelecting = true;
      _textSelBase = _findCharAt(pos);
      _textSelExt = _textSelBase;
      setState(() {});
      return;
    }

    // Non-mouse tools: allow editing of selected annotation
    if (_pa.selected != null) {
      final sel = _pa.selected!;
      final h = hitTestAnnHandle(sel, pos, scale: _handleScale);
      if (h != null) { _edDrag = h; _edBase = getAnnBounds(sel); _edBaseObj = sel; _edLastPos = pos; setState(() {}); return; }
    }

    // Start drawing
    _pa.selAnnId = null;
    _clearTextSelection();
    _drawStart = pos; _drawCurrent = pos; _freehandPts.clear();
    if (_tool == AnnotationTool.freehand || _tool == AnnotationTool.mosaic || _tool == AnnotationTool.eraser) _freehandPts.add(pos);
    if (_tool == AnnotationTool.text) { _startTextEdit(pos); _drawStart = null; _drawCurrent = null; }
    if (_tool == AnnotationTool.numberTag) {
      int maxNum = 0;
      for (final a in _pa.shapes) { if (a is NumberTagAnnotation && a.number > maxNum) maxNum = a.number; }
      _addAnnotation(NumberTagAnnotation(x: pos.dx, y: pos.dy, number: maxNum + 1,
          color: _opts.color, style: _opts.numberTagStyle, fontSize: _opts.numberTagSize, id: _makeId()));
      _drawStart = null;
    }
    setState(() {});
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_currentImage == null) return;

    if (_midPanning && _midLast != null) {
      final delta = e.localPosition - _midLast!; _midLast = e.localPosition;
      _tc.value = _tc.value.clone()..multiply(Matrix4.translationValues(delta.dx, delta.dy, 0));
      return;
    }

    final pos = _toImageSpace(e.localPosition), last = _edLastPos; _edLastPos = pos;

    if (_edDrag != null && _edBase != null && _edBaseObj != null && last != null) {
      final delta = pos - last;
      if (_edDrag == AnnHandle.move) {
        final cur = _pa.shapes.firstWhere((a) => a.id == _edBaseObj!.id, orElse: () => _edBaseObj!);
        final moved = translateAnn(cur, delta.dx, delta.dy);
        _edBase = getAnnBounds(moved); _replaceAnn(cur, moved); _edBaseObj = moved;
      } else if (_edDrag == AnnHandle.rotate) {
        final rc = _edBase!.center;
        final da = math.atan2(pos.dy - rc.dy, pos.dx - rc.dx) - math.atan2(last.dy - rc.dy, last.dx - rc.dx);
        final cur = _pa.shapes.firstWhere((a) => a.id == _edBaseObj!.id, orElse: () => _edBaseObj!);
        final rotated = rotateAnn(_edBaseObj!, da);
        _edBase = getAnnBounds(rotated); _replaceAnn(cur, rotated); _edBaseObj = rotated;
      } else {
        final cur = _pa.shapes.firstWhere((a) => a.id == _edBaseObj!.id, orElse: () => _edBaseObj!);
        final pkp = HardwareKeyboard.instance.physicalKeysPressed;
        final ka = pkp.contains(PhysicalKeyboardKey.shiftLeft) || pkp.contains(PhysicalKeyboardKey.shiftRight);
        final resized = resizeAnn(_edBaseObj!, _edDrag!, delta, _edBase!, keepAspect: ka);
        _edBase = getAnnBounds(resized); _replaceAnn(cur, resized); _edBaseObj = resized;
      }
      return;
    }

    if (_textSelecting && _tool == AnnotationTool.mouse) {
      final idx = _findCharAt(pos);
      if (idx >= 0) { _textSelExt = idx; setState(() {}); }
      return;
    }

    if (_drawStart != null) {
      _drawCurrent = pos;
      if (_tool == AnnotationTool.freehand || _tool == AnnotationTool.mosaic || _tool == AnnotationTool.eraser) _freehandPts.add(pos);
      setState(() {});
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    if (_currentImage == null) return;
    _midPanning = false; _midLast = null;
    _edDrag = null; _edBase = null; _edBaseObj = null; _edLastPos = null;
    _textSelecting = false;
    if (_drawStart != null && _drawCurrent != null) _commitDrawing();
    _drawStart = null; _drawCurrent = null; _freehandPts.clear();
    setState(() {});
  }

  void _commitDrawing() {
    final ds = _drawStart!, dc = _drawCurrent!, id = _makeId();
    final adjCellSize = _opts.mosaicCellSize * _handleScale;
    AnnotationShape? shape;
    switch (_tool) {
      case AnnotationTool.rectangle:
        final n = Rect.fromLTWH(math.min(ds.dx, dc.dx), math.min(ds.dy, dc.dy), (dc.dx - ds.dx).abs(), (dc.dy - ds.dy).abs());
        if (n.width < 5 && n.height < 5) return;
        shape = RectAnnotation(x: n.left, y: n.top, w: n.width, h: n.height, color: _opts.color,
            strokeWidth: _opts.strokeWidth, shapeKind: _opts.shapeKind, cornerRadius: _opts.cornerRadius,
            fillStyle: _opts.fillStyle, fillColor: null, lineStyle: _opts.lineStyle, id: id);
      case AnnotationTool.arrow:
        if ((dc - ds).distance < 5) return;
        shape = ArrowAnnotation(fromX: ds.dx, fromY: ds.dy, toX: dc.dx, toY: dc.dy,
            color: _opts.color, strokeWidth: _opts.strokeWidth, startHead: _opts.startHead,
            endHead: _opts.endHead, lineStyle: _opts.lineStyle, id: id);
      case AnnotationTool.freehand:
        if (_freehandPts.length < 2) return;
        shape = FreehandAnnotation(points: _freehandPts.toList(), color: _opts.color,
            strokeWidth: _opts.strokeWidth, lineStyle: _opts.lineStyle, id: id);
      case AnnotationTool.mosaic:
        if (_opts.mosaicMode == MosaicMode.line) {
          if (_freehandPts.length < 2) return;
          shape = MosaicAnnotation(mode: MosaicMode.line, points: _freehandPts.toList(),
              cellSize: adjCellSize, effect: _opts.mosaicEffect, blurAmount: _opts.mosaicBlurAmount, id: id);
        } else {
          final n = Rect.fromLTWH(math.min(ds.dx, dc.dx), math.min(ds.dy, dc.dy), (dc.dx - ds.dx).abs(), (dc.dy - ds.dy).abs());
          if (n.width < 5 && n.height < 5) return;
          shape = MosaicAnnotation(mode: _opts.mosaicMode, rect: n, cellSize: adjCellSize,
              effect: _opts.mosaicEffect, blurAmount: _opts.mosaicBlurAmount, id: id);
        }
      case AnnotationTool.eraser:
        _pa.undoStack.add(_pa.shapes.toList()); _pa.redoStack.clear();
        if (_opts.mosaicMode == MosaicMode.line) {
          if (_freehandPts.length < 2) return;
          _pa.eraserMasks.add(EraserMask.withOrderId(++_pa.orderCounter, mode: MosaicMode.line,
              points: _freehandPts.toList(), cellSize: adjCellSize));
        } else {
          final n = Rect.fromLTWH(math.min(ds.dx, dc.dx), math.min(ds.dy, dc.dy), (dc.dx - ds.dx).abs(), (dc.dy - ds.dy).abs());
          if (n.width < 5 && n.height < 5) return;
          _pa.eraserMasks.add(EraserMask.withOrderId(++_pa.orderCounter, mode: _opts.mosaicMode,
              rect: n, cellSize: adjCellSize));
        }
        setState(() {}); return;
      default: return;
    }
    _addAnnotation(shape);
  }

  // ══════════════════════════════════════════════════════════════════
  // Keyboard
  // ══════════════════════════════════════════════════════════════════

  /// Global key handler — catches Ctrl+A/F even when search bar is focused.
  bool _onGlobalKey(KeyEvent event) {
    if (_tx) return false;
    if (event is! KeyDownEvent) return false;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyA) { _selectAllText(); return true; }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyF) { _toggleSearch(); return true; }
    return false;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // During text editing, let the TextField handle everything
    if (_tx) return KeyEventResult.ignored;

    // Arrow up/down — allow long press (KeyRepeatEvent) so holding the key
    // scrolls pages continuously.  Must be checked BEFORE the KeyDownEvent
    // gate below.
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (!_searchF.hasFocus) {
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) { _goToPage(_currentPage - 1); return KeyEventResult.handled; }
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) { _goToPage(_currentPage + 1); return KeyEventResult.handled; }
      }
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (_searchF.hasFocus) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.keyZ && HardwareKeyboard.instance.isControlPressed) { _pa.undo(); setState(() {}); return KeyEventResult.handled; }
    if ((key == LogicalKeyboardKey.keyX || key == LogicalKeyboardKey.keyY) && HardwareKeyboard.instance.isControlPressed) { _pa.redo(); setState(() {}); return KeyEventResult.handled; }
    if (key == LogicalKeyboardKey.keyC && HardwareKeyboard.instance.isControlPressed) {
      if (_hasTextSelection) { _copySelectedText(); } else { _onCopy(); }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) { final s = _pa.selected; if (s != null) { _pa.deleteAnnotation(s.id); setState(() {}); } return KeyEventResult.handled; }
    if (key == LogicalKeyboardKey.tab) { _cycleSelection(); return KeyEventResult.handled; }
    if (key == LogicalKeyboardKey.keyH) { _showHelp = !_showHelp; setState(() {}); return KeyEventResult.handled; }
    if (key == LogicalKeyboardKey.keyM) { _showMagnifier = !_showMagnifier; setState(() {}); return KeyEventResult.handled; }
    // Magnifier shortcuts Z/X/C (same as CursorMagnifier)
    if (_showMagnifier && !HardwareKeyboard.instance.isControlPressed) {
      if (key == LogicalKeyboardKey.keyZ && _magPos != null) {
        Clipboard.setData(ClipboardData(text: '${_magPos!.dx.round()},${_magPos!.dy.round()}'));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyC && _magRgb != null) {
        final (r, g, b) = _magRgb!;
        Clipboard.setData(ClipboardData(text: 'RGB($r,$g,$b)'));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyX && _magHex != null) {
        Clipboard.setData(ClipboardData(text: _magHex!));
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _cycleSelection() {
    if (_pa.shapes.isEmpty) return;
    int idx = 0;
    if (_pa.selAnnId != null) { final cur = _pa.shapes.indexWhere((a) => a.id == _pa.selAnnId); if (cur >= 0) idx = (cur + 1) % _pa.shapes.length; }
    _pa.selAnnId = _pa.shapes[idx].id; setState(() {});
  }

  // ══════════════════════════════════════════════════════════════════
  // Compose / Copy / Save / Translate
  // ══════════════════════════════════════════════════════════════════

  Future<void> _onCopy() async {
    final bytes = await _composePage(); if (bytes == null) return;
    try { await const MethodChannel('com.xmate/screenshot').invokeMethod('copyToClipboard', {'data': bytes}); } catch (_) {}
  }

  void _copySelectedText() {
    final text = _getSelectedText();
    if (text.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: text));
    }
  }

  Future<void> _onSave() async {
    String? dirPath;
    try { dirPath = await const MethodChannel('com.xmate/picker').invokeMethod<String>('pickFolder'); } catch (_) {}
    if (dirPath == null || dirPath.isEmpty) return;
    final pdfName = widget.filePath.split(RegExp(r'[/\\]')).last;
    final fileName = '${pdfName.replaceAll('.pdf', '')}_copy.pdf';
    final outPath = '$dirPath\\$fileName';
    try {
      File(widget.filePath).copySync(outPath);
      _showSnack('Saved: $fileName');
    } catch (e) { _showSnack('Save failed: $e'); }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(left: 16, bottom: 8, right: 500)),
    );
  }
  void _cleanFile(String path) { try { File(path).deleteSync(); } catch (_) {} }

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
    final isEnc = info?['encrypted'] == true;
    final result = await showDialog<Map<String, String>>(
      context: context, barrierColor: Colors.transparent,
      builder: (ctx) => _PdfInfoDialog(
        cs: cs, info: info, sizeStr: sizeStr, pages: _totalPages,
        filePath: widget.filePath, isEncrypted: isEnc,
        savedPassword: _savedPassword,),
    );
    if (result == null) return;
    final savedPage = _currentPage;
    _doc?.dispose(); _doc = null; _pageCache.clear(); _currentImage = null; _thumbs.clear();
    _selectedPages.clear();
    if (result.containsKey('_optimize')) {
      await _tryOpen(widget.filePath);
      _goToPage(savedPage);
    } else if (result.containsKey('_remove_encrypt')) {
      final pwd = _savedPassword!;
      final ok = await removeEncryption(widget.filePath, pwd);
      _showSnack(ok ? 'Encryption removed — saved as unencrypted PDF' : 'Remove encryption failed');
      _cleanupDecryptTmp();
      await _tryOpen(widget.filePath);
      _goToPage(savedPage);
    } else if (result.containsKey('_encrypt')) {
      final userPwd = result['_encrypt'] ?? '';
      final ownerPwd = result['_encrypt_owner'] ?? '';
      if (userPwd.isEmpty && ownerPwd.isEmpty) {
        _showSnack('Both password fields are empty — no encryption applied');
      } else {
        final ok = await encryptPdf(widget.filePath,
            userPassword: userPwd, ownerPassword: ownerPwd,
            keyLength: result['_encrypt_key'] ?? '256',
            allowPrint: result['_encrypt_print'] != '0',
            allowModify: result['_encrypt_modify'] != '0',
            allowCopy: result['_encrypt_copy'] != '0',
            allowAnnotate: result['_encrypt_annotate'] != '0');
        _showSnack(ok ? 'Encryption applied' : 'Encryption failed');
      }
      await _tryOpen(widget.filePath);
      _goToPage(savedPage);
    } else {
      final ok = await setPdfMetadata(widget.filePath,
          title: result['title'], author: result['author'],
          subject: result['subject'], keywords: result['keywords']);
      _showSnack(ok ? 'Metadata updated' : 'Metadata update failed');
      await _tryOpen(widget.filePath);
      _goToPage(savedPage);
    }
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  void _onTranslate() async {
    final filePath = widget.filePath; // capture before async gap
    try {
      final appData = Platform.environment['APPDATA'] ?? '';
      final dir = Directory('$appData\\XMate');
      if (!await dir.exists()) await dir.create(recursive: true);
      await File('$appData\\XMate\\ql_translate_req.json')
          .writeAsString(jsonEncode({'path': filePath}));
      await const MethodChannel('com.xmate/quicklook').invokeMethod('requestTranslate');
    } catch (_) {}
    // One-shot action — switch back to mouse tool
    if (mounted) setState(() { _tool = AnnotationTool.mouse; _showMagnifier = false; });
  }

  Future<Uint8List?> _composePage() async {
    if (_currentImage == null) return null;
    final img = _currentImage!, r = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    final rec = ui.PictureRecorder(), canvas = Canvas(rec, r);
    canvas.drawImage(img, Offset.zero, Paint());
    final ops = <MapEntry<int, Object>>[];
    for (final a in _pa.shapes) ops.add(MapEntry(_pa.assignOrder(a), a));
    for (final m in _pa.eraserMasks) ops.add(MapEntry(m.orderId, m));
    ops.sort((x, y) => x.key.compareTo(y.key));
    canvas.saveLayer(r, Paint());
    for (final op in ops) {
      if (op.value is AnnotationShape) drawAnnotation(canvas, op.value as AnnotationShape, image: img, widgetSize: r.size);
      else if (op.value is EraserMask) drawEraserMask(canvas, op.value as EraserMask);
    }
    canvas.restore();
    final pic = rec.endRecording(), composed = await pic.toImage(img.width, img.height); pic.dispose();
    final data = await composed.toByteData(format: ui.ImageByteFormat.png); composed.dispose();
    return data?.buffer.asUint8List();
  }

  // ══════════════════════════════════════════════════════════════════
  // UI — Build
  // ══════════════════════════════════════════════════════════════════

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_error != null) return _errorWidget(cs);
    if (_doc == null) return Center(child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary));
    return Focus(autofocus: true, onKeyEvent: _onKey, child: Column(children: [
      _buildToolbar(),
      Expanded(child: _buildSplitView()),
    ]));
  }

  Widget _errorWidget(ColorScheme cs) => Center(child: Padding(padding: const EdgeInsets.all(24),
      child: Text('PDF load error:\n$_error', style: TextStyle(color: cs.onSurface.withAlpha(138), fontSize: 14), textAlign: TextAlign.center)));

  Widget _buildSearchBar() {
    final cs = Theme.of(context).colorScheme;
    return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(color: XMateColors.panelBg(context), borderRadius: BorderRadius.circular(6)),
    margin: const EdgeInsets.all(8),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.search, color: cs.onSurface.withAlpha(138), size: 16),
      const SizedBox(width: 4),
      SizedBox(width: 160, child: TextField(
        controller: _searchC, focusNode: _searchF,
        style: TextStyle(color: cs.onSurface, fontSize: 13),
        decoration: InputDecoration(
          isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          hintText: 'Search...', hintStyle: TextStyle(color: cs.onSurface.withAlpha(77), fontSize: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(3), borderSide: BorderSide(color: cs.onSurface.withAlpha(61))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(3), borderSide: BorderSide(color: cs.onSurface.withAlpha(61))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(3), borderSide: BorderSide(color: cs.primary)),
        ),
        onChanged: (_) => _performSearch(),
        onSubmitted: (_) => _nextSearchMatch(),
      )),
      const SizedBox(width: 4),
      Text(_searchMatches.isEmpty ? '0/0' : '${_searchCur + 1}/${_searchMatches.length}',
          style: TextStyle(color: cs.onSurface.withAlpha(138), fontSize: 11)),
      IconButton(icon: Icon(Icons.chevron_left, size: 16, color: cs.onSurface.withAlpha(179)), padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          onPressed: _searchMatches.isEmpty ? null : _prevSearchMatch),
      IconButton(icon: Icon(Icons.chevron_right, size: 16, color: cs.onSurface.withAlpha(179)), padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          onPressed: _searchMatches.isEmpty ? null : _nextSearchMatch),
      IconButton(icon: Icon(Icons.text_fields, size: 16, color: _searchCaseSensitive ? cs.primary : cs.onSurface.withAlpha(138)),
          padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          onPressed: () { _searchCaseSensitive = !_searchCaseSensitive; _performSearch(); }),
      IconButton(icon: Icon(Icons.close, size: 16, color: cs.onSurface.withAlpha(138)), padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          onPressed: _toggleSearch),
    ]));
  }

  Widget _buildToolbar() => AnnotateToolbar(
      currentTool: _tool, options: _opts,
      hasSelection: true, // copy works without annotation selection
      canUndo: _pa.canUndo, canRedo: _pa.canRedo,
      onToolChanged: (t) {
        _cancelDrawing();
        _clearTextSelection();
        if (t == AnnotationTool.magnifier) {
          _showMagnifier = !_showMagnifier;
          setState(() => _tool = _showMagnifier ? AnnotationTool.magnifier : AnnotationTool.mouse);
          return;
        }
        // Translate is a one-shot action, not a persistent tool
        if (t == AnnotationTool.translate) {
          _onTranslate();
          return;
        }
        _showMagnifier = false;
        setState(() => _tool = t);
      },
      onOptionsChanged: _onOptionsChanged,
      onUndo: () { _pa.undo(); setState(() {}); },
      onRedo: () { _pa.redo(); setState(() {}); },
      onCopy: _onCopy, onSave: _onSave, onPin: _onTranslate,
      onClose: widget.onClose,
      onClearAll: () { _pa.shapes.clear(); _pa.eraserMasks.clear(); _pa.undoStack.clear(); _pa.redoStack.clear(); _pa.selAnnId = null; _pa.orderCounter = 0; setState(() {}); },
      optionsRowFirst: false,
      hiddenTools: const {AnnotationTool.crop, AnnotationTool.bgRemove, AnnotationTool.ocr},
      hiddenActions: const {'pin', 'close'},
    );

  Widget _buildSplitView() => Row(children: [_buildThumbnailSidebar(), Expanded(child: Stack(children: [
    _buildPageArea(),
    if (_searchVisible) Positioned(bottom: 0, right: 0, child: _buildSearchBar()),
  ]))]);

  // ── Thumbnail sidebar ──

  Widget _buildThumbnailSidebar() {
    final cs = Theme.of(context).colorScheme;
    return Container(width: _thumbW,
      decoration: BoxDecoration(border: Border(right: BorderSide(color: cs.onSurface.withAlpha(31)))),
      child: Listener(onPointerSignal: (e) {
        if (e is PointerScrollEvent && _thumbScroll.hasClients) {
          // Scroll one page per tick — _thumbH is the itemExtent, so one
          // thumb height = one page slot.  The old * 40 multiplier was far
          // too aggressive, making a single tick jump multiple pages and
          // often land straight at the bottom.
          _thumbScroll.jumpTo((_thumbScroll.offset + e.scrollDelta.dy.sign * _thumbH).clamp(0.0, _thumbScroll.position.maxScrollExtent));
          _onThumbScroll();
        }
      }, child: NotificationListener<ScrollNotification>(
        onNotification: (n) { if (n is ScrollEndNotification) _onThumbScroll(); return false; },
        child: ListView.builder(controller: _thumbScroll, itemCount: _totalPages, itemExtent: _thumbH, itemBuilder: (_, i) => _buildThumb(i)),
      )));
  }

  Widget _buildThumb(int page) {
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
        ])));
  }

  // ── Page area ──

  Widget _buildPageArea() => LayoutBuilder(builder: (ctx, box) {
    final cs = Theme.of(context).colorScheme;
    _viewportW = box.maxWidth; _viewportH = box.maxHeight;

    if (_currentImage != null && !_currentZoomApplied && box.maxWidth > 0 && box.maxHeight > 0) {
      _currentZoomApplied = true;
      final iw = _currentImage!.width.toDouble(), ih = _currentImage!.height.toDouble();
      _setZoom(math.min(box.maxWidth / iw, box.maxHeight / ih));
    }

    final childContent = _currentImage != null
        ? SizedBox(width: _currentImage!.width.toDouble() + _overflow * 2,
            height: _currentImage!.height.toDouble() + _overflow * 2,
            child: Stack(clipBehavior: Clip.none, children: [
              CustomPaint(painter: _PdfPainter(image: _currentImage!,
                  offsetX: _overflow, offsetY: _overflow,
                  annotations: _pa.shapes, eraserMasks: _pa.eraserMasks,
                  annOrderCache: _pa.annOrderCache, selectedAnnId: _pa.selAnnId,
                  previewTool: _tool, previewStart: _drawStart,
                  previewCurrent: _drawCurrent, previewFreehand: _freehandPts,
                  previewColor: _opts.color, previewStrokeWidth: _opts.strokeWidth,
                  previewOptions: _opts, handleScale: _handleScale,
                  textCharRects: _buildCharRects(),
                  textSelBase: _textSelBase, textSelExt: _textSelExt,
                  pageFullText: _pageText?.fullText ?? '')),
              if (_tx) Positioned(left: _overflow + _tP.dx, top: _overflow + _tP.dy,
                  child: SizedBox(width: 200, child: TextField(controller: _tC, focusNode: _tF,
                      autofocus: true,
                      style: TextStyle(color: _opts.color, fontSize: _opts.fontSize,
                          fontFamily: _opts.fontFamily,
                          fontWeight: _opts.bold ? FontWeight.bold : FontWeight.normal,
                          fontStyle: _opts.italic ? FontStyle.italic : FontStyle.normal),
                      decoration: const InputDecoration(border: InputBorder.none, contentPadding: EdgeInsets.zero)))),
            ]))
        : const SizedBox.shrink();

    return ClipRect(child: Stack(children: [
      Transform(transform: _tc.value, child: childContent),

      Positioned.fill(
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) {
              // Shift+wheel on selected NumberTag: change number
              final pkp = HardwareKeyboard.instance.physicalKeysPressed;
              final shift = pkp.contains(PhysicalKeyboardKey.shiftLeft) || pkp.contains(PhysicalKeyboardKey.shiftRight);
              if (shift) {
                final sel = _pa.selected;
                if (sel is NumberTagAnnotation) {
                  final sign = e.scrollDelta.dy > 0 ? 1 : -1;
                  final newN = (sel.number + sign).clamp(1, 999);
                  final updated = NumberTagAnnotation(x: sel.x, y: sel.y, number: newN,
                      color: sel.color, style: sel.style, fontSize: sel.fontSize, id: sel.id)
                    ..rotation = sel.rotation;
                  _replaceAnn(sel, updated);
                  return;
                }
              }
              _onPageAreaWheel(e);
            }
          },
          onPointerDown: _onPointerDownViewport,
          onPointerMove: _onPointerMoveViewport,
          onPointerUp: _onPointerUpViewport,
        ),
      ),

      // Magnifier overlay (when enabled via M key)
      if (_showMagnifier && _currentImage != null)
        Positioned.fill(child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerMove: (e) { _magPos = e.localPosition; _updateMagnifierViewport(); },
          onPointerHover: (e) { _magPos = e.localPosition; _updateMagnifierViewport(); },
        )),
      if (_showMagnifier && _magPos != null && _imageRgba != null)
        _buildMagnifierBox(),

      if (_showHelp) _buildHelpPanel(),
      Positioned(bottom: 8, right: 8, child: Row(mainAxisSize: MainAxisSize.min, children: [
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
  }

  // ── Magnifier ──

  Offset? _magPos;
  (int, int, int)? _magRgb;
  String? _magHex;
  List<Color>? _magGrid;

  void _updateMagnifierViewport() {
    if (!_showMagnifier || _imageRgba == null || _currentImage == null || _magPos == null) return;
    final vp = _magPos!;
    final ip = _toImageSpace(vp);
    final px = ip.dx.round(), py = ip.dy.round();
    final iw = _currentImage!.width, ih = _currentImage!.height;
    if (px < 0 || px >= iw || py < 0 || py >= ih) {
      _magRgb = null; _magHex = null; _magGrid = null; return;
    }
    final idx = (py * iw + px) * 4;
    if (idx + 3 >= _imageRgba!.length) return;
    final r = _imageRgba![idx], g = _imageRgba![idx + 1], b = _imageRgba![idx + 2];
    _magRgb = (r, g, b);
    _magHex = '#${r.toRadixString(16).padLeft(2, '0').toUpperCase()}${g.toRadixString(16).padLeft(2, '0').toUpperCase()}${b.toRadixString(16).padLeft(2, '0').toUpperCase()}';
    final gr = <Color>[];
    for (int dy = -5; dy <= 5; dy++) {
      for (int dx = -7; dx <= 7; dx++) {
        final sx = (px + dx).clamp(0, iw - 1), sy = (py + dy).clamp(0, ih - 1);
        final i = (sy * iw + sx) * 4;
        gr.add(Color.fromARGB(255, _imageRgba![i], _imageRgba![i + 1], _imageRgba![i + 2]));
      }
    }
    _magGrid = gr;
    setState(() {});
  }

  // ── Magnifier box — identical styling to CursorMagnifier._box() ──
  static const _cellSz = 13.0;
  static const _gridW = 15 * _cellSz;
  static const _gridH = 11 * _cellSz;
  static const _boxW = 211.0;
  static const _boxH = 233.0;
  static const _ox = 14.0;
  static const _oy = 14.0;

  Widget _buildMagnifierBox() {
    if (_magPos == null || _magRgb == null || _magGrid == null || _magHex == null) return const SizedBox();
    final cs = Theme.of(context).colorScheme;
    final p = _magPos!;
    final (r, g, b) = _magRgb!;
    final hex = _magHex!;
    final grid = _magGrid!;
    final ws = MediaQuery.of(context).size;
    double l = p.dx + _ox, t = p.dy + _oy;
    if (l + _boxW > ws.width) l = p.dx - _ox - _boxW;
    if (l < 2) l = 2;
    if (t + _boxH > ws.height) t = p.dy - _oy - _boxH;
    if (t < 2) t = 2;

    final s = TextStyle(color: cs.onSurface, fontSize: 16, fontFamily: 'Consolas', height: 1.25);
    final k = TextStyle(color: cs.primary, fontSize: 14, fontFamily: 'Consolas', height: 1.25);

    return Stack(children: [
      Positioned(left: l, top: t, child: IgnorePointer(child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: XMateColors.panelBg(context), borderRadius: BorderRadius.circular(4)),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: _gridW, height: _gridH, child: CustomPaint(painter: MagnifierPainter(colors: grid, cellSize: _cellSz))),
            const SizedBox(height: 4),
            Row(mainAxisSize: MainAxisSize.min, children: [Text('Z ', style: k), Text('${p.dx.round()}, ${p.dy.round()}', style: s)]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text('C ', style: k),
              Container(width: 10, height: 10, margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(color: Color.fromARGB(255, r, g, b), borderRadius: BorderRadius.circular(1), border: Border.all(color: cs.onSurface.withAlpha(60), width: 0.5))),
              Text('RGB($r,$g,$b)', style: s),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [Text('X ', style: k), Text(hex, style: s.copyWith(fontWeight: FontWeight.bold))]),
          ])))),
    ]);
  }

  // ── Help panel ──

  Widget _buildHelpPanel() {
    final cs = Theme.of(context).colorScheme;
    return Positioned(right: 8, top: 8, child: Container(padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: XMateColors.panelBg(context), borderRadius: BorderRadius.circular(8), border: Border.all(color: cs.onSurface.withAlpha(61))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('Shortcuts', style: TextStyle(color: cs.onSurface, fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          _Hk('Ctrl+Z', 'Undo'), _Hk('Ctrl+X/Y', 'Redo'), _Hk('Ctrl+C', 'Copy page'),
          _Hk('Del/Bksp', 'Delete'), _Hk('Tab', 'Cycle'), _Hk('WASD', 'Nudge'),
          _Hk('Wheel', 'Zoom'), _Hk('Mid-drag', 'Pan'), _Hk('Right-click', 'Switch tool'),
          _Hk('M', 'Magnifier'), _Hk('H', 'Help'),
        ])));
  }
}

// ══════════════════════════════════════════════════════════════════════
// Top-level helpers
// ══════════════════════════════════════════════════════════════════════


// ================================================================
// Info dialog
// ================================================================

class _PdfInfoDialog extends StatefulWidget {
  final ColorScheme cs;
  final Map<String, dynamic>? info;
  final String sizeStr;
  final int pages;
  final String filePath;
  final bool isEncrypted;
  final String? savedPassword;
  const _PdfInfoDialog({required this.cs, this.info, required this.sizeStr,
    required this.pages, required this.filePath, this.isEncrypted = false,
    this.savedPassword});
  @override State<_PdfInfoDialog> createState() => _PdfInfoDialogState();
}

class _PdfInfoDialogState extends State<_PdfInfoDialog> {
  late final TextEditingController _titleC, _authorC, _subjectC, _kwC;
  late final TextEditingController _encUserC, _encOwnerC;
  bool _optimizing = false, _saving = false, _showEncrypt = false;
  String _encKey = '256';
  bool _encPrint = true, _encMod = true, _encCopy = true, _encAnnot = true;

  @override void initState() {
    super.initState();
    final i = widget.info;
    _titleC   = TextEditingController(text: i?['title'] as String? ?? '');
    _authorC  = TextEditingController(text: i?['author'] as String? ?? '');
    _subjectC = TextEditingController(text: i?['subject'] as String? ?? '');
    _kwC      = TextEditingController(text: i?['keywords'] as String? ?? '');
    _encUserC = TextEditingController();
    _encOwnerC = TextEditingController();
  }
  @override void dispose() {
    _titleC.dispose(); _authorC.dispose(); _subjectC.dispose(); _kwC.dispose();
    _encUserC.dispose(); _encOwnerC.dispose();
    super.dispose();
  }

  @override Widget build(BuildContext ctx) {
    final cs = widget.cs;
    final sw = _switch(cs);
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
        const SizedBox(height: 12),
        // ── Encrypt section ──
        SizedBox(height: 24, child: Row(children: [
          Text('Encrypt', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface)),
          const Spacer(), Transform.scale(scale: 0.7, child: Switch(value: _showEncrypt, activeTrackColor: cs.primary,
            onChanged: (v) => setState(() => _showEncrypt = v)))])),
        if (_showEncrypt) ...[
          const SizedBox(height: 6),
          _field(cs, 'User pwd', _encUserC),
          const SizedBox(height: 4),
          _field(cs, 'Owner pwd', _encOwnerC),
          const SizedBox(height: 6),
          SizedBox(height: 28, child: Row(children: [
            SizedBox(width: 72, child: Text('Key', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(160)))),
            SizedBox(width: 100, child: DropdownButtonFormField<String>(
              value: _encKey, isDense: true, isExpanded: true,
              decoration: _inputDeco(), style: TextStyle(fontSize: 12, color: cs.onSurface),
              items: const [DropdownMenuItem(value: '128', child: Text('128-bit', style: TextStyle(fontSize: 12))),
                DropdownMenuItem(value: '256', child: Text('256-bit', style: TextStyle(fontSize: 12)))],
              onChanged: (v) { if (v != null) setState(() => _encKey = v); })),
          ])),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: Column(children: [
              SizedBox(height: 22, child: sw('Print', _encPrint, (v) => setState(() => _encPrint = v))),
              const SizedBox(height: 4),
              SizedBox(height: 22, child: sw('Modify', _encMod, (v) => setState(() => _encMod = v))),
            ])),
            const SizedBox(width: 12),
            Expanded(child: Column(children: [
              SizedBox(height: 22, child: sw('Copy', _encCopy, (v) => setState(() => _encCopy = v))),
              const SizedBox(height: 4),
              SizedBox(height: 22, child: sw('Annotate', _encAnnot, (v) => setState(() => _encAnnot = v))),
            ])),
          ]),
          const SizedBox(height: 8),
          SizedBox(height: 32, child: OutlinedButton.icon(
            icon: const Icon(Icons.lock, size: 16), label: const Text('Apply Encryption'),
            onPressed: _doApplyEncrypt)),
          const SizedBox(height: 8),
        ],
      ])),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      actions: [Row(children: [
        Tooltip(message: 'Recompress streams, remove unused resources, reduce file size', child:
          OutlinedButton.icon(
            icon: _optimizing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.compress, size: 18),
            label: Text(_optimizing ? '...' : 'Compress'),
            onPressed: _optimizing ? null : () => _doOptimize(),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(onPressed: _saving ? null : () => _doSaveMetadata(), child: Text(_saving ? '...' : 'Save Metadata')),
        if (widget.isEncrypted && widget.savedPassword != null) ...[
          const SizedBox(width: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.lock_open, size: 16, color: Colors.orangeAccent),
            label: const Text('Remove Encrypt', style: TextStyle(color: Colors.orangeAccent, fontSize: 12)),
            style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.orangeAccent)),
            onPressed: () => _doRemoveEncrypt(),
          ),
        ],
        const Spacer(),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ])],
    );
  }

  void _doRemoveEncrypt() {
    Navigator.pop(context, {'_remove_encrypt': '1'});
  }

  Row Function(String, bool, ValueChanged<bool>) _switch(ColorScheme cs) =>
      (String label, bool val, ValueChanged<bool> cb) =>
      Row(children: [Text(label, style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(180))), const Spacer(),
        Transform.scale(scale: 0.7, child: Switch(value: val, onChanged: cb, activeTrackColor: cs.primary))]);

  InputDecoration _inputDeco() => InputDecoration(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
      isDense: true);

  Future<void> _doOptimize() async {
    final fp = widget.filePath; setState(() => _optimizing = true);
    final oldSize = File(fp).lengthSync();
    Navigator.pop(context, {'_optimize': '1'});
    try {
      final ok = await optimizePdf(fp);
      if (ok) {
        final newSize = File(fp).lengthSync();
        _snack('Compressed: ${_fmtBs(oldSize)} -> ${_fmtBs(newSize)} (${((1 - newSize / oldSize) * 100).round()}% reduction)');
      } else { _snack('Compress failed'); }
    } catch (e) { _snack('Compress error: $e'); }
  }

  Future<void> _doSaveMetadata() async {
    setState(() => _saving = true);
    Navigator.pop(context, {'title': _titleC.text, 'author': _authorC.text,
      'subject': _subjectC.text, 'keywords': _kwC.text});
  }

  void _doApplyEncrypt() {
    Navigator.pop(context, {
      '_encrypt': _encUserC.text, '_encrypt_owner': _encOwnerC.text,
      '_encrypt_key': _encKey, '_encrypt_print': _encPrint ? '1' : '0',
      '_encrypt_modify': _encMod ? '1' : '0', '_encrypt_copy': _encCopy ? '1' : '0',
      '_encrypt_annotate': _encAnnot ? '1' : '0',
    });
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
          decoration: _inputDeco())))]));

  static String _fmtBs(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _Hk extends StatelessWidget {
  final String hkey, label;
  const _Hk(this.hkey, this.label);
  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(padding: const EdgeInsets.only(bottom: 2),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 88, child: Text(hkey, style: TextStyle(color: cs.primary, fontSize: 12, fontFamily: 'Consolas'))),
        Text(label, style: TextStyle(color: cs.onSurface.withAlpha(179), fontSize: 12)),
      ]));}
}

// ══════════════════════════════════════════════════════════════════════
// PDF page painter
// ══════════════════════════════════════════════════════════════════════

class _PdfPainter extends CustomPainter {
  final ui.Image image;
  final double offsetX, offsetY;
  final List<AnnotationShape> annotations;
  final List<EraserMask> eraserMasks;
  final Map<String, int> annOrderCache;
  final String? selectedAnnId;
  final AnnotationTool previewTool;
  final Offset? previewStart, previewCurrent;
  final List<Offset> previewFreehand;
  final Color previewColor;
  final double previewStrokeWidth;
  final ToolOptions previewOptions;
  final double handleScale;
  final List<(int, Rect)> textCharRects;
  final int textSelBase, textSelExt;
  final String pageFullText;

  _PdfPainter({required this.image, this.offsetX = 0, this.offsetY = 0,
    required this.annotations, required this.eraserMasks, required this.annOrderCache,
    this.selectedAnnId, this.previewTool = AnnotationTool.mouse,
    this.previewStart, this.previewCurrent, this.previewFreehand = const [],
    this.previewColor = Colors.red, this.previewStrokeWidth = 2.0,
    this.previewOptions = const ToolOptions(), this.handleScale = 1.0,
    this.textCharRects = const [], this.textSelBase = -1, this.textSelExt = -1,
    this.pageFullText = ''});

  @override void paint(Canvas canvas, Size size) {
    canvas.save(); canvas.translate(offsetX, offsetY);
    canvas.drawImage(image, Offset.zero, Paint());

    // ── Text selection highlight ──
    if (textSelBase >= 0 && textSelExt >= 0 && textSelBase != textSelExt && textCharRects.isNotEmpty) {
      final start = math.min(textSelBase, textSelExt), end = math.max(textSelBase, textSelExt);
      final selPaint = Paint()..color = const Color(0x604A6CF7)..style = PaintingStyle.fill;
      for (final (idx, r) in textCharRects) {
        if (idx >= start && idx < end) canvas.drawRect(r, selPaint);
      }
    }

    if (annotations.isNotEmpty || eraserMasks.isNotEmpty) {
      final ops = <MapEntry<int, Object>>[];
      for (final a in annotations) ops.add(MapEntry(getOrAssignAnnOrderWithCache(a, annOrderCache, () => 0), a));
      for (final m in eraserMasks) ops.add(MapEntry(m.orderId, m));
      ops.sort((x, y) => x.key.compareTo(y.key));
      final r = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
      canvas.saveLayer(r, Paint());
      for (final op in ops) {
        if (op.value is AnnotationShape) drawAnnotation(canvas, op.value as AnnotationShape, image: image, widgetSize: r.size);
        else if (op.value is EraserMask) drawEraserMask(canvas, op.value as EraserMask);
      }
      canvas.restore();
    }
    if (selectedAnnId != null) {
      final sel = annotations.cast<AnnotationShape?>().firstWhere((a) => a!.id == selectedAnnId, orElse: () => null);
      if (sel != null) _drawHandles(canvas, sel);
    }
    _drawPreview(canvas);
    canvas.restore();
  }

  void _drawHandles(Canvas canvas, AnnotationShape a) {
    final hs2 = handleScale * 1.5; // 1.5× for PDF zoom levels
    final raw = _getUnrotated(a), corners = _rotCorners(raw, a.rotation);
    final tm = Offset((corners[1].dx + corners[0].dx) / 2, (corners[1].dy + corners[0].dy) / 2);
    final cx = raw.center.dx, cy = raw.center.dy, dx = tm.dx - cx, dy = tm.dy - cy;
    final len = math.sqrt(dx * dx + dy * dy + 0.001);
    final rh = Offset(tm.dx + dx / len * 20 * hs2, tm.dy + dy / len * 20 * hs2);
    final bp = Path()..moveTo(corners[0].dx, corners[0].dy);
    for (int i = 1; i < 4; i++) bp.lineTo(corners[i].dx, corners[i].dy);
    bp.close();
    canvas.drawPath(bp, Paint()..color = const Color(0xFF4FC3F7)..style = PaintingStyle.stroke..strokeWidth = 1.5 * hs2);
    final s = 8.0 * hs2; final hp = Paint()..color = Colors.white..style = PaintingStyle.fill;
    final hs = Paint()..color = const Color(0xFF4FC3F7)..style = PaintingStyle.stroke..strokeWidth = 2 * hs2;
    for (int i = 0; i < 4; i++) { canvas.drawRect(Rect.fromCenter(center: corners[i], width: s, height: s), hp); canvas.drawRect(Rect.fromCenter(center: corners[i], width: s, height: s), hs); }
    canvas.drawLine(tm, rh, Paint()..color = const Color(0xFF4FC3F7)..strokeWidth = 1.5 * hs2);
    canvas.drawCircle(rh, 5 * hs2, hp); canvas.drawCircle(rh, 5 * hs2, hs);
  }

  Rect _getUnrotated(AnnotationShape a) {
    if (a is RectAnnotation) return Rect.fromLTWH(a.x, a.y, a.w, a.h);
    if (a is ArrowAnnotation) return Rect.fromPoints(Offset(a.fromX, a.fromY), Offset(a.toX, a.toY));
    if (a is TextAnnotation) { final tp = TextPainter(text: TextSpan(text: a.text, style: TextStyle(fontSize: a.fontSize, fontFamily: a.fontFamily)), textDirection: TextDirection.ltr)..layout(); return Rect.fromLTWH(a.x, a.y, tp.width, tp.height); }
    return getAnnBounds(a);
  }

  List<Offset> _rotCorners(Rect r, double angle) {
    if (angle.abs() < 0.001) return [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];
    final cx = r.center.dx, cy = r.center.dy, ca = math.cos(angle), sa = math.sin(angle);
    return [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft].map((p) { final dx = p.dx - cx, dy = p.dy - cy; return Offset(cx + dx * ca - dy * sa, cy + dx * sa + dy * ca); }).toList();
  }

  void _drawPreview(Canvas canvas) {
    if (previewStart == null || previewCurrent == null) return;
    if (previewFreehand.length > 1) {
      final p = Path()..moveTo(previewFreehand.first.dx, previewFreehand.first.dy);
      for (int i = 1; i < previewFreehand.length; i++) p.lineTo(previewFreehand[i].dx, previewFreehand[i].dy);
      canvas.drawPath(p, Paint()..color = previewTool == AnnotationTool.eraser ? Colors.red.withAlpha(80) : previewColor..strokeWidth = previewStrokeWidth..style = PaintingStyle.stroke..strokeCap = StrokeCap.round);
      return;
    }
    final ds = previewStart!, dc = previewCurrent!;
    if (previewTool == AnnotationTool.eraser) {
      if (previewOptions.mosaicMode == MosaicMode.rect || previewOptions.mosaicMode == MosaicMode.ellipse) {
        final r = Rect.fromPoints(ds, dc), ph = previewOptions.mosaicMode == MosaicMode.ellipse ? (Path()..addOval(r)) : (Path()..addRect(r));
        canvas.drawPath(ph, Paint()..color = Colors.red.withAlpha(40)..style = PaintingStyle.fill);
        canvas.drawPath(ph, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5);
      }
      return;
    }
    if (previewTool == AnnotationTool.mosaic && (previewOptions.mosaicMode == MosaicMode.rect || previewOptions.mosaicMode == MosaicMode.ellipse)) {
      final r = Rect.fromPoints(ds, dc), ph = previewOptions.mosaicMode == MosaicMode.ellipse ? (Path()..addOval(r)) : (Path()..addRect(r));
      canvas.drawPath(ph, Paint()..color = previewColor..strokeWidth = previewStrokeWidth..style = PaintingStyle.stroke);
      return;
    }
    if (previewTool == AnnotationTool.rectangle) {
      final r = Rect.fromPoints(ds, dc); Path ph;
      switch (previewOptions.shapeKind) { case ShapeKind.rectangle: ph = Path()..addRect(r); case ShapeKind.roundedRectangle: ph = Path()..addRRect(RRect.fromRectAndRadius(r, Radius.circular(previewOptions.cornerRadius > 0 ? previewOptions.cornerRadius : 4.0))); case ShapeKind.ellipse: ph = Path()..addOval(r); }
      if (previewOptions.fillStyle == FillStyle.solid) canvas.drawPath(ph, Paint()..color = previewOptions.color.withAlpha(80)..style = PaintingStyle.fill);
      canvas.drawPath(ph, Paint()..color = previewColor..strokeWidth = previewStrokeWidth..style = PaintingStyle.stroke);
    }
    if (previewTool == AnnotationTool.arrow) {
      final dx = dc.dx - ds.dx, dy = dc.dy - ds.dy, dist = math.sqrt(dx * dx + dy * dy); if (dist == 0) return;
      final ux = dx / dist, uy = dy / dist, trim = 10.0 + previewStrokeWidth * 2;
      final fx = previewOptions.startHead == ArrowHeadStyle.arrow ? ds.dx + ux * trim : ds.dx;
      final fy = previewOptions.startHead == ArrowHeadStyle.arrow ? ds.dy + uy * trim : ds.dy;
      final tx = previewOptions.endHead == ArrowHeadStyle.arrow ? dc.dx - ux * trim : dc.dx;
      final ty = previewOptions.endHead == ArrowHeadStyle.arrow ? dc.dy - uy * trim : dc.dy;
      canvas.drawLine(Offset(fx, fy), Offset(tx, ty), Paint()..color = previewColor..strokeWidth = previewStrokeWidth);
      if (previewOptions.endHead == ArrowHeadStyle.arrow) drawArrowHead(canvas, fx, fy, dc.dx, dc.dy, previewColor, previewStrokeWidth);
      if (previewOptions.startHead == ArrowHeadStyle.arrow) drawArrowHead(canvas, tx, ty, ds.dx, ds.dy, previewColor, previewStrokeWidth);
    }
  }

  @override bool shouldRepaint(covariant _PdfPainter o) => true;
}
