library;

import 'dart:async';
import 'dart:developer' as dev;
import 'dart:ui' as ui;
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img_lib;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'annotate_canvas.dart';
import 'annotate_toolbar.dart';
import '../flow/scroll_screenshot_manager.dart';
import 'ocr_service.dart';
import '../integration/translate_service.dart';
import '../capture/capture_win32.dart';
import '../models/screenshot_data.dart';
import '../../../core/window/window_manager.dart';
import '../../translate/translate_service.dart' as tr;
import '../../translate/model_manager.dart';
import '../../../core/search/search_engine_service.dart';
import '../../../core/annotate/magnifier.dart';
import '../../../core/drag/drag_out_helper.dart';
import '../../../core/utils/filename_template.dart';
import '../../../core/theme/theme_colors.dart';
import '../../../core/settings/settings_service.dart';

class AnnotatePage extends StatefulWidget {

// Settings keys persisted across sessions.
static const kOcrLanguageKey = 'screenshot.ocrLanguage';
static const kOcrEngineKey = 'screenshot.ocrEngine';
  final Uint8List imageBytes;
  final String format;
  final void Function(Uint8List, ScreenshotAction, Rect?)? onDone;
  final String? savePathOverride;
  final List<Rect> previousRegions;
  final double captureDpr;
  final Rect? captureMonitorRect;
  final String? filenameTemplate;
  final Future<void> Function(Rect selRect, double captureDpr, Rect captureMonitorRect, Uint8List overlayPng)? onOpenRecording;
  const AnnotatePage({super.key, required this.imageBytes, this.format = 'png', this.onDone, this.savePathOverride, this.previousRegions = const [], this.captureDpr = 1.0, this.captureMonitorRect, this.filenameTemplate, this.onOpenRecording});
  @override State<AnnotatePage> createState() => _S();
}

enum _Ph { selecting, annotating }

// V1.8.0: OCR line-grouping helpers removed — C++ generates full_text now.

class _S extends State<AnnotatePage> {
  ui.Image? _img;
  Uint8List? _imgRgba;
  _Ph _ph = _Ph.selecting;
  Rect? _sel;
  Offset _slS = Offset.zero;
  _D? _drg;
  Offset _dBs = Offset.zero;
  Rect? _dRc;
  final _ann = <AnnotationShape>[], _rd = <AnnotationShape>[];
  final _eraserMasks = <EraserMask>[];
  AnnotationTool _tl = AnnotationTool.mouse;
  Color _cl = Colors.red;
  double _sw = 2.0;
  ToolOptions _opts = const ToolOptions();
  Offset? _ds, _dc;
  List<Offset> _fh = [];
  bool _tx = false;
  Offset _tP = Offset.zero;
  final _tC = TextEditingController(), _tF = FocusNode();
  static const _h = 8.0;

  // Selection / editing state
  String? _selAnnId;
  AnnHandle? _edDrag;
  Rect? _edBase;
  AnnotationShape? _edBaseObj;

  // Long-press repeat (WASD / arrow keys)
  Timer? _holdTimer;
  LogicalKeyboardKey? _holdKey;
  DateTime? _holdStart;

  // Previous regions (R key cycles through up to 3)
  late List<Rect> _prevRegions;
  int _prevRegionIdx = 0;

  // Multi-monitor metadata (from screenshot_plugin via widget)
  late double _captureDpr;
  Rect? _captureMonitorRect;

  // Shortcut help panel
  bool _showHelp = false;

  // Snap-to-window auto-snap (uses pre-fetched _windowPartitionRects)
  static const _debugSnap = false;
bool _dragMoved = false;
  /// True when [_sel] was auto-snapped (highest-rank window rect or full screen)
  /// and has not yet been discarded by a drag.
  bool _autoSnap = false;
  /// Last hover position — used to re-apply auto-snap after window data loads.
  Offset? _lastHoverPos;
  /// Last _sel set by hover auto-snap — used to skip redundant setState.
  Rect? _lastAutoSnapSel;
  /// Window partition rects — fetched once after screenshot loads.
  /// Blue-bordered overlay + rank labels drawn on canvas during selecting.
  List<WindowRectEntry> _windowPartitionRects = [];
  bool _windowRectsLoaded = false;
  double? _lockedRatio;
  Offset _downPos = Offset.zero;
  static const double _kDragThreshold = 5.0;

  // OCR state
  OcrResult? _ocrResult;
  bool _ocrLoading = false;
  String? _ocrError;

  // OCR floating panel (draggable / resizable)
  Rect? _ocrPanelRect;
  Offset? _panelDragTouch;   // globalPosition on drag start
  Offset? _panelDragOrigin;  // _ocrPanelRect.topLeft on drag start
  static const double _kPanelMinW = 460;
  static const double _kPanelMinH = 200;

  // Crosshair state (toggled by Shift in annotating phase)
  bool _showCrosshair = false;

  // Translation state
  Map<int, String>? _translations;
  bool _translating = false;
  String? _translateError;
  String _tlFrom = 'auto';
  String _tlTo = 'zh';
  List<Map<String, String>> _tlLangs = [];
  bool _tlLangsLoaded = false;

  // In-place OCR display toggle (default ON)
  bool _ocrInPlace = true;

  /// OCR language: "ch" (Chinese) or "en" (English).
  String _ocrLanguage = 'ch';

  /// OCR engine / model: "ppocrv6" (PP-OCRv6 ONNX) or "winrt" (Windows.Media.Ocr).
  String _ocrEngine = 'ppocrv6';

  /// UVDoc text unwarping toggle (default OFF, PP-OCRv6 only).
  /// When toggled, re-runs OCR.
  bool _unwarpEnabled = false;

  // ── Scroll-screenshot mode ──
  final _scrollMgr = ScrollScreenshotManager();
  bool get _isScrollMode => _scrollMgr.mode == ScrollMode.active;
  bool _scrollPending = false;

  /// Image dimensions captured at OCR time for accurate coordinate mapping.
  double _ocrImageW = 0;
  double _ocrImageH = 0;

  /// Toggle in-place OCR display.
  void _toggleOcrInPlace() => setState(() => _ocrInPlace = !_ocrInPlace);

  void _saveOcrSettings() {
    final svc = SettingsService();
    svc.set(AnnotatePage.kOcrLanguageKey, _ocrLanguage);
    svc.set(AnnotatePage.kOcrEngineKey, _ocrEngine);
  }

  /// Average character width factor for [text]:
  /// CJK / fullwidth ≈ 0.95, mixed or Latin ≈ 0.58.
  double _avgCharWidthFactor(String text) {
    if (text.isEmpty) return 0.58;
    int cjk = 0;
    for (int i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      // CJK Unified, CJK Ext A/B, Hiragana, Katakana, Hangul, fullwidth forms
      if ((c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF) ||
          (c >= 0x3040 && c <= 0x30FF) || (c >= 0xAC00 && c <= 0xD7AF) ||
          (c >= 0xFF01 && c <= 0xFF60)) {
        cjk++;
      }
    }
    final ratio = cjk / text.length;
    return 0.58 + ratio * (0.95 - 0.58);  // pure Latin 0.58, pure CJK 0.95
  }

  /// Search selected OCR text via the default search engine, then close the annotation window.
  void _ocrSearchText() {
    final txt = _ocrDisplayText;
    if (txt == null || txt.trim().isEmpty) return;
    final service = SearchEngineService();
    final engine = service.getDefaultEngine(SearchEngineCategory.text);
    if (engine == null) return;
    service.execute(engine, txt.trim());
    _cl_();
  }

  /// Search screenshot image via the default image search engine, then close the window.
  /// Copies the screenshot to clipboard first so the user can paste into search.
  Future<void> _searchImageOnBing() async {
    try {
      await _cp(); // copies screenshot to clipboard
    } catch (_) {}
    final service = SearchEngineService();
    final engine = service.getDefaultEngine(SearchEngineCategory.image);
    if (engine != null) {
      service.executeImageSearch(engine);
    }
    _cl_();
  }

/// Builds the context menu for OCR SelectableText widgets.
  /// Context menu for OCR / translate text fields.
  /// Search submenu appears next to parent (not centered) and lists
  /// engines from text, translate, and dictionary categories.
  Widget _ocrSelectionMenuBuilder(BuildContext ctx, EditableTextState state) {
    final sel = state.textEditingValue.selection;
    final selText = sel.textInside(state.textEditingValue.text).trim();
    final cs = Theme.of(ctx).colorScheme;
    final service = SearchEngineService();
    final textEngines = service.loadEnginesByCategory(SearchEngineCategory.text);
    final defaultEngine = service.getDefaultEngine(SearchEngineCategory.text);
    final defaultName = defaultEngine?.name ?? '';
    // All non-text engines for the submenu
    final translateEngines = service.loadEnginesByCategory(SearchEngineCategory.translate);
    final dictEngines = service.loadEnginesByCategory(SearchEngineCategory.dictionary);
    final hasSubmenu = translateEngines.isNotEmpty || dictEngines.isNotEmpty;
    return AdaptiveTextSelectionToolbar(
      anchors: state.contextMenuAnchors,
      children: [
        TextButton(
          onPressed: () {
            state.copySelection(SelectionChangedCause.toolbar);
            state.hideToolbar();
          },
          child: SizedBox(
            width: 120,
            child: Text('Copy',
              textAlign: TextAlign.left,
              style: TextStyle(color: cs.onSurface.withAlpha(179), fontSize: 13)),
          ),
        ),
        TextButton(
          onPressed: () {
            state.selectAll(SelectionChangedCause.toolbar);
            state.hideToolbar();
          },
          child: SizedBox(
            width: 120,
            child: Text('Select All',
              textAlign: TextAlign.left,
              style: TextStyle(color: cs.onSurface.withAlpha(179), fontSize: 13)),
          ),
        ),
        if (selText.isNotEmpty)
          TextButton(
            onPressed: () {
              final engine = textEngines.cast<SearchEngine?>().firstWhere(
                (e) => e!.name == defaultName,
                orElse: () => textEngines.isNotEmpty ? textEngines.first : null,
              );
              if (engine != null) {
                service.execute(engine, selText);
              }
              state.hideToolbar();
              _cl_();
            },
            child: SizedBox(
              width: 120,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Expanded(
                  child: Text('Search',
                    textAlign: TextAlign.left,
                    style: TextStyle(color: cs.primary, fontSize: 13)),
                ),
                if (hasSubmenu)
                  GestureDetector(
                    onTapDown: (d) => _showSearchEnginePopup(
                      ctx, d.globalPosition, selText, state),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(Icons.arrow_drop_down, color: cs.primary, size: 16),
                    ),
                  ),
              ]),
            ),
          ),
      ],
    );
  }

  /// Popup listing text + translate + dictionary engines, positioned at
  /// [position] with boundary clamping (flips if exceeds screen edge).
  void _showSearchEnginePopup(BuildContext ctx, Offset position,
      String selText, EditableTextState state) {
    final service = SearchEngineService();
    final textEngines = service.loadEnginesByCategory(SearchEngineCategory.text);
    final translateEngines = service.loadEnginesByCategory(SearchEngineCategory.translate);
    final dictEngines = service.loadEnginesByCategory(SearchEngineCategory.dictionary);

    final screen = MediaQuery.of(ctx).size;
    const menuW = 210.0;
    const rowH = 40.0;
    int headerCount = 0;
    if (textEngines.isNotEmpty) headerCount++;
    if (translateEngines.isNotEmpty) headerCount++;
    if (dictEngines.isNotEmpty) headerCount++;
    final totalItems = textEngines.length +
        translateEngines.length +
        dictEngines.length +
        headerCount;
    final menuH = totalItems * rowH + 4;
    final left = (position.dx + menuW > screen.width)
        ? position.dx - menuW
        : position.dx;
    final top = (position.dy + menuH > screen.height)
        ? position.dy - menuH
        : position.dy;

    final overlay = Overlay.of(ctx);
    late OverlayEntry entry;
    entry = OverlayEntry(builder: (ctx2) {
      final cs = Theme.of(ctx2).colorScheme;

      Widget engineRow(SearchEngine e) => InkWell(
            onTap: () {
              entry.remove();
              service.execute(e, selText);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                state.hideToolbar();
                _cl_();
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                Icon(e.copyMode ? Icons.content_copy : Icons.open_in_browser,
                    size: 14, color: cs.onSurface.withAlpha(138)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(e.name,
                      style: TextStyle(fontSize: 13, color: cs.onSurface)),
                ),
              ]),
            ),
          );

      Widget catHeader(String label) => Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(label,
                  style: TextStyle(
                      fontSize: 10,
                      color: cs.primary.withAlpha(153),
                      fontWeight: FontWeight.w600)),
            ),
          );

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => entry.remove(),
        child: Stack(children: [
          Positioned(
            left: left,
            top: top,
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: menuW),
                decoration: BoxDecoration(
                  color: XMateColors.dialogBg(ctx2),
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: cs.primary.withAlpha(60), width: 1),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (textEngines.isNotEmpty) ...[
                      catHeader('Text'),
                      ...textEngines.map((e) => engineRow(e)),
                    ],
                    if (translateEngines.isNotEmpty) ...[
                      catHeader('Translate'),
                      ...translateEngines.map((e) => engineRow(e)),
                    ],
                    if (dictEngines.isNotEmpty) ...[
                      catHeader('Dictionary'),
                      ...dictEngines.map((e) => engineRow(e)),
                    ],
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ),
          ),
        ]),
      );
    });
    overlay.insert(entry);
  }


  // V1.8.0: Per-block overlay tuning constants removed — C++ generates full_text now.


  @override void initState() {
    super.initState();
    _captureDpr = widget.captureDpr;
    _captureMonitorRect = widget.captureMonitorRect;
    _prevRegions = widget.previousRegions;
    _ld();
    // Restore persisted OCR language / engine.
    final s = SettingsService();
    _ocrLanguage = (s.get(AnnotatePage.kOcrLanguageKey) as String?) ?? 'ch';
    _ocrEngine = (s.get(AnnotatePage.kOcrEngineKey) as String?) ?? 'ppocrv6';
    // Listen for native scroll hook notifications
    const MethodChannel('com.xmate/scroll').setMethodCallHandler((call) async {
      if (call.method == 'capture') {
        final wheelDelta = (call.arguments as Map?)?['wheelDelta'] as int? ?? 0;
        await _onScrollCapture(wheelDelta);
      }
    });
  }
  @override void dispose() {
    const MethodChannel('com.xmate/scroll').setMethodCallHandler(null);
    _tC.dispose(); _tF.dispose();
    if (_isScrollMode) {
      CaptureServiceWin32().uninstallScrollHook(); // fire-and-forget
      WindowService.clearWindowHole();             // fire-and-forget
    }
    _scrollMgr.exitMode();
    super.dispose();
  }

  Future<void> _ld() async {
    final c = await ui.instantiateImageCodec(widget.imageBytes);
    if (!mounted) return;
    final f = await c.getNextFrame();
    if (!mounted) return;
    final img = f.image;
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (!mounted) return;
    setState(() { _img = img; _imgRgba = bd?.buffer.asUint8List(); });
    // Fetch window partition rects in background — doesn't block paint.
    _loadWindowRects();
  }

  /// Fetch visible window rects from C++ (occlusion-filtered by shotRect).
  /// Convert from screen-physical to widget-logical coords for rendering.
  Future<void> _loadWindowRects() async {
    if (_windowRectsLoaded) return;
    // Capture widget size before async gap to avoid BuildContext lint.
    final ws = MediaQuery.of(context).size;
    try {
      final entries = await CaptureServiceWin32().getWindowRects(
        outerOnly: false, includeChildren: true);

      if (!mounted || entries.isEmpty) return;
      final dpr = WidgetsBinding.instance.platformDispatcher
              .displays.first.devicePixelRatio;
      final logical = <WindowRectEntry>[];
      for (final e in entries) {
        final lr = Rect.fromLTWH(
          e.rect.left / dpr,
          e.rect.top  / dpr,
          e.rect.width  / dpr,
          e.rect.height / dpr,
        );
        // Intersect with widget bounds (clip to visible area)
        if (lr.left >= ws.width || lr.top >= ws.height ||
            lr.right <= 2 || lr.bottom <= 2) continue;
        logical.add(WindowRectEntry(rect: lr, rank: e.rank));
      }
      if (!mounted) return;
      if (!mounted) return;
      setState(() {
        _windowPartitionRects = logical;
        _windowRectsLoaded = true;
      });
      // Re-apply auto-snap now that window data has loaded.
      // Use addPostFrameCallback to avoid calling MediaQuery mid-build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _ph == _Ph.selecting) _applyAutoSnap();
      });
    } catch (_) {
      // Non-critical — silently skip
    }
  }

  @override Widget build(BuildContext c) {
    if (_img == null) return Container(color: XMateColors.panelBg(c));
    final cs = Theme.of(c).colorScheme;
    final sz = MediaQuery.of(c).size;
    final s = _sel;
    final an = _ph == _Ph.annotating;
    Offset? tp; const tw = 480.0, th = 38.0;
    if (an && s != null) {
      double tx = s.right - tw - 56, ty = s.bottom + 4;
      if (ty + th > sz.height) ty = s.top - th - 4;
      tp = Offset(tx.clamp(0, sz.width - tw), ty.clamp(0, sz.height - th));
    }
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        final key = event.logicalKey;

        // ── Key-up: stop hold timer for repeating keys ──
        if (event is KeyUpEvent) {
          if (_holdKey != null && key == _holdKey) _stopHold();
          return KeyEventResult.handled;
        }

        // Only handle KeyDown and KeyRepeat events below
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final isRepeat = event is KeyRepeatEvent;
        final isDown = event is KeyDownEvent;

        // ── 1. Escape ──
        if (key == LogicalKeyboardKey.escape) {
          _stopHold();
          // In scroll mode, close directly (same as close button)
          if (_isScrollMode) {
            _cl_();
            return KeyEventResult.handled;
          }
          if (_tl == AnnotationTool.translate && _translations != null) {
            _clearTranslate();
            return KeyEventResult.handled;
          }
          if (_ocrResult != null || _ocrError != null || _ocrLoading) {
            _clearOcr();
            _tl = AnnotationTool.mouse;
            return KeyEventResult.handled;
          }
          _autoSnap = false;
          _showCrosshair = false;
          _cl_();
          return KeyEventResult.handled;
        }

        // ── 2. Ctrl-modified keys (always handled, not blocked by _tx) ──
        final ctrlHeld = HardwareKeyboard.instance.logicalKeysPressed
            .any((k) => k == LogicalKeyboardKey.controlLeft ||
                       k == LogicalKeyboardKey.controlRight);
        if (isRepeat) {
          if (ctrlHeld && key == LogicalKeyboardKey.keyA) {
            // handled below — fall through
          } else {
            return KeyEventResult.ignored;
          }
        }
        if (ctrlHeld) {
          final ocrActive = _ocrResult != null || _ocrError != null || _ocrLoading ||
              _translations != null || _translating || _translateError != null;
          if (key == LogicalKeyboardKey.keyA && isDown) {
            // Ctrl+A: if OCR/translation panel visible, let SelectableText handle selection
            if (ocrActive) return KeyEventResult.ignored;
            setState(() => _sel = Rect.fromLTWH(0, 0, sz.width, sz.height));
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.keyZ && isDown && _ph == _Ph.annotating) {
            // Ctrl+Z = undo
            _un();
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.keyX && isDown && _ph == _Ph.annotating) {
            // Ctrl+X = redo
            _rd_();
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.keyC && (ocrActive || (_sel != null && _ph == _Ph.annotating))) {
            _cp();
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.keyS && (ocrActive || (_sel != null && _ph == _Ph.annotating))) {
            _sv();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        // ── 3. Guard: don't intercept keys during text input ──
        if (_tx) return KeyEventResult.ignored;

        // ── 4. Alt — toggle crosshair (annotating, not dragging) ──
        if ((key == LogicalKeyboardKey.altLeft || key == LogicalKeyboardKey.altRight) &&
            isDown) {
          if (_ph == _Ph.annotating && _sel != null &&
              _edDrag == null && _drg == null) {
            setState(() => _showCrosshair = !_showCrosshair);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        // ── 5. WASD — micro-adjust cursor (both phases, custom-hold repeat) ──
        final wasdMove = <LogicalKeyboardKey, Offset>{
          LogicalKeyboardKey.keyW: const Offset(0, -1),
          LogicalKeyboardKey.keyA: const Offset(-1, 0),
          LogicalKeyboardKey.keyS: const Offset(0, 1),
          LogicalKeyboardKey.keyD: const Offset(1, 0),
        };
        if (wasdMove.containsKey(key)) {
          if (isDown) {
            _moveCursorBy(wasdMove[key]!);
            _startHold(key, () => _moveCursorBy(wasdMove[key]!));
          }
          return KeyEventResult.handled;
        }

        // ── 6. F — refresh screenshot (disabled in scroll mode) ──
        if (key == LogicalKeyboardKey.keyF && isDown && !_isScrollMode) {
          _refreshCapture();
          return KeyEventResult.handled;
        }

        // ── 7. R — restore previous region ──
        if (key == LogicalKeyboardKey.keyR && isDown) {
          _restorePrevRegion();
          return KeyEventResult.handled;
        }

        // ── 8. Arrow keys (annotating, custom-hold repeat) ──
        if (_ph == _Ph.annotating) {
          final shiftHeld = HardwareKeyboard.instance.logicalKeysPressed
              .any((k) => k == LogicalKeyboardKey.shiftLeft ||
                         k == LogicalKeyboardKey.shiftRight);
          if (key == LogicalKeyboardKey.arrowUp ||
              key == LogicalKeyboardKey.arrowDown ||
              key == LogicalKeyboardKey.arrowLeft ||
              key == LogicalKeyboardKey.arrowRight) {
            if (isDown) {
              if (shiftHeld && !_isScrollMode) {
                _resizeByArrow(key);
                _startHold(key, () => _resizeByArrow(key));
              } else if (!shiftHeld) {
                _moveByArrow(key);
                _startHold(key, () => _moveByArrow(key));
              }
            }
            return KeyEventResult.handled;
          }

          // ── 9. Tab — cycle selected annotation ──
          if (key == LogicalKeyboardKey.tab && isDown) {
            _cycleSelection();
            return KeyEventResult.handled;
          }

          // ── 10. Delete / Backspace — delete selected annotation ──
          if (key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) {
            if (isDown) _deleteSelectedAnnotation();
            return KeyEventResult.handled;
          }

          // ── 10. H — toggle help panel ──
          if (key == LogicalKeyboardKey.keyH && isDown) {
            setState(() => _showHelp = !_showHelp);
            return KeyEventResult.handled;
          }

          // ── 11. T — translate (disabled in scroll mode) ──
          if (key == LogicalKeyboardKey.keyT && isDown && !_isScrollMode) {
            setState(() => _tl = AnnotationTool.translate);
            _doTranslate();
            return KeyEventResult.handled;
          }
        }

        return KeyEventResult.ignored;
      },
      child: Scaffold(backgroundColor: XMateColors.panelBg(c), body: Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent && _ph == _Ph.annotating && !_tx) {
            // ── Scroll-screenshot mode: native WH_MOUSE_LL hook handles scroll ──
            if (_isScrollMode) return; // always consume — no Flutter-layer zoom
            // If OCR panel is visible and pointer is inside it, let the panel scroll
            if (_ocrPanelRect != null && _ocrPanelRect!.contains(e.localPosition)) return;
            final d = e.scrollDelta.dy;
            if (d == 0.0) return;
            final sign = d > 0 ? 1 : -1;
            final shiftHeld = HardwareKeyboard.instance.logicalKeysPressed
                .any((k) => k == LogicalKeyboardKey.shiftLeft ||
                           k == LogicalKeyboardKey.shiftRight);
            // NumberTag + Shift+scroll: change number
            if (shiftHeld && _selAnnId != null) {
              final a = _findById(_selAnnId!);
              if (a is NumberTagAnnotation) {
                final newN = (a.number + sign).clamp(1, 999);
                setState(() {
                  _replaceAnnInPlace(a, NumberTagAnnotation(
                    x: a.x, y: a.y, number: newN,
                    color: a.color, style: a.style, fontSize: a.fontSize,
                    id: a.id,
                  )..rotation = a.rotation);
                  _selAnnId = a.id;
                });
                return;
              }
            }
            if (shiftHeld) {
              _zoomFromTLAnchor(sign);
            } else {
              _zoomFromCenter(sign.toDouble());
            }
          }
        },
        child: Stack(children: [
      Positioned.fill(child: MouseRegion(
        onHover: _ph == _Ph.selecting ? _onHover : null,
        child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: _ps, onPanUpdate: _pu, onPanEnd: _pe,
        onSecondaryTapUp: _onRightClick,
        child: AnnotateCanvas(
            image: _img!,
            imageRgba: _imgRgba,
            selection: _sel,
            showSelectionHandles: _ph == _Ph.annotating && !_isScrollMode,
            annotations: _ann,
            eraserMasks: _eraserMasks,
            previewTool: _tl,
            previewStart: _ds,
            previewCurrent: _dc,
            previewFreehand: _fh,
            previewColor: _cl,
            previewStrokeWidth: _sw,
            previewOptions: _opts,
            selectedAnnotationId: _selAnnId,
            snapPreviewRect: null, // auto-snap replaces old snap preview
            showCrosshair: _showCrosshair,
            crosshairRect: _sel,
          ),
      ))),
      if (_tx) Positioned(left: _tP.dx, top: _tP.dy, child: Material(color: Colors.transparent, child: SizedBox(width: 200, child: TextField(
        controller: _tC, focusNode: _tF, autofocus: true,
        style: TextStyle(
          fontSize: _opts.fontSize, color: _cl,
          fontWeight: _opts.bold ? FontWeight.bold : FontWeight.normal,
          fontStyle: _opts.italic ? FontStyle.italic : FontStyle.normal,
          fontFamily: _opts.fontFamily,
        ),
        decoration: const InputDecoration(border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero),
        onSubmitted: (_) => _ct(), onTapOutside: (_) => _ct(),
      )))),
      if (s != null && s.width > 0) Positioned(left: s.left, top: math.max(0, s.top - 28),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            color: XMateColors.panelBg(c),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              GestureDetector(
                onTap: _ph == _Ph.annotating ? _showResizeDialog : null,
                child: Text('${s.width.round()} x ${s.height.round()}',
                    style: TextStyle(color: cs.onSurface, fontSize: 12)),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: _ph == _Ph.annotating && !_isScrollMode ? _refreshCapture : null,
                child: Icon(Icons.refresh,
                    color: _isScrollMode ? cs.onSurface.withAlpha(102) : cs.primary,
                    size: 18),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: _ph == _Ph.annotating && !_isScrollMode ? _searchImageOnBing : null,
                child: Icon(Icons.image_search,
                    color: _isScrollMode ? cs.onSurface.withAlpha(102) : cs.primary,
                    size: 18),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: _ph == _Ph.annotating && !_isScrollMode &&
                    _sel != null && widget.onOpenRecording != null
                    ? () async {
                        final png = await _renderOverlayPng(_sel!,
                            scale: _captureDpr);
                        await widget.onOpenRecording!.call(
                            _sel!, _captureDpr, _captureMonitorRect!, png);
                      }
                    : null,
                child: Icon(Icons.videocam,
                    color: _isScrollMode ? cs.onSurface.withAlpha(102) : cs.primary,
                    size: 18),
              ),
            ]),
          ),
        ])),
      // ── Scroll-mode debug panel ──
      if (_isScrollMode && _scrollMgr.hasFrames && s != null && s.width > 0)
        Positioned(
          left: s.right + 8,
          top: s.top,
          child: _buildDebugPreview(),
        ),
      if (an && tp != null) Positioned(left: tp.dx, top: tp.dy, child: Material(elevation: 8, borderRadius: BorderRadius.circular(8),
        color: XMateColors.panelBg(c).withAlpha(204),
        child: AnnotateToolbar(currentTool: _tl, options: _opts,
          hiddenTools: const {AnnotationTool.crop, AnnotationTool.bgRemove, AnnotationTool.magnifier},
          hasSelection: _sel != null, canUndo: _ann.isNotEmpty, canRedo: _rd.isNotEmpty,
          onToolChanged: (v) {
          // Block OCR/translate tools in scroll-screenshot mode
          if (_isScrollMode && (v == AnnotationTool.ocr || v == AnnotationTool.translate)) return;
          if (_tx) _ct();
          final wasOcr = _tl == AnnotationTool.ocr;
          final wasTranslate = _tl == AnnotationTool.translate;
          if ((wasOcr || wasTranslate) && v != AnnotationTool.ocr && v != AnnotationTool.translate) {
            _clearOcr();
            _clearTranslate();
          }
          setState(() { _tl = v; });
          if (v == AnnotationTool.ocr) {
            _doOcr();
          } else if (v == AnnotationTool.translate) {
            _doTranslate();
          }
        },
          onOptionsChanged: (v) => setState(() {
            _opts = v; _cl = v.color; _sw = v.strokeWidth;
            if (_selAnnId != null) {
              final a = _findById(_selAnnId!);
              if (a != null) {
                final u = _applyOptsToAnnotation(a);
                if (u != null) _replaceAnn(a, u);
              }
            }
          }),
          onUndo: _un, onRedo: _rd_, onCopy: _cp, onSave: _sv, onPin: _pn, onClose: _cl_,
          onClearAll: () => setState(() {
            _rd.addAll(_ann); _ann.clear();
            _eraserMasks.clear();
          })))),
      // ── Shortcut help panel (bottom-left overlay, toggle with H) ──
      if (_showHelp) _buildHelpPanel(sz, an),
      // OCR in-place text overlays (semi-transparent, at image coordinates)
      ..._buildOcrInPlace(sz),
      // OCR floating panel — selectable text + search
      ..._buildOcrOverlay(sz),
      // ── Task 7: Cursor preview (independent widget, own setState) ──
      // Hidden during scroll-screenshot mode (hole is transparent, no magnifier needed)
      if (_ph == _Ph.selecting || (_ph == _Ph.annotating && _tl == AnnotationTool.mouse && !_isScrollMode))
        CursorMagnifier(image: _img!, imageRgba: _imgRgba!),
    ]))));
  }

  // ─── Shortcut help panel ───

  /// Build the keyboard shortcut help panel at the bottom-left of the screen.
  /// Auto-hides when [_sel] overlaps it.
  Widget _buildHelpPanel(Size sz, bool annotating) {
    final cs = Theme.of(context).colorScheme;
    final k = TextStyle(color: cs.primary, fontSize: 12,
        fontFamily: 'Consolas', height: 1.45);
    final v = TextStyle(color: cs.onSurface.withAlpha(179), fontSize: 12, height: 1.45);
    final s = TextStyle(color: cs.onSurface, fontSize: 12,
        fontWeight: FontWeight.w600, height: 1.5);

    Widget row(String key, String desc, {bool bold = false}) => Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 130, child: Text(key, style: bold ? s : k)),
        Expanded(child: Text(desc, style: v)),
      ]),
    );

    final rows = <Widget>[];
    rows.add(Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        Expanded(child: Text('快捷键说明',
            style: TextStyle(color: cs.onSurface, fontSize: 13, fontWeight: FontWeight.w600))),
        Text('[H] 隐藏', style: k),
      ]),
    ));

    if (annotating) {
      rows.addAll([
        const SizedBox(height: 2),
        row('Esc', '取消 / 关闭浮层'),
        row('Del / Backspace', '删除选中标记'),
        row('Tab', '切换选中标记'),
        row('Ctrl+A', '选中整个屏幕'),
        row('Ctrl+C', '复制到剪贴板'),
        row('Ctrl+S', '保存到文件'),
        row('F', '刷新截图'),
        row('R', '恢复之前的选区'),
        row('T', '翻译 (先 OCR)'),
        row('Ctrl+Z / X', '撤销 / 重做'),
        row('←↑↓→', '移动选区 1px'),
        row('Shift + ←↑↓→', '调整选区大小 1px'),
        row('鼠标滚轮 / Shift+滚轮', '中心缩放 / 左上角缩放'),
        row('Alt', '切换十字参考线'),
        row('WASD', '微调光标 1px'),
        row('Z / C / X', '复制坐标 / RGB / HEX'),
        row('鼠标右键', '切换工具 / 复制'),
      ]);
    } else {
      rows.addAll([
        const SizedBox(height: 2),
        row('Esc', '取消'),
        row('Ctrl+A', '选中整个屏幕'),
        row('F', '刷新截图'),
        row('R', '恢复之前的选区'),
        row('WASD', '微调光标 1px'),
        row('Z / C / X', '复制坐标 / RGB / HEX'),
      ]);
    }

    return Positioned(
      left: 12,
      bottom: 12,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.all(12),
          width: 300,
          decoration: BoxDecoration(
            color: XMateColors.panelBg(context).withAlpha(204),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: cs.onSurface.withAlpha(61)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: rows,
          ),
        ),
      ),
    );
  }

  // ─── OCR ───

  /// Encode [rgba] bytes for the given [rect] (or whole image) as PNG,
  /// then call the native OCR engine.
  Future<void> _doOcr() async {
    if (_ocrLoading) return;
    setState(() { _ocrLoading = true; _ocrError = null; _ocrResult = null; _ocrPanelRect = null; });

    try {
      final img = _img;
      final rgba = _imgRgba;
      if (img == null || rgba == null) {
        setState(() { _ocrError = 'Image not loaded'; _ocrLoading = false; });
        return;
      }

      // Always OCR the selected region only — no full-image fallback.
      final sel = _sel;
      if (sel == null || sel.width <= 5 || sel.height <= 5) {
        setState(() { _ocrError = '请先框选一个区域再执行 OCR'; _ocrLoading = false; });
        return;
      }
      final iw = img.width.toDouble();
      final ih = img.height.toDouble();
      final ws = MediaQuery.of(context).size;
      final sx = ws.width > 0 ? iw / ws.width : 1.0;
      final sy = ws.height > 0 ? ih / ws.height : 1.0;

      final cropR = Rect.fromLTWH(
        (sel.left * sx).roundToDouble(),
        (sel.top * sy).roundToDouble(),
        (sel.width * sx).roundToDouble(),
        (sel.height * sy).roundToDouble(),
      );

      final pngBytes = await _encodePngCrop(img, rgba, cropR);

      final svc = OcrService();
      final result = await svc.recognize(pngBytes,
        cropX: cropR.left.round(),
        cropY: cropR.top.round(),
        enableUnwarp: _ocrEngine == 'ppocrv6' ? _unwarpEnabled : false,
        engine: _ocrEngine,
        language: _ocrLanguage,
      );

      if (!mounted) return;
      setState(() {
        _ocrResult = result;
        _ocrLoading = false;
        // Store image dims at OCR time for accurate in-place mapping
        _ocrImageW = img.width.toDouble();
        _ocrImageH = img.height.toDouble();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ocrError = e.toString().replaceFirst('Exception: ', '');
        _ocrLoading = false;
      });
    }
  }

  /// PNG-encode [img]'s pixel data cropped to [cropR] (image pixels).
  ///
  /// Uses the `image` package (pure CPU) to avoid GPU contention:
  /// `PictureRecorder → Canvas → toImage()` allocates a GPU texture while
  /// AnnotateCanvas is still reading from the same source image, which on
  /// some GPU/driver combinations corrupts the swapchain → black frame.
  Future<Uint8List> _encodePngCrop(ui.Image img, Uint8List rgba, Rect cropR) async {
    // Clamp to image bounds
    final x = cropR.left.round().clamp(0, img.width);
    final y = cropR.top.round().clamp(0, img.height);
    final w = cropR.width.round().clamp(1, img.width - x);
    final h = cropR.height.round().clamp(1, img.height - y);

    // Build img_lib.Image from RGBA bytes, crop, encode — all CPU, zero GPU
    final src = img_lib.Image.fromBytes(
      width: img.width, height: img.height,
      bytes: rgba.buffer,
      numChannels: 4,
      order: img_lib.ChannelOrder.rgba,
    );
    final cropped = img_lib.copyCrop(src, x: x, y: y, width: w, height: h);
    final png = img_lib.encodePng(cropped);
    return Uint8List.fromList(png);
  }

  /// Clear OCR overlay. Called when tool switches away from OCR.
  void _clearOcr() {
    if (_ocrResult != null || _ocrError != null || _ocrLoading) {
      setState(() {
        _ocrResult = null;
        _ocrError = null;
        _ocrLoading = false;
        _ocrPanelRect = null;
      });
    }
  }

  /// Load available languages from installed models (for the dropdowns).
  Future<void> _loadTlLangs() async {
    if (_tlLangsLoaded) return;
    final mgr = ModelManager();
    final installed = await mgr.listInstalledPairs();
    if (!mounted) return;
    final codes = <String>{'en'};
    String norm(String c) => c == 'zh-Hans' ? 'zh' : c;
    for (final m in installed) {
      codes.add(norm(m.code1));
      codes.add(norm(m.code2));
    }
    final langs = <Map<String, String>>[
      {'code': 'auto', 'name': '自动检测'},
    ];
    for (final c in codes) {
      langs.add({'code': c, 'name': tr.langNameZh(c)});
    }
    langs.sort((a, b) => a['code'] == 'auto' ? -1 : a['code']!.compareTo(b['code']!));
    setState(() {
      _tlLangs = langs;
      _tlLangsLoaded = true;
    });
  }

  /// Execute translation on all OCR block texts.
  ///
  /// If [_ocrResult] is null or OCR hasn't run yet, this triggers OCR first
  /// (via [_doOcr]), which will then call [_doTranslate] again once complete.
  Future<void> _doTranslate() async {
    _loadTlLangs(); // fire-and-forget

    if (_ocrResult == null && !_ocrLoading) {
      setState(() { _translating = true; _translateError = null; });
      await _doOcr();
      if (!mounted) return;
      if (_ocrResult == null) {
        setState(() {
          _translating = false;
          _translateError = _ocrError ?? 'OCR failed';
        });
        return;
      }
      _translating = false;
    }

    if (_translating) return;
    setState(() { _translating = true; _translateError = null; });

    final blocks = _ocrResult!.blocks;
    final texts = <String>[];
    final indices = <int>[];
    for (int i = 0; i < blocks.length; i++) {
      if (blocks[i].text.isNotEmpty) {
        texts.add(blocks[i].text);
        indices.add(i);
      }
    }

    if (texts.isEmpty) {
      setState(() { _translating = false; });
      return;
    }

    try {
      final svc = TranslateService();
      final results = await svc.translateBatch(texts, from: _tlFrom, to: _tlTo);

      if (!mounted) return;
      setState(() {
        _translations = {};
        for (int j = 0; j < indices.length && j < results.length; j++) {
          _translations![indices[j]] = results[j];
        }
        _translating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _translateError = e.toString().replaceFirst('Exception: ', '');
        _translating = false;
      });
    }
  }

  /// Clear translation overlay, but keep OCR results intact.
  void _clearTranslate() {
    if (_translations != null || _translating || _translateError != null) {
      setState(() {
        _translations = null;
        _translateError = null;
        _translating = false;
      });
    }
  }

  /// Compact segment-button for OCR language: "中" or "EN".
  Widget _ocrLangSegBtn(String label, String lang) {
    final cs = Theme.of(context).colorScheme;
    final active = _ocrLanguage == lang;
    return SizedBox(
      width: 28, height: 24,
      child: TextButton(
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          backgroundColor: cs.primary.withAlpha(active ? 51 : 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
            side: BorderSide(
              color: cs.primary.withAlpha(active ? 179 : 51),
              width: 1,
            ),
          ),
        ),
        onPressed: active ? null : () => setState(() {
          _ocrLanguage = lang;
          // PP-OCRv6 is Chinese-only; English always uses WinRT.
          if (lang == 'en') _ocrEngine = 'winrt';
          _saveOcrSettings();
          _doOcr();
        }),
        child: Text(label, style: TextStyle(
          color: active ? cs.primary : cs.onSurface.withAlpha(90),
          fontSize: 10, fontWeight: FontWeight.w700,
        )),
      ),
    );
  }

  /// Compact engine dropdown (Chinese only): PP-OCRv6 | WinRT.
  Widget _ocrEngineDropdown(ColorScheme cs) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: _ocrEngine,
        isDense: true,
        dropdownColor: XMateColors.dialogBg(context),
        style: TextStyle(color: cs.primary, fontSize: 10),
        icon: Icon(Icons.arrow_drop_down, color: cs.onSurface.withAlpha(97), size: 14),
        items: const [
          DropdownMenuItem(value: 'ppocrv6', child: Text('PP-OCRv6', style: TextStyle(fontSize: 10))),
          DropdownMenuItem(value: 'winrt', child: Text('WinRT', style: TextStyle(fontSize: 10))),
        ],
        onChanged: (v) {
          if (v == null) return;
          setState(() => _ocrEngine = v);
          _saveOcrSettings();
          _doOcr();
        },
      ),
    );
  }

  /// Compact language dropdown for the translate panel title bar.
  Widget _tlLangDropdown(String value, bool isSource) {
    final cs = Theme.of(context).colorScheme;
    final items = isSource ? _tlLangs : _tlLangs.where((l) => l['code'] != 'auto').toList();
    if (!items.any((l) => l['code'] == value)) {
      // auto-select first available
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {
          if (isSource) _tlFrom = items.first['code']!;
          else _tlTo = items.first['code']!;
        });
      });
    }
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: items.any((l) => l['code'] == value) ? value : items.first['code'],
        isDense: true,
        dropdownColor: XMateColors.dialogBg(context),
        style: TextStyle(color: cs.primary, fontSize: 11),
        icon: Icon(Icons.arrow_drop_down, color: cs.onSurface.withAlpha(97), size: 14),
        items: items
            .map((l) => DropdownMenuItem(value: l['code'], child: Text(l['name'] ?? '', style: const TextStyle(fontSize: 11))))
            .toList(),
        onChanged: (v) {
          if (v == null) return;
          setState(() {
            if (isSource) { _tlFrom = v; } else { _tlTo = v; }
          });
          _doTranslate();
        },
      ),
    );
  }

  // V1.9.0: Floating OCR panel — auto-positioned near _sel, draggable, resizable

  Rect _ocrPanelAutoRect(Size ws) {
    final sel = _sel;
    final double pw, ph;
    if (sel != null && sel.width > 5 && sel.height > 5) {
      pw = sel.width.clamp(_kPanelMinW, math.min(ws.width - 20, 550.0));
      ph = sel.height.clamp(_kPanelMinH, math.min(ws.height - 40, 400.0));
      // Try: right → below → left → above → center
      final cand = <Offset>[
        Offset(sel.right + 16, sel.top),                          // right
        Offset(sel.left, sel.bottom + 16),                        // below
        Offset(sel.left - pw - 16, sel.top),                      // left
        Offset(sel.left, sel.top - ph - 16),                      // above
        Offset((ws.width - pw) / 2, (ws.height - ph) / 2),        // center
      ];
      for (final c in cand) {
        final r = Rect.fromLTWH(c.dx, c.dy, pw, ph);
        if (r.right <= ws.width - 8 && r.bottom <= ws.height - 8 && r.left >= 0 && r.top >= 0) {
          return r;
        }
      }
      return Rect.fromLTWH(
        ((ws.width - pw) / 2).clamp(8.0, ws.width - pw - 8),
        ((ws.height - ph) / 2).clamp(8.0, ws.height - ph - 8),
        pw, ph);
    }
    // No selection: centered panel, capped to a fixed reasonable size
    pw = 440.0;
    ph = 320.0;
    return Rect.fromLTWH(
      (ws.width - pw) / 2,
      (ws.height - ph) / 2,
      pw, ph);
  }

  /// Debug overlay — shows the current frame with fixed borders / ROI / dy annotations.
  Widget _buildDebugPreview() {
    final debug = _scrollMgr.debugPng;
    if (debug == null || debug.length <= 4) return const SizedBox.shrink();
    final selW = _sel?.width ?? 240.0;
    final selH = _sel?.height ?? 200.0;
    // Side-by-side: ~2.2× wider than selection
    final previewW = (selW * 2.2).clamp(400.0, 800.0);
    final previewH = selH.clamp(160.0, MediaQuery.of(context).size.height * 0.55);
    return Container(
      width: previewW,
      height: previewH,
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xAA00FF00), width: 1.5),
        color: XMateColors.panelBg(context),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          color: const Color(0xAA00FF00),
          child: const Text('prev                 DEBUG                             curr',
              style: TextStyle(color: Colors.black87, fontSize: 8, fontWeight: FontWeight.w700)),
        ),
        Expanded(
          child: ClipRect(
            child: Image.memory(debug, fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (e, s, t) => const SizedBox.shrink()),
          ),
        ),
      ]),
    );
  }

  /// Build stitched preview thumbnail — fixed width (240px), adaptive height,
  /// capped to screen bounds.  Shows the live composite of all captured frames.
  /// Build in-place OCR text overlays positioned at original image coordinates.
  ///
  /// Each box uses the quad AABB height directly (no 2× multiplier).  Font size
  /// is the box height, clamped 12–96 px.  Text is bottom-aligned so the
  /// baseline sits at the quad's bottom edge; letter-spacing fills short text.
  List<Widget> _buildOcrInPlace(Size ws) {
    if (!_ocrInPlace) return const [];
    final cs = Theme.of(context).colorScheme;
    final result = _ocrResult;
    if (result == null || result.boxes.isEmpty) return const [];
    if (_img == null) return const [];

    final iw = _ocrImageW > 0 ? _ocrImageW : _img!.width.toDouble();
    final ih = _ocrImageH > 0 ? _ocrImageH : _img!.height.toDouble();
    final sx = ws.width > 0 ? ws.width / iw : 1.0;
    final sy = ws.height > 0 ? ws.height / ih : 1.0;

    final isTranslate = _tl == AnnotationTool.translate;
    return result.boxes.take(50).toList().asMap().entries.map((entry) {
      final i = entry.key;
      final box = entry.value;
      final q = box.quad;
      if (q.length < 4) return const SizedBox.shrink();

      // Show translation text when in translate mode, OCR text otherwise
      final displayText = (isTranslate && _translations != null)
          ? (_translations![i] ?? box.text)
          : box.text;

      // Map 4 quad corners to widget space → AABB
      final xs = q.map((p) => p.dx * sx);
      final ys = q.map((p) => p.dy * sy);
      final left = xs.reduce(math.min);
      final top  = ys.reduce(math.min);
      final right  = xs.reduce(math.max);
      final bottom = ys.reduce(math.max);
      final bw = right - left;
      final rawH = math.max(8.0, bottom - top);
      // Use the quad height directly — no 2× multiplication.
      final bh = math.max(16.0, rawH);
      if (bw < 4) return const SizedBox.shrink();

      // Font size derived from box WIDTH to fill horizontally.
      // Average char width factor depends on script:
      //   CJK / fullwidth ~ 0.95×fontSize, Latin ~ 0.55×fontSize.
      double avgFactor = _avgCharWidthFactor(displayText);
      final charCount = math.max(displayText.length, 1);
      final byWidth = bw / (charCount * avgFactor);
      final fontSize = byWidth.clamp(10.0, bh);

      return Positioned(
        left: left, top: top, width: bw, height: bh,
        child: IgnorePointer(
          ignoring: false,
          child: RepaintBoundary(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.transparent,
                border: Border.all(color: cs.primary.withAlpha(85), width: 1),
                borderRadius: BorderRadius.circular(2),
              ),
              alignment: Alignment.center,
              child: DragOutSelectableText(
                displayText,
                style: TextStyle(
                  color: cs.onSurface.withAlpha(51),
                  fontSize: fontSize,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                selectionColor: cs.primary.withAlpha(51),
                cursorColor: cs.primary.withAlpha(102),
                contextMenuBuilder: _ocrSelectionMenuBuilder,
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  List<Widget> _buildOcrOverlay(Size ws) {
    final cs = Theme.of(context).colorScheme;
    final hasAnyOcr = _ocrLoading || _ocrError != null || _ocrResult != null;
    final hasAnyTranslate = _translating || _translateError != null || _translations != null;
    if (!hasAnyOcr && !hasAnyTranslate) return const [];
    if (_img == null) return const [];
    // Only show when on OCR or translate tool
    if (_tl != AnnotationTool.ocr && _tl != AnnotationTool.translate) return const [];

    final widgets = <Widget>[];

    // --- Loading indicator (compact, positioned, never covers the canvas) ---
    if (_ocrLoading || _translating) {
      final label = _translating ? 'Translating…' : 'OCR…';
      widgets.add(Positioned(
        left: 0, top: 40, right: 0,
        child: IgnorePointer(
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: XMateColors.panelBg(context).withAlpha(221),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: cs.onSurface)),
                const SizedBox(width: 10),
                Text(label, style: TextStyle(color: cs.onSurface.withAlpha(179), fontSize: 13)),
              ]),
            ),
          ),
        ),
      ));
      return widgets;
    }

    final result = _ocrResult;
    final isErr = _ocrError != null;

    // --- Error panel: compact, no full-screen overlay ---
    if (isErr) {
      widgets.add(Positioned(
        top: 10, left: 10, width: math.min(ws.width - 20, 550),
        child: Material(color: Colors.transparent, child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: XMateColors.panelBg(context).withAlpha(238),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.redAccent.withAlpha(120), width: 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            const Row(children: [
              Icon(Icons.error_outline, size: 14, color: Colors.redAccent),
              SizedBox(width: 6),
              Text('OCR Error', style: TextStyle(color: Colors.redAccent,
                  fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 160),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: cs.onSurface.withAlpha(12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: SingleChildScrollView(child: DragOutSelectableText(
                _ocrError!,
                style: TextStyle(
                  color: Colors.redAccent.shade200,
                  fontSize: 11, fontFamily: 'Consolas', height: 1.5,
                ),
              )),
            ),
          ]),
        )),
      ));
      return widgets;
    }

    if (result == null) return const [];

    // --- Floating success panel ---
    _ocrPanelRect ??= _ocrPanelAutoRect(ws);
    final p = _ocrPanelRect!;
    // Clamp to current window size
    final double cx2 = p.left.clamp(0.0, math.max(0.0, ws.width - p.width)).toDouble();
    final double cy2 = p.top.clamp(0.0, math.max(0.0, ws.height - p.height)).toDouble();
    final double cw2 = math.max(_kPanelMinW, math.min(p.width, ws.width - 8.0));
    final double ch2 = math.max(_kPanelMinH, math.min(p.height, ws.height - 8.0));
    final cr = Rect.fromLTWH(cx2, cy2, cw2, ch2);

    final isTranslate = _tl == AnnotationTool.translate;

    // --- Build display text ---
    final String displayText;
    final String title;
    final IconData titleIcon;
    final Color titleColor;

    if (isTranslate && _translations != null) {
      title = 'Translation';
      titleIcon = Icons.translate;
      titleColor = cs.primary;
      final parts = <String>[];
      for (int i = 0; i < result.blocks.length; i++) {
        final tr = _translations?[i];
        if (tr != null && tr.isNotEmpty) parts.add(tr);
      }
      displayText = parts.isNotEmpty ? parts.join('\n') : result.fullText;
    } else {
      title = 'OCR Result';
      titleIcon = Icons.article;
      titleColor = cs.primary;
      displayText = result.fullText;
    }

    final display = displayText.isEmpty ? '[empty]' : displayText;

    // --- Diag badge info ---
    final diag = result.diag;
    final engineName = (diag?['engine_src'] as String?) ?? 'PP-OCRv6';
    final buf1 = StringBuffer();
    buf1.write('$engineName  |  ${result.blocks.length} blk');
    if (diag != null) {
      final tbl = diag['table_detected'];
      if (tbl != null && tbl is int && tbl > 0) {
        buf1.write('  |  $tbl table(s)');
      }
    }
    final extra1 = buf1.toString();

    String? extra2;
    if (diag != null) {
      final su = diag['num_structure_units'];
      final ab = diag['num_assigned_text_blocks'];
      final tcs = diag['table_cell_stats'] as String?;
      if ((su is int && su > 0) || (ab is int && ab > 0) ||
          (tcs != null && tcs.isNotEmpty && tcs != 'none')) {
        final buf2 = StringBuffer();
        if (su is int) { buf2.write('$su unit(s)'); }
        if (ab is int) { buf2.write('  $ab assigned'); }
        if (tcs != null && tcs.isNotEmpty && tcs != 'none') { buf2.write('  $tcs'); }
        extra2 = buf2.toString();
      }
    }

    widgets.add(Positioned(
      left: cr.left, top: cr.top, width: cr.width, height: cr.height,
      child: Material(color: Colors.transparent, child: Stack(
        clipBehavior: Clip.none,
        children: [
          // ── Content ──
          Container(
            decoration: BoxDecoration(
              color: XMateColors.dialogBg(context),  // fully opaque
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: cs.primary.withAlpha(136), width: 1),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              // ── Title bar (draggable, always hit-testable) ──
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) {
                  _panelDragTouch = d.globalPosition;
                  _panelDragOrigin = _ocrPanelRect?.topLeft;
                },
                onPanUpdate: (d) {
                  if (_panelDragOrigin == null) return;
                  final px = _ocrPanelRect;
                  if (px == null) return;
                  final delta = d.globalPosition - _panelDragTouch!;
                  final newLeft = (_panelDragOrigin!.dx + delta.dx)
                      .clamp(0.0, math.max(0.0, ws.width - px.width));
                  final newTop = (_panelDragOrigin!.dy + delta.dy)
                      .clamp(0.0, math.max(0.0, ws.height - px.height));
                  setState(() {
                    _ocrPanelRect = Rect.fromLTWH(
                      newLeft.toDouble(), newTop.toDouble(), px.width, px.height);
                  });
                },
                onPanEnd: (_) { _panelDragTouch = null; _panelDragOrigin = null; },
                child: Container(
                  padding: const EdgeInsets.only(left: 12, right: 4, top: 8, bottom: 4),
                  child: Row(children: [
                    Icon(titleIcon, size: 14, color: titleColor),
                    const SizedBox(width: 6),
                    if (isTranslate && _tlLangs.isNotEmpty) ...[
                      _tlLangDropdown(_tlFrom, true),
                      Icon(Icons.arrow_forward, size: 10, color: cs.onSurface.withAlpha(97)),
                      _tlLangDropdown(_tlTo, false),
                      const SizedBox(width: 6),
                    ] else ...[
                      Text(title, style: TextStyle(color: titleColor,
                          fontSize: 13, fontWeight: FontWeight.w600)),
                    ],
                    const SizedBox(width: 6),
                    // ── Language segment: 中 | EN ──
                    _ocrLangSegBtn('中', 'ch'),
                    const SizedBox(width: 1),
                    _ocrLangSegBtn('EN', 'en'),
                    // ── Engine dropdown (Chinese only) ──
                    if (_ocrLanguage == 'ch') ...[
                      const SizedBox(width: 6),
                      _ocrEngineDropdown(cs),
                    ],
                    const Spacer(),
                    Text(extra1, style: TextStyle(color: cs.onSurface.withAlpha(97), fontSize: 11)),
                    const SizedBox(width: 4),
                    // In-place display toggle
                    SizedBox(
                      width: 28, height: 28,
                      child: IconButton(
                        padding: EdgeInsets.zero, iconSize: 16,
                        icon: Icon(
                          _ocrInPlace ? Icons.visibility : Icons.visibility_off,
                          color: _ocrInPlace ? cs.primary : cs.onSurface.withAlpha(77),
                        ),
                        tooltip: _ocrInPlace ? 'Hide in-place' : 'Show in-place',
                        onPressed: _toggleOcrInPlace,
                      ),
                    ),
                    const SizedBox(width: 2),
                    // Unwarp toggle
                    SizedBox(
                      width: 28, height: 28,
                      child: IconButton(
                        padding: EdgeInsets.zero, iconSize: 16,
                        icon: Icon(
                          Icons.auto_fix_high,
                          color: _unwarpEnabled ? cs.primary : cs.onSurface.withAlpha(77),
                        ),
                        tooltip: _unwarpEnabled ? 'Unwarp ON' : 'Unwarp OFF',
                        onPressed: () => setState(() {
                          _unwarpEnabled = !_unwarpEnabled;
                          _doOcr();
                        }),
                      ),
                    ),
                    const SizedBox(width: 2),
                    SizedBox(
                      width: 28, height: 28,
                      child: IconButton(
                        padding: EdgeInsets.zero, iconSize: 16,
                        icon: Icon(Icons.close, color: cs.onSurface.withAlpha(138)),
                        onPressed: () {
                          _ocrPanelRect = null;
                          _clearOcr();
                          _tl = AnnotationTool.mouse;
                        },
                      ),
                    ),
                  ]),
                ),
              ),
              // ── Second diag line ──
              if (extra2 != null)
                Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 2),
                  child: Text(extra2, style: TextStyle(color: cs.onSurface.withAlpha(77), fontSize: 10)),
                ),
              // ── Body: text selectable, scroll for overflow ──
              Expanded(child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: cs.onSurface.withAlpha(12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SingleChildScrollView(child: DragOutSelectableText(
                    display,
                    style: TextStyle(
                      color: cs.onSurface, fontSize: 14, height: 1.5,
                    ),
                    contextMenuBuilder: _ocrSelectionMenuBuilder,
                  )),
                )),
            ]),
          ),
          // ── Resize handle (bottom-right corner, always hit-testable) ──
          Positioned(
            right: 0, bottom: 0,
            width: 24, height: 24,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) {},
              onPanUpdate: (d) {
                final px = _ocrPanelRect;
                if (px == null) return;
                setState(() {
                  _ocrPanelRect = Rect.fromLTWH(
                    px.left,
                    px.top,
                    math.max(_kPanelMinW, math.min(px.width + d.delta.dx, ws.width - px.left - 8.0)),
                    math.max(_kPanelMinH, math.min(px.height + d.delta.dy, ws.height - px.top - 8.0)),
                  );
                });
              },
              onPanEnd: (_) {},
              child: Icon(Icons.drag_indicator, color: cs.onSurface.withAlpha(61), size: 16),
            ),
          ),
        ],
      )),
    ));

    return widgets;
  }

  // ─── Task 5.1: Resize dialog ───

  /// Show a dialog to manually set selection width/height.
  ///
  /// Units match the display label: current logical pixels (same as
  /// `_sel.width.round()` / `_sel.height.round()`).
  Future<void> _showResizeDialog() async {
    final s = _sel;
    if (s == null) return;

    final wCtl = TextEditingController(text: '${s.width.round()}');
    final hCtl = TextEditingController(text: '${s.height.round()}');
    var alignCenter = false; // default: top-left anchor

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Resize Selection', style: TextStyle(fontSize: 14)),
          content: SizedBox(
            width: 260,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                const SizedBox(width: 40, child: Text('W:', style: TextStyle(fontSize: 13))),
                Expanded(child: TextField(
                  controller: wCtl, keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                )),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                const SizedBox(width: 40, child: Text('H:', style: TextStyle(fontSize: 13))),
                Expanded(child: TextField(
                  controller: hCtl, keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                )),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                SizedBox(width: 260,
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Top-left', style: TextStyle(fontSize: 11))),
                      ButtonSegment(value: true, label: Text('Center', style: TextStyle(fontSize: 11))),
                    ],
                    selected: {alignCenter},
                    onSelectionChanged: (v) => setDlg(() => alignCenter = v.first),
                  ),
                ),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apply')),
          ],
        ),
      ),
    );

    if (ok != true) return;
    final w = double.tryParse(wCtl.text.trim());
    final h = double.tryParse(hCtl.text.trim());
    if (w == null || h == null || w <= 0 || h <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid size', style: TextStyle(fontSize: 12)), duration: Duration(seconds: 2)),
        );
      }
      return;
    }

    final r = _sel;
    if (r == null) return;
    setState(() {
      if (alignCenter) {
        final cx = r.center.dx;
        final cy = r.center.dy;
        _sel = Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);
      } else {
        _sel = Rect.fromLTWH(r.left, r.top, w, h);
      }
    });

    wCtl.dispose();
    hCtl.dispose();
  }

  // ─── Task 5.2: Refresh capture while keeping selection ───

  /// Re-capture the full screen and reload the background image,
  /// preserving [_sel], [_ann], [_ph] and all editing state.
  ///
  /// Hides the XMate window briefly before capture so the screenshot UI
  /// itself doesn't appear in the refreshed image.
  Future<void> _refreshCapture() async {
    try {
      await windowManager.hide();
      // Small delay so the window is off-screen before capture
      await Future.delayed(const Duration(milliseconds: 80));
      final cap = await CaptureServiceWin32().captureFullScreen();
      // Restore window immediately — image decode is async, no UI flash
      if (mounted) {
        await windowManager.show();
        await windowManager.focus();
      }
      if (!mounted) return;
      final c = await ui.instantiateImageCodec(cap.png);
      if (!mounted) return;
      final f = await c.getNextFrame();
      if (!mounted) return;
      final img = f.image;
      final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (!mounted) return;
      setState(() {
        _img = img; _imgRgba = bd?.buffer.asUint8List();
        _captureDpr = cap.dpr;
        _captureMonitorRect = Rect.fromLTWH(
          cap.monX.toDouble(), cap.monY.toDouble(),
          cap.monW.toDouble(), cap.monH.toDouble());
      });
    } catch (_) {
      if (mounted) {
        // Ensure window is visible even on error
        try { await windowManager.show(); } catch (_) {}
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Refresh failed', style: TextStyle(fontSize: 12)), duration: Duration(seconds: 2)),
        );
      }
    }
  }

  // ─── Scroll-screenshot mode ───

  /// Cleanup helper — unified order: uninstall hook → clear hole → release frames.
  void _cleanupScrollMode() {
    if (!_isScrollMode) return;
    CaptureServiceWin32().uninstallScrollHook();  // 1. stop receiving events
    WindowService.clearWindowHole();               // 2. restore window region
    _scrollMgr.exitMode();                         // 3. release frame resources
  }

  /// Called by C++ hook via com.xmate/scroll "capture" method.
  /// [wheelDelta] = raw WHEEL_DELTA from MSLLHOOKSTRUCT (typically ±120 per notch).
  Future<void> _onScrollCapture(int wheelDelta) async {
    if (!mounted || !_isScrollMode) return;
    if (_scrollMgr.isCapturing) {
      _scrollPending = true;
      return;
    }

    _scrollMgr.isCapturing = true;
    try {
      do {
        _scrollPending = false;

        await Future.delayed(const Duration(milliseconds: 50));
        if (!mounted || !_isScrollMode) break;

        final sel = _sel;
        if (sel == null || sel.isEmpty) break;
        final monRect = _captureMonitorRect;
        if (monRect == null) break;
        final dpr = _captureDpr;

        final physX = (monRect.left + sel.left * dpr).round();
        final physY = (monRect.top + sel.top * dpr).round();
        final physW = (sel.width * dpr).round();
        final physH = (sel.height * dpr).round();
        final region = await CaptureServiceWin32().captureRect(
            physX, physY, physW, physH);

        if (!mounted || !_isScrollMode) break;
        final rc = await ui.instantiateImageCodec(region.png);
        if (!mounted || !_isScrollMode) break;
        final rf = await rc.getNextFrame();
        if (!mounted || !_isScrollMode) break;
        final regionImg = rf.image;

        _scrollMgr.addFrame(region.png, regionImg, wheelDelta: wheelDelta);
        setState(() {});
      } while (_scrollPending);
    } catch (err, stack) {
      dev.log('[scroll] onScrollCapture failed: $err\n$stack');
    } finally {
      _scrollMgr.isCapturing = false;
    }
  }

  bool get _shiftHeld {
    return HardwareKeyboard.instance.logicalKeysPressed
        .any((k) => k == LogicalKeyboardKey.shiftLeft ||
                   k == LogicalKeyboardKey.shiftRight);
  }

  /// Constrain a rect from [anchor] to [mouse] to match [ratio].
  ///
  /// Projects the mouse onto the line through [anchor] where
  /// width/height == ratio, so the corner stays as close to the mouse as
  /// geometrically possible.  Works for all four corner-drag directions.
  Rect _lockAspectFromAnchor(Offset anchor, Offset mouse, double ratio) {
    final dx = mouse.dx - anchor.dx;
    final dy = mouse.dy - anchor.dy;
    if (dx.abs() < 0.01 && dy.abs() < 0.01) {
      return Rect.fromPoints(anchor, mouse);
    }

    // Project (|dx|, |dy|) onto the ray  y = x / ratio  (x ≥ 0).
    // Minimise  (t·ratio - |dx|)² + (t - |dy|)²  →  t = (ratio·|dx| + |dy|) / (ratio² + 1)
    final sx = dx >= 0 ? 1.0 : -1.0;
    final sy = dy >= 0 ? 1.0 : -1.0;
    final absDx = dx.abs();
    final absDy = dy.abs();
    final t = (ratio * absDx + absDy) / (ratio * ratio + 1);
    final newDx = t * ratio * sx;
    final newDy = t * sy;

    return Rect.fromLTRB(
      math.min(anchor.dx, anchor.dx + newDx),
      math.min(anchor.dy, anchor.dy + newDy),
      math.max(anchor.dx, anchor.dx + newDx),
      math.max(anchor.dy, anchor.dy + newDy),
    );
  }

  void _replaceAnn(AnnotationShape old, AnnotationShape newA) {
    setState(() {
      final i = _ann.indexOf(old);
      if (i >= 0) { _ann.removeAt(i); newA.selected = false; _ann.insert(i, newA); _rd.clear(); }
    });
  }

  AnnotationShape? _findById(String id) {
    try { return _ann.firstWhere((a) => a.id == id); } catch (_) { return null; }
  }

  /// Compute the next number-tag label by scanning existing [NumberTagAnnotation]
  /// instances in the annotation list.  Resets to 1 automatically when the list
  /// is empty (including after [onClearAll]).
  ///
  /// Strategy: **max+1**.  Erased tags (hidden by EraserMask but still in _ann)
  /// still contribute their number — erased numbers are "taken" and won't be
  /// re-used.  This keeps numbering predictable and undo/redo-safe.
  int _nextNumber() {
    int maxN = 0;
    for (final a in _ann) {
      if (a is NumberTagAnnotation && a.number > maxN) maxN = a.number;
    }
    return maxN + 1;
  }

  AnnotationShape? _applyOptsToAnnotation(AnnotationShape a) {
    if (a is RectAnnotation) {
      return RectAnnotation(
        x: a.x, y: a.y, w: a.w, h: a.h,
        color: _opts.color, strokeWidth: _opts.strokeWidth,
        shapeKind: _opts.shapeKind, cornerRadius: _opts.cornerRadius,
        fillStyle: _opts.fillStyle,
        fillColor: _opts.fillStyle != FillStyle.none ? _opts.color : null,
        lineStyle: _opts.lineStyle, id: a.id,
      )..rotation = a.rotation;
    }
    if (a is ArrowAnnotation) {
      return ArrowAnnotation(
        fromX: a.fromX, fromY: a.fromY, toX: a.toX, toY: a.toY,
        color: _opts.color, strokeWidth: _opts.strokeWidth,
        startHead: _opts.startHead, endHead: _opts.endHead,
        lineStyle: _opts.lineStyle, id: a.id,
      )..rotation = a.rotation;
    }
    if (a is FreehandAnnotation) {
      return FreehandAnnotation(
        points: a.points, color: _opts.color,
        strokeWidth: _opts.strokeWidth, lineStyle: _opts.lineStyle,
        id: a.id,
      )..rotation = a.rotation;
    }
    if (a is TextAnnotation) {
      return TextAnnotation(
        x: a.x, y: a.y, text: a.text, color: _opts.color,
        fontSize: _opts.fontSize, bold: _opts.bold,
        italic: _opts.italic, outline: _opts.outline,
        fontFamily: _opts.fontFamily, textStyleKind: _opts.textStyleKind,
        id: a.id,
      )..rotation = a.rotation;
    }
    if (a is NumberTagAnnotation) {
      return NumberTagAnnotation(
        x: a.x, y: a.y, number: a.number, color: _opts.color,
        style: _opts.numberTagStyle, fontSize: _opts.numberTagSize,
        id: a.id,
      )..rotation = a.rotation;
    }
    if (a is MosaicAnnotation) {
      return MosaicAnnotation(
        mode: a.mode, rect: a.rect, points: a.points,
        cellSize: _opts.mosaicCellSize, effect: _opts.mosaicEffect,
        blurAmount: _opts.mosaicBlurAmount,
        id: a.id,
      )..rotation = a.rotation;
    }
    return null;
  }

  // ─── Gesture handlers ───

  /// Hit-test [_windowPartitionRects] and return the entry with the highest
  /// [rank] that contains [point].  Returns null when the point is not inside
  /// any known window rect.
  /// Find the highest-rank window whose rect contains [point].
  ///
  /// Returns the best-matching [WindowRectEntry], or null when [point] does
  /// not fall inside any known window rect.
  /// Combined score = rank + area-specificity bonus.
  ///
  /// Small windows get up to +2000 bonus; full-screen windows get +0.
  /// This ensures a tiny rank-10 control (score ~1970) beats a full-screen
  /// rank-50 window (score 50), but foreground children (rank~1030+bonus)
  /// still beat background children.
  double _snapScore(WindowRectEntry e, double screenArea) {
    if (screenArea <= 0) return e.rank.toDouble();
    final areaRatio = (e.rect.width * e.rect.height) / screenArea;
    final specBonus = (1.0 - areaRatio).clamp(0.0, 1.0) * 2000.0;
    return e.rank + specBonus;
  }

  WindowRectEntry? _windowAt(Offset point, double screenArea) {
    WindowRectEntry? best;
    double bestScore = double.negativeInfinity;
    for (final e in _windowPartitionRects) {
      if (e.rect.contains(point)) {
        final s = _snapScore(e, screenArea);
        if (s > bestScore) {
          bestScore = s;
          best = e;
        }
      }
    }
    return best;
  }

  /// Recompute _sel from the current hover position (or the last known one).
  /// Called both from [_onHover] and from [_loadWindowRects] after data loads.
  void _applyAutoSnap() {
    final p = _lastHoverPos;
    if (p == null) return;
    final sz = MediaQuery.of(context).size;
    final screenArea = sz.width * sz.height;
    final best = _windowAt(p, screenArea);
    Rect target;
    if (best != null) {
      target = best.rect;
    } else {
      // Mouse is not over any window — snap to full screen.
      final sz = MediaQuery.of(context).size;
      target = Rect.fromLTWH(0, 0, sz.width, sz.height);
    }

    // Avoid redundant setState when the target hasn't changed.
    if (_lastAutoSnapSel != null &&
        (_lastAutoSnapSel!.left - target.left).abs() < 1 &&
        (_lastAutoSnapSel!.top  - target.top).abs()  < 1 &&
        (_lastAutoSnapSel!.width  - target.width).abs()  < 1 &&
        (_lastAutoSnapSel!.height - target.height).abs() < 1) {
      return;
    }
    _lastAutoSnapSel = target;
    setState(() {
      _autoSnap = true;
      _sel = target;
    });
  }

  void _onHover(PointerHoverEvent e) {
    _lastHoverPos = e.localPosition;
    if (_ph != _Ph.selecting) return;
    // Once a real drag has started, don't interfere.
    if (_sel != null && !_autoSnap) return;
    _applyAutoSnap();
  }

  void _ps(DragStartDetails d) {
    if (_ph == _Ph.selecting) {
      _slS = d.localPosition;          // real press position (for drag exit)
      _downPos = d.localPosition;
      _dragMoved = false;
      _lockedRatio = null;
      // _sel is already set by hover auto-snap — keep it unchanged.
      // _autoSnap stays true until drag breaks it.
      return;
    }
    // OCR overlay lifetime is now state-driven, not event-driven.
    // Blocks stay visible until the user switches tool or presses Escape.
    // (Previously _clearOcr() was called here, which destroyed the overlay
    //  on any click outside a SelectableText block.)
    if (_tx) { _ct(); return; }

    // Mouse tool: check edit handles first, then annotation hit-test
    if (_tl == AnnotationTool.mouse) {
      // Check selected annotation edit handles
      if (_selAnnId != null) {
        final sa = _findById(_selAnnId!);
        if (sa != null) {
          _edDrag = hitTestAnnHandle(sa, d.localPosition);
          if (_edDrag != null) {
            _edBase = getAnnBounds(sa);
            _edBaseObj = sa; // will be replaced with mutated copy
            _dBs = d.localPosition;
            return;
          }
        }
      }
      // Check annotation hit-test (topmost first)
      final hit = hitTestAnnotation(_ann, d.localPosition);
      if (hit != null) {
        setState(() => _selAnnId = hit.id);
        // Start dragging for move if hit was body
        _edDrag = hitTestAnnHandle(hit, d.localPosition);
        if (_edDrag != null) {
          _edBase = getAnnBounds(hit);
          _edBaseObj = hit;
          _dBs = d.localPosition;
          return;
        }
      } else {
        setState(() => _selAnnId = null);
      }
      // Fall through to selection handle check
      _drg = _ht(d.localPosition);
      if (_drg != null) {
        _dBs = d.localPosition; _dRc = _sel; return;
      }
      return; // clicked empty area — done
    }

    // OCR / translate: read-only tools — only handle selection box manipulation
    // and annotation edit handles.  No drawing / preview allowed.
    if (_tl == AnnotationTool.ocr || _tl == AnnotationTool.translate) {
      // Annotation edit handles (move/resize/rotate selected annotation)
      if (_selAnnId != null) {
        final sa = _findById(_selAnnId!);
        if (sa != null) {
          _edDrag = hitTestAnnHandle(sa, d.localPosition);
          if (_edDrag != null) {
            _edBase = getAnnBounds(sa);
            _edBaseObj = sa;
            _dBs = d.localPosition;
            return;
          }
        }
      }
      // Selection box handles (resize / move selection rectangle)
      _drg = _ht(d.localPosition);
      if (_drg != null) {
        _dBs = d.localPosition; _dRc = _sel; return;
      }
      // Clicked empty area — deselect annotation, nothing else
      setState(() => _selAnnId = null);
      return;
    }

    // Non-mouse drawing tools: check edit handles on selected annotation first.
    // Handles take priority over creating — enables editing even in drawing mode.
    if (_tl != AnnotationTool.mouse) {
      if (_selAnnId != null) {
        final sa = _findById(_selAnnId!);
        if (sa != null) {
          _edDrag = hitTestAnnHandle(sa, d.localPosition);
          if (_edDrag != null) {
            _edBase = getAnnBounds(sa);
            _edBaseObj = sa;
            _dBs = d.localPosition;
            return; // editing via handles, not creating
          }
        }
      }
      // Not hitting handles — clear selection, start creating
      _selAnnId = null;
      _edDrag = null;
      _edBase = null;
      _edBaseObj = null;
    }
    if (_tl == AnnotationTool.freehand) _fh = [d.localPosition];
    else if (_tl == AnnotationTool.mosaic && _opts.mosaicMode == MosaicMode.line) _fh = [d.localPosition];
    else if (_tl == AnnotationTool.eraser && _opts.mosaicMode == MosaicMode.line) _fh = [d.localPosition];
    else if (_tl == AnnotationTool.text) { _tP = d.localPosition; _tC.clear(); setState(() => _tx = true); WidgetsBinding.instance.addPostFrameCallback((_) => _tF.requestFocus()); }
    else if (_tl == AnnotationTool.numberTag) {
      // Click to place a numbered tag.  Number auto-increments (max+1).
      final n = _nextNumber();
      _ad(NumberTagAnnotation(
        x: d.localPosition.dx, y: d.localPosition.dy, number: n,
        color: _cl, style: _opts.numberTagStyle, fontSize: _opts.numberTagSize,
      ));
    }
    else { _ds = d.localPosition; _dc = d.localPosition; }
  }

  void _pu(DragUpdateDetails d) {
    if (_ph == _Ph.selecting) {
      if (!_dragMoved) {
        final dist = (d.localPosition - _downPos).distance;
        if (dist >= _kDragThreshold) _dragMoved = true;
      }
      // Drag exit from auto-snap: switch to normal free-drag from press point
      if (_dragMoved && _autoSnap) {
        _autoSnap = false;
        final rect = Rect.fromPoints(_slS, d.localPosition);
        setState(() => _sel = rect);
        return;
      }
      // While auto-snap is active and no drag yet, keep _sel pinned to snap
      if (!_dragMoved && _autoSnap) return;
      var rect = Rect.fromPoints(_slS, d.localPosition);
      if (_shiftHeld) {
        // Capture ratio on the first frame where the rect is meaningful
        // (drag threshold met OR rect has a non-trivial dimension).
        if (_lockedRatio == null &&
            rect.width >= _kDragThreshold &&
            rect.height >= _kDragThreshold) {
          _lockedRatio = rect.width / rect.height;
        }
        if (_lockedRatio != null) {
          rect = _lockAspectFromAnchor(_slS, d.localPosition, _lockedRatio!);
        }
      } else {
        _lockedRatio = null; // clear when Shift released mid-drag
      }
      setState(() => _sel = rect);
      return;
    }
    final delta = d.localPosition - _dBs;

    // Annotation editing (move/resize/rotate)
    if (_edDrag != null && _edBaseObj != null && _edBase != null) {
      AnnotationShape updated;
      switch (_edDrag!) {
        case AnnHandle.move: {
          // Frame-by-frame incremental: fetch current object from list
          final cur = _findById(_selAnnId ?? '');
          if (cur == null) return;
          updated = translateAnn(cur, delta.dx, delta.dy);
          _replaceAnn(cur, updated);
          _selAnnId = updated.id;
          _dBs = d.localPosition; // reset base so each frame's delta is small
          return;
        }
        case AnnHandle.rotate: {
          // Cumulative angle computed from drag start → current position
          final cx = _edBase!.center.dx;
          final cy = _edBase!.center.dy;
          final startAngle = math.atan2(_dBs.dy - cy, _dBs.dx - cx);
          final currAngle = math.atan2(d.localPosition.dy - cy, d.localPosition.dx - cx);
          updated = rotateAnn(_edBaseObj!, currAngle - startAngle);
          break;
        }
        default:
          updated = resizeAnn(_edBaseObj!, _edDrag!, delta, _edBase!,
              keepAspect: _shiftHeld);
      }
      // Find current reference in list by id and replace
      final curInList = _findById(_edBaseObj!.id);
      if (curInList != null) {
        _replaceAnn(curInList, updated);
        _selAnnId = updated.id;
      }
      return;
    }

    // Selection handle drag (resize/move selection rect)
    if (_drg != null && _dRc != null) {
      var newSel = _ap(_drg!, _dRc!, delta);
      if (_shiftHeld && _drg != _D.mv) {
        final ratio = _dRc!.width / _dRc!.height;
        final isCorner = _drg == _D.tl || _drg == _D.tr ||
            _drg == _D.bl || _drg == _D.br;
        Rect locked;
        if (isCorner) {
          // Corner drag: opposite corner is the fixed anchor.
          final anchor = _drg == _D.tl ? _dRc!.bottomRight
              : _drg == _D.tr ? Offset(_dRc!.left, _dRc!.bottom)
              : _drg == _D.bl ? Offset(_dRc!.right, _dRc!.top)
              : _dRc!.topLeft; // _D.br
          final mouseCorner = _drg == _D.tl ? newSel.topLeft
              : _drg == _D.tr ? newSel.topRight
              : _drg == _D.bl ? newSel.bottomLeft
              : newSel.bottomRight; // _D.br
          locked = _lockAspectFromAnchor(anchor, mouseCorner, ratio);
        } else {
          // Edge drag: opposite edge fixed, expand symmetrically from centre.
          Rect r;
          switch (_drg) {
            case _D.t:  // top edge — bottom fixed
              final fixedY = _dRc!.bottom;
              final newH = (fixedY - newSel.top).abs();
              r = Rect.fromCenter(
                  center: Offset(_dRc!.center.dx, (fixedY + newSel.top) / 2),
                  width: newH * ratio, height: newH);
            case _D.b:  // bottom edge — top fixed
              final fixedY = _dRc!.top;
              final newH = (newSel.bottom - fixedY).abs();
              r = Rect.fromCenter(
                  center: Offset(_dRc!.center.dx, (fixedY + newSel.bottom) / 2),
                  width: newH * ratio, height: newH);
            case _D.l:  // left edge — right fixed
              final fixedX = _dRc!.right;
              final newW = (fixedX - newSel.left).abs();
              r = Rect.fromCenter(
                  center: Offset((fixedX + newSel.left) / 2, _dRc!.center.dy),
                  width: newW, height: newW / ratio);
            case _D.r:  // right edge — left fixed
              final fixedX = _dRc!.left;
              final newW = (newSel.right - fixedX).abs();
              r = Rect.fromCenter(
                  center: Offset((fixedX + newSel.right) / 2, _dRc!.center.dy),
                  width: newW, height: newW / ratio);
            default: r = newSel;
          }
          locked = r;
        }
        // Move annotations inside the selection by the delta
        final selDelta = locked.topLeft - _dRc!.topLeft;
        for (int i = 0; i < _ann.length; i++) {
          _ann[i] = translateAnn(_ann[i], selDelta.dx, selDelta.dy);
        }
        _dRc = locked;
        _dBs = d.localPosition;
        newSel = locked;
      }
      // Shift + move drag: move all annotations along with the selection
      if (_shiftHeld && _drg == _D.mv) {
        for (int i = 0; i < _ann.length; i++) {
          _ann[i] = translateAnn(_ann[i], delta.dx, delta.dy);
        }
        _dBs = d.localPosition; // reset so next frame uses incremental delta
        _dRc = newSel;          // keep base rect in sync with base-point reset
      }
      setState(() => _sel = newSel);
      return;
    }

    // Drawing
    if (_tl == AnnotationTool.freehand) setState(() => _fh.add(d.localPosition));
    else if (_tl == AnnotationTool.mosaic && _opts.mosaicMode == MosaicMode.line) setState(() => _fh.add(d.localPosition));
    else if (_tl == AnnotationTool.eraser && _opts.mosaicMode == MosaicMode.line) setState(() => _fh.add(d.localPosition));
    else if (!_tx) {
      var pos = d.localPosition;
      // Task 3: Shift = 1:1 square lock for rectangle / rounded-rect /
      // ellipse tools.  Uses its own local square computation so it is
      // completely independent of the selecting-phase _lockedRatio.
      if (_tl == AnnotationTool.rectangle && _shiftHeld && _ds != null) {
        final dx = pos.dx - _ds!.dx;
        final dy = pos.dy - _ds!.dy;
        // Keep whichever axis the user dragged further; force the other
        // to the same magnitude to form a square with anchor at _ds.
        if (dx.abs() >= dy.abs()) {
          pos = Offset(_ds!.dx + dx, _ds!.dy + dx.abs() * (dy >= 0 ? 1 : -1));
        } else {
          pos = Offset(_ds!.dx + dy.abs() * (dx >= 0 ? 1 : -1), _ds!.dy + dy);
        }
      }
      setState(() => _dc = pos);
    }
  }

  void _pe(DragEndDetails d) {
    if (_ph == _Ph.selecting) {
      _autoSnap = false; // clear auto-snap flag regardless
      if (!_dragMoved) {
        // Click (no drag) — accept the current _sel as-is (auto-snap or full-screen).
        if (_debugSnap) {
          dev.log('[snap] _pe click: dragMoved=$_dragMoved '
              'sel w=${_sel?.width.toStringAsFixed(0)} h=${_sel?.height.toStringAsFixed(0)}');
        }
        final r = _sel;
        if (r != null && r.width > 5 && r.height > 5) {
          setState(() { _ph = _Ph.annotating; _lockedRatio = null; });
        } else {
          setState(() => _sel = null);
        }
      } else {
        // Drag — keep the free-drawn _sel.
        if (_debugSnap) {
          dev.log('[snap] _pe drag: dragMoved=$_dragMoved '
              'sel w=${_sel?.width.toStringAsFixed(0)} h=${_sel?.height.toStringAsFixed(0)}');
        }
        final r = _sel;
        if (r != null && r.width > 5 && r.height > 5) {
          setState(() { _ph = _Ph.annotating; _lockedRatio = null; });
        } else {
          setState(() => _sel = null);
        }
      }
      return;
    }

    // Commit edit drag
    _edDrag = null;
    _edBase = null;
    _edBaseObj = null;

    _drg = null; _dBs = Offset.zero; _dRc = null;
    if (_tl == AnnotationTool.freehand && _fh.length >= 2) { _ad(FreehandAnnotation(points: List.from(_fh), color: _cl, strokeWidth: _sw, lineStyle: _opts.lineStyle)); _fh = []; }
    else if (_tl == AnnotationTool.mosaic && _opts.mosaicMode == MosaicMode.line && _fh.length >= 2) { _ad(MosaicAnnotation(mode: MosaicMode.line, points: List.from(_fh), cellSize: _opts.mosaicCellSize, effect: _opts.mosaicEffect, blurAmount: _opts.mosaicBlurAmount)); _fh = []; }
    else if (_tl == AnnotationTool.eraser && _opts.mosaicMode == MosaicMode.line && _fh.length >= 2) { _eraserMasks.add(EraserMask(mode: MosaicMode.line, points: List.from(_fh), cellSize: _opts.mosaicCellSize)); setState(() {}); _fh = []; }
    else if (_tl == AnnotationTool.eraser && _ds != null && _dc != null) {
      final r = Rect.fromLTRB(
        math.min(_ds!.dx, _dc!.dx), math.min(_ds!.dy, _dc!.dy),
        math.max(_ds!.dx, _dc!.dx), math.max(_ds!.dy, _dc!.dy),
      );
      if (r.width > 3 && r.height > 3) { _eraserMasks.add(EraserMask(mode: _opts.mosaicMode, rect: r)); setState(() {}); }
      _ds = _dc = null;
    }
    else if (_ds != null && _dc != null && !_tx) _cd();
  }

  _D? _ht(Offset p) {
    if (_sel == null || _ph != _Ph.annotating) return null;
    final r = _sel!; const h = _h;
    if ((p - r.topLeft).distance < h * 2) return _D.tl;
    if ((p - r.topRight).distance < h * 2) return _D.tr;
    if ((p - r.bottomLeft).distance < h * 2) return _D.bl;
    if ((p - r.bottomRight).distance < h * 2) return _D.br;
    if ((p.dy - r.top).abs() < h && p.dx > r.left + h && p.dx < r.right - h) return _D.t;
    if ((p.dy - r.bottom).abs() < h && p.dx > r.left + h && p.dx < r.right - h) return _D.b;
    if ((p.dx - r.left).abs() < h && p.dy > r.top + h && p.dy < r.bottom - h) return _D.l;
    if ((p.dx - r.right).abs() < h && p.dy > r.top + h && p.dy < r.bottom - h) return _D.r;
    if (r.contains(p)) return _D.mv;
    return null;
  }

  Rect _ap(_D t, Rect r, Offset d) { switch (t) {
    case _D.tl: return Rect.fromLTRB(r.left + d.dx, r.top + d.dy, r.right, r.bottom);
    case _D.tr: return Rect.fromLTRB(r.left, r.top + d.dy, r.right + d.dx, r.bottom);
    case _D.bl: return Rect.fromLTRB(r.left + d.dx, r.top, r.right, r.bottom + d.dy);
    case _D.br: return Rect.fromLTRB(r.left, r.top, r.right + d.dx, r.bottom + d.dy);
    case _D.t:  return Rect.fromLTRB(r.left, r.top + d.dy, r.right, r.bottom);
    case _D.b:  return Rect.fromLTRB(r.left, r.top, r.right, r.bottom + d.dy);
    case _D.l:  return Rect.fromLTRB(r.left + d.dx, r.top, r.right, r.bottom);
    case _D.r:  return Rect.fromLTRB(r.left, r.top, r.right + d.dx, r.bottom);
    case _D.mv: return r.translate(d.dx, d.dy);
  }}

  void _cd() { final dx = _ds!.dx, dy = _ds!.dy, ex = _dc!.dx, ey = _dc!.dy; if ((ex - dx).abs() < 3 && (ey - dy).abs() < 3) { _ds = _dc = null; return; }
    if (_tl == AnnotationTool.rectangle) _ad(RectAnnotation(
      x: math.min(dx, ex), y: math.min(dy, ey),
      w: (ex - dx).abs(), h: (ey - dy).abs(),
      color: _cl, strokeWidth: _sw,
      shapeKind: _opts.shapeKind,
      cornerRadius: _opts.cornerRadius,
      fillStyle: _opts.fillStyle,
      fillColor: _opts.fillStyle != FillStyle.none ? _opts.color : null,
      lineStyle: _opts.lineStyle,
    ));
    else if (_tl == AnnotationTool.arrow) _ad(ArrowAnnotation(
      fromX: dx, fromY: dy, toX: ex, toY: ey,
      color: _cl, strokeWidth: _sw,
      startHead: _opts.startHead,
      endHead: _opts.endHead,
      lineStyle: _opts.lineStyle,
    ));
    else if (_tl == AnnotationTool.mosaic && (_opts.mosaicMode == MosaicMode.rect || _opts.mosaicMode == MosaicMode.ellipse)) _ad(MosaicAnnotation(
      mode: _opts.mosaicMode,
      rect: Rect.fromLTRB(math.min(dx, ex), math.min(dy, ey), math.max(dx, ex), math.max(dy, ey)),
      cellSize: _opts.mosaicCellSize,
      effect: _opts.mosaicEffect, blurAmount: _opts.mosaicBlurAmount,
    )); _ds = _dc = null; }

  /// Map an [AnnotationShape] subclass to the corresponding [AnnotationTool].
  AnnotationTool? _toolForAnnotationType(AnnotationShape a) {
    if (a is RectAnnotation) return AnnotationTool.rectangle;
    if (a is ArrowAnnotation) return AnnotationTool.arrow;
    if (a is TextAnnotation) return AnnotationTool.text;
    if (a is FreehandAnnotation) return AnnotationTool.freehand;
    if (a is MosaicAnnotation) return AnnotationTool.mosaic;
    if (a is NumberTagAnnotation) return AnnotationTool.numberTag;
    return null;
  }

  void _onRightClick(TapUpDetails d) {
    if (_ph != _Ph.annotating) return;
    if (_tx) { _ct(); return; }

    if (_tl != AnnotationTool.mouse) {
      // Non-mouse tool: switch to mouse, clear all selections
      setState(() {
        _tl = AnnotationTool.mouse;
        _selAnnId = null;
        _edDrag = null;
        _edBase = null;
        _edBaseObj = null;
      });
    } else if (_selAnnId != null) {
      // Mouse tool with selected annotation: switch to that annotation's tool
      final a = _findById(_selAnnId!);
      final tool = a != null ? _toolForAnnotationType(a) : null;
      if (tool != null) {
        setState(() => _tl = tool);
      }
    } else {
      // Mouse tool with no selection: copy screenshot
      _cp();
    }
  }

  void _ct() { final t = _tC.text; setState(() => _tx = false); if (t.isNotEmpty) _ad(TextAnnotation(x: _tP.dx, y: _tP.dy, text: t, color: _cl, fontSize: _opts.fontSize, bold: _opts.bold, italic: _opts.italic, outline: _opts.outline, fontFamily: _opts.fontFamily, textStyleKind: _opts.textStyleKind)); _tC.clear(); }
  void _ad(AnnotationShape a) { setState(() { _ann.add(a); _rd.clear(); _selAnnId = a.id; }); }
  void _un() { if (_ann.isEmpty) return; setState(() => _rd.add(_ann.removeLast())); }
  void _rd_() { if (_rd.isEmpty) return; setState(() => _ann.add(_rd.removeLast())); }

  void _drawDashedRect(Canvas canvas, Rect rect, Paint paint,
      {double dashWidth = 8, double gapWidth = 4}) {
    final path = Path();
    // Top edge (left to right)
    _dashLine(path, rect.topLeft, rect.topRight, dashWidth, gapWidth);
    // Right edge (top to bottom)
    _dashLine(path, rect.topRight, rect.bottomRight, dashWidth, gapWidth);
    // Bottom edge (right to left)
    _dashLine(path, rect.bottomRight, rect.bottomLeft, dashWidth, gapWidth);
    // Left edge (bottom to top)
    _dashLine(path, rect.bottomLeft, rect.topLeft, dashWidth, gapWidth);
    canvas.drawPath(path, paint);
  }

  void _dashLine(Path path, Offset start, Offset end,
      double dashWidth, double gapWidth) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1) return;
    final ux = dx / len;
    final uy = dy / len;
    double pos = 0;
    bool draw = true;
    while (pos < len) {
      final segLen = (draw ? dashWidth : gapWidth).clamp(0, len - pos);
      path.moveTo(start.dx + ux * pos, start.dy + uy * pos);
      path.lineTo(start.dx + ux * (pos + segLen), start.dy + uy * (pos + segLen));
      pos += segLen;
      draw = !draw;
    }
  }

  Future<Uint8List> _renderOverlayPng(Rect sel, {double scale = 1.0}) async {
    final cs = Theme.of(context).colorScheme;
    final w = (sel.width * scale).round().clamp(1, 8000);
    final h = (sel.height * scale).round().clamp(1, 8000);
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);

    // Scale first, then translate — this maps widget coords within [sel]
    // to the overlay's (0,0)-based physical-pixel space:
    //   P' = ((P.x - sel.left) * scale, (P.y - sel.top) * scale)
    c.scale(scale, scale);
    c.translate(-sel.left, -sel.top);

    // Sort annotations + eraser masks by creation order, same pattern
    // as _AnnotationPainter.paint() in annotate_canvas.dart.
    final ops = <MapEntry<int, Object>>[];
    for (final a in _ann) {
      ops.add(MapEntry(getOrAssignAnnOrder(a), a));
    }
    for (final m in _eraserMasks) {
      ops.add(MapEntry(m.orderId, m));
    }
    ops.sort((a, b) => a.key.compareTo(b.key));

    for (final op in ops) {
      final v = op.value;
      if (v is AnnotationShape) {
        drawAnnotation(c, v, widgetSize: Size(_img!.width / _captureDpr, _img!.height / _captureDpr));
      } else if (v is EraserMask) {
        drawEraserMask(c, v);
      }
    }

    // Cyan dashed border around the selection.
    final borderPaint = Paint()
      ..color = cs.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    // Border: draw at sel position so it maps to (0,0)..(w*s,h*s) via the canvas transform.
    _drawDashedRect(c, sel, borderPaint,
        dashWidth: 8, gapWidth: 4);

    final pic = rec.endRecording();
    final img = await pic.toImage(w, h);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  Future<Uint8List> _exp(Size cs, {String? forceFormat}) async {
    final rec = ui.PictureRecorder(); final c = Canvas(rec);
    final iw = _img!.width.toDouble(), ih = _img!.height.toDouble();

    final sx = cs.width > 0 ? iw / cs.width : 1.0;
    final sy = cs.height > 0 ? ih / cs.height : 1.0;

    if (_sel != null && cs.width > 0 && cs.height > 0) {
      c.translate(-_sel!.left * sx, -_sel!.top * sy);
    }

    c.drawImageRect(_img!, Rect.fromLTWH(0, 0, iw, ih), Rect.fromLTWH(0, 0, iw, ih), Paint());

    c.save();
    c.scale(sx, sy);
    for (final a in _ann) drawAnnotation(c, a, image: _img, widgetSize: cs, imageRgba: _imgRgba);
    c.restore();

    final pic = rec.endRecording();
    double ow = iw, oh = ih;
    if (_sel != null && cs.width > 0) {
      ow = (_sel!.width * sx).roundToDouble();
      oh = (_sel!.height * sy).roundToDouble();
    }
    final img = await pic.toImage(
      ow.round().clamp(1, 10000),
      oh.round().clamp(1, 10000),
    );
    return await _encodeExportImage(img, forceFormat ?? widget.format);
  }

  /// Encode [image] in the requested [fmt] (png / jpeg / webp).
  ///
  /// - PNG: dart:ui native encoder (fast, no extra pixel copy).
  /// - JPEG: `image` package, quality=90 (TODO: read from settings).
  /// - WebP: `image` package, lossless (TODO: lossy when image pkg supports it).
  Future<Uint8List> _encodeExportImage(ui.Image image, String fmt) async {
    switch (fmt) {
      case 'jpeg': {
        final pkg = await _uiToImagePkg(image);
        return Uint8List.fromList(img_lib.encodeJpg(pkg, quality: 90));
      }
      case 'webp': {
        final pkg = await _uiToImagePkg(image);
        // image 4.9.x WebP encoder is lossless-only; no quality param.
        return Uint8List.fromList(img_lib.encodeWebP(pkg));
      }
      default: { // png
        final bd = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bd == null) throw Exception('Failed to encode PNG');
        return bd.buffer.asUint8List();
      }
    }
  }

  /// Convert a [ui.Image] to an `image` package [img_lib.Image].
  Future<img_lib.Image> _uiToImagePkg(ui.Image image) async {
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (raw == null) throw Exception('Failed to read image pixels');
    final pkg = img_lib.Image(width: image.width, height: image.height, numChannels: 4);
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final off = (y * image.width + x) * 4;
        pkg.setPixelRgba(x, y,
            raw.getUint8(off), raw.getUint8(off + 1),
            raw.getUint8(off + 2), raw.getUint8(off + 3));
      }
    }
    return pkg;
  }
  String _extForFormat(String fmt) {
    switch (fmt) {
      case 'jpeg': return '.jpg';
      case 'webp': return '.webp';
      default: return '.png';
    }
  }

  /// Get currently selected text from the focused SelectableText widget.
  /// Returns null if no SelectableText has focus or no text is selected.
  String? _getSelectedText() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return null;
    final ctx = focus.context;
    if (ctx == null) return null;
    final state = ctx.findAncestorStateOfType<EditableTextState>();
    if (state == null) return null;
    final sel = state.textEditingValue.selection;
    if (!sel.isValid || sel.isCollapsed) return null;
    final selected = sel.textInside(state.textEditingValue.text);
    return selected.isNotEmpty ? selected : null;
  }

  /// Current OCR/translation display text (for Ctrl+C/S priority).
  String? get _ocrDisplayText {
    final r = _ocrResult; if (r == null) return null;
    if (_tl == AnnotationTool.translate && _translations != null) {
      final parts = <String>[];
      for (int i = 0; i < r.blocks.length; i++) {
        final tr = _translations?[i];
        if (tr != null && tr.isNotEmpty) parts.add(tr);
      }
      return parts.isNotEmpty ? parts.join('\n') : r.fullText;
    }
    return r.fullText;
  }

  Future<void> _cp() async {
    if (!mounted) return;
    // Priority 1: Copy user-selected text from any active SelectableText
    final selText = _getSelectedText();
    if (selText != null && selText.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: selText));
      dev.log('[cp] Copied selected text (${selText.length} chars)');
      return;
    }
    // Priority 2: Copy full OCR / translation text (floating panel only)
    final txt = _ocrDisplayText;
    if (txt != null && txt.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: txt));
      dev.log('[cp] Copied OCR text (${txt.length} chars)');
      return;
    }
    // Priority 3: Copy screenshot image
    if (_sel == null) return;
    try {
      final Uint8List b;
      if (_isScrollMode) {
        b = await _scrollMgr.exportStitchedPng();
        dev.log('[cp] Scroll mode: latest frame ${b.length}B');
      } else {
        final cs = MediaQuery.of(context).size;
        b = await _exp(cs, forceFormat: 'png');
      }
      if (b.isEmpty) throw Exception('Export returned 0 bytes');
      dev.log('[cp] PNG ${b.length}B → native CopyToClipboard');

      final ok = await CaptureServiceWin32().copyToClipboard(b);
      dev.log('[cp] native returned: $ok');
      if (!ok) throw Exception('Clipboard write returned false');

      if (mounted) widget.onDone?.call(b, ScreenshotAction.copy, _sel);
    } catch (e, s) {
      dev.log('[cp] ERROR: $e\n$s');
    }
  }
  Future<void> _sv() async {
    if (!mounted) return;
    // Priority 1: Save OCR / translation text if visible
    final txt = _ocrDisplayText;
    if (txt != null && txt.isNotEmpty) {
      final ext = '.txt';
      final savePath = widget.savePathOverride;
      late final Directory sd;
      if (savePath != null && savePath.isNotEmpty) {
        sd = Directory(savePath);
      } else {
        final docs = await getApplicationDocumentsDirectory();
        sd = Directory('${docs.path}/XMate/screenshots');
      }
      if (!await sd.exists()) await sd.create(recursive: true);
      final fileName = 'xmate_ocr_${DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '-')}$ext';
      await File('${sd.path}/$fileName').writeAsString(txt);
      dev.log('[sv] Saved OCR text to $fileName (${txt.length} chars)');
      return;
    }
    // Priority 2: Save screenshot image
    try {
      final Uint8List b;
      if (_isScrollMode) {
        b = await _scrollMgr.exportStitchedPng();
        dev.log('[sv] Scroll mode: latest frame ${b.length}B');
      } else {
        final cs = MediaQuery.of(context).size;
        b = await _exp(cs);
      }
      if (b.isEmpty) throw Exception('Export returned 0 bytes');
      final ext = _extForFormat(widget.format); // '.png' / '.jpg' / '.webp'
      final savePath = widget.savePathOverride;
      late final Directory sd;
      if (savePath != null && savePath.isNotEmpty) {
        sd = Directory(savePath);
      } else {
        final docs = await getApplicationDocumentsDirectory();
        sd = Directory('${docs.path}/XMate/screenshots');
      }
      if (!await sd.exists()) await sd.create(recursive: true);
      final template = widget.filenameTemplate ?? 'Screenshot_%yyyy%-%MM%-%dd%_%HH%%mm%%ss%';
      final name = formatFilename(template, DateTime.now());
      final fileName = '$name$ext';
      await File('${sd.path}/$fileName').writeAsBytes(b);
      if (mounted) widget.onDone?.call(b, ScreenshotAction.save, _sel);
    } catch (e, s) {
      dev.log('[sv] ERROR: $e\n$s');
    }
  }
  Future<void> _pn() async {
    if (!mounted) return;
    final Uint8List b;
    if (_isScrollMode) {
      b = await _scrollMgr.exportStitchedPng();
    } else {
      b = await _exp(MediaQuery.of(context).size);
    }
    widget.onDone?.call(b, ScreenshotAction.pin, _sel);
  }
  void _cl_() {
    _cleanupScrollMode();
    widget.onDone?.call(widget.imageBytes, ScreenshotAction.cancel, null);
  }

  // ─── Keyboard shortcut helpers ───

  /// Move the system cursor by [delta] logical pixels.
  /// Converts to physical pixels using the device pixel ratio.
  void _moveCursorBy(Offset delta) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    WindowService().moveCursor(
      (delta.dx * dpr).round(),
      (delta.dy * dpr).round(),
    );
  }

  // ─── Long-press hold repeat ───
  // 延迟300ms后开始连续触发，初始间隔70ms，线性加速30ms/s，最小间隔10ms

  void _startHold(LogicalKeyboardKey key, VoidCallback action) {
    _stopHold();
    _holdKey = key;
    _holdStart = DateTime.now();
    // Initial delay 300ms, then periodic
    _holdTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || _holdKey != key) return;
      action(); // first repeat after initial delay
      _scheduleNextHold(key, action);
    });
  }

  void _scheduleNextHold(LogicalKeyboardKey key, VoidCallback action) {
    if (!mounted || _holdKey != key) return;
    final elapsed = DateTime.now().difference(_holdStart!).inMilliseconds - 300;
    // interval = max(2, 70 - elapsed * 60 / 1000) millis
    final interval = (70 - elapsed * 60 / 1000).clamp(2.0, 70.0).round();
    _holdTimer = Timer(Duration(milliseconds: interval), () {
      if (!mounted || _holdKey != key) return;
      action();
      _scheduleNextHold(key, action);
    });
  }

  void _stopHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _holdKey = null;
    _holdStart = null;
  }

  /// Cycle through up to 3 previous region rects.
  void _restorePrevRegion() {
    if (_prevRegions.isEmpty) return;
    final r = _prevRegions[_prevRegionIdx % _prevRegions.length];
    _prevRegionIdx = (_prevRegionIdx + 1) % _prevRegions.length;
    setState(() {
      _sel = r;
      if (_ph == _Ph.selecting) _ph = _Ph.annotating;
    });
  }

  /// Move selected annotation(s) or selection by 1px via arrow keys.
  void _moveByArrow(LogicalKeyboardKey key) {
    final dx = key == LogicalKeyboardKey.arrowLeft ? -1.0
        : key == LogicalKeyboardKey.arrowRight ? 1.0 : 0.0;
    final dy = key == LogicalKeyboardKey.arrowUp ? -1.0
        : key == LogicalKeyboardKey.arrowDown ? 1.0 : 0.0;

    if (_selAnnId != null) {
      final a = _findById(_selAnnId!);
      if (a != null) {
        final updated = translateAnn(a, dx, dy);
        setState(() {
          _replaceAnnInPlace(a, updated);
          _selAnnId = updated.id;
        });
      }
    } else if (_sel != null) {
      setState(() {
        _sel = _sel!.translate(dx, dy);
      });
    }
  }

  /// Resize selected annotation(s) or selection by 1px via Shift+Arrow keys.
  /// Up: bottom edge up (−height). Down: bottom edge down (+height).
  /// Left: right edge left (−width). Right: right edge right (+width).
  void _resizeByArrow(LogicalKeyboardKey key) {
    final dw = key == LogicalKeyboardKey.arrowLeft ? -1.0
        : key == LogicalKeyboardKey.arrowRight ? 1.0 : 0.0;
    final dh = key == LogicalKeyboardKey.arrowUp ? -1.0
        : key == LogicalKeyboardKey.arrowDown ? 1.0 : 0.0;

    if (_selAnnId != null) {
      final a = _findById(_selAnnId!);
      if (a != null) {
        final bounds = getAnnBounds(a);
        final newBounds = Rect.fromLTRB(
          bounds.left, bounds.top,
          bounds.right + dw, bounds.bottom + dh,
        );
        if (newBounds.width > 2 && newBounds.height > 2) {
          final updated = resizeAnnToBounds(a, newBounds);
          setState(() {
            _replaceAnnInPlace(a, updated);
            _selAnnId = updated.id;
          });
        }
      }
    } else if (_sel != null) {
      // Resize selection: bottom-right anchor
      final r = _sel!;
      final newW = (r.width + dw).clamp(5.0, 100000.0);
      final newH = (r.height + dh).clamp(5.0, 100000.0);
      setState(() {
        _sel = Rect.fromLTWH(r.left, r.top, newW, newH);
      });
    }
  }

  /// Zoom selected annotation or selection from center by 1px.
  /// [sign] < 0 = zoom out (shrink), sign > 0 = zoom in (grow).
  void _zoomFromCenter(double sign) {
    final d = sign > 0 ? 1.0 : -1.0;
    _applyZoom(d, fromCenter: true);
  }

  /// Zoom selected annotation or selection from top-left anchor by 1px.
  /// [sign] < 0 = zoom out, sign > 0 = zoom in.
  void _zoomFromTLAnchor(int sign) {
    final d = sign > 0 ? 1.0 : -1.0;
    _applyZoom(d, fromCenter: false);
  }

  void _applyZoom(double d, {required bool fromCenter}) {
    if (_ph != _Ph.annotating) return;
    if (_tx) return;

    if (_selAnnId != null) {
      final a = _findById(_selAnnId!);
      if (a != null) {
        final bounds = getAnnBounds(a);
        final newBounds = fromCenter
            ? Rect.fromCenter(
                center: bounds.center,
                width: (bounds.width + d * 2).clamp(5.0, 100000.0),
                height: (bounds.height + d * 2).clamp(5.0, 100000.0),
              )
            : Rect.fromLTWH(
                bounds.left, bounds.top,
                (bounds.width + d * 2).clamp(5.0, 100000.0),
                (bounds.height + d * 2).clamp(5.0, 100000.0),
              );
        final updated = resizeAnnToBounds(a, newBounds);
        setState(() {
          _replaceAnnInPlace(a, updated);
          _selAnnId = updated.id;
        });
      }
    } else if (_sel != null) {
      final r = _sel!;
      final newW = (r.width + d * 2).clamp(5.0, 100000.0);
      final newH = (r.height + d * 2).clamp(5.0, 100000.0);
      setState(() {
        _sel = fromCenter
            ? Rect.fromCenter(center: r.center, width: newW, height: newH)
            : Rect.fromLTWH(r.left, r.top, newW, newH);
      });
    }
  }

  /// Cycle to the next selectable annotation (Tab key).
  void _cycleSelection() {
    if (_ph != _Ph.annotating || _ann.isEmpty) return;
    if (_selAnnId == null) {
      // Select the first one
      setState(() => _selAnnId = _ann.first.id);
    } else {
      final idx = _ann.indexWhere((a) => a.id == _selAnnId);
      if (idx >= 0) {
        final next = (idx + 1) % _ann.length;
        setState(() => _selAnnId = _ann[next].id);
      } else {
        setState(() => _selAnnId = _ann.first.id);
      }
    }
  }

  /// Delete the currently selected annotation.
  void _deleteSelectedAnnotation() {
    if (_ph != _Ph.annotating) return;
    if (_selAnnId == null) return;
    final target = _findById(_selAnnId!);
    if (target != null) {
      setState(() {
        _ann.remove(target);
        _rd.clear();
        _rd.add(target);
        _selAnnId = null;
        _edDrag = null;
        _edBase = null;
        _edBaseObj = null;
      });
    }
  }

  /// Replace an annotation in-place without clearing [_rd].
  /// Unlike [_replaceAnn], this preserves the redo stack — useful for
  /// incremental arrow-key moves where each step is individually undoable.
  void _replaceAnnInPlace(AnnotationShape old, AnnotationShape newA) {
    final i = _ann.indexOf(old);
    if (i >= 0) {
      newA.selected = false;
      _ann.removeAt(i);
      _ann.insert(i, newA);
    }
  }

  // ─── Eraser logic (mask-based) ───
  // Eraser now records mask primitives instead of deleting annotations.
  // The canvas painter draws masks with BlendMode.clear to punch holes
  // through the annotation layer, revealing the background image.
}

enum _D { tl, tr, bl, br, t, b, l, r, mv }

