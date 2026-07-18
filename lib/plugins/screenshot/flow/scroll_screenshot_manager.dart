/// Scroll-screenshot — displacement-based vertical stitching.
///
/// Strip-based compositing:
///   Frame 0 = header + moving + footer
///   Each new frame → dy → extract new-exposed strip from moving region
///   Preview = lazy layout: header | top strips | frame0 moving | bottom strips | footer
///   Full composite only on export (copy/save)
///
/// Dy estimation: gray+downsample(4xH only) → fixed rows → column strips → phase correlation → ZNCC → RANSAC
library;

import 'dart:developer' as dev;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/widgets.dart' show Rect;
import 'package:image/image.dart' as img;

enum ScrollMode { inactive, active }

class _StripResult {
  final int colX, dy; final double zncc; final bool kept;
  _StripResult({required this.colX, required this.dy, required this.zncc, required this.kept});
}

class ScrollScreenshotManager {
  ScrollMode mode = ScrollMode.inactive;
  bool isCapturing = false;
  int? targetHwnd;

  // ── Frame 0 decomposition ──
  Uint8List? _frame0Png;   // full PNG of first frame
  int _frameW = 0, _frameH = 0;

  // ── Dy estimation state ──
  Uint8List? _prevGray;
  int _fixedTop = 0, _fixedBot = 0;

  // ── Strip accumulation ──
  final List<Uint8List> _topStrips = [];       // newest first
  final List<Uint8List> _bottomStrips = [];    // oldest first
  int _topCovered = 0;   // max rows covered above moving region
  int _botCovered = 0;   // max rows covered below moving region

  // ── Caches ──
  Uint8List? _stitchedPng;
  Uint8List? _debugPng;
  ({int w, int h})? stitchedSize;
  bool debugVis = false;

  int _lastDy = 0;
  int _lastWheelDelta = 0;
  Uint8List? _prevPng;  // previous frame for debug side-by-side
  final _stripResults = <_StripResult>[];

  // ── Public ──

  void enterMode({required Rect sel, required Rect monRect, required double dpr,
      Map<String, dynamic>? targetInfo}) {
    mode = ScrollMode.active;
    _frame0Png = null; _frameW = 0; _frameH = 0;
    _prevGray = null; _fixedTop = 0; _fixedBot = 0;
    _topStrips.clear(); _bottomStrips.clear();
    _topCovered = 0; _botCovered = 0;
    _debugPng = null; _lastDy = 0; _stripResults.clear(); _prevPng = null;
    isCapturing = false; targetHwnd = null;
    _invalidateStitch();
  }

  void addFirstFrame(Uint8List png, ui.Image image) {
    _frame0Png = png;
    _frameW = image.width;
    _frameH = image.height;
    final pxImg = img.decodePng(png)!;
    _prevGray = _toGrayDownsampled(pxImg);
    _prevPng = png;
    _invalidateStitch();
  }

  void addFrame(Uint8List png, ui.Image image, {int wheelDelta = 0}) {
    if (_frame0Png == null) return;
    final pxImg = img.decodePng(png)!;
    final currGray = _toGrayDownsampled(pxImg);
    if (_prevGray == null || _prevGray!.length != currGray.length) {
      _prevGray = currGray; return;
    }

    final fw = pxImg.width, fh = pxImg.height;
    final dsW = fw ~/ 4, dsH = fh;

    // 1. Fixed rows
    final (top, bot) = _measureFixedRows(_prevGray!, currGray, dsW, dsH);
    if (_fixedTop == 0) { _fixedTop = top; _fixedBot = bot; }
    else { if (top < _fixedTop) _fixedTop = top; if (bot < _fixedBot) _fixedBot = bot; }

    final roiT = _fixedTop, roiB = dsH - _fixedBot;
    if (roiB - roiT < 12) return;

    // 2. Dy — algorithm consistently produces the OPPOSITE sign relative to
    //    the strip-placement convention.  Invert once here so the rest of the
    //    code can use the natural convention: dy<0 = scroll down, dy>0 = scroll up.
    //
    //    wheelDelta: raw WHEEL_DELTA from MSLLHOOKSTRUCT (120 per notch).
    //    wheelDelta sign == rawDy2 sign (both track content shift direction in image).
    //    wheelDelta > 0 → content shifted down → rawDy2 > 0 → dy < 0 (new at bottom)
    //    wheelDelta < 0 → content shifted up   → rawDy2 < 0 → dy > 0 (new at top)
    _stripResults.clear();
    final rawDy2 = _findDyConsensus(_prevGray!, currGray, roiT, roiB, dsW, fh, wheelDelta);
    final dy = -rawDy2;
    _lastDy = dy;
    _lastWheelDelta = wheelDelta;
    dev.log('[stitch] rawDy2=$rawDy2 inverted dy=$dy fh=$fh roi=($roiT,$roiB) ds=($dsW,$dsH)');

    // 3. Dedup by covered range — only track absolute pixels in each direction
    final movingT = _fixedTop, movingB = fh - _fixedBot;

    if (dy < 0 && dy.abs() < fh * 8 / 10) {
      // dy<0 = scroll UP = new rows at BOTTOM
      final need = (-dy).clamp(1, movingB - movingT);
      if (need > _botCovered) {
        final newH = need - _botCovered;
        final sy0 = (movingB - need).clamp(0, movingB);
        final sy1 = (movingB - _botCovered).clamp(0, movingB);
        dev.log('[compose] UP   dy=$dy need=$need botCov=$_botCovered→$need new=$newH [$sy0,$sy1)');
        if (sy1 > sy0) _bottomStrips.add(_extractRows(pxImg, sy0, sy1, fw));
        _botCovered = need;
        // Shrink topCovered when retracing: if total covered shrinks from top
        if (_topCovered > 0 && _topCovered + dy > 0) {
          _topCovered = (_topCovered + dy).clamp(0, 999999);
        } else if (_topCovered > 0) {
          _topCovered = 0;
        }
      } else {
        dev.log('[compose] UP   dy=$dy need=$need botCov=$_botCovered skip');
        // Scrolling UP but _botCovered already >= need: consuming bottom territory
        _botCovered -= (-dy);
        if (_botCovered < 0) _botCovered = 0;
      }
    } else if (dy > 0 && dy < fh * 8 / 10) {
      // dy>0 = scroll DOWN = new rows at TOP
      final need = dy.clamp(1, movingB - movingT);
      if (need > _topCovered) {
        final newH = need - _topCovered;
        final sy0 = movingT + _topCovered;
        final sy1 = (movingT + need).clamp(0, movingB);
        dev.log('[compose] DOWN dy=$dy need=$need topCov=$_topCovered→$need new=$newH [$sy0,$sy1)');
        if (sy1 > sy0) _topStrips.insert(0, _extractRows(pxImg, sy0, sy1, fw));
        _topCovered = need;
        // Shrink botCovered when retracing
        if (_botCovered > 0 && _botCovered - dy > 0) {
          _botCovered = (_botCovered - dy).clamp(0, 999999);
        } else if (_botCovered > 0) {
          _botCovered = 0;
        }
      } else {
        dev.log('[compose] DOWN dy=$dy need=$need topCov=$_topCovered skip');
        _topCovered -= dy;
        if (_topCovered < 0) _topCovered = 0;
      }
    }

    if (debugVis) _debugPng = _buildDebugOverlay(pxImg, fw, fh);
    _prevPng = png; // save for next debug overlay
    _prevGray = currGray; _invalidateStitch();
  }

  bool get hasFrames => _frame0Png != null;
  Uint8List get stitchedPng { _stitchedPng ??= _buildComposite(); return _stitchedPng!; }
  Uint8List? get debugPng => _debugPng;
  Future<Uint8List> exportStitchedPng() async => stitchedPng;

  static const double previewWidth = 240.0;
  double previewHeight(double maxH) {
    if (stitchedSize == null) return 120.0;
    final h = previewWidth * stitchedSize!.h / stitchedSize!.w;
    return h.clamp(80.0, maxH - 40);
  }

  void exitMode() {
    mode = ScrollMode.inactive;
    _frame0Png = null; _frameW = 0; _frameH = 0;
    _prevGray = null; _fixedTop = 0; _fixedBot = 0;
    _topStrips.clear(); _bottomStrips.clear();
    _topCovered = 0; _botCovered = 0;
    _debugPng = null; _lastDy = 0; _stripResults.clear(); _prevPng = null;
    isCapturing = false; targetHwnd = null;
    _invalidateStitch();
  }

  // ── Row extraction ──

  Uint8List _extractRows(img.Image src, int y0, int y1, int fw) {
    final h = y1 - y0;
    final strip = img.Image(width: fw, height: h);
    for (int y = y0; y < y1; y++) {
      for (int x = 0; x < fw; x++) {
        final p = src.getPixel(x, y);
        strip.setPixelRgba(x, y - y0, (p.r as int), (p.g as int), (p.b as int), (p.a as int));
      }
    }
    return Uint8List.fromList(img.encodePng(strip));
  }

  // ── Composite builder (lazy, called by stitchedPng getter) ──

  Uint8List _buildComposite() {
    if (_frame0Png == null || _frameH == 0) return Uint8List(0);

    final f0 = img.decodePng(_frame0Png!)!;
    final cw = _frameW;

    // Decompose frame 0
    final mTop = _fixedTop, mBot = _frameH - _fixedBot;
    final headerH = mTop, movingH = mBot - mTop, footerH = _frameH - mBot;

    // Compute strip heights
    int topH = 0;
    for (final s in _topStrips) { final d = img.decodePng(s); if (d != null) topH += d.height; }
    int botH = 0;
    for (final s in _bottomStrips) { final d = img.decodePng(s); if (d != null) botH += d.height; }

    final totalH = headerH + topH + movingH + botH + footerH;
    dev.log('[compose] header=$headerH top=$topH moving=$movingH bot=$botH footer=$footerH → $totalH');

    final canvas = img.Image(width: cw, height: totalH);
    int dstY = 0;

    // Header
    for (int y = 0; y < headerH; y++) {
      for (int x = 0; x < cw; x++) {
        final p = f0.getPixel(x, y);
        canvas.setPixelRgba(x, dstY + y, (p.r as int), (p.g as int), (p.b as int), (p.a as int));
      }
    }
    dstY += headerH;

    // Top strips (inserted at 0 → newest first. Composite: newest at TOP)
    for (int si = 0; si < _topStrips.length; si++) {
      final s = img.decodePng(_topStrips[si]);
      if (s == null) continue;
      for (int y = 0; y < s.height; y++) {
        for (int x = 0; x < cw && x < s.width; x++) {
          final p = s.getPixel(x, y);
          canvas.setPixelRgba(x, dstY + y, (p.r as int), (p.g as int), (p.b as int), (p.a as int));
        }
      }
      dstY += s.height;
    }

    // Frame0 moving region
    for (int y = mTop; y < mBot; y++) {
      for (int x = 0; x < cw; x++) {
        final p = f0.getPixel(x, y);
        canvas.setPixelRgba(x, dstY + (y - mTop), (p.r as int), (p.g as int), (p.b as int), (p.a as int));
      }
    }
    dstY += movingH;

    // Bottom strips
    for (final bPng in _bottomStrips) {
      final s = img.decodePng(bPng);
      if (s == null) continue;
      for (int y = 0; y < s.height; y++) {
        for (int x = 0; x < cw && x < s.width; x++) {
          final p = s.getPixel(x, y);
          canvas.setPixelRgba(x, dstY + y, (p.r as int), (p.g as int), (p.b as int), (p.a as int));
        }
      }
      dstY += s.height;
    }

    // Footer
    for (int y = mBot; y < _frameH; y++) {
      for (int x = 0; x < cw; x++) {
        final p = f0.getPixel(x, y);
        canvas.setPixelRgba(x, dstY + (y - mBot), (p.r as int), (p.g as int), (p.b as int), (p.a as int));
      }
    }

    stitchedSize = (w: cw, h: totalH);
    return Uint8List.fromList(img.encodePng(canvas));
  }

  // ═══════════════════════════════════════════════
  // Below: dy estimation pipeline
  // ═══════════════════════════════════════════════

  Uint8List _toGrayDownsampled(img.Image src) {
    final sw = src.width, sh = src.height;
    final dw = sw ~/ 4, dh = sh;
    final out = Uint8List(dw * dh);
    for (int dy = 0; dy < dh; dy++) {
      final sy = dy; if (sy >= sh) break;
      for (int dx = 0; dx < dw; dx++) {
        final sx = dx * 4; if (sx >= sw) break;
        final p = src.getPixel(sx, sy);
        out[dy * dw + dx] = ((p.r as int) * 77 + (p.g as int) * 150 + (p.b as int) * 29) >> 8;
      }
    }
    return out;
  }

  (int, int) _measureFixedRows(Uint8List a, Uint8List b, int dw, int dh) {
    int top = 0, bot = 0;
    for (int y = 0; y < dh; y++) {
      int s = 0; for (int x = 0; x < dw; x++) { s += (a[y*dw+x] - b[y*dw+x]).abs(); }
      if (s < dw * 5) { top++; } else { break; }
    }
    for (int y = dh - 1; y >= 0; y--) {
      int s = 0; for (int x = 0; x < dw; x++) { s += (a[y*dw+x] - b[y*dw+x]).abs(); }
      if (s < dw * 5) { bot++; } else { break; }
    }
    return (top, bot);
  }

  int _findDyConsensus(Uint8List a, Uint8List b, int roiT, int roiB, int dw, int fh, int wheelDelta) {
    final roiH = roiB - roiT;
    final expectSign = wheelDelta.sign;

    // Search range: generous — SAD on full grayscale is discriminative enough
    final maxDy = (roiH * 3 ~/ 4).clamp(12, roiH - 1);

    // Detect fixed columns (static UI bars, side panels)
    final fixedCols = _measureFixedCols(a, b, dw, roiT, roiB);

    // 7 narrow vertical strips, ~5% width each, no overlap
    final stripW = (dw * 5 ~/ 100).clamp(2, dw ~/ 8);
    final step = dw / 7.0;
    final candidates = <_StripResult>[];

    _stripResults.clear();

    for (int si = 0; si < 7; si++) {
      final cx = (step * (si + 0.5)).round();
      final left = (cx - stripW ~/ 2).clamp(0, dw - stripW);
      final colX = left * 4;

      // Check how many columns in this strip are scrolling
      int scrollCols = 0;
      for (int c = 0; c < stripW; c++) {
        if (!fixedCols[left + c]) scrollCols++;
      }
      if (scrollCols < stripW ~/ 4) {
        _stripResults.add(_StripResult(colX: colX, dy: 0, zncc: 0, kept: false));
        continue;
      }

      // SAD search over [−maxDy, +maxDy] — find dy with minimum SAD
      int bestDy = 0; int bestSad = 0x7FFFFFFF;
      for (int d = -maxDy; d <= maxDy; d++) {
        if (d == 0) continue;
        if (wheelDelta != 0 && expectSign != 0 && d.sign != expectSign) continue;

        int aStart, bStart, overlap;
        if (d >= 0) { aStart = d; bStart = 0; overlap = roiH - d; }
        else        { aStart = 0; bStart = -d; overlap = roiH + d; }
        if (overlap < 8) continue;

        int sad = 0;
        for (int r = 0; r < overlap; r++) {
          final ar = (roiT + aStart + r) * dw + left;
          final br = (roiT + bStart + r) * dw + left;
          for (int c = 0; c < stripW; c++) {
            if (fixedCols[left + c]) continue;
            sad += (a[ar + c] - b[br + c]).abs();
          }
        }

        if (sad < bestSad) { bestSad = sad; bestDy = d; }
      }

      if (bestDy == 0) {
        _stripResults.add(_StripResult(colX: colX, dy: 0, zncc: 0, kept: false));
      } else {
        final score = bestSad > 0 ? 1.0 / bestSad : 1.0;
        _stripResults.add(_StripResult(colX: colX, dy: bestDy, zncc: score, kept: true));
        candidates.add(_StripResult(colX: colX, dy: bestDy, zncc: score, kept: true));
      }
    }

    if (candidates.isEmpty) return 0;
    if (candidates.length == 1) return candidates[0].dy;
    final inliers = _ransacConsensus(candidates, maxDy);
    if (inliers.isEmpty) return candidates[0].dy;
    inliers.sort((a, b) => a.dy.compareTo(b.dy));
    final medianDy = inliers[inliers.length ~/ 2].dy;

    // Update debug strip status
    for (int si = 0; si < _stripResults.length; si++) {
      final r = _stripResults[si];
      if (r.kept && !inliers.any((i) => i.colX == r.colX)) {
        _stripResults[si] = _StripResult(colX: r.colX, dy: r.dy, zncc: r.zncc, kept: false);
      }
    }

    dev.log('[stitch] sad ransac: ${inliers.length}/${candidates.length} inliers → dy=$medianDy');
    return medianDy;
  }

  /// Detect columns that are static (not scrolling) between consecutive frames.
  /// Returns a bool list of length [dw] with true for fixed columns.
  List<bool> _measureFixedCols(Uint8List a, Uint8List b, int dw, int roiT, int roiB) {
    final fixed = List<bool>.filled(dw, false);
    final roiH = roiB - roiT;
    for (int x = 0; x < dw; x++) {
      int totalDiff = 0;
      for (int r = roiT; r < roiB; r++) {
        totalDiff += (a[r * dw + x] - b[r * dw + x]).abs();
      }
      // A column that barely changed is likely static (e.g. sidebar, toolbar)
      // Threshold: avg < 3 grayscale levels per row
      if (totalDiff < roiH * 3) fixed[x] = true;
    }
    return fixed;
  }

  List<_StripResult> _ransacConsensus(List<_StripResult> candidates, int maxDy) {
    if (candidates.length < 2) return candidates.toList();
    const inlierThreshold = 2, iterations = 20, minInliers = 2;
    List<_StripResult> bestInliers = [];
    final rng = math.Random(42);
    for (int iter = 0; iter < iterations; iter++) {
      final i1 = rng.nextInt(candidates.length); int i2; do { i2 = rng.nextInt(candidates.length); } while (i2 == i1);
      final modelDy = (candidates[i1].dy + candidates[i2].dy) ~/ 2;
      final inliers = <_StripResult>[];
      for (final c in candidates) { if ((c.dy - modelDy).abs() <= inlierThreshold) inliers.add(c); }
      if (inliers.length >= minInliers && inliers.length > bestInliers.length) bestInliers = inliers;
    }
    return bestInliers;
  }

  // ── Debug overlay ──

  Uint8List _buildDebugOverlay(img.Image frame, int fw, int fh) {
    final gab = 4; // pixel gap between prev and curr
    final cw = fw * 2 + gab;
    final canvas = img.Image(width: cw, height: fh);

    final gre = img.ColorRgba8(0,255,0,180), cyan = img.ColorRgba8(0,200,255,220);
    final warm = img.ColorRgba8(255,120,80,160), yel = img.ColorRgba8(255,220,0,160);
    final wht = img.ColorRgba8(255,255,255,180);
    final newTop = img.ColorRgba8(40, 80, 255, 64);
    final newBot = img.ColorRgba8(255, 60, 140, 64);

    // Copy prev frame to left half
    if (_prevPng != null) {
      final prev = img.decodePng(_prevPng!);
      if (prev != null && prev.width == fw && prev.height == fh) {
        for (int y = 0; y < fh; y++) {
          for (int x = 0; x < fw; x++) {
            final p = prev.getPixel(x, y);
            canvas.setPixelRgba(x, y, (p.r as int), (p.g as int), (p.b as int), (p.a as int));
          }
        }
      }
    }

    // Copy curr frame to right half
    final rX = fw + gab;
    for (int y = 0; y < fh; y++) {
      for (int x = 0; x < fw; x++) {
        final p = frame.getPixel(x, y);
        canvas.setPixelRgba(rX + x, y, (p.r as int), (p.g as int), (p.b as int), (p.a as int));
      }
    }

    // Fill gap with dark divider
    for (int y = 0; y < fh; y++) {
      for (int x = fw; x < rX; x++) {
        canvas.setPixelRgba(x, y, 0, 0, 0, 255);
      }
    }

    // ── Helper: draw on right half (with rX offset) ──
    void hln(int y, img.ColorRgba8 c, {int dash = 0}) {
      for (int x = 0; x < fw; x++) {
        if (dash > 0 && (x ~/ dash) % 2 == 0) continue;
        if (y >= 0 && y < fh) canvas.setPixelRgba(rX + x, y, c.r, c.g, c.b, c.a);
      }
    }
    void vln(int x, img.ColorRgba8 c, int y0, int y1) {
      for (int y = y0.clamp(0,fh); y < y1.clamp(0,fh); y++) {
        if (x >= 0 && x < fw) canvas.setPixelRgba(rX + x, y, c.r, c.g, c.b, c.a);
      }
    }
    void rectH(int x, int y, int w2, int h2, img.ColorRgba8 c) {
      hln(y, c); hln(y + h2 - 1, c);
      vln(x, c, y, y + h2); vln(x + w2 - 1, c, y, y + h2);
    }
    void tintRows(int y0, int y1, img.ColorRgba8 c) {
      for (int y = y0.clamp(0, fh); y < y1.clamp(0, fh); y++) {
        for (int x = 0; x < fw; x++) {
          final p = canvas.getPixel(rX + x, y);
          final r = ((p.r as int) * (256 - c.a) + c.r * c.a) ~/ 256;
          final g = ((p.g as int) * (256 - c.a) + c.g * c.a) ~/ 256;
          final b = ((p.b as int) * (256 - c.a) + c.b * c.a) ~/ 256;
          canvas.setPixelRgba(rX + x, y, r, g, b, 255);
        }
      }
    }

    // ── Annotations on right (curr) half ──
    const sy = 1;
    if (_fixedTop > 0) hln(_fixedTop * sy - 1, gre);
    if (_fixedBot > 0) hln(fh - _fixedBot * sy, gre);
    final rY0 = _fixedTop * sy, rY1 = fh - _fixedBot * sy;
    if (rY1 > rY0) rectH(0, rY0, fw, rY1 - rY0, yel);

    // Strip columns
    for (final r in _stripResults) {
      final c = r.kept ? cyan : warm;
      vln(r.colX, c, rY0, rY1);
      vln(r.colX + 2, c, rY0, rY1);
    }

    // White dashed line at dy=0 reference
    final cy = fh ~/ 2;
    hln(cy, wht, dash: 8);

    // New region overlay
    final movingT = _fixedTop, movingB = fh - _fixedBot;
    if (_lastDy < 0) {
      final absDy = (-_lastDy).clamp(0, movingB - movingT);
      final y0 = (movingB - absDy).clamp(0, movingB);
      tintRows(y0, movingB, newBot);
      rectH(0, y0, fw, movingB - y0, img.ColorRgba8(255, 60, 140, 200));
    } else if (_lastDy > 0) {
      final absDy = _lastDy.clamp(0, movingB - movingT);
      final y1 = (movingT + absDy).clamp(0, movingB);
      tintRows(movingT, y1, newTop);
      rectH(0, movingT, fw, y1 - movingT, img.ColorRgba8(40, 80, 255, 200));
    }

    // ── Labels: "prev" top-left of left half, "curr" top-left of right half ──
    void drawSmallLabel(int rx, int ry, String s, img.ColorRgba8 c) {
      img.drawString(canvas, s, font: img.arial14, x: rx + 3, y: ry + 3, color: c);
      // tiny background
      final w2 = s.length * 8 + 6, h2 = 14 + 6;
      for (int y2 = ry; y2 < ry + h2 && y2 < fh; y2++) {
        for (int x = rx; x < rx + w2 && x < cw; x++) {
          if (y2 < ry + 2 || y2 >= ry + h2 - 2 || x < rx + 2 || x >= rx + w2 - 2) {
            canvas.setPixelRgba(x, y2, 0, 0, 0, 140);
          }
        }
      }
    }
    drawSmallLabel(4, 4, 'prev', gre);
    drawSmallLabel(rX + 4, 4, 'curr', cyan);

    // Dy / wheel text at top of right half (large, 3× scale)
    final dyStr = 'dy=$_lastDy';
    final tp = 4, lp = rX + 4, pad = 6;
    final txtH0 = 36 + pad * 2;
    void drawLabel(int line, String s, img.ColorRgba8 c) {
      final y0 = tp + line * (txtH0 + 3);
      final w2 = s.length * 24 + pad * 2;
      for (int y2 = y0; y2 < y0 + txtH0 && y2 < fh; y2++) {
        for (int x = lp; x < lp + w2 && x < cw; x++) {
          if (y2 < y0 + pad || y2 >= y0 + txtH0 - pad || x < lp + pad || x >= lp + w2 - pad) {
            canvas.setPixelRgba(x, y2, 0, 0, 0, 180);
          }
        }
      }
      img.drawString(canvas, s, font: img.arial48, x: lp + pad, y: y0 + pad, color: c);
    }
    drawLabel(0, dyStr, wht);
    if (_lastWheelDelta != 0) {
      final dir = _lastWheelDelta > 0 ? '↑' : '↓';
      drawLabel(1, 'wheel=$_lastWheelDelta $dir', _lastWheelDelta > 0 ? cyan : warm);
    }

    return Uint8List.fromList(img.encodePng(canvas));
  }

  void _invalidateStitch() { _stitchedPng = null; stitchedSize = null; }
}
