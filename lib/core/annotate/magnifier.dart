/// Shared magnifier widget — 15×11 pixel-colour grid + RGB/HEX info.
///
/// Used by both the screenshot annotate page and QuickLook image annotator.
library;

import 'dart:async';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ─── Magnifier painter ───

/// Draws a 15×11 pixel-colour grid centered on the cursor pixel.
class MagnifierPainter extends CustomPainter {
  final List<Color> colors;
  final double cellSize;
  const MagnifierPainter({required this.colors, this.cellSize = 13.0});

  static const cols = 15;
  static const rows = 11;
  static const cCol = 7;
  static const cRow = 5;

  @override
  void paint(Canvas canvas, Size size) {
    void drawCell(int row, int col, Color borderColor, double strokeWidth) {
      final idx = row * cols + col;
      if (idx >= colors.length) return;
      final rect = Rect.fromLTWH(
          col * cellSize, row * cellSize, cellSize, cellSize);
      canvas.drawRect(rect, Paint()..color = colors[idx]);
      canvas.drawRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = borderColor
            ..strokeWidth = strokeWidth);
    }
    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        if (col == cCol && row == cRow) continue;
        if (col == cCol || row == cRow) continue;
        drawCell(row, col, Colors.white24, 0.5);
      }
    }
    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        if (col == cCol && row == cRow) continue;
        if (col == cCol || row == cRow) {
          drawCell(row, col, const Color(0xFF448AFF), 1.0);
        }
      }
    }
    drawCell(cRow, cCol, Colors.red, 1.5);
  }

  @override
  bool shouldRepaint(covariant MagnifierPainter old) =>
      colors != old.colors || cellSize != old.cellSize;
}

// ─── CursorMagnifier widget ───

/// A hover-driven magnifier showing a 15×11 pixel grid + RGB/HEX info.
///
/// [image] & [imageRgba] provide pixel data.  Scale from viewport→image is
/// computed automatically from [MediaQuery] size vs. image dimensions.
/// Wrap in a `Stack`; the widget provides its own `Positioned.fill` + `Listener`.
class CursorMagnifier extends StatefulWidget {
  final ui.Image image;
  final Uint8List imageRgba;

  const CursorMagnifier({
    super.key,
    required this.image,
    required this.imageRgba,
  });

  @override
  State<CursorMagnifier> createState() => _CursorMagnifierState();
}

class _CursorMagnifierState extends State<CursorMagnifier> {
  Offset? _pos;
  (int, int, int)? _rgb;
  String? _hex;
  List<Color>? _gridColors;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _debounce?.cancel();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final ctrlHeld = keys.any((k) =>
        k == LogicalKeyboardKey.controlLeft ||
        k == LogicalKeyboardKey.controlRight);
    if (ctrlHeld) return false;
    final c = event.character?.toLowerCase();
    if (c == 'z' && _pos != null) {
      Clipboard.setData(
          ClipboardData(text: '${_pos!.dx.round()},${_pos!.dy.round()}'));
      return true;
    }
    if (c == 'c' && _rgb != null) {
      final (r, g, b) = _rgb!;
      Clipboard.setData(ClipboardData(text: 'RGB($r,$g,$b)'));
      return true;
    }
    if (c == 'x' && _hex != null) {
      Clipboard.setData(ClipboardData(text: _hex!));
      return true;
    }
    return false;
  }

  void _onMove(Offset viewportPos) {
    setState(() => _pos = viewportPos);
    if (_debounce != null) return;
    _debounce = Timer(const Duration(milliseconds: 40), () {
      _debounce = null;
      if (!mounted) return;
      final img = widget.image;
      final ws = MediaQuery.of(context).size;
      final sx = img.width.toDouble() / ws.width;
      final sy = img.height.toDouble() / ws.height;
      final px = (viewportPos.dx * sx).round();
      final py = (viewportPos.dy * sy).round();
      if (px < 0 || px >= img.width || py < 0 || py >= img.height) {
        setState(() {
          _rgb = null;
          _hex = null;
          _gridColors = null;
        });
        return;
      }
      final rgba = widget.imageRgba;
      final idx = (py * img.width + px) * 4;
      if (idx + 3 >= rgba.length) return;
      final r = rgba[idx], g = rgba[idx + 1], b = rgba[idx + 2];
      final hex =
          '#${r.toRadixString(16).padLeft(2, '0').toUpperCase()}'
          '${g.toRadixString(16).padLeft(2, '0').toUpperCase()}'
          '${b.toRadixString(16).padLeft(2, '0').toUpperCase()}';
      final grid = _sampleGridColors(
          centerX: px, centerY: py, img: img, rgba: rgba);
      setState(() {
        _rgb = (r, g, b);
        _hex = hex;
        _gridColors = grid;
      });
    });
  }

  List<Color> _sampleGridColors({
    required int centerX,
    required int centerY,
    required ui.Image img,
    required Uint8List rgba,
  }) {
    final w = img.width;
    final h = img.height;
    final result = <Color>[];
    for (int dy = -5; dy <= 5; dy++) {
      for (int dx = -7; dx <= 7; dx++) {
        final px = (centerX + dx).clamp(0, w - 1);
        final py = (centerY + dy).clamp(0, h - 1);
        final idx = (py * w + px) * 4;
        final r = rgba[idx], g = rgba[idx + 1], b = rgba[idx + 2];
        result.add(Color.fromARGB(255, r, g, b));
      }
    }
    return result;
  }

  bool get _visible =>
      _pos != null && _rgb != null && _hex != null && _gridColors != null;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerMove: (e) => _onMove(e.localPosition),
        onPointerHover: (e) => _onMove(e.localPosition),
        child: _visible ? _box() : const SizedBox.shrink(),
      ),
    );
  }

  static const _ox = 14.0, _oy = 14.0;
  static const _cellSize = 13.0;
  static const _gridW = 15 * _cellSize;
  static const _gridH = 11 * _cellSize;
  static const _bw = 211.0;
  static const _bh = 233.0;

  Widget _box() {
    final p = _pos!;
    final (r, g, b) = _rgb!;
    final hex = _hex!;
    final grid = _gridColors!;
    final ws = MediaQuery.of(context).size;
    double l = p.dx + _ox, t = p.dy + _oy;
    if (l + _bw > ws.width) l = p.dx - _ox - _bw;
    if (l < 2) l = 2;
    if (t + _bh > ws.height) t = p.dy - _oy - _bh;
    if (t < 2) t = 2;

    const s = TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontFamily: 'Consolas',
        height: 1.25);
    const k = TextStyle(
        color: Color(0xFF80D8FF),
        fontSize: 14,
        fontFamily: 'Consolas',
        height: 1.25);

    return Stack(children: [
      Positioned(
        left: l,
        top: t,
        child: IgnorePointer(
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xCC1A1A2E),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: _gridW,
                  height: _gridH,
                  child: CustomPaint(
                    painter: MagnifierPainter(
                        colors: grid, cellSize: _cellSize),
                  ),
                ),
                const SizedBox(height: 4),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Z ', style: k),
                  Text('${p.dx.round()}, ${p.dy.round()}', style: s),
                ]),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const Text('C ', style: k),
                  Container(
                      width: 10,
                      height: 10,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: Color.fromARGB(255, r, g, b),
                        borderRadius: BorderRadius.circular(1),
                        border: Border.all(
                            color: Colors.white.withAlpha(60), width: 0.5),
                      )),
                  Text('RGB($r,$g,$b)', style: s),
                ]),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const Text('X ', style: k),
                  Text(hex, style: s.copyWith(fontWeight: FontWeight.bold)),
                ]),
              ],
            ),
          ),
        ),
      ),
    ]);
  }
}
