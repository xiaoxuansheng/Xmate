import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img_lib;
import 'package:window_manager/window_manager.dart';
import '../../core/window/window_manager.dart' show WindowService;
import '../../core/drag/drag_out_helper.dart';
import '../../core/annotate/annotate_models.dart';
import '../../core/annotate/annotate_toolbar.dart';
import '../../core/annotate/annotate_canvas.dart';
import '../../core/annotate/magnifier.dart';
import '../../core/search/search_engine_service.dart';
import '../../core/settings/settings_service.dart';
import '../../plugins/screenshot/annotate/ocr_service.dart';
import '../../plugins/screenshot/integration/translate_service.dart' as ocr_tr;
import 'parsers/image_utils.dart';
import '../../core/theme/theme_colors.dart';

// Settings keys persisted across sessions, shared with screenshot annotator.
const kQlOcrLanguageKey = 'screenshot.ocrLanguage';
const kQlOcrEngineKey = 'screenshot.ocrEngine';

class QuickLookImageAnnotator extends StatefulWidget {
  final String filePath; final Uint8List? cachedBytes;
  final ValueChanged<bool>? onEditingChanged;
  const QuickLookImageAnnotator({super.key, required this.filePath, this.cachedBytes, this.onEditingChanged});
  @override State<QuickLookImageAnnotator> createState() => _QuickLookImageAnnotatorState();
}

class _QuickLookImageAnnotatorState extends State<QuickLookImageAnnotator> {
  // --- Image ---
  Uint8List? _bytes, _rgba;
  ui.Image? _decoded;
  int _imgW = 1, _imgH = 1;
  int _bitDepth = 0;  // bits per pixel (e.g. 24, 32, 8)
  String _imgFormat = '';  // detected format (PNG, JPEG, WebP, etc.)
  String? _errorMsg;
  final TransformationController _tc = TransformationController();
  bool _centered = false;
  VoidCallback? _tcListener;
  double _boxW = 0, _boxH = 0;
  double _crX = 0, _crY = 0, _crW = 0, _crH = 0;

  // --- Annotation ---
  bool _editing = false;
  AnnotationTool _tool = AnnotationTool.mouse;
  ToolOptions _opts = const ToolOptions();
  final List<AnnotationShape> _ann = [];
  final List<EraserMask> _eraserMasks = [];
  final List<Uint8List> _undoBytesStack = [];
  final List<Uint8List> _redoBytesStack = [];
  final List<List<AnnotationShape>> _undoStack = [];
  final List<List<AnnotationShape>> _redoStack = [];
  int _nextId = 1;

  // --- Editing ---
  String? _selAnnId;
  AnnHandle? _edDrag;
  Rect? _edBase;
  AnnotationShape? _edBaseObj;
  Offset? _edLastPos;

  // --- Drawing ---
  Offset? _drawStart, _drawCurrent;
  final List<Offset> _freehandPts = [];

  // --- Crop ---
  Rect? _cropRect;
  String? _cropHandle; // 'tl','tr','bl','br','move'

  // --- Text editing (in-place, like screenshot) ---
  bool _tx = false;
  Offset _tP = Offset.zero;
  final _tC = TextEditingController(), _tF = FocusNode();

  // --- Magnifier ---
  bool _showMagnifier = false;
  Offset? _magPos;
  (int, int, int)? _magRgb;
  String? _magHex;
  List<Color>? _magGrid;

  // --- Hold repeat (WASD nudge) ---
  Timer? _holdTimer;
  LogicalKeyboardKey? _holdKey;
  DateTime? _holdStart;

  // --- Help panel ---
  bool _showHelp = false;

  // --- Background toggle ---
  bool _bgWhite = false;

  // --- OCR (same UI as screenshot annotator) ---
  bool _ocrLoading = false;
  String? _ocrError;
  OcrResult? _ocrResult;
  bool _ocrInPlace = true;
  String _ocrLanguage = 'ch';
  String _ocrEngine = 'ppocrv6';
  // Floating panel
  Rect? _ocrPanelRect;
  Offset? _panelDragTouch;
  Offset? _panelDragOrigin;
  static const double _kPanelMinW = 460;
  static const double _kPanelMinH = 200;
  // Image dims at OCR time for coordinate mapping
  double _ocrImageW = 0;
  double _ocrImageH = 0;

  // --- Translate (same as screenshot annotator) ---
  Map<int, String>? _translations;
  bool _translating = false;
  String? _translateError;

  static const _kBgWhite = 'app.quicklook.bgWhite';

  @override void initState() {
    super.initState();
    _bgWhite = SettingsService().getWithDefault<bool>(_kBgWhite, false);
    _tcListener = () { if (mounted) setState(() {}); };
    _tc.addListener(_tcListener!);
    // Restore persisted OCR language / engine.
    final s = SettingsService();
    _ocrLanguage = (s.get(kQlOcrLanguageKey) as String?) ?? 'ch';
    _ocrEngine = (s.get(kQlOcrEngineKey) as String?) ?? 'ppocrv6';
    _loadImage();
  }

  @override void didUpdateWidget(covariant QuickLookImageAnnotator old) {
    super.didUpdateWidget(old);
    if (widget.filePath != old.filePath) {
      _bytes = null; _rgba = null; _decoded = null; _errorMsg = null;
      _bitDepth = 0; _imgFormat = '';
      _centered = false; _boxW = 0;
      if (_editing) widget.onEditingChanged?.call(false);
      _editing = false; _selAnnId = null; _tx = false;
      _edDrag = null; _edBase = null; _edBaseObj = null;
      _ann.clear(); _eraserMasks.clear(); _undoStack.clear(); _redoStack.clear();
      _loadImage();
    }
  }

  @override void dispose() {
    widget.onEditingChanged?.call(false);
    if (_tcListener != null) _tc.removeListener(_tcListener!);
    _tc.dispose(); _tC.dispose(); _tF.dispose();
    super.dispose();
  }

  // ─── Load ───
  Future<void> _loadImage() async {
    Uint8List bytes;
    if (widget.cachedBytes != null) { bytes = widget.cachedBytes!; }
    else {
      try {
        final f = File(widget.filePath);
        if (!await f.exists()) { if (mounted) setState(() => _errorMsg = 'Failed to load image'); return; }
        bytes = await f.readAsBytes();
      } catch (_) { if (mounted) setState(() => _errorMsg = 'Failed to load image'); return; }
    }
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      _imgW = frame.image.width; _imgH = frame.image.height;

      // Detect format and bit depth from file header.
      // The image lib decodes the header without decoding pixel data.
      try {
        final decoded = img_lib.decodeImage(bytes);
        if (decoded != null) {
          _bitDepth = computeBpp(decoded);
          _imgFormat = detectImageFormat(bytes);
        }
      } catch (_) {
        _imgFormat = detectImageFormat(bytes);
      }

      final rgba = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      setState(() { _bytes = bytes; _decoded = frame.image; _rgba = rgba?.buffer.asUint8List(); });
    } catch (_) { if (mounted) setState(() => _errorMsg = 'Failed to decode image'); }
  }

  /// OCR the whole image, same engine/pipeline as screenshot annotator.
  /// Toggle: first click runs OCR and shows results, second click dismisses.
  Future<void> _toggleOcr() async {
    if (_ocrResult != null || _ocrError != null) {
      setState(() { _ocrResult = null; _ocrError = null; _ocrPanelRect = null; });
      return;
    }
    if (_ocrLoading) return;
    final rgba = _rgba;
    final img = _decoded;
    if (rgba == null || img == null) return;
    setState(() { _ocrLoading = true; _ocrError = null; _ocrResult = null; _ocrPanelRect = null; });
    try {
      final src = img_lib.Image.fromBytes(
        width: img.width, height: img.height,
        bytes: rgba.buffer, numChannels: 4, order: img_lib.ChannelOrder.rgba,
      );
      final pngBytes = Uint8List.fromList(img_lib.encodePng(src));
      final svc = OcrService();
      final result = await svc.recognize(pngBytes,
        engine: _ocrEngine, language: _ocrLanguage);
      if (!mounted) return;
      setState(() {
        _ocrResult = result;
        _ocrLoading = false;
        _ocrImageW = img.width.toDouble();
        _ocrImageH = img.height.toDouble();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ocrLoading = false;
        _ocrError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _saveOcrSettings() {
    final s = SettingsService();
    s.set(kQlOcrLanguageKey, _ocrLanguage);
    s.set(kQlOcrEngineKey, _ocrEngine);
  }

  // ─── Translate ─────────────────────────────────────────────────────────

  Future<void> _translateOcr() async {
    final result = _ocrResult;
    if (result == null || result.boxes.isEmpty) return;
    if (_translating) return;

    final texts = <String>[];
    for (final box in result.boxes) {
      if (box.text.isNotEmpty) texts.add(box.text);
    }
    if (texts.isEmpty) return;

    setState(() { _translating = true; _translateError = null; _translations = null; });

    try {
      final svc = ocr_tr.TranslateService();
      final results = await svc.translateBatch(texts, from: 'auto', to: 'zh');
      if (!mounted) return;
      final indexMap = <int, String>{};
      for (int i = 0; i < result.boxes.length && i < results.length; i++) {
        final src = result.boxes[i].text;
        final tr = results[i];
        if (tr != src) indexMap[i] = tr;
      }
      setState(() { _translating = false; _translations = indexMap; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _translating = false;
        _translateError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _clearTranslate() {
    setState(() { _translations = null; _translateError = null; _translating = false; });
  }


  // ─── Layout ───
  void _updateContainRect(double boxW, double boxH) {
    if (_imgW <= 0 || _imgH <= 0) return;
    final scale = math.min(boxW / _imgW, boxH / _imgH);
    _crW = _imgW * scale; _crH = _imgH * scale;
    _crX = (boxW - _crW) / 2; _crY = (boxH - _crH) / 2;
  }
  bool get _containRectValid => _crW > 0 && _crH > 0;

  Offset _toImageSpace(Offset screenPos) {
    Offset cp; try { cp = MatrixUtils.transformPoint(Matrix4.inverted(_tc.value), screenPos); }
    catch (_) { cp = screenPos; }
    if (!_containRectValid) return cp;
    final sx = _crW / _imgW, sy = _crH / _imgH;
    return Offset((cp.dx - _crX) / sx, (cp.dy - _crY) / sy);
  }

  // ─── Tool handlers ───
  void _onPointerDown(PointerDownEvent e) {
    if (_tx) { _ct(); return; }
    if (e.buttons == 2) { setState(() => _tool = AnnotationTool.mouse); return; }
    if (_tool == AnnotationTool.mouse) return;

    // Crop: start drag to define region, or handle drag if rect exists
    if (_tool == AnnotationTool.crop) {
      final ip = _toImageSpace(e.localPosition);
      if (_cropRect != null) {
        final h = _hitTestCropHandle(ip);
        if (h != null) { _cropHandle = h; setState(() {}); return; }
        // Hit test ✓/✗ buttons (image space, bottom-right of rect)
        _checkCropButton(ip);
        // Click elsewhere → start new drag
        _cropRect = null; _cropHandle = null;
      }
      _drawStart = ip; _drawCurrent = ip; setState(() {}); return;
    }
    // bgRemove: select pixel to flood-fill
    if (_tool == AnnotationTool.bgRemove) { _selectBgRemovePixel(e.localPosition); return; }

    // Check handles of selected annotation (editing in any tool mode).
    final ip = _toImageSpace(e.localPosition);
    if (_selAnnId != null) {
      final sel = _findById(_selAnnId!);
      if (sel != null) {
        final h = hitTestAnnHandle(sel, ip);
        if (h != null) { _edDrag = h; _edBase = getAnnBounds(sel);
          if (h != AnnHandle.move) _edBaseObj = _deepCopy(sel);
          _edLastPos = ip; setState(() {}); return; }
      }
    }

    if (_tool == AnnotationTool.text) { _tP = e.localPosition; _tC.clear();
      setState(() => _tx = true);
      WidgetsBinding.instance.addPostFrameCallback((_) => _tF.requestFocus()); return; }
    if (_tool == AnnotationTool.numberTag) {
      final a = NumberTagAnnotation(x: ip.dx, y: ip.dy, number: _nextNumber,
          color: _opts.color, style: _opts.numberTagStyle, fontSize: _opts.numberTagSize, id: 'ql$_nextId');
      _undoStack.add(List.from(_ann)); _redoStack.clear(); _selAnnId = a.id;
      setState(() { _ann.add(a); _nextId++; }); return;
    }
    if (_tool == AnnotationTool.eraser && _opts.mosaicMode != MosaicMode.line) {
      _drawStart = ip; _drawCurrent = _drawStart; setState(() {}); return;
    }
    _drawStart = ip; _drawCurrent = _drawStart;
    _freehandPts.clear(); _freehandPts.add(_drawStart!);
    setState(() {});
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_edDrag != null && _edLastPos != null) {
      final p = _toImageSpace(e.localPosition); final delta = p - _edLastPos!; _edLastPos = p;
      final sel = _findById(_selAnnId!); if (sel == null) return;
      if (_edDrag == AnnHandle.move) { _replaceAnn(sel, translateAnn(sel, delta.dx, delta.dy));
        if (_edBase != null) _edBase = _edBase!.translate(delta.dx, delta.dy); }
      else if (_edDrag == AnnHandle.rotate) { if (_edBase == null) return;
        final c = _edBase!.center; final pr = p - delta;
        final da = math.atan2(p.dy - c.dy, p.dx - c.dx) - math.atan2(pr.dy - c.dy, pr.dx - c.dx);
        _replaceAnn(sel, rotateAnn(sel, da)); }
      else if (_edBaseObj != null && _edBase != null) {
        final u = resizeAnn(sel, _edDrag!, delta, _edBase!, keepAspect: HardwareKeyboard.instance.isShiftPressed);
        _replaceAnn(sel, u); _edBase = getAnnBounds(u); }
      setState(() {}); return;
    }
    if (_drawStart == null) {
      // Crop handle drag
      if (_tool == AnnotationTool.crop && _cropHandle != null && _cropRect != null) {
        final p = _toImageSpace(e.localPosition);
        _updateCropRect(_cropHandle!, p);
        setState(() {});
        return;
      }
      return;
    }
    final p = _toImageSpace(e.localPosition); _drawCurrent = p;
    if (_tool == AnnotationTool.crop) {
      _drawCurrent = p; setState(() {}); return;
    }
    if (_tool == AnnotationTool.freehand ||
        (_tool == AnnotationTool.mosaic && _opts.mosaicMode == MosaicMode.line) ||
        (_tool == AnnotationTool.eraser && _opts.mosaicMode == MosaicMode.line)) {
      _freehandPts.add(p);
    }
    setState(() {});
  }

  void _onPointerUp(PointerUpEvent e) {
    // Crop handle release
    if (_tool == AnnotationTool.crop && _cropHandle != null) { _cropHandle = null; setState(() {}); return; }
    if (_edDrag != null) { _edDrag = null; _edBase = null; _edBaseObj = null; _edLastPos = null; setState(() {}); return; }
    if (_tool == AnnotationTool.mouse || _tool == AnnotationTool.text || _tool == AnnotationTool.numberTag) {
      // Mouse click while crop is active → hit test confirm/cancel buttons
      if (_tool == AnnotationTool.mouse && _cropRect != null) {
        _checkCropButton(_toImageSpace(e.localPosition));
        return;
      }
      return;
    }
    // Crop drag end → set _cropRect
    if (_tool == AnnotationTool.crop) {
      if (_drawStart != null && _drawCurrent != null) {
        final s = _drawStart!, c = _drawCurrent!;
        final r = Rect.fromLTRB(math.min(s.dx, c.dx), math.min(s.dy, c.dy), math.max(s.dx, c.dx), math.max(s.dy, c.dy));
        if (r.width > 5 && r.height > 5) { _cropRect = r; _cropHandle = null; }
        _drawStart = null; _drawCurrent = null;
        setState(() {});
      }
      return;
    }
    if (_drawStart == null) return;
    final start = _drawStart!, end = _drawCurrent!;
    AnnotationShape? c;
    switch (_tool) {
      case AnnotationTool.rectangle:
        c = RectAnnotation(x: math.min(start.dx, end.dx), y: math.min(start.dy, end.dy),
            w: (start.dx - end.dx).abs(), h: (start.dy - end.dy).abs(),
            color: _opts.color, strokeWidth: _opts.strokeWidth, shapeKind: _opts.shapeKind,
            cornerRadius: _opts.cornerRadius, fillStyle: _opts.fillStyle, lineStyle: _opts.lineStyle, id: 'ql$_nextId');
      case AnnotationTool.arrow:
        c = ArrowAnnotation(fromX: start.dx, fromY: start.dy, toX: end.dx, toY: end.dy,
            color: _opts.color, strokeWidth: _opts.strokeWidth, startHead: _opts.startHead,
            endHead: _opts.endHead, lineStyle: _opts.lineStyle, id: 'ql$_nextId');
      case AnnotationTool.freehand:
        if (_freehandPts.length >= 2) c = FreehandAnnotation(points: List.from(_freehandPts),
            color: _opts.color, strokeWidth: _opts.strokeWidth, lineStyle: _opts.lineStyle, id: 'ql$_nextId');
      case AnnotationTool.mosaic:
        if (_opts.mosaicMode == MosaicMode.line) {
          if (_freehandPts.length >= 2) c = MosaicAnnotation(
              mode: MosaicMode.line, points: List.from(_freehandPts),
              cellSize: _opts.mosaicCellSize * _screenScale, effect: _opts.mosaicEffect,
              blurAmount: _opts.mosaicBlurAmount, id: 'ql$_nextId');
        } else {
          if ((end.dx - start.dx).abs() > 2 || (end.dy - start.dy).abs() > 2) c = MosaicAnnotation(
              mode: _opts.mosaicMode, rect: Rect.fromPoints(start, end),
              cellSize: _opts.mosaicCellSize * _screenScale, effect: _opts.mosaicEffect,
              blurAmount: _opts.mosaicBlurAmount, id: 'ql$_nextId');
        }
      case AnnotationTool.eraser:
        if (_opts.mosaicMode == MosaicMode.line) {
          if (_freehandPts.length >= 2) {
            _eraserMasks.add(EraserMask(mode: MosaicMode.line, points: List.from(_freehandPts), cellSize: _opts.mosaicCellSize * _screenScale));
            setState(() {});
          }
        } else {
          final r = Rect.fromLTRB(math.min(start.dx, end.dx), math.min(start.dy, end.dy), math.max(start.dx, end.dx), math.max(start.dy, end.dy));
          if (r.width > 3 && r.height > 3) {
            _eraserMasks.add(EraserMask(mode: _opts.mosaicMode, rect: r));
            setState(() {});
          }
        }
        _drawStart = null; _drawCurrent = null; _freehandPts.clear(); return;
      default: break;
    }
    _drawStart = null; _drawCurrent = null; _freehandPts.clear();
    if (c != null) { _undoStack.add(List.from(_ann)); _redoStack.clear(); _selAnnId = c.id;
      setState(() { _ann.add(c!); _nextId++; }); }
    else setState(() {});
  }

  void _ct() { final t = _tC.text; setState(() => _tx = false);
    final ip = _toImageSpace(_tP);
    if (t.isNotEmpty) { final a = TextAnnotation(x: ip.dx, y: ip.dy, text: t,
        color: _opts.color, fontSize: _opts.fontSize, bold: _opts.bold, italic: _opts.italic,
        outline: _opts.outline, fontFamily: _opts.fontFamily, textStyleKind: _opts.textStyleKind, id: 'ql$_nextId');
      _undoStack.add(List.from(_ann)); _redoStack.clear(); _selAnnId = a.id;
      setState(() { _ann.add(a); _nextId++; }); }
    _tC.clear();
  }

  int get _nextNumber { int mx = 0; for (final a in _ann) { if (a is NumberTagAnnotation && a.number > mx) mx = a.number; } return mx + 1; }

  // ─── Tool mapping ───

  AnnotationTool? _toolForAnnotationType(AnnotationShape a) {
    if (a is RectAnnotation) return AnnotationTool.rectangle;
    if (a is ArrowAnnotation) return AnnotationTool.arrow;
    if (a is TextAnnotation) return AnnotationTool.text;
    if (a is FreehandAnnotation) return AnnotationTool.freehand;
    if (a is MosaicAnnotation) return AnnotationTool.mosaic;
    if (a is NumberTagAnnotation) return AnnotationTool.numberTag;
    return null;
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

  // ─── Mouse tool ───
  AnnotationShape? _findById(String id) { for (final a in _ann) { if (a.id == id) return a; } return null; }
  void _replaceAnn(AnnotationShape o, AnnotationShape u) { final i = _ann.indexOf(o); if (i >= 0) _ann[i] = u; }

  void _deleteSelectedAnnotation() {
    if (_selAnnId == null) return;
    final target = _findById(_selAnnId!);
    if (target != null) {
      _undoStack.add(List.from(_ann)); _redoStack.clear();
      setState(() { _ann.remove(target); _selAnnId = null; _edDrag = null; _edBase = null; _edBaseObj = null; });
    }
  }

  void _cycleSelection() {
    if (_ann.isEmpty) return;
    if (_selAnnId == null) {
      setState(() => _selAnnId = _ann.first.id);
    } else {
      final idx = _ann.indexWhere((a) => a.id == _selAnnId);
      final next = idx >= 0 ? (idx + 1) % _ann.length : 0;
      setState(() => _selAnnId = _ann[next].id);
    }
    _edDrag = null; _edBase = null; _edBaseObj = null;
  }

  /// Move the system cursor by (dx, dy) logical pixels.
  void _moveCursorBy(int dx, int dy) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    WindowService().moveCursor((dx * dpr).round(), (dy * dpr).round());
  }

  // ─── Hold-repeat (WASD long press) ───

  void _startHold(LogicalKeyboardKey key, VoidCallback action) {
    _stopHold();
    _holdKey = key;
    _holdStart = DateTime.now();
    _holdTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || _holdKey != key) return;
      action();
      _scheduleNextHold(key, action);
    });
  }

  void _scheduleNextHold(LogicalKeyboardKey key, VoidCallback action) {
    if (!mounted || _holdKey != key) return;
    final elapsed = DateTime.now().difference(_holdStart!).inMilliseconds - 300;
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

  // ─── Scroll wheel resize ───

  void _onScrollResize(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    if (_selAnnId == null) return;
    final sel = _findById(_selAnnId!);
    if (sel == null) return;
    final oldBounds = getAnnBounds(sel);
    if (oldBounds.width < 5 || oldBounds.height < 5) return;

    final factor = 1.0 + e.scrollDelta.dy / 200.0;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    double newW = oldBounds.width * factor;
    double newH = oldBounds.height * factor;
    if (newW < 5) newW = 5; if (newH < 5) newH = 5;

    final targetRect = shift
        ? Rect.fromLTWH(oldBounds.left, oldBounds.top, newW, newH)
        : Rect.fromCenter(center: oldBounds.center, width: newW, height: newH);

    _undoStack.add(List.from(_ann)); _redoStack.clear();
    final u = resizeAnnToBounds(sel, targetRect);
    _replaceAnn(sel, u);
    setState(() {});
  }

  Offset? _mousePtrStart, _mousePtrLast;

  void _onMousePtrDown(PointerDownEvent e) {
    if (e.buttons == 2) {
      // Right click: switch tool logic
      if (_tool != AnnotationTool.mouse) {
        setState(() { _tool = AnnotationTool.mouse; _selAnnId = null; _edDrag = null; _edBase = null; _edBaseObj = null; });
      } else if (_selAnnId != null) {
        final a = _findById(_selAnnId!);
        final tool = a != null ? _toolForAnnotationType(a) : null;
        if (tool != null) { setState(() => _tool = tool); }
      } else {
        _onExitEditing();
      }
      return;
    }
    final p = _toImageSpace(e.localPosition);
    _mousePtrStart = e.localPosition; _mousePtrLast = e.localPosition;
    if (_selAnnId != null) { final sel = _findById(_selAnnId!); if (sel != null) { final h = hitTestAnnHandle(sel, p, scale: _screenScale);
      if (h != null) { _edDrag = h; _edBase = getAnnBounds(sel);
        if (h != AnnHandle.move) _edBaseObj = _deepCopy(sel);
        _edLastPos = p; _mousePtrStart = null; setState(() {}); return; } } }
    final hit = hitTestAnnotation(_ann, p);
    if (hit != null) { _undoStack.add(List.from(_ann)); _redoStack.clear();
      _selAnnId = hit.id; _edDrag = AnnHandle.move; _edBase = getAnnBounds(hit);
      _edLastPos = p; _mousePtrStart = null; setState(() {}); return; }
    if (_selAnnId != null) setState(() { _selAnnId = null; _edDrag = null; });
  }

  void _onMousePtrMove(PointerMoveEvent e) {
    if (_mousePtrStart != null && _mousePtrLast != null) { final d = e.localPosition - _mousePtrLast!;
      _mousePtrLast = e.localPosition; final m = _tc.value.clone();
      m.storage[12] += d.dx; m.storage[13] += d.dy; _tc.value = m; setState(() {}); return; }
    if (_edDrag == null || _selAnnId == null) return;
    final p = _toImageSpace(e.localPosition); final delta = p - _edLastPos!; _edLastPos = p;
    final sel = _findById(_selAnnId!); if (sel == null) return;
    if (_edDrag == AnnHandle.move) { _replaceAnn(sel, translateAnn(sel, delta.dx, delta.dy));
      if (_edBase != null) _edBase = _edBase!.translate(delta.dx, delta.dy); }
    else if (_edDrag == AnnHandle.rotate) { if (_edBase == null) return;
      final c = _edBase!.center; final pr = p - delta;
      final da = math.atan2(p.dy - c.dy, p.dx - c.dx) - math.atan2(pr.dy - c.dy, pr.dx - c.dx);
      _replaceAnn(sel, rotateAnn(sel, da)); }
    else if (_edBaseObj != null && _edBase != null) { final u = resizeAnn(sel, _edDrag!, delta, _edBase!,
        keepAspect: HardwareKeyboard.instance.isShiftPressed);
      _replaceAnn(sel, u); _edBase = getAnnBounds(u); }
    setState(() {});
  }

  void _onMousePtrUp(PointerUpEvent e) {
    _mousePtrStart = null; _mousePtrLast = null;
    _edDrag = null; _edBase = null; _edBaseObj = null; _edLastPos = null; setState(() {});
  }

  void _enterEditing() {
    // Dismiss OCR if active.
    if (_ocrResult != null || _ocrError != null) {
      _ocrResult = null; _ocrError = null; _ocrPanelRect = null;
      _clearTranslate();
    }
    _undoStack.clear(); _redoStack.clear();
    if (_bytes != null) {
      _undoBytesStack.add(_bytes!);
      _redoBytesStack.clear();
    }
    setState(() => _editing = true);
    widget.onEditingChanged?.call(true);
    _refitForToolbar();
  }
  void _onExitEditing() { setState(() { _editing = false; _selAnnId = null; _edDrag = null; _edBase = null; _edBaseObj = null; });
    widget.onEditingChanged?.call(false); }

  AnnotationShape _deepCopy(AnnotationShape a) {
    if (a is RectAnnotation) return RectAnnotation(x: a.x, y: a.y, w: a.w, h: a.h, color: a.color,
        strokeWidth: a.strokeWidth, shapeKind: a.shapeKind, cornerRadius: a.cornerRadius,
        fillStyle: a.fillStyle, fillColor: a.fillColor, lineStyle: a.lineStyle, id: a.id)..rotation = a.rotation;
    if (a is ArrowAnnotation) return ArrowAnnotation(fromX: a.fromX, fromY: a.fromY, toX: a.toX, toY: a.toY,
        color: a.color, strokeWidth: a.strokeWidth, startHead: a.startHead, endHead: a.endHead,
        lineStyle: a.lineStyle, id: a.id)..rotation = a.rotation;
    if (a is TextAnnotation) return TextAnnotation(x: a.x, y: a.y, text: a.text, color: a.color,
        fontSize: a.fontSize, bold: a.bold, italic: a.italic, outline: a.outline,
        fontFamily: a.fontFamily, textStyleKind: a.textStyleKind, id: a.id)..rotation = a.rotation;
    if (a is FreehandAnnotation) return FreehandAnnotation(points: List.from(a.points), color: a.color,
        strokeWidth: a.strokeWidth, lineStyle: a.lineStyle, id: a.id)..rotation = a.rotation;
    if (a is NumberTagAnnotation) return NumberTagAnnotation(x: a.x, y: a.y, number: a.number,
        color: a.color, style: a.style, fontSize: a.fontSize, id: a.id)..rotation = a.rotation;
    return a;
  }

  void _onToolChanged(AnnotationTool v) {
    if (_tx) _ct();
    if (v == AnnotationTool.crop) {
      _cropRect = null; _cropHandle = null;
      _drawStart = null; _drawCurrent = null;
      setState(() => _tool = v);
      return;
    }
    if (v != AnnotationTool.mouse && v != AnnotationTool.eraser) { _selAnnId = null; _edDrag = null; _edBase = null; _edBaseObj = null; }
    _cropRect = null; _cropHandle = null;
    _drawStart = null; _drawCurrent = null; _freehandPts.clear();
    setState(() => _tool = v);
  }

  void _onUndo() {
    if (_undoBytesStack.isNotEmpty) {
      _redoBytesStack.add(_bytes!);
      _redoStack.add(List.from(_ann));
      _applyBytes(Uint8List.fromList(_undoBytesStack.removeLast()));
      return;
    }
    if (_undoStack.isEmpty) return;
    _redoStack.add(List.from(_ann)); setState(() { _ann.clear(); _ann.addAll(_undoStack.removeLast()); _selAnnId = null; }); }
  void _onRedo() {
    if (_redoBytesStack.isNotEmpty) {
      _undoBytesStack.add(_bytes!);
      _undoStack.add(List.from(_ann));
      _applyBytes(Uint8List.fromList(_redoBytesStack.removeLast()));
      return;
    }
    if (_redoStack.isEmpty) return;
    _undoStack.add(List.from(_ann)); setState(() { _ann.clear(); _ann.addAll(_redoStack.removeLast()); _selAnnId = null; }); }

  void _applyBytes(Uint8List bytes) {
    ui.instantiateImageCodec(bytes).then((codec) {
      codec.getNextFrame().then((frame) async {
        final rgba = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (!mounted) return;
        final newSize = _computeSizeForDims(frame.image.width, frame.image.height);
        try { await windowManager.setSize(_editing
            ? Size(math.max(newSize.width, 550), math.max(newSize.height, 350))
            : newSize); } catch (_) {}
        setState(() { _bytes = bytes; _decoded = frame.image; _rgba = rgba?.buffer.asUint8List();
          _imgW = frame.image.width; _imgH = frame.image.height; _boxW = 0; _centered = false;
          if (!_editing) _tool = AnnotationTool.mouse;
          _selAnnId = null; _cropRect = null; _cropHandle = null; });
      });
    });
  }

  // ─── Crop / BgRemove (editing toolbar tools) ───


  // ─── Crop helpers ───

  // (no cropHandleSz — handled inline)

  double get _screenScale {
    if (_imgW <= 0 || _imgH <= 0 || _crW <= 0 || _crH <= 0) return 1.0;
    final sx = _crW / _imgW, sy = _crH / _imgH;
    final s = math.min(sx, sy);
    return s > 0.01 ? 1.0 / s : 1.0;
  }

  String? _hitTestCropHandle(Offset p) {
    if (_cropRect == null) return null;
    final r = _cropRect!;
    final h = 10.0 * _screenScale;
    if ((p - r.topLeft).distance < h) return 'tl';
    if ((p - r.topRight).distance < h) return 'tr';
    if ((p - r.bottomLeft).distance < h) return 'bl';
    if ((p - r.bottomRight).distance < h) return 'br';
    if (r.contains(p)) return 'move';
    return null;
  }

  void _updateCropRect(String handle, Offset p) {
    if (_cropRect == null) return;
    final r = _cropRect!;
    Rect nr;
    switch (handle) {
      case 'tl': nr = Rect.fromLTRB(p.dx, p.dy, r.right, r.bottom); break;
      case 'tr': nr = Rect.fromLTRB(r.left, p.dy, p.dx, r.bottom); break;
      case 'bl': nr = Rect.fromLTRB(p.dx, r.top, r.right, p.dy); break;
      case 'br': nr = Rect.fromLTRB(r.left, r.top, p.dx, p.dy); break;
      case 'move': nr = r.translate(p.dx - r.center.dx, p.dy - r.center.dy); break;
      default: return;
    }
    if (nr.width >= 10 && nr.height >= 10) _cropRect = nr;
  }

  void _checkCropButton(Offset viewP) {
    if (_cropRect == null) return;
    final r = _cropRect!;
    final ss = _screenScale;
    final btnSz = 24.0 * ss;
    final gap = 4.0 * ss;
    final confirmBtn = Rect.fromLTWH(r.right - btnSz * 2 - gap, r.bottom + gap, btnSz, btnSz);
    final cancelBtn = Rect.fromLTWH(r.right - btnSz, r.bottom + gap, btnSz, btnSz);
    if (confirmBtn.contains(viewP)) { _confirmCrop(); return; }
    if (cancelBtn.contains(viewP)) { _cancelCrop(); return; }
  }

  Future<void> _confirmCrop() async {
    if (_cropRect == null || _bytes == null) return;
    final r = _cropRect!;
    final ix = math.max(0, r.left.round());
    final iy = math.max(0, r.top.round());
    final iw = math.min(_imgW - ix, r.width.round());
    final ih = math.min(_imgH - iy, r.height.round());
    if (iw <= 0 || ih <= 0) return;
    final decoded = img_lib.decodeImage(_bytes!);
    if (decoded == null) return;
    final oldBytes = _bytes!;
    final oldAnnotations = List<AnnotationShape>.from(_ann);
    final cropped = img_lib.copyCrop(decoded, x: ix, y: iy, width: iw, height: ih);
    final newBytes = img_lib.encodePng(cropped);
    try { await File(widget.filePath).writeAsBytes(newBytes); } catch (_) {}
    await _reloadBytes(Uint8List.fromList(newBytes));
    _undoBytesStack.add(oldBytes); _redoBytesStack.clear();
    _undoStack.add(oldAnnotations); _redoStack.clear();
  }

  void _cancelCrop() {
    _cropRect = null; _cropHandle = null;
    _tool = AnnotationTool.mouse;
    setState(() {});
  }

  void _refitForToolbar() {
    // Ensure window is large enough to show image + toolbar (~550px wide, ~350px tall)
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final current = await windowManager.getSize();
        const minW = 550.0, minH = 350.0;
        if (current.width < minW || current.height < minH) {
          await windowManager.setSize(Size(
            math.max(current.width, minW),
            math.max(current.height, minH)));
        }
      } catch (_) {}
    });
  }

  Future<void> _selectBgRemovePixel(Offset viewPos) async {
    if (_rgba == null) return;
    final ip = _toImageSpace(viewPos); final px = ip.dx.round(), py = ip.dy.round();
    if (px < 0 || px >= _imgW || py < 0 || py >= _imgH) return;
    final decoded = img_lib.decodeImage(_bytes!); if (decoded == null) return;
    img_lib.fillFlood(decoded, x: px, y: py, color: img_lib.ColorRgba8(0, 0, 0, 0),
        threshold: 12.0, compareAlpha: false);
    final newBytes = img_lib.encodePng(decoded);
    try { await File(widget.filePath).writeAsBytes(newBytes); } catch (_) {}
    await _reloadBytes(Uint8List.fromList(newBytes));
  }

  Future<void> _reloadBytes(Uint8List newBytes) async {
    final codec = await ui.instantiateImageCodec(newBytes);
    final frame = await codec.getNextFrame();
    final rgba = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (!mounted) return;
    try { await windowManager.setSize(_computeSizeForDims(frame.image.width, frame.image.height)); } catch (_) {}
    setState(() { _bytes = newBytes; _decoded = frame.image; _rgba = rgba?.buffer.asUint8List();
      _imgW = frame.image.width; _imgH = frame.image.height; _boxW = 0; _centered = false;
      _tool = AnnotationTool.mouse;
      _selAnnId = null; _cropRect = null; _cropHandle = null; });
  }

  Size _computeSizeForDims(int w, int h) {
    final display = ui.PlatformDispatcher.instance.displays.first;
    final ss = display.size / display.devicePixelRatio;
    final maxW = ss.width * 0.5, maxH = ss.height * 0.5;
    double nw = w.toDouble().clamp(400.0, maxW);
    double nh = h * (nw / w);
    if (nh > maxH) { nh = maxH; nw = w * (nh / h); }
    nw = nw.clamp(400.0, maxW); nh = nh.clamp(300.0, maxH);
    const p = 16.0, th = 36.0;
    return Size(nw + p * 2, nh + th + p * 2);
  }

  // ─── Actions ───

  Future<void> _copyImage() async { if (_bytes == null) return;
    try { await const MethodChannel('com.xmate/screenshot').invokeMethod('copyToClipboard', {'data': _bytes}); } catch (_) {} }
  Future<void> _toggleBg() async {
    setState(() => _bgWhite = !_bgWhite);
    await SettingsService().set(_kBgWhite, _bgWhite);
  }
  Future<void> _imageSearch() async { await _copyImage();
    try { await SettingsService().init(); final svc = SearchEngineService();
      final eng = svc.getDefaultEngine(SearchEngineCategory.image);
      if (eng != null) await svc.executeImageSearch(eng); } catch (_) {} }
  Future<void> _rotateCW() async => await _rotate(90);
  Future<void> _rotateCCW() async => await _rotate(-90);
  Future<void> _rotate(int deg) async { if (_bytes == null) return;
    final d = img_lib.decodeImage(_bytes!); if (d == null) return;
    final r = img_lib.copyRotate(d, angle: deg == 90 ? -90 : 90);
    final b = img_lib.encodePng(r);
    try { await File(widget.filePath).writeAsBytes(b); } catch (_) {}
    await _reloadBytes(Uint8List.fromList(b));
  }

  // ─── Toolbar callbacks ───
  Future<void> _onCopy() async { final b = await _composeImage(); if (b != null && mounted)
    try { await const MethodChannel('com.xmate/screenshot').invokeMethod('copyToClipboard', {'data': b}); } catch (_) {} }
  Future<void> _onSave() async { final b = await _composeImage(); if (b == null || !mounted) return;
    try { final f = File(widget.filePath); final dir = f.parent;
      final stem = f.uri.pathSegments.last.replaceAll(RegExp(r'\.[^.]+$'), '');
      final ext = f.uri.pathSegments.last.split('.').last;
      // Find the next available numbered filename
      String p; int n = 1;
      while (true) {
        p = '${dir.path}/${stem}-${n.toString().padLeft(3, '0')}.$ext'.replaceAll('\\', '/');
        if (!await File(p).exists()) break;
        n++;
      }
      await File(p).writeAsBytes(b); } catch (_) {} }
  Future<void> _onSaveReplace() async { final b = await _composeImage(); if (b == null || !mounted) return;
    try { await File(widget.filePath).writeAsBytes(b); } catch (_) {} }
  void _onPin() async { final b = await _composeImage(); if (b != null && mounted) {
    final c = await ui.instantiateImageCodec(b); final fr = await c.getNextFrame();
    final rb = await fr.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    setState(() { _bytes = b; _decoded = fr.image; _rgba = rb?.buffer.asUint8List();
      _imgW = fr.image.width; _imgH = fr.image.height; _boxW = 0; _centered = false;
      _ann.clear(); _eraserMasks.clear(); _undoStack.clear(); _redoStack.clear(); _selAnnId = null; _editing = false; }); } }
  Future<Uint8List?> _composeImage() async { if (_decoded == null) return null;
    final w = _decoded!.width, h = _decoded!.height;
    final rec = ui.PictureRecorder(); final c = Canvas(rec);
    c.drawImage(_decoded!, Offset.zero, Paint());
    for (final a in _ann) drawAnnotation(c, a, image: _decoded, widgetSize: Size(w.toDouble(), h.toDouble()));
    final pic = rec.endRecording(); final im = await pic.toImage(w, h);
    final pd = await im.toByteData(format: ui.ImageByteFormat.png); return pd?.buffer.asUint8List(); }

  // ─── Magnifier ───
  void _updateMagnifier(Offset vp) { if (!_showMagnifier || _rgba == null) return;
    final ip = _toImageSpace(vp); final px = ip.dx.round(), py = ip.dy.round();
    if (px < 0 || px >= _imgW || py < 0 || py >= _imgH) { setState(() { _magPos = null; _magRgb = null; _magHex = null; _magGrid = null; }); return; }
    final idx = (py * _imgW + px) * 4; if (idx + 3 >= _rgba!.length) return;
    final r = _rgba![idx], g = _rgba![idx + 1], b = _rgba![idx + 2];
    final hx = '#${r.toRadixString(16).padLeft(2,'0').toUpperCase()}${g.toRadixString(16).padLeft(2,'0').toUpperCase()}${b.toRadixString(16).padLeft(2,'0').toUpperCase()}';
    final gr = <Color>[]; for (int dy = -5; dy <= 5; dy++) for (int dx = -7; dx <= 7; dx++) {
        final sx = (px+dx).clamp(0,_imgW-1), sy = (py+dy).clamp(0,_imgH-1); final i = (sy*_imgW+sx)*4;
        gr.add(Color.fromARGB(255, _rgba![i], _rgba![i+1], _rgba![i+2])); }
    setState(() { _magPos = vp; _magRgb = (r,g,b); _magHex = hx; _magGrid = gr; });
  }
  Widget _buildMagnifierBox() { if (_magPos == null || _magGrid == null || _magRgb == null || _magHex == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final p = _magPos!; final (r,g,b) = _magRgb!; final ws = MediaQuery.of(context).size;
    const cl = 13.0, ox = 14.0, oy = 14.0, gw = 15*cl, gh = 11*cl, bw = 211.0, bh = 233.0;
    double l = p.dx+ox, t = p.dy+oy; if (l+bw > ws.width) l = p.dx-ox-bw; if (l<2) l=2;
    if (t+bh > ws.height) t = p.dy-oy-bh; if (t<2) t=2;
    final s = TextStyle(color: cs.onSurface, fontSize: 16, fontFamily: 'Consolas', height: 1.25);
    final k = TextStyle(color: cs.primary, fontSize: 14, fontFamily: 'Consolas', height: 1.25);
    return Positioned(left: l, top: t, child: IgnorePointer(child: Container(padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: XMateColors.panelBg(context), borderRadius: BorderRadius.circular(4)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: gw, height: gh, child: CustomPaint(painter: MagnifierPainter(colors: _magGrid!, cellSize: cl))),
        const SizedBox(height: 4),
        Row(mainAxisSize: MainAxisSize.min, children: [Text('Z ', style: k), Text('${p.dx.round()}, ${p.dy.round()}', style: s)]),
        Row(mainAxisSize: MainAxisSize.min, children: [Text('C ', style: k),
          Container(width: 10, height: 10, margin: const EdgeInsets.only(right: 4),
            decoration: BoxDecoration(color: Color.fromARGB(255,r,g,b), borderRadius: BorderRadius.circular(1),
                border: Border.all(color: cs.onSurface.withAlpha(60)))), Text('RGB($r,$g,$b)', style: s)]),
        Row(mainAxisSize: MainAxisSize.min, children: [Text('X ', style: k), Text(_magHex!, style: s.copyWith(fontWeight: FontWeight.bold))]),
      ])))); }

  // ─── Keyboard ───
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    // Stop hold-repeat on key up
    if (event is KeyUpEvent) {
      if (_holdKey != null && event.logicalKey == _holdKey) _stopHold();
      return KeyEventResult.ignored;
    }
    // During text editing, block Enter from bubbling to parent (_openFile).
    // Other keys are ignored so the TextField can process them.
    if (_tx) {
      final keys = HardwareKeyboard.instance.logicalKeysPressed;
      if (keys.contains(LogicalKeyboardKey.enter)) return KeyEventResult.handled;
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final ctrl = keys.any((k) => k == LogicalKeyboardKey.controlLeft || k == LogicalKeyboardKey.controlRight);
    final shift = keys.any((k) => k == LogicalKeyboardKey.shiftLeft || k == LogicalKeyboardKey.shiftRight);

    // === Editing-mode shortcuts ===
    if (_editing) {
      // Block Enter from bubbling to _openFile
      if (keys.contains(LogicalKeyboardKey.enter)) return KeyEventResult.handled;

      final key = event.logicalKey;
      // WASD nudge selected annotation 1px (with hold-repeat)
      final wasd = <LogicalKeyboardKey, Offset>{
        LogicalKeyboardKey.keyW: const Offset(0, -1),
        LogicalKeyboardKey.keyA: const Offset(-1, 0),
        LogicalKeyboardKey.keyS: const Offset(0, 1),
        LogicalKeyboardKey.keyD: const Offset(1, 0),
      };
      if (wasd.containsKey(key)) {
        final d = wasd[key]!;
        _moveCursorBy(d.dx.toInt(), d.dy.toInt());
        _startHold(key, () => _moveCursorBy(d.dx.toInt(), d.dy.toInt()));
        return KeyEventResult.handled;
      }

      // Del/Backspace — delete selected annotation
      if (keys.contains(LogicalKeyboardKey.delete) || keys.contains(LogicalKeyboardKey.backspace)) {
        _deleteSelectedAnnotation(); return KeyEventResult.handled;
      }

      // Ctrl+Z/X — undo/redo
      if (ctrl && keys.contains(LogicalKeyboardKey.keyZ)) { _onUndo(); return KeyEventResult.handled; }
      if (ctrl && keys.contains(LogicalKeyboardKey.keyX)) { _onRedo(); return KeyEventResult.handled; }

      // Tab — cycle selection
      if (keys.contains(LogicalKeyboardKey.tab)) { _cycleSelection(); return KeyEventResult.handled; }

      // H — toggle help
      if (keys.contains(LogicalKeyboardKey.keyH)) { setState(() => _showHelp = !_showHelp); return KeyEventResult.handled; }

      // Ctrl+S / Ctrl+Shift+S — save
      if (ctrl && shift && keys.contains(LogicalKeyboardKey.keyS)) { _onSaveReplace(); return KeyEventResult.handled; }
      if (ctrl && keys.contains(LogicalKeyboardKey.keyS)) { _onSave(); return KeyEventResult.handled; }
      // Ctrl+C — copy composed image
      if (ctrl && keys.contains(LogicalKeyboardKey.keyC)) { _onCopy(); return KeyEventResult.handled; }

      return KeyEventResult.ignored; // don't let editing shortcuts leak to viewer shortcuts
    }

    // === Viewer-mode shortcuts (non-editing) ===
    if (keys.contains(LogicalKeyboardKey.tab)) { _toggleBg(); return KeyEventResult.handled; }
    if (ctrl && keys.contains(LogicalKeyboardKey.keyC)) { _copyImage(); return KeyEventResult.handled; }
    if (shift && keys.contains(LogicalKeyboardKey.keyT)) { _rotateCCW(); return KeyEventResult.handled; }
    if (!ctrl && keys.contains(LogicalKeyboardKey.keyT)) { _rotateCW(); return KeyEventResult.handled; }
    return KeyEventResult.ignored;
  }

  // ─── UI ───
  @override Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    if (_errorMsg != null) return Center(child: Text(_errorMsg!, style: const TextStyle(fontSize: 15, color: Colors.redAccent)));
    if (_decoded == null) return Center(child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary));
    return Focus(autofocus: true, onKeyEvent: _onKeyEvent, child: Column(children: [
      Expanded(child: _buildViewer()),
      if (_editing) _buildToolbar(),
    ]));
  }

  Widget _buildViewer() => LayoutBuilder(builder: (c, cs) {
    final vw=cs.maxWidth, vh=cs.maxHeight; const pad=32.0;
    final bw=(vw-pad*2).clamp(50.0,double.infinity), bh=(vh-pad*2).clamp(50.0,double.infinity);
    if (bw!=_boxW||bh!=_boxH) { _updateContainRect(bw,bh); _boxW=bw; _boxH=bh; }
    if (!_centered||bw!=_boxW||bh!=_boxH) { _centered=true;
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted)
        _tc.value = Matrix4.translationValues((vw-bw)/2,(vh-bh)/2,0); }); }
    final dt=_editing && _tool!=AnnotationTool.mouse;
    final bd=_editing && !dt && _selAnnId!=null;
    return Stack(children: [
      // Background color layer — Tab key toggles black/white.
      Positioned.fill(
        child: Container(color: _bgWhite ? Colors.white : const Color(0xFF1a1a1a)),
      ),
      IgnorePointer(ignoring: dt||bd, child: InteractiveViewer(
        transformationController: _tc, constrained: false, minScale: 0.2, maxScale: 5.0,
        boundaryMargin: EdgeInsets.all(vw+vh),
        child: Stack(children: [
          SizedBox(width: bw, height: bh, child: Image.memory(_bytes!, fit: BoxFit.contain)),
          // OCR in-place overlays inside InteractiveViewer → follow zoom/pan
          ..._buildOcrInPlace(Size(bw, bh)),
        ]))),
      // Info bar + OCR floating panel
      Positioned(top: 0, left: 0, child: _buildInfoBar()),
      // OCR floating panel (in-place overlays are inside InteractiveViewer above)
      if (_ocrResult != null && !_ocrLoading) ..._buildOcrPanel(Size(vw, vh)),
      if (_ocrLoading || _ocrError != null) ..._buildOcrPanel(Size(vw, vh)),
      if (_showMagnifier) ...[
        Positioned.fill(child: Listener(behavior: HitTestBehavior.translucent,
          onPointerMove: (e) => _updateMagnifier(e.localPosition),
          onPointerHover: (e) => _updateMagnifier(e.localPosition))),
        _buildMagnifierBox()],
      if (!_editing) ...[
        Positioned.fill(child: Listener(behavior: HitTestBehavior.translucent,
          onPointerDown: (e) {
            if (e.buttons == 2) {
              // During OCR, right-click opens context menu instead of entering edit.
              if (_ocrResult != null) return;
              _enterEditing();
            }
          })),
        Positioned(bottom: 16, right: 16, child: _buildActionButtons())],
      if (_editing) ...[
        IgnorePointer(child: CustomPaint(size: Size(vw,vh),
          painter: _AnnotationsPainter(annotations: _ann, eraserMasks: _eraserMasks,
            tcValue: _tc.value, image: _decoded, imageRgba: _rgba,
            crX: _crX, crY: _crY, crW: _crW, crH: _crH, imgW: _imgW, imgH: _imgH,
            selectedAnnotationId: _selAnnId,
            drawPreview: _drawStart!=null && _drawCurrent!=null,
            previewTool: _tool, previewStart: _drawStart, previewCurrent: _drawCurrent,
            previewColor: _opts.color, previewStrokeWidth: _opts.strokeWidth,
            previewOptions: _opts, freehandPreview: List.from(_freehandPts),
            mosaicEffect: _opts.mosaicEffect, cropRect: _cropRect,
            screenScale: _screenScale))),
        if (_tx) Positioned(left: _tP.dx, top: _tP.dy,
          child: Material(color: Colors.transparent, child: SizedBox(width: 200, child: TextField(
            controller: _tC, focusNode: _tF, autofocus: true,
            style: TextStyle(fontSize: _opts.fontSize, color: _opts.color,
                fontWeight: _opts.bold ? FontWeight.bold : FontWeight.normal,
                fontStyle: _opts.italic ? FontStyle.italic : FontStyle.normal,
                fontFamily: _opts.fontFamily),
            decoration: const InputDecoration(border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero),
            onSubmitted: (_) => _ct(), onTapOutside: (_) => _ct())))),
        if (dt) Positioned.fill(child: Listener(onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove, onPointerUp: _onPointerUp,
            behavior: HitTestBehavior.translucent)),
        if (!dt) Positioned.fill(child: Listener(onPointerDown: _onMousePtrDown,
            onPointerMove: _onMousePtrMove, onPointerUp: _onMousePtrUp,
            behavior: HitTestBehavior.translucent)),
        if (_selAnnId != null) Positioned.fill(
          child: Listener(onPointerSignal: _onScrollResize, behavior: HitTestBehavior.translucent)),
        if (_showHelp) _buildHelpPanel(),
      ]]);
  });

  Widget _buildActionButtons() => Column(mainAxisSize: MainAxisSize.min, children: [
    _fab(Icons.image_search, '图片搜索', _imageSearch), const SizedBox(height: 8),
    _fab(Icons.zoom_in, '放大镜', () => setState(() => _showMagnifier = !_showMagnifier), active: _showMagnifier), const SizedBox(height: 8),
    _fab(Icons.text_snippet, 'OCR', _toggleOcr, active: _ocrResult != null || _ocrError != null), const SizedBox(height: 8),
    _fab(Icons.copy, '复制图片', _copyImage), const SizedBox(height: 8),
    _fab(Icons.rotate_right, 'L=+90° / R=-90°', _rotateCW, onSecondaryTap: _rotateCCW), const SizedBox(height: 8),
    _fab(Icons.edit, '编辑', () { _enterEditing(); }),
  ]);
  Widget _fab(IconData icon, String tip, VoidCallback onTap, {bool active=false, VoidCallback? onSecondaryTap}) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(message: tip, child: GestureDetector(
      onSecondaryTap: onSecondaryTap,
      behavior: HitTestBehavior.opaque,
      child: FloatingActionButton.small(heroTag: 'ql_$tip',
        backgroundColor: active ? cs.primary.withAlpha(0xCC) : XMateColors.panelBg(context),
        onPressed: onTap, child: Icon(icon, size: 18, color: active ? cs.onSurface : cs.onSurface.withAlpha(179)))));
  }

  Widget _buildInfoBar() {
    final cs = Theme.of(context).colorScheme;
    final fmt = _imgFormat.isNotEmpty && _imgFormat != '?' ? _imgFormat : '';
    final bpp = _bitDepth > 0 ? '${_bitDepth}bit' : '';
    final parts = ['${_imgW}×$_imgH', bpp, fmt].where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 4, left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: XMateColors.panelBg(context),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        parts.join(' · '),
        style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(179), height: 1.3),
      ),
    );
  }

  // ─── OCR UI (matching screenshot annotator) ──────────────────────────

  // Determine screen-space rect for the OCR in-place overlays / panel.
  Rect get _imageScreenRect {
    if (_imgW <= 0 || _imgH <= 0 || _crW <= 0 || _crH <= 0) return Rect.zero;
    return Rect.fromLTWH(_crX, _crY, _crW, _crH);
  }

  /// Average character width factor for [text]: CJK ≈ 0.95, Latin ≈ 0.58.
  double _avgCharWidthFactor(String text) {
    if (text.isEmpty) return 0.58;
    int cjk = 0;
    for (int i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if ((c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF) ||
          (c >= 0x3040 && c <= 0x30FF) || (c >= 0xAC00 && c <= 0xD7AF) ||
          (c >= 0xFF01 && c <= 0xFF60)) cjk++;
    }
    final ratio = cjk / text.length;
    return 0.58 + ratio * (0.95 - 0.58);
  }

  Widget _ocrLangSegBtn(String label, String lang) {
    final cs = Theme.of(context).colorScheme;
    final active = _ocrLanguage == lang;
    return SizedBox(width: 28, height: 24,
      child: TextButton(
        style: TextButton.styleFrom(padding: EdgeInsets.zero,
          backgroundColor: cs.primary.withAlpha(active ? 51 : 13),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4),
            side: BorderSide(color: cs.primary.withAlpha(active ? 179 : 51), width: 1))),
        onPressed: active ? null : () => setState(() {
          _ocrLanguage = lang;
          if (lang == 'en') _ocrEngine = 'winrt';
          _saveOcrSettings();
          _toggleOcr();
        }),
        child: Text(label, style: TextStyle(
          color: active ? cs.primary : cs.onSurface.withAlpha(90),
          fontSize: 10, fontWeight: FontWeight.w700)),
      ));
  }

  Widget _ocrEngineDropdown(ColorScheme cs) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(value: _ocrEngine, isDense: true,
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
          _toggleOcr();
        },
      ));
  }

  /// In-place OCR text overlays at image coordinates.
  List<Widget> _buildOcrInPlace(Size ws) {
    if (!_ocrInPlace) return const [];
    final cs = Theme.of(context).colorScheme;
    final result = _ocrResult;
    if (result == null || result.boxes.isEmpty) return const [];

    final r = _imageScreenRect;
    if (r.isEmpty || _imgW <= 0 || _imgH <= 0) return const [];
    final sx = r.width / _imgW;
    final sy = r.height / _imgH;

    return result.boxes.take(50).toList().asMap().entries.map((entry) {
      final box = entry.value;
      final q = box.quad;
      if (q.length < 4) return const SizedBox.shrink();

      // Map quad corners to screen space (relative to the center-fitted rect)
      final xs = q.map((p) => r.left + p.dx * sx);
      final ys = q.map((p) => r.top + p.dy * sy);
      final left = xs.reduce(math.min);
      final top = ys.reduce(math.min);
      final right = xs.reduce(math.max);
      final bottom = ys.reduce(math.max);
      final bw = right - left;
      final rawH = math.max(8.0, bottom - top);
      final bh = math.max(16.0, rawH);
      if (bw < 4) return const SizedBox.shrink();

      final avgFactor = _avgCharWidthFactor(box.text);
      final charCount = math.max(box.text.length, 1);
      final byWidth = bw / (charCount * avgFactor);
      final fontSize = byWidth.clamp(10.0, bh);

      return Positioned(left: left, top: top, width: bw, height: bh,
        child: IgnorePointer(ignoring: false,
          child: RepaintBoundary(child: Container(
            decoration: BoxDecoration(color: Colors.transparent,
              border: Border.all(color: cs.primary.withAlpha(85), width: 1),
              borderRadius: BorderRadius.circular(2)),
            alignment: Alignment.center,
            child: DragOutSelectableText(box.text,
              style: TextStyle(color: cs.onSurface.withAlpha(51),
                fontSize: fontSize, fontWeight: FontWeight.w500,
                decoration: TextDecoration.none),
              textAlign: TextAlign.center, maxLines: 1,
              selectionColor: cs.primary.withAlpha(51),
              cursorColor: cs.primary.withAlpha(102))))));
    }).toList();
  }

  /// Floating OCR result panel — same as screenshot annotator.
  List<Widget> _buildOcrPanel(Size ws) {
    final cs = Theme.of(context).colorScheme;
    final hasOcr = _ocrLoading || _ocrError != null || _ocrResult != null;
    if (!hasOcr) return const [];

    final widgets = <Widget>[];

    // Loading indicator
    if (_ocrLoading) {
      widgets.add(Positioned(left: 0, top: 40, right: 0,
        child: IgnorePointer(
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: XMateColors.panelBg(context).withAlpha(221),
                borderRadius: BorderRadius.circular(8)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: cs.onSurface)),
                const SizedBox(width: 10),
                Text('OCR…', style: TextStyle(color: cs.onSurface.withAlpha(179), fontSize: 13)),
              ]))))));
      return widgets;
    }

    // Error panel
    if (_ocrError != null) {
      widgets.add(Positioned(top: 10, left: 10, width: math.min(ws.width - 20, 550),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: XMateColors.panelBg(context).withAlpha(238),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.redAccent.withAlpha(120), width: 1)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            const Row(children: [
              Icon(Icons.error_outline, size: 14, color: Colors.redAccent),
              SizedBox(width: 6),
              Text('OCR Error', style: TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 160),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: cs.onSurface.withAlpha(12), borderRadius: BorderRadius.circular(4)),
              child: SingleChildScrollView(
                child: DragOutSelectableText(_ocrError!,
                  style: TextStyle(color: Colors.redAccent.shade200, fontSize: 11, fontFamily: 'Consolas', height: 1.5),
                ))),
          ]))));
      return widgets;
    }

    final result = _ocrResult;
    if (result == null) return const [];

    // Auto-position panel
    _ocrPanelRect ??= Rect.fromLTRB(
      (ws.width - _kPanelMinW) / 2, ws.height * 0.55, _kPanelMinW, math.min(350.0, ws.height * 0.35));
    final p = _ocrPanelRect!;
    final cl = p.left.clamp(0.0, math.max(0.0, ws.width - p.width)).toDouble();
    final ct = p.top.clamp(0.0, math.max(0.0, ws.height - p.height)).toDouble();
    final cw = math.max(_kPanelMinW, math.min(p.width, ws.width - 8.0)).toDouble();
    final ch = math.max(_kPanelMinH, math.min(p.height, ws.height - 8.0)).toDouble();
    final cr = Rect.fromLTRB(cl, ct, cl + cw, ct + ch);

    final diag = result.diag;
    final engineName = (diag?['engine_src'] as String?) ?? 'PP-OCRv6';

    // Build title bar row separately for readability.
    final titleBar = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (d) { _panelDragTouch = d.globalPosition; _panelDragOrigin = _ocrPanelRect?.topLeft; },
      onPanUpdate: (d) {
        if (_panelDragOrigin == null) return;
        final px = _ocrPanelRect; if (px == null) return;
        final delta = d.globalPosition - _panelDragTouch!;
        final nl = (_panelDragOrigin!.dx + delta.dx).clamp(0.0, math.max(0.0, ws.width - px.width)).toDouble();
        final nt = (_panelDragOrigin!.dy + delta.dy).clamp(0.0, math.max(0.0, ws.height - px.height)).toDouble();
        setState(() => _ocrPanelRect = Rect.fromLTRB(nl, nt, nl + px.width, nt + px.height));
      },
      onPanEnd: (_) { _panelDragTouch = null; _panelDragOrigin = null; },
      child: Container(
        padding: const EdgeInsets.only(left: 12, right: 4, top: 8, bottom: 4),
        child: Row(children: [
          const Icon(Icons.article, size: 14),
          const SizedBox(width: 6),
          const Text('OCR Result', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          _ocrLangSegBtn('中', 'ch'), const SizedBox(width: 1),
          _ocrLangSegBtn('EN', 'en'),
          if (_ocrLanguage == 'ch') ...[const SizedBox(width: 6), _ocrEngineDropdown(cs)],
          const Spacer(),
          Text('$engineName  |  ${result.blocks.length} blk',
              style: TextStyle(color: cs.onSurface.withAlpha(97), fontSize: 11)),
          const SizedBox(width: 4),
          // Translate button
          _ocrPanelIconBtn(Icons.translate, Icons.translate,
            _translations != null || _translating,
            tip: _translations != null ? 'Show OCR' : 'Translate to zh',
            onTap: () {
              if (_translations != null) { _clearTranslate(); }
              else { _translateOcr(); }
            }),
          const SizedBox(width: 2),
          _ocrPanelIconBtn(Icons.visibility, Icons.visibility_off, _ocrInPlace,
            tip: _ocrInPlace ? 'Hide in-place' : 'Show in-place',
            onTap: () => setState(() => _ocrInPlace = !_ocrInPlace)),
          const SizedBox(width: 2),
          _ocrPanelIconBtn(Icons.close, Icons.close, false,
            tip: 'Close',
            onTap: () { _ocrPanelRect = null; setState(() { _ocrResult = null; _ocrError = null; _ocrLoading = false; _clearTranslate(); }); }),
        ])));

    // Body — show translation or OCR text
    final displayText = _translating
        ? null // shows spinner
        : (_translations != null
            ? _buildTranslationText(result)
            : result.fullText);
    final body = Expanded(
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 8), padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: cs.onSurface.withAlpha(8), borderRadius: BorderRadius.circular(6)),
        child: _translating
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : SingleChildScrollView(
                child: DragOutSelectableText(displayText!,
                  style: TextStyle(color: cs.onSurface.withAlpha(179), fontSize: 12, fontFamily: 'Consolas', height: 1.55),
              ))));

    // Resize handle
    final resizeHandle = Positioned(right: 0, bottom: 0, width: 20, height: 20,
      child: GestureDetector(
        onPanUpdate: (d) {
          final px = _ocrPanelRect; if (px == null) return;
          final nw = math.max(_kPanelMinW, math.min(px.width + d.delta.dx, ws.width - px.left - 8.0));
          final nh = math.max(_kPanelMinH, math.min(px.height + d.delta.dy, ws.height - px.top - 8.0));
          setState(() => _ocrPanelRect = Rect.fromLTRB(px.left, px.top, px.left + nw, px.top + nh));
        },
        child: Align(alignment: Alignment.bottomRight,
          child: Padding(padding: const EdgeInsets.only(bottom: 4, right: 4),
            child: Icon(Icons.drag_indicator, size: 14, color: cs.onSurface.withAlpha(77))))));

    final panel = Container(
      decoration: BoxDecoration(
        color: XMateColors.dialogBg(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.primary.withAlpha(136), width: 1)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        titleBar, body,
      ]));

    widgets.add(Positioned(
      left: cr.left, top: cr.top, width: cr.width, height: cr.height,
      child: Stack(clipBehavior: Clip.none, children: [panel, resizeHandle])));

    return widgets;
  }

  String _buildTranslationText(OcrResult result) {
    if (_translations == null || _translations!.isEmpty) return result.fullText;
    final parts = <String>[];
    for (int i = 0; i < result.boxes.length; i++) {
      final tr = _translations?[i];
      parts.add(tr ?? result.boxes[i].text);
    }
    return parts.join('\n');
  }

  // Small icon-button for OCR panel title bar.
  Widget _ocrPanelIconBtn(IconData onIcon, IconData offIcon, bool active, {String tip = '', required VoidCallback onTap}) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(width: 28, height: 28,
      child: IconButton(
        padding: EdgeInsets.zero, iconSize: 16,
        icon: Icon(active ? onIcon : offIcon,
            color: active ? cs.primary : cs.onSurface.withAlpha(77)),
        tooltip: tip,
        onPressed: onTap));
  }

  // ─── Help panel ───
  Widget _buildHelpPanel() {
    final cs = Theme.of(context).colorScheme;
    final k = TextStyle(color: cs.primary, fontSize: 12, fontFamily: 'Consolas', height: 1.45);
    final v = TextStyle(color: cs.onSurface.withAlpha(179), fontSize: 12, height: 1.45);
    final s = TextStyle(color: cs.onSurface, fontSize: 12, fontWeight: FontWeight.w600, height: 1.5);

    Widget row(String key, String desc, {bool bold = false}) => Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 120, child: Text(key, style: bold ? s : k)),
        Expanded(child: Text(desc, style: v)),
      ]),
    );

    return Positioned(
      left: 12,
      bottom: 12,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.all(10),
          width: 280,
          decoration: BoxDecoration(
            color: XMateColors.panelBg(context),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: cs.onSurface.withAlpha(61)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('快捷键说明 (编辑模式)',
                  style: TextStyle(color: cs.onSurface, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              row('Del / Backspace', '删除选中标记'),
              row('Tab', '切换选中标记'),
              row('WASD', '微移系统光标 1px'),
              row('Ctrl+Z / Ctrl+X', '撤销 / 重做'),
              row('Ctrl+S', '保存编号副本'),
              row('Ctrl+Shift+S', '覆写原文件'),
              row('Ctrl+C', '复制标注合成图'),
              row('H', '隐藏此面板'),
              row('鼠标右键', '切换工具'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar() => AnnotateToolbar(
    currentTool: _tool, options: _opts, hasSelection: _selAnnId != null,
    canUndo: _undoStack.isNotEmpty, canRedo: _redoStack.isNotEmpty,
    optionsRowFirst: true,
    hiddenTools: const {AnnotationTool.ocr, AnnotationTool.translate, AnnotationTool.bgRemove, AnnotationTool.magnifier},
    hiddenActions: const {'pin'},
    onToolChanged: _onToolChanged, onOptionsChanged: (v) => setState(() {
      _opts = v;
      if (_selAnnId != null) {
        final a = _findById(_selAnnId!);
        if (a != null) {
          final u = _applyOptsToAnnotation(a);
          if (u != null) _replaceAnn(a, u);
        }
      }
    }),
    onUndo: _onUndo, onRedo: _onRedo, onCopy: _onCopy, onSave: _onSave, onPin: _onPin,
    onClose: () => _onExitEditing(),
    onClearAll: () => setState(() { _ann.clear(); _eraserMasks.clear(); _undoStack.clear(); _redoStack.clear(); _undoBytesStack.clear(); _redoBytesStack.clear(); _selAnnId = null; }));
}

// ─── Painter ───
class _AnnotationsPainter extends CustomPainter {
  final List<AnnotationShape> annotations; final List<EraserMask> eraserMasks;
  final Matrix4 tcValue;
  final double crX, crY, crW, crH; final int imgW, imgH;
  final ui.Image? image; final Uint8List? imageRgba;
  final String? selectedAnnotationId; final bool drawPreview; final AnnotationTool previewTool;
  final Offset? previewStart, previewCurrent;
  final Color previewColor; final double previewStrokeWidth;
  final ToolOptions previewOptions;
  final List<Offset> freehandPreview; final MosaicEffect mosaicEffect;
  final Rect? cropRect;
  final double screenScale;
  _AnnotationsPainter({required this.annotations, required this.eraserMasks,
    required this.tcValue, required this.image, required this.imageRgba,
    required this.crX, required this.crY, required this.crW, required this.crH,
    required this.imgW, required this.imgH, this.selectedAnnotationId,
    required this.drawPreview, required this.previewTool,
    this.previewStart, this.previewCurrent, required this.previewColor,
    required this.previewStrokeWidth, required this.previewOptions,
    this.freehandPreview = const [], this.mosaicEffect = MosaicEffect.pixelate,
    this.cropRect, this.screenScale = 1.0});

  @override void paint(Canvas c, Size s) {
    final v = crW>0 && crH>0 && imgW>0 && imgH>0;
    final sx = v ? crW/imgW : 1.0, sy = v ? crH/imgH : 1.0;
    // ss = image→screen pixel ratio. When image is large & scaled down, ss > 1.
    // All UI elements (handles, buttons, stroke widths) are multiplied by ss
    // so they appear the same physical size on screen regardless of zoom level.
    final ss = screenScale;
    c.save(); c.transform(tcValue.storage);
    if (v) { c.translate(crX, crY); c.scale(sx, sy); }

    // Interleave annotations + eraser masks by creation order.
    // Annotations get an order-id on first paint from the same global counter
    // that EraserMask uses, guaranteeing directly comparable sort keys.
    // Mask drawn after ann → clears it. Ann drawn after mask → appears above.
    final widgetSize = Size(imgW.toDouble(), imgH.toDouble());
    final ops = <MapEntry<int, Object>>[];
    for (final a in annotations) {
      ops.add(MapEntry(getOrAssignAnnOrder(a), a));
    }
    for (final m in eraserMasks) {
      ops.add(MapEntry(m.orderId, m));
    }
    ops.sort((x, y) => x.key.compareTo(y.key));

    final annLayerBounds = Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble());
    c.saveLayer(annLayerBounds, Paint());
    for (final op in ops) {
      final v = op.value;
      if (v is AnnotationShape) {
        drawAnnotation(c, v, image: image, widgetSize: widgetSize, imageRgba: imageRgba);
      } else if (v is EraserMask) {
        drawEraserMask(c, v);
      }
    }
    c.restore();

    // Handles on top of eraser masks
    if (selectedAnnotationId != null) for (final a in annotations)
      if (a.id == selectedAnnotationId) { _drawHandles(c, a, ss); break; }

    // Preview
    if (drawPreview && previewStart != null && previewCurrent != null) {
      final ds = previewStart!, dc = previewCurrent!;
      if (previewTool == AnnotationTool.rectangle) {
        final r = Rect.fromPoints(ds, dc);
        drawAnnotation(c, RectAnnotation(x: r.left, y: r.top, w: r.width, h: r.height,
            color: previewColor, strokeWidth: previewStrokeWidth, shapeKind: previewOptions.shapeKind,
            fillStyle: previewOptions.fillStyle, lineStyle: previewOptions.lineStyle));
      } else if (previewTool == AnnotationTool.arrow) {
        drawAnnotation(c, ArrowAnnotation(fromX: ds.dx, fromY: ds.dy, toX: dc.dx, toY: dc.dy,
            color: previewColor, strokeWidth: previewStrokeWidth, lineStyle: previewOptions.lineStyle));
      } else if (previewTool == AnnotationTool.freehand && freehandPreview.length >= 2) {
        drawAnnotation(c, FreehandAnnotation(points: freehandPreview, color: previewColor,
            strokeWidth: previewStrokeWidth, lineStyle: previewOptions.lineStyle));
      } else if (previewTool == AnnotationTool.mosaic) {
        if (previewOptions.mosaicMode == MosaicMode.rect || previewOptions.mosaicMode == MosaicMode.ellipse) {
          final r = Rect.fromPoints(ds, dc);
          drawAnnotation(c, MosaicAnnotation(mode: previewOptions.mosaicMode, rect: r,
              cellSize: previewOptions.mosaicCellSize, effect: mosaicEffect),
              image: image, widgetSize: widgetSize, imageRgba: imageRgba);
        } else if (freehandPreview.length >= 2) {
          drawAnnotation(c, MosaicAnnotation(mode: MosaicMode.line, points: freehandPreview,
              cellSize: previewOptions.mosaicCellSize, effect: mosaicEffect),
              image: image, widgetSize: widgetSize, imageRgba: imageRgba);
        }
      } else if (previewTool == AnnotationTool.eraser) {
        if (previewOptions.mosaicMode == MosaicMode.line && freehandPreview.length >= 2) {
          // Eraser line preview: red path
          final path = Path()..moveTo(freehandPreview.first.dx, freehandPreview.first.dy);
          for (int i = 1; i < freehandPreview.length; i++) {
            path.lineTo(freehandPreview[i].dx, freehandPreview[i].dy);
          }
          c.drawPath(path, Paint()
            ..color = Colors.red.withAlpha(60)
            ..strokeWidth = previewOptions.mosaicCellSize
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round);
        } else if (previewOptions.mosaicMode != MosaicMode.line) {
          final rect = Rect.fromPoints(ds, dc);
          final path = previewOptions.mosaicMode == MosaicMode.ellipse
              ? (Path()..addOval(rect))
              : (Path()..addRect(rect));
          c.drawPath(path, Paint()..color = Colors.red.withAlpha(40)..style = PaintingStyle.fill);
          _strokePreview(c, path, Colors.white, 1.5);
        }
      }
    }
    // Draw crop overlay
    _drawCropOverlay(c, widgetSize, ss);
    c.restore();
  }

  void _strokePreview(Canvas c, Path path, Color color, double sw) {
    final p = Paint()..color = color..strokeWidth = sw..style = PaintingStyle.stroke;
    c.drawPath(path, p);
  }

  void _drawCropOverlay(Canvas c, Size widgetSize, double ss) {
    // Draw crop rect (committed) or drag preview
    Rect? r = cropRect;
    if (r == null && drawPreview && previewTool == AnnotationTool.crop &&
        previewStart != null && previewCurrent != null) {
      final ds = previewStart!, dc = previewCurrent!;
      r = Rect.fromLTRB(
        math.min(ds.dx, dc.dx), math.min(ds.dy, dc.dy),
        math.max(ds.dx, dc.dx), math.max(ds.dy, dc.dy));
    }
    if (r == null || r.width < 3 || r.height < 3) return;

    // ss is already the image-space multiplier (passed from state._screenScale = 1/min(sx,sy))

    // Darken outside
    final dark = Paint()..color = Colors.black.withAlpha(100)..style = PaintingStyle.fill;
    c.drawRect(Rect.fromLTWH(0, 0, widgetSize.width, r.top), dark);
    c.drawRect(Rect.fromLTWH(0, r.bottom, widgetSize.width, widgetSize.height - r.bottom), dark);
    c.drawRect(Rect.fromLTWH(0, r.top, r.left, r.height), dark);
    c.drawRect(Rect.fromLTWH(r.right, r.top, widgetSize.width - r.right, r.height), dark);

    // White border
    c.drawRect(r, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5 * ss);

    // Only draw handles + ✓/✗ for committed rect
    if (cropRect == null) return;

    // Corner handles — scaled for screen size
    final handleSz = 8.0 * ss;
    final hp = Paint()..color = Colors.white..style = PaintingStyle.fill;
    final hs = Paint()..color = const Color(0xFF4FC3F7)..style = PaintingStyle.stroke..strokeWidth = 2.0 * ss;
    for (final p in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      c.drawRect(Rect.fromCenter(center: p, width: handleSz, height: handleSz), hp);
      c.drawRect(Rect.fromCenter(center: p, width: handleSz, height: handleSz), hs);
    }

    // ✓ and ✗ buttons — scaled for screen size
    final btnSz = 24.0 * ss;
    final gap = 4.0 * ss;
    final btnRadius = 4.0 * ss;
    final fontSize = 16.0 * ss;
    final confirmR = Rect.fromLTWH(r.right - btnSz * 2 - gap, r.bottom + gap, btnSz, btnSz);
    final cancelR = Rect.fromLTWH(r.right - btnSz, r.bottom + gap, btnSz, btnSz);

    // Confirm button
    c.drawRRect(RRect.fromRectAndRadius(confirmR, Radius.circular(btnRadius)),
      Paint()..color = const Color(0xCC4CAF50));
    final tp = TextPainter(
      text: TextSpan(text: '✓', style: TextStyle(color: Colors.white, fontSize: fontSize, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr)..layout();
    tp.paint(c, Offset(confirmR.center.dx - tp.width / 2, confirmR.center.dy - tp.height / 2));

    // Cancel button
    c.drawRRect(RRect.fromRectAndRadius(cancelR, Radius.circular(btnRadius)),
      Paint()..color = const Color(0xCCF44336));
    final tp2 = TextPainter(
      text: TextSpan(text: '✕', style: TextStyle(color: Colors.white, fontSize: fontSize, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr)..layout();
    tp2.paint(c, Offset(cancelR.center.dx - tp2.width / 2, cancelR.center.dy - tp2.height / 2));
  }

  void _drawHandles(Canvas c, AnnotationShape a, double ss) {
    Rect ur = a is RectAnnotation ? Rect.fromLTWH(a.x, a.y, a.w, a.h) : getAnnBounds(a);
    final crs = _corners(ur, a.rotation);
    final hp = Paint()..color=Colors.white..style=PaintingStyle.fill;
    final hs = Paint()..color=const Color(0xFF4FC3F7)..style=PaintingStyle.stroke..strokeWidth = 2.0 * ss;
    final bp = Path()..moveTo(crs[0].dx, crs[0].dy);
    for (int i=1; i<4; i++) bp.lineTo(crs[i].dx, crs[i].dy); bp.close();
    c.drawPath(bp, Paint()..color=const Color(0xFF4FC3F7)..style=PaintingStyle.stroke..strokeWidth = 1.5 * ss);
    final sz = 8.0 * ss; for (int i=0; i<4; i++) {
      c.drawRect(Rect.fromCenter(center: crs[i], width: sz, height: sz), hp);
      c.drawRect(Rect.fromCenter(center: crs[i], width: sz, height: sz), hs); }
    final tm = Offset((crs[1].dx+crs[0].dx)/2, (crs[1].dy+crs[0].dy)/2);
    final cx=ur.center.dx, cy=ur.center.dy, dx=tm.dx-cx, dy=tm.dy-cy;
    final ln = 20.0 * ss / math.sqrt(dx*dx+dy*dy+0.001);
    final rh = Offset(tm.dx+dx*ln, tm.dy+dy*ln);
    c.drawLine(tm, rh, Paint()..color=const Color(0xFF4FC3F7)..strokeWidth = 1.5 * ss);
    c.drawCircle(rh, 5.0 * ss, hp); c.drawCircle(rh, 5.0 * ss, hs);
  }

  List<Offset> _corners(Rect r, double a) {
    if (a.abs()<0.001) return [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];
    final cx=r.center.dx, cy=r.center.dy, ca=math.cos(a), sa=math.sin(a);
    return [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft].map((p) {
      final dx=p.dx-cx, dy=p.dy-cy; return Offset(cx+dx*ca-dy*sa, cy+dx*sa+dy*ca); }).toList();
  }
  @override bool shouldRepaint(covariant _AnnotationsPainter o) => true;
}
