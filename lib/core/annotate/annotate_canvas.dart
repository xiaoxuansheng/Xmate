/// 标注画布
///
/// 统一处理标注绘制：显示层（CustomPainter）+ 导出层（共享 drawAnnotation）。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'annotate_toolbar.dart';
import 'annotate_models.dart';

/// Shared monotonic counter for both annotations and eraser masks.
/// Annotations get an order-id lazily on first paint; masks get one at creation.
int _sharedOrderCounter = 0;

/// Per-annotation order cache: first time an annotation id is seen in any
/// paint() cycle, it receives the next order-id from [_sharedOrderCounter].
/// This guarantees annotation-vs-mask sort keys come from the same counter
/// so they are directly comparable.
final Map<String, int> _annOrderCache = <String, int>{};

int getOrAssignAnnOrder(AnnotationShape a) {
  return _annOrderCache.putIfAbsent(a.id, () => ++_sharedOrderCounter);
}

/// Per-page variant: uses a caller-supplied cache map and counter closure
/// instead of the module-level globals.  PDF viewer uses this so each page
/// has an independent order counter.
int getOrAssignAnnOrderWithCache(
    AnnotationShape a, Map<String, int> cache, int Function() nextCounter) {
  return cache.putIfAbsent(a.id, () => nextCounter());
}

// ===== Eraser mask (blend-mode based) =====

/// An eraser stroke / region recorded when the user drags eraser.
/// During paint, every mask is drawn with [BlendMode.clear] on the annotation
/// layer so the base image shows through only where erased.
class EraserMask {
  final MosaicMode mode;
  final List<Offset>? points; // brush path (line mode)
  final Rect? rect;           // box / ellipse bounds
  final double cellSize;      // stroke width for brush, unused for rect/ellipse
  final int orderId;          // global creation order for time-interleaving

  EraserMask({this.mode = MosaicMode.line, this.points, this.rect, this.cellSize = 10.0})
      : orderId = ++_sharedOrderCounter;

  /// Per-page constructor: caller supplies an explicit order-id from a
  /// per-page counter.  PDF viewer uses this to keep each page's eraser
  /// masks independent.
  EraserMask.withOrderId(int orderId, {this.mode = MosaicMode.line, this.points, this.rect, this.cellSize = 10.0})
      : orderId = orderId;

  bool get isBrush => mode == MosaicMode.line && points != null && points!.length >= 2;
  bool get isRect => mode == MosaicMode.rect && rect != null;
  bool get isEllipse => mode == MosaicMode.ellipse && rect != null;
}

/// Draw a single eraser mask primitive with [BlendMode.clear] to punch
/// through the annotation layer to the background image.
void drawEraserMask(Canvas canvas, EraserMask m) {
  final clearPaint = Paint()..blendMode = BlendMode.clear;
  if (m.isBrush) {
    final pts = m.points!;
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (int j = 1; j < pts.length; j++) {
      path.lineTo(pts[j].dx, pts[j].dy);
    }
    canvas.drawPath(path,
        Paint()
          ..blendMode = BlendMode.clear
          ..style = PaintingStyle.stroke
          ..strokeWidth = m.cellSize
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round);
  } else if (m.isRect) {
    canvas.drawRect(m.rect!, clearPaint);
  } else if (m.isEllipse) {
    canvas.drawOval(m.rect!, clearPaint);
  }
}

// ===== Annotation edit handle type =====

enum AnnHandle { move, tl, tr, bl, br, rotate }

/// Point-in-convex-quadrilateral test. Returns true if [p] is inside quad [q].
/// Quad vertices must be in clockwise or counter-clockwise order.
bool _pointInQuad(Offset p, List<Offset> q) {
  // Cross-product sign consistency check (all same sign → inside)
  int pos = 0, neg = 0;
  for (int i = 0; i < 4; i++) {
    final a = q[i];
    final b = q[(i + 1) % 4];
    final cross = (b.dx - a.dx) * (p.dy - a.dy) - (b.dy - a.dy) * (p.dx - a.dx);
    if (cross > 0) pos++;
    if (cross < 0) neg++;
    if (pos > 0 && neg > 0) return false;
  }
  return true;
}

// ===== Annotation helpers (hit-test, bounds, translate) =====

/// Compute axis-aligned bounding box of a rotated rectangle.
Rect _rotRectBounds(Rect r, double angle) {
  if (angle.abs() < 0.001) return r;
  final cx = r.center.dx, cy = r.center.dy;
  final cosA = math.cos(angle), sinA = math.sin(angle);
  final corners = [
    Offset(r.left, r.top), Offset(r.right, r.top),
    Offset(r.right, r.bottom), Offset(r.left, r.bottom),
  ].map((p) {
    final dx = p.dx - cx, dy = p.dy - cy;
    return Offset(cx + dx * cosA - dy * sinA, cy + dx * sinA + dy * cosA);
  });
  double l = corners.first.dx, t = corners.first.dy,
         ri = l, b = t;
  for (final c in corners) {
    l = math.min(l, c.dx); t = math.min(t, c.dy);
    ri = math.max(ri, c.dx); b = math.max(b, c.dy);
  }
  return Rect.fromLTRB(l, t, ri, b);
}

/// Return rotated corners of [r] around its center by [angle] radians.
/// Order: topLeft, topRight, bottomRight, bottomLeft.
List<Offset> _rotRectCorners(Rect r, double angle) {
  if (angle.abs() < 0.001) {
    return [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];
  }
  final cx = r.center.dx, cy = r.center.dy;
  final cosA = math.cos(angle), sinA = math.sin(angle);
  return [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft].map((p) {
    final dx = p.dx - cx, dy = p.dy - cy;
    return Offset(cx + dx * cosA - dy * sinA, cy + dx * sinA + dy * cosA);
  }).toList();
}

/// Point-in-convex-polygon test (ray casting).
bool _pointInPolygon(Offset p, List<Offset> poly) {
  bool inside = false;
  for (int i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    if ((poly[i].dy > p.dy) != (poly[j].dy > p.dy) &&
        p.dx <
            (poly[j].dx - poly[i].dx) * (p.dy - poly[i].dy) /
                    (poly[j].dy - poly[i].dy) +
                poly[i].dx) {
      inside = !inside;
    }
  }
  return inside;
}

/// Stroke/fill-aware hit test for RectAnnotation.
/// - Transforms [p] to local (unrotated) space.
/// - If fill is enabled: path-interior hit.
/// - If fill is disabled: only stroke-edge hit (annular region).
bool _hitTestRectAnn(RectAnnotation a, Offset p) {
  final raw = Rect.fromLTWH(a.x, a.y, a.w, a.h);
  final cx = raw.center.dx, cy = raw.center.dy;

  // Un-rotate p into the shape's local space
  double lpx, lpy;
  if (a.rotation.abs() > 0.001) {
    final cosA = math.cos(-a.rotation), sinA = math.sin(-a.rotation);
    final dx = p.dx - cx, dy = p.dy - cy;
    lpx = cx + dx * cosA - dy * sinA;
    lpy = cy + dx * sinA + dy * cosA;
  } else {
    lpx = p.dx; lpy = p.dy;
  }
  final lp = Offset(lpx, lpy);

  final hasFill = a.fillStyle == FillStyle.solid;
  final halfSw = a.strokeWidth / 2 + 4; // half stroke + hit margin

  switch (a.shapeKind) {
    case ShapeKind.rectangle:
    case ShapeKind.roundedRectangle:
      final outer = raw.inflate(halfSw);
      if (!outer.contains(lp)) return false;
      if (hasFill) return true; // fill mode: any interior point counts
      // Stroke-only: must be outside inner rect
      final inner = raw.inflate(-halfSw);
      return !inner.contains(lp);

    case ShapeKind.ellipse:
      final erx = raw.width / 2 + halfSw;
      final ery = raw.height / 2 + halfSw;
      final eccx = raw.center.dx, eccy = raw.center.dy;
      final ex = (lpx - eccx) / erx;
      final ey = (lpy - eccy) / ery;
      final eOuter = ex * ex + ey * ey;
      if (eOuter > 1.0) return false;
      if (hasFill) return true;
      // Stroke-only: must be outside inner ellipse
      final irx = math.max(0.0, raw.width / 2 - halfSw);
      final iry = math.max(0.0, raw.height / 2 - halfSw);
      if (irx <= 0 || iry <= 0) return true; // degenerate inner → all outer counts
      final ix = (lpx - eccx) / irx;
      final iy = (lpy - eccy) / iry;
      final eInner = ix * ix + iy * iy;
      return eInner > 1.0;
  }
}

/// Get bounding rect for an annotation (logical coordinates).
Rect getAnnBounds(AnnotationShape a) {
  if (a is RectAnnotation) {
    final raw = Rect.fromLTWH(a.x, a.y, a.w, a.h);
    return _rotRectBounds(raw, a.rotation);
  }
  if (a is ArrowAnnotation) {
    return Rect.fromPoints(Offset(a.fromX, a.fromY), Offset(a.toX, a.toY));
  }
  if (a is FreehandAnnotation) {
    if (a.points.isEmpty) return Rect.zero;
    double l = a.points.first.dx, t = a.points.first.dy,
        r = l, b = t;
    for (final p in a.points) {
      l = math.min(l, p.dx); t = math.min(t, p.dy);
      r = math.max(r, p.dx); b = math.max(b, p.dy);
    }
    return Rect.fromLTRB(l, t, r, b);
  }
  if (a is TextAnnotation) {
    final tp = TextPainter(
      text: TextSpan(text: a.text, style: TextStyle(
        fontSize: a.fontSize,
        fontWeight: a.bold ? FontWeight.bold : FontWeight.normal,
        fontStyle: a.italic ? FontStyle.italic : FontStyle.normal,
        fontFamily: a.fontFamily,
      )),
      textDirection: TextDirection.ltr,
    )..layout();
    double w = tp.width, h = tp.height;
    if (a.outline) { w += 2; h += 2; }
    return Rect.fromLTWH(a.x, a.y, w, h);
  }
  if (a is NumberTagAnnotation) {
    final r = a.fontSize;
    return Rect.fromCenter(
        center: Offset(a.x, a.y), width: r * 2, height: r * 2);
  }
  if (a is MosaicAnnotation) {
    if (a.rect != null) return a.rect!;
    if (a.points != null && a.points!.isNotEmpty) {
      double l = a.points!.first.dx, t = a.points!.first.dy,
          r = l, b = t;
      for (final p in a.points!) {
        l = math.min(l, p.dx); t = math.min(t, p.dy);
        r = math.max(r, p.dx); b = math.max(b, p.dy);
      }
      return Rect.fromLTRB(l, t, r, b);
    }
    return Rect.zero;
  }
  return Rect.zero;
}

/// Point-to-segment distance.
double _distToSeg(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final ap = p - a;
  final t = (ap.dx * ab.dx + ap.dy * ab.dy) / (ab.dx * ab.dx + ab.dy * ab.dy);
  final tc = t.clamp(0.0, 1.0);
  final proj = Offset(a.dx + tc * ab.dx, a.dy + tc * ab.dy);
  return (p - proj).distance;
}

/// Hit-test: find the topmost annotation at [p]. Returns null if none.
AnnotationShape? hitTestAnnotation(List<AnnotationShape> anns, Offset p) {
  for (int i = anns.length - 1; i >= 0; i--) {
    final a = anns[i];
    if (a is RectAnnotation) {
      if (_hitTestRectAnn(a, p)) return a;
    } else if (a is ArrowAnnotation) {
      if (_distToSeg(p, Offset(a.fromX, a.fromY), Offset(a.toX, a.toY)) < 10) {
        return a;
      }
    } else if (a is FreehandAnnotation && a.points.length >= 2) {
      for (int j = 0; j < a.points.length - 1; j++) {
        if (_distToSeg(p, a.points[j], a.points[j + 1]) < 8) return a;
      }
    } else if (a is TextAnnotation) {
      final b = getAnnBounds(a);
      if (b.inflate(6).contains(p)) return a;
    } else if (a is NumberTagAnnotation) {
      final r = a.fontSize + 6;
      if ((p - Offset(a.x, a.y)).distance < r) return a;
    } else if (a is MosaicAnnotation) {
      final b = getAnnBounds(a);
      if (b.inflate(6).contains(p)) return a;
    }
  }
  return null;
}

/// Return the unrotated axis-aligned bounding rect for [a].
/// This is the rect whose corners are rotated by [a.rotation] during rendering.
Rect _getUnrotatedRect(AnnotationShape a) {
  if (a is RectAnnotation) {
    return Rect.fromLTWH(a.x, a.y, a.w, a.h);
  }
  if (a is ArrowAnnotation) {
    return Rect.fromPoints(
        Offset(a.fromX, a.fromY), Offset(a.toX, a.toY));
  }
  if (a is TextAnnotation) {
    // Use same measurement as getAnnBounds but without outline inflation for
    // the raw rect — then handle inflation belongs to getAnnBounds callers.
    final tp = TextPainter(
      text: TextSpan(text: a.text, style: TextStyle(
        fontSize: a.fontSize,
        fontWeight: a.bold ? FontWeight.bold : FontWeight.normal,
        fontStyle: a.italic ? FontStyle.italic : FontStyle.normal,
        fontFamily: a.fontFamily,
      )),
      textDirection: TextDirection.ltr,
    )..layout();
    return Rect.fromLTWH(a.x, a.y, tp.width, tp.height);
  }
  if (a is FreehandAnnotation) {
    if (a.points.isEmpty) return Rect.zero;
    double l = a.points.first.dx, t = a.points.first.dy,
        r = l, b = t;
    for (final p in a.points) {
      l = math.min(l, p.dx); t = math.min(t, p.dy);
      r = math.max(r, p.dx); b = math.max(b, p.dy);
    }
    return Rect.fromLTRB(l, t, r, b);
  }
  return getAnnBounds(a);
}

/// Build rotation-handle hit-test geometry for a shape with unrotated [raw]
/// rect and [rotation] angle. Returns (corners, topMid, rotH).
({List<Offset> corners, Offset topMid, Offset rotH}) _handlesGeometry(
    Rect raw, double rotation) {
  final corners = _rotRectCorners(raw, rotation); // tl tr br bl
  final topMid = Offset((corners[1].dx + corners[0].dx) / 2,
      (corners[1].dy + corners[0].dy) / 2);
  final cx = raw.center.dx, cy = raw.center.dy;
  final dx = topMid.dx - cx, dy = topMid.dy - cy;
  final outLen = 20.0 / math.sqrt(dx * dx + dy * dy + 0.001);
  final rotH = Offset(topMid.dx + dx * outLen, topMid.dy + dy * outLen);
  return (corners: corners, topMid: topMid, rotH: rotH);
}

/// Hit-test an annotation's edit handles using rotation-aware geometry.
/// All types (Rect, Arrow, Text, Freehand) use rotated corners.
AnnHandle? hitTestAnnHandle(AnnotationShape a, Offset p, {double scale = 1.0}) {
  final hs = 10.0 * scale; // hit radius, scaled for zoom level

  // Only handle-able types
  if (a is! RectAnnotation &&
      a is! ArrowAnnotation &&
      a is! TextAnnotation &&
      a is! FreehandAnnotation &&
      a is! NumberTagAnnotation) {
    return null;
  }

  final raw = _getUnrotatedRect(a);
  final geo = _handlesGeometry(raw, a.rotation);
  final corners = geo.corners;
  final rotH = geo.rotH;

  if ((p - rotH).distance < hs) return AnnHandle.rotate;
  if ((p - corners[0]).distance < hs) return AnnHandle.tl;
  if ((p - corners[1]).distance < hs) return AnnHandle.tr;
  if ((p - corners[2]).distance < hs) return AnnHandle.br;
  if ((p - corners[3]).distance < hs) return AnnHandle.bl;
  if (_pointInPolygon(p, corners)) return AnnHandle.move;
  return null;
}

/// Translate an annotation by (dx, dy), returning a new instance.
AnnotationShape translateAnn(AnnotationShape a, double dx, double dy) {
  if (a is RectAnnotation) {
    return RectAnnotation(
      x: a.x + dx, y: a.y + dy, w: a.w, h: a.h,
      color: a.color, strokeWidth: a.strokeWidth,
      shapeKind: a.shapeKind, cornerRadius: a.cornerRadius,
      fillStyle: a.fillStyle, fillColor: a.fillColor,
      lineStyle: a.lineStyle, id: a.id,
    )..rotation = a.rotation;
  }
  if (a is ArrowAnnotation) {
    return ArrowAnnotation(
      fromX: a.fromX + dx, fromY: a.fromY + dy,
      toX: a.toX + dx, toY: a.toY + dy,
      color: a.color, strokeWidth: a.strokeWidth,
      startHead: a.startHead, endHead: a.endHead,
      lineStyle: a.lineStyle, id: a.id,
    )..rotation = a.rotation;
  }
  if (a is TextAnnotation) {
    return TextAnnotation(
      x: a.x + dx, y: a.y + dy, text: a.text,
      color: a.color, fontSize: a.fontSize,
      bold: a.bold, italic: a.italic, outline: a.outline,
      fontFamily: a.fontFamily, textStyleKind: a.textStyleKind,
      id: a.id,
    )..rotation = a.rotation;
  }
  if (a is FreehandAnnotation) {
    return FreehandAnnotation(
      points: a.points.map((p) => Offset(p.dx + dx, p.dy + dy)).toList(),
      color: a.color, strokeWidth: a.strokeWidth,
      lineStyle: a.lineStyle, id: a.id,
    )..rotation = a.rotation;
  }
  if (a is NumberTagAnnotation) {
    return NumberTagAnnotation(
      x: a.x + dx, y: a.y + dy, number: a.number,
      color: a.color, style: a.style, fontSize: a.fontSize,
      id: a.id,
    )..rotation = a.rotation;
  }
  if (a is MosaicAnnotation) {
    return MosaicAnnotation(
      mode: a.mode,
      rect: a.rect?.translate(dx, dy),
      points: a.points?.map((p) => Offset(p.dx + dx, p.dy + dy)).toList(),
      cellSize: a.cellSize, effect: a.effect, id: a.id,
    )..rotation = a.rotation;
  }
  return a;
}

/// Resize an annotation by dragging handle [h] by [delta].
/// When [keepAspect] is true, maintains [baseBounds] aspect ratio.
AnnotationShape resizeAnn(AnnotationShape a, AnnHandle h, Offset delta,
    Rect baseBounds, {bool keepAspect = false}) {
  if (a is RectAnnotation) {
    if (keepAspect && baseBounds.width > 0 && baseBounds.height > 0) {
      // Compute free new w/h from base (which equals a's raw w/h)
      double freeW, freeH;
      switch (h) {
        case AnnHandle.tl:
          freeW = baseBounds.width - delta.dx;
          freeH = baseBounds.height - delta.dy;
        case AnnHandle.tr:
          freeW = baseBounds.width + delta.dx;
          freeH = baseBounds.height - delta.dy;
        case AnnHandle.bl:
          freeW = baseBounds.width - delta.dx;
          freeH = baseBounds.height + delta.dy;
        case AnnHandle.br:
          freeW = baseBounds.width + delta.dx;
          freeH = baseBounds.height + delta.dy;
        default: return a;
      }
      // Dominant axis determines uniform scale
      final sW = freeW / baseBounds.width;
      final sH = freeH / baseBounds.height;
      final s = (sW - 1).abs() >= (sH - 1).abs() ? sW : sH;
      if (s <= 0.1) return a;
      double dx = 0, dy = 0;
      switch (h) {
        case AnnHandle.tl:
          dx = baseBounds.width * (1 - s);
          dy = baseBounds.height * (1 - s);
        case AnnHandle.tr:
          dy = baseBounds.height * (1 - s);
        case AnnHandle.bl:
          dx = baseBounds.width * (1 - s);
        case AnnHandle.br:
          break;
        default: return a;
      }
      return _scaleAnn(a, s, s,
          baseBounds.left, baseBounds.top, dx, dy);
    }
    // Free resize (no aspect lock)
    double x = a.x, y = a.y, w = a.w, hh = a.h;
    switch (h) {
      case AnnHandle.tl:
        x += delta.dx; y += delta.dy; w -= delta.dx; hh -= delta.dy;
      case AnnHandle.tr:
        y += delta.dy; w += delta.dx; hh -= delta.dy;
      case AnnHandle.bl:
        x += delta.dx; w -= delta.dx; hh += delta.dy;
      case AnnHandle.br:
        w += delta.dx; hh += delta.dy;
      default: return a;
    }
    if (w < 5) w = 5;
    if (hh < 5) hh = 5;
    return RectAnnotation(
      x: x, y: y, w: w, h: hh,
      color: a.color, strokeWidth: a.strokeWidth,
      shapeKind: a.shapeKind, cornerRadius: a.cornerRadius,
      fillStyle: a.fillStyle, fillColor: a.fillColor,
      lineStyle: a.lineStyle, id: a.id,
    )..rotation = a.rotation;
  }
  // For other types, scale by bounding rect delta
  final oldW = baseBounds.width;
  final oldH = baseBounds.height;
  if (oldW <= 0 || oldH <= 0) return a;
  double sx = 1, sy = 1, dx = 0, dy = 0;

  if (keepAspect) {
    // Uniform scale: dominant axis determines s
    double freeW, freeH;
    switch (h) {
      case AnnHandle.tl:
        freeW = oldW - delta.dx; freeH = oldH - delta.dy;
      case AnnHandle.tr:
        freeW = oldW + delta.dx; freeH = oldH - delta.dy;
      case AnnHandle.bl:
        freeW = oldW - delta.dx; freeH = oldH + delta.dy;
      case AnnHandle.br:
        freeW = oldW + delta.dx; freeH = oldH + delta.dy;
      default: return a;
    }
    final sW = freeW / oldW;
    final sH = freeH / oldH;
    final s = (sW - 1).abs() >= (sH - 1).abs() ? sW : sH;
    if (s <= 0.1) return a;
    sx = s; sy = s;
    switch (h) {
      case AnnHandle.tl:
        dx = oldW * (1 - s); dy = oldH * (1 - s);
      case AnnHandle.tr:
        dy = oldH * (1 - s);
      case AnnHandle.bl:
        dx = oldW * (1 - s);
      case AnnHandle.br:
        break;
      default: return a;
    }
  } else {
    switch (h) {
      case AnnHandle.tl:
        sx = (oldW - delta.dx) / oldW; sy = (oldH - delta.dy) / oldH;
        dx = delta.dx; dy = delta.dy;
      case AnnHandle.tr:
        sx = (oldW + delta.dx) / oldW; sy = (oldH - delta.dy) / oldH;
        dy = delta.dy;
      case AnnHandle.bl:
        sx = (oldW - delta.dx) / oldW; sy = (oldH + delta.dy) / oldH;
        dx = delta.dx;
      case AnnHandle.br:
        sx = (oldW + delta.dx) / oldW; sy = (oldH + delta.dy) / oldH;
      default: return a;
    }
  }
  if (sx < 0.1) sx = 0.1;
  if (sy < 0.1) sy = 0.1;
  final ox = baseBounds.left;
  final oy = baseBounds.top;
  return _scaleAnn(a, sx, sy, ox, oy, dx, dy);
}

AnnotationShape _scaleAnn(
    AnnotationShape a, double sx, double sy, double ox, double oy,
    double dx, double dy) {
  Offset scalePt(Offset p) =>
      Offset(ox + (p.dx - ox) * sx + dx, oy + (p.dy - oy) * sy + dy);

  if (a is RectAnnotation) {
    final tl = scalePt(Offset(a.x, a.y));
    final br = scalePt(Offset(a.x + a.w, a.y + a.h));
    return RectAnnotation(
      x: tl.dx, y: tl.dy, w: br.dx - tl.dx, h: br.dy - tl.dy,
      color: a.color, strokeWidth: a.strokeWidth,
      shapeKind: a.shapeKind, cornerRadius: a.cornerRadius,
      fillStyle: a.fillStyle, fillColor: a.fillColor,
      lineStyle: a.lineStyle, id: a.id,
    )..rotation = a.rotation;
  }
  if (a is ArrowAnnotation) {
    return ArrowAnnotation(
      fromX: scalePt(Offset(a.fromX, a.fromY)).dx,
      fromY: scalePt(Offset(a.fromX, a.fromY)).dy,
      toX: scalePt(Offset(a.toX, a.toY)).dx,
      toY: scalePt(Offset(a.toX, a.toY)).dy,
      color: a.color, strokeWidth: a.strokeWidth,
      startHead: a.startHead, endHead: a.endHead,
      lineStyle: a.lineStyle, id: a.id,
    )..rotation = a.rotation;
  }
  if (a is FreehandAnnotation) {
    return FreehandAnnotation(
      points: a.points.map(scalePt).toList(),
      color: a.color, strokeWidth: a.strokeWidth,
      lineStyle: a.lineStyle, id: a.id,
    )..rotation = a.rotation;
  }
  if (a is TextAnnotation) {
    final p = scalePt(Offset(a.x, a.y));
    // Use the dominant axis scale so dragging any handle changes font size
    final fs = (sx - 1).abs() > (sy - 1).abs() ? sx : sy;
    return TextAnnotation(
      x: p.dx, y: p.dy, text: a.text, color: a.color,
      fontSize: math.max(8, (a.fontSize * fs).roundToDouble()),
      bold: a.bold, italic: a.italic, outline: a.outline,
      fontFamily: a.fontFamily, textStyleKind: a.textStyleKind,
      id: a.id,
    )..rotation = a.rotation;
  }
  if (a is NumberTagAnnotation) {
    final p = scalePt(Offset(a.x, a.y));
    return NumberTagAnnotation(
      x: p.dx, y: p.dy, number: a.number,
      color: a.color, style: a.style,
      fontSize: math.max(8, (a.fontSize * sy).roundToDouble()),
      id: a.id,
    )..rotation = a.rotation;
  }
  return a;
}

/// Rotate an annotation around its bounding rect center by [da] radians.
///
/// Pure 2D planar rotation: increments the rotation field without changing
/// positional coordinates. Canvas rendering applies the stored rotation.
AnnotationShape rotateAnn(AnnotationShape a, double da) {
  final total = a.rotation + da;
  if (a is RectAnnotation) {
    return RectAnnotation(
      x: a.x, y: a.y, w: a.w, h: a.h,
      color: a.color, strokeWidth: a.strokeWidth,
      shapeKind: a.shapeKind, cornerRadius: a.cornerRadius,
      fillStyle: a.fillStyle, fillColor: a.fillColor,
      lineStyle: a.lineStyle, id: a.id,
    )..rotation = total;
  }
  if (a is ArrowAnnotation) {
    return ArrowAnnotation(
      fromX: a.fromX, fromY: a.fromY, toX: a.toX, toY: a.toY,
      color: a.color, strokeWidth: a.strokeWidth,
      startHead: a.startHead, endHead: a.endHead,
      lineStyle: a.lineStyle, id: a.id,
    )..rotation = total;
  }
  if (a is FreehandAnnotation) {
    return FreehandAnnotation(
      points: a.points, color: a.color,
      strokeWidth: a.strokeWidth, lineStyle: a.lineStyle, id: a.id,
    )..rotation = total;
  }
  if (a is TextAnnotation) {
    return TextAnnotation(
      x: a.x, y: a.y, text: a.text, color: a.color,
      fontSize: a.fontSize, bold: a.bold, italic: a.italic,
      outline: a.outline, fontFamily: a.fontFamily,
      textStyleKind: a.textStyleKind, id: a.id,
    )..rotation = total;
  }
  return a;
}

/// Resize an annotation so its bounding box matches [targetBounds].
///
/// Computes scale factors from the current bounds to [targetBounds] and
/// delegates to [_scaleAnn]. Useful for keyboard/mouse-wheel resize where
/// the caller knows the desired final rect rather than a handle delta.
AnnotationShape resizeAnnToBounds(AnnotationShape a, Rect targetBounds) {
  final oldBounds = getAnnBounds(a);
  if (oldBounds.width <= 0 || oldBounds.height <= 0) return a;
  final sx = targetBounds.width / oldBounds.width;
  final sy = targetBounds.height / oldBounds.height;
  if (sx < 0.1 || sy < 0.1) return a;
  final dx = targetBounds.left - oldBounds.left;
  final dy = targetBounds.top - oldBounds.top;
  return _scaleAnn(a, sx, sy, oldBounds.left, oldBounds.top, dx, dy);
}

// ===== Widget =====

class AnnotateCanvas extends StatelessWidget {
  final ui.Image image;
  final Uint8List? imageRgba;
  final Rect? selection;
  final bool showSelectionHandles;
  final List<AnnotationShape> annotations;
  final List<EraserMask> eraserMasks;
  final AnnotationTool previewTool;
  final Offset? previewStart;
  final Offset? previewCurrent;
  final List<Offset> previewFreehand;
  final Color previewColor;
  final double previewStrokeWidth;
  final ToolOptions previewOptions;
  final String? selectedAnnotationId;
  /// IDs of all annotations to highlight as multi-selected (Ctrl+A).
  final Set<String> selectedAnnotationIds;
  /// Hover snap-to-window preview rect (null when inactive). Drawn as a
  /// semi-transparent blue fill with dashed white border.
  final Rect? snapPreviewRect;

  /// Whether to draw crosshair lines (selection centre lines).
  final bool showCrosshair;
  /// Rect that defines the crosshair centre (typically [_sel]).
  final Rect? crosshairRect;

  /// Window partition rects — blue-bordered overlay drawn on canvas.
  /// Coordinates are widget-logical pixels.  Only visible during selecting.
  final List<WindowRectEntry> windowPartitionRects;

  const AnnotateCanvas({
    super.key,
    required this.image,
    this.imageRgba,
    this.selection,
    this.showSelectionHandles = false,
    this.annotations = const [],
    this.eraserMasks = const [],
    this.previewTool = AnnotationTool.mouse,
    this.previewStart,
    this.previewCurrent,
    this.previewFreehand = const [],
    this.previewColor = Colors.red,
    this.previewStrokeWidth = 2.0,
    this.previewOptions = const ToolOptions(),
    this.selectedAnnotationId,
    this.selectedAnnotationIds = const {},
    this.snapPreviewRect,
    this.showCrosshair = false,
    this.crosshairRect,
    this.windowPartitionRects = const [],
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _AnnotationPainter(
          image: image,
          imageRgba: imageRgba,
          selection: selection,
          showSelectionHandles: showSelectionHandles,
          annotations: annotations,
          eraserMasks: eraserMasks,
          previewTool: previewTool,
          previewStart: previewStart,
          previewCurrent: previewCurrent,
          previewFreehand: previewFreehand,
          previewColor: previewColor,
          previewStrokeWidth: previewStrokeWidth,
          previewOptions: previewOptions,
          selectedAnnotationId: selectedAnnotationId,
          selectedAnnotationIds: selectedAnnotationIds,
          snapPreviewRect: snapPreviewRect,
          showCrosshair: showCrosshair,
          crosshairRect: crosshairRect,
          windowPartitionRects: windowPartitionRects,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

// ===== Painter =====

class _AnnotationPainter extends CustomPainter {
  final ui.Image image;
  final Uint8List? imageRgba;
  final Rect? selection;
  final bool showSelectionHandles;
  final List<AnnotationShape> annotations;
  final List<EraserMask> eraserMasks;
  final AnnotationTool previewTool;
  final Offset? previewStart;
  final Offset? previewCurrent;
  final List<Offset> previewFreehand;
  final Color previewColor;
  final double previewStrokeWidth;
  final ToolOptions previewOptions;
  final String? selectedAnnotationId;
  final Set<String> selectedAnnotationIds;
  final Rect? snapPreviewRect;
  final bool showCrosshair;
  final Rect? crosshairRect;
  final List<WindowRectEntry> windowPartitionRects;

  static const _handleSize = 8.0;

  _AnnotationPainter({
    required this.image,
    this.imageRgba,
    this.selection,
    this.showSelectionHandles = false,
    required this.annotations,
    this.eraserMasks = const [],
    this.previewTool = AnnotationTool.mouse,
    this.previewStart,
    this.previewCurrent,
    this.previewFreehand = const [],
    this.previewColor = Colors.red,
    this.previewStrokeWidth = 2.0,
    this.previewOptions = const ToolOptions(),
    this.selectedAnnotationId,
    this.selectedAnnotationIds = const {},
    this.snapPreviewRect,
    this.showCrosshair = false,
    this.crosshairRect,
    this.windowPartitionRects = const [],
  });
  // (end _AnnotationPainter constructor)

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Background image
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint(),
    );

    // 1a. (scroll-screenshot region overlay removed — hole is permanent now)

    // 1.5. Window partition rects — blue border overlay + rank label
    if (windowPartitionRects.isNotEmpty) {
      final borderPaint = Paint()
        ..color = const Color(0xFF4DA3FF)
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke;
      final fillPaint = Paint()
        ..color = const Color(0x154DA3FF)
        ..style = PaintingStyle.fill;
      final rankStyle = TextStyle(
        color: Colors.white.withAlpha(220),
        fontSize: 9,
        fontFamily: 'Consolas',
        backgroundColor: const Color(0xAA4DA3FF),
        height: 1.1,
      );
      for (final e in windowPartitionRects) {
        final r = e.rect;
        if (r.width > 2 && r.height > 2) {
          canvas.drawRect(r, fillPaint);
          canvas.drawRect(r, borderPaint);
          // Rank label at top-left corner
          final rp = TextPainter(
            text: TextSpan(text: 'R${e.rank}', style: rankStyle),
            textDirection: TextDirection.ltr,
          )..layout();
          rp.paint(canvas, Offset(r.left + 1, r.top + 1));
        }
      }
    }

    // 2. Selection overlay + border + handles
    if (selection != null) {
      _drawSelectionOverlay(canvas, size, selection!);
    }

    // 3. Interleave annotations + eraser masks by creation order.
    // Annotations get an order-id on first paint from the same global counter
    // that EraserMask uses.  This guarantees directly comparable sort keys.
    // Mask drawn after ann → clears it.
    // Ann drawn after mask → appears above (not spuriously erased).
    final ops = <MapEntry<int, Object>>[];
    for (final a in annotations) {
      ops.add(MapEntry(getOrAssignAnnOrder(a), a));
    }
    for (final m in eraserMasks) {
      ops.add(MapEntry(m.orderId, m));
    }
    ops.sort((x, y) => x.key.compareTo(y.key));

    final annLayerBounds = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.saveLayer(annLayerBounds, Paint());
    for (final op in ops) {
      final v = op.value;
      if (v is AnnotationShape) {
        drawAnnotation(canvas, v, image: image, widgetSize: size, imageRgba: imageRgba);
      } else if (v is EraserMask) {
        drawEraserMask(canvas, v);
      }
    }
    canvas.restore();

    // 4. Selected annotation handles (drawn above erased areas for usability)
    if (selectedAnnotationId != null) {
      final sel = annotations.cast<AnnotationShape?>().firstWhere(
          (a) => a!.id == selectedAnnotationId,
          orElse: () => null);
      if (sel != null) _drawAnnHandles(canvas, sel);
    }

    // 4b. Multi-select highlights (light cyan border on all in the set)
    if (selectedAnnotationIds.isNotEmpty) {
      for (final a in annotations) {
        if (!selectedAnnotationIds.contains(a.id)) continue;
        if (a.id == selectedAnnotationId) continue; // skip the one with full handles
        final bounds = getAnnBounds(a);
        canvas.drawRect(
          bounds.inflate(2),
          Paint()
            ..style = PaintingStyle.stroke
            ..color = const Color(0x664FC3F7)
            ..strokeWidth = 1.0,
        );
      }
    }

    // 5. Current drawing preview
    _drawPreview(canvas);

    // 6. Snap-to-window hover preview (draw on top of everything)
    if (snapPreviewRect != null) {
      _drawSnapPreview(canvas, snapPreviewRect!);
    }

    // 7. Crosshair (selection centre lines, toggled by Shift in annotating phase)
    if (showCrosshair && crosshairRect != null) {
      _drawCrosshair(canvas, crosshairRect!, size);
    }
  }

  void _drawSelectionOverlay(Canvas canvas, Size size, Rect sel) {
    // Normalize: guarantee non-negative width/height so the four corner-based
    // dark masks always cover the correct areas — even when the user drags a
    // handle past the opposite edge.
    final n = Rect.fromLTRB(
      math.min(sel.left, sel.right),
      math.min(sel.top, sel.bottom),
      math.max(sel.left, sel.right),
      math.max(sel.top, sel.bottom),
    );
    final m = Paint()..color = Colors.black.withAlpha(130);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, n.top), m);
    canvas.drawRect(
        Rect.fromLTWH(0, n.bottom, size.width, size.height - n.bottom), m);
    canvas.drawRect(Rect.fromLTWH(0, n.top, n.left, n.height), m);
    canvas.drawRect(
        Rect.fromLTWH(n.right, n.top, size.width - n.right, n.height), m);
    canvas.drawRect(n,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);

    if (showSelectionHandles) {
      for (final pt in [
        n.topLeft,
        n.topRight,
        n.bottomLeft,
        n.bottomRight
      ]) {
        canvas.drawRect(
          Rect.fromCenter(center: pt, width: _handleSize, height: _handleSize),
          Paint()..color = Colors.white..style = PaintingStyle.fill,
        );
        canvas.drawRect(
          Rect.fromCenter(center: pt, width: _handleSize, height: _handleSize),
          Paint()
            ..color = Colors.black54
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
    }
  }

  /// Draw edit handles for the selected annotation.
  /// Uses rotation-aware geometry for all editable types.
  void _drawAnnHandles(Canvas canvas, AnnotationShape a) {
    if (a is! RectAnnotation &&
        a is! ArrowAnnotation &&
        a is! TextAnnotation &&
        a is! FreehandAnnotation &&
        a is! NumberTagAnnotation) {
      return;
    }

    final raw = _getUnrotatedRect(a);
    final geo = _handlesGeometry(raw, a.rotation);
    final corners = geo.corners;
    final topMid = geo.topMid;
    final rotH = geo.rotH;

    final hp = Paint()..color = Colors.white..style = PaintingStyle.fill;
    final hs = Paint()
      ..color = const Color(0xFF4FC3F7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    const s = 8.0;

    // Rotated bbox polygon
    final bboxPath = Path()..moveTo(corners[0].dx, corners[0].dy);
    for (int i = 1; i < corners.length; i++) {
      bboxPath.lineTo(corners[i].dx, corners[i].dy);
    }
    bboxPath.close();
    canvas.drawPath(bboxPath, Paint()
      ..color = const Color(0xFF4FC3F7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);

    // Corner handles
    for (int i = 0; i < 4; i++) {
      canvas.drawRect(
          Rect.fromCenter(center: corners[i], width: s, height: s), hp);
      canvas.drawRect(
          Rect.fromCenter(center: corners[i], width: s, height: s), hs);
    }

    // Rotation handle: line + circle
    canvas.drawLine(topMid, rotH, Paint()
      ..color = const Color(0xFF4FC3F7)
      ..strokeWidth = 1.5);
    canvas.drawCircle(rotH, 5, hp);
    canvas.drawCircle(rotH, 5, hs);
  }

  void _drawPreview(Canvas canvas) {
    final ds = previewStart;
    final dc = previewCurrent;

    if (previewFreehand.length > 1) {
      final path = Path()..moveTo(previewFreehand.first.dx, previewFreehand.first.dy);
      for (int i = 1; i < previewFreehand.length; i++) {
        path.lineTo(previewFreehand[i].dx, previewFreehand[i].dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = previewColor
          ..strokeWidth = previewStrokeWidth
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
      return;
    }

    if (ds == null || dc == null) return;

    final opts = previewOptions;

    if (previewTool == AnnotationTool.eraser &&
        (opts.mosaicMode == MosaicMode.rect ||
         opts.mosaicMode == MosaicMode.ellipse)) {
      final rect = Rect.fromPoints(ds, dc);
      final path = opts.mosaicMode == MosaicMode.ellipse
          ? (Path()..addOval(rect))
          : (Path()..addRect(rect));
      // Eraser preview: semi-transparent red fill with dashed white border
      canvas.drawPath(path, Paint()
        ..color = Colors.red.withAlpha(40)
        ..style = PaintingStyle.fill);
      _strokePreview(canvas, path, Colors.white, 1.5, LineStyle.dashed);
      return;
    }

    if (previewTool == AnnotationTool.mosaic &&
        (opts.mosaicMode == MosaicMode.rect ||
         opts.mosaicMode == MosaicMode.ellipse)) {
      final rect = Rect.fromPoints(ds, dc);
      final path = opts.mosaicMode == MosaicMode.ellipse
          ? (Path()..addOval(rect))
          : (Path()..addRect(rect));
      _strokePreview(canvas, path, previewColor, previewStrokeWidth, LineStyle.solid);
      return;
    }

    if (previewTool == AnnotationTool.rectangle) {
      final rect = Rect.fromPoints(ds, dc);

      // Build shape path first — fill and stroke share the same geometry
      Path path;
      switch (opts.shapeKind) {
        case ShapeKind.rectangle:
          path = Path()..addRect(rect);
        case ShapeKind.roundedRectangle:
          final r = opts.cornerRadius > 0 ? opts.cornerRadius : 4.0;
          path = Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)));
        case ShapeKind.ellipse:
          path = Path()..addOval(rect);
      }

      // Fill preview — same path
      if (opts.fillStyle == FillStyle.solid) {
        canvas.drawPath(
          path,
          Paint()
            ..color = opts.color.withAlpha(80)
            ..style = PaintingStyle.fill,
        );
      }

      // Stroke preview with lineStyle
      _strokePreview(canvas, path, previewColor, previewStrokeWidth, opts.lineStyle);
    } else if (previewTool == AnnotationTool.arrow) {
      final dx = dc.dx - ds.dx;
      final dy = dc.dy - ds.dy;
      final dist = math.sqrt(dx * dx + dy * dy);
      if (dist == 0) return;
      final ux = dx / dist;
      final uy = dy / dist;
      final trim = _arrowTrimLength(previewStrokeWidth);

      final fx = opts.startHead == ArrowHeadStyle.arrow
          ? ds.dx + ux * trim : ds.dx;
      final fy = opts.startHead == ArrowHeadStyle.arrow
          ? ds.dy + uy * trim : ds.dy;
      final tx = opts.endHead == ArrowHeadStyle.arrow
          ? dc.dx - ux * trim : dc.dx;
      final ty = opts.endHead == ArrowHeadStyle.arrow
          ? dc.dy - uy * trim : dc.dy;

      final path = Path()..moveTo(fx, fy)..lineTo(tx, ty);
      _strokePreview(canvas, path, previewColor, previewStrokeWidth, opts.lineStyle);

      if (opts.endHead == ArrowHeadStyle.arrow) {
        drawArrowHead(canvas, fx, fy, dc.dx, dc.dy, previewColor, previewStrokeWidth);
      }
      if (opts.startHead == ArrowHeadStyle.arrow) {
        drawArrowHead(canvas, tx, ty, ds.dx, ds.dy, previewColor, previewStrokeWidth);
      }
    }
  }

  /// Draw the snap-to-window hover preview as a semi-transparent blue
  /// fill with a dashed white border -- distinct from the real selection
  /// overlay which is dark-matte + solid white border.
  void _drawSnapPreview(Canvas canvas, Rect rect) {
    // Blue semi-transparent fill (0x55 = ~33% alpha, clearly visible)
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0x5500BFFF)
        ..style = PaintingStyle.fill,
    );
    // Dashed white border (2.5px for visibility on high-DPI)
    final path = Path()..addRect(rect);
    _strokePreview(canvas, path, const Color(0xFF80D8FF), 2.5, LineStyle.dashed);
  }

  /// Draw crosshair lines through the centre of [rect], spanning the full [canvasSize].
  /// One horizontal and one vertical dashed line, light blue.
  void _drawCrosshair(Canvas canvas, Rect rect, Size canvasSize) {
    final cx = rect.center.dx;
    final cy = rect.center.dy;

    final paint = Paint()
      ..color = const ui.Color.fromARGB(255, 252, 136, 4)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    const dashLen = 6.0;
    const gapLen = 4.0;

    // Vertical line (full height)
    final vPath = Path()..moveTo(cx, 0)..lineTo(cx, canvasSize.height);
    _strokeDashed(canvas, vPath, paint, dashLen, gapLen);

    // Horizontal line (full width)
    final hPath = Path()..moveTo(0, cy)..lineTo(canvasSize.width, cy);
    _strokeDashed(canvas, hPath, paint, dashLen, gapLen);
  }
  /// Draw a dashed path with custom dash/gap lengths.
  void _strokeDashed(Canvas canvas, Path path, Paint paint, double dash, double gap) {
    final metrics = path.computeMetrics();
    for (final m in metrics) {
      double distance = 0;
      bool dashOn = true;
      while (distance < m.length) {
        final len = dashOn ? dash : gap;
        final end = (distance + len).clamp(0.0, m.length);
        if (dashOn) {
          final segment = m.extractPath(distance, end);
          canvas.drawPath(segment, paint);
        }
        distance = end;
        dashOn = !dashOn;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter o) => true;

  /// Stroke a path with line-style support for preview.
  static void _strokePreview(Canvas canvas, Path path, Color color,
      double strokeWidth, LineStyle style) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    if (style == LineStyle.solid) {
      canvas.drawPath(path, paint);
      return;
    }

    final dashLen = style == LineStyle.dashed ? 6.0 : 1.0;
    final gapLen = style == LineStyle.dashed ? 4.0 : 3.0;
    if (style == LineStyle.dotted) paint.strokeCap = StrokeCap.round;

    for (final metric in path.computeMetrics()) {
      double dist = 0;
      while (dist < metric.length) {
        final end = math.min(dist + dashLen, metric.length);
        canvas.drawPath(metric.extractPath(dist, end), paint);
        dist += dashLen + gapLen;
      }
    }
  }
}

// ===== 共享绘制函数（显示 + 导出复用） =====

/// Draw a single annotation shape (logical coordinates).
/// Optional [image] and [widgetSize] enable blur mosaic rendering.
/// Optional [imageRgba] enables pixel sampling from source image.
void drawAnnotation(Canvas canvas, AnnotationShape shape,
    {ui.Image? image, Size? widgetSize, Uint8List? imageRgba}) {
  // Apply 2D planar rotation if needed.
  // Rotation origin is the shape's un-rotated center.
  final rot = shape.rotation;
  final rotated = rot.abs() > 0.001;
  if (rotated) {
    final b = getAnnBounds(shape);
    // Un-rotated center: for RectAnnotation use its raw center,
    // otherwise use the (already rotated) AABB center.
    double cx, cy;
    if (shape is RectAnnotation) {
      cx = shape.x + shape.w / 2;
      cy = shape.y + shape.h / 2;
    } else {
      cx = b.center.dx;
      cy = b.center.dy;
    }
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(rot);
    canvas.translate(-cx, -cy);
  }

  if (shape is RectAnnotation) {
    _drawRect(canvas, shape);
  } else if (shape is ArrowAnnotation) {
    _drawArrow(canvas, shape);
  } else if (shape is TextAnnotation) {
    _drawText(canvas, shape);
  } else if (shape is FreehandAnnotation) {
    _drawFreehand(canvas, shape);
  } else if (shape is NumberTagAnnotation) {
    _drawNumberTag(canvas, shape);
  } else if (shape is MosaicAnnotation) {
    _drawMosaic(canvas, shape, image: image, widgetSize: widgetSize, imageRgba: imageRgba);
  }

  if (rotated) {
    canvas.restore();
  }
}

/// 计算箭头头沿直线方向需要缩短的长度。
///
/// 箭头头从尖端向根部投影长度为 `len * cos(headAngle)`。
double _arrowTrimLength(double strokeWidth) {
  const headAngle = 0.45;
  return (10 + strokeWidth * 2) * math.cos(headAngle);
}

/// 绘制箭头头部（静态方法，供 preview 和 export 复用）。
///
/// 箭头尖端位于 (toX, toY)，指向从 (fromX, fromY) → (toX, toY) 的方向。
void drawArrowHead(Canvas canvas, double fromX, double fromY,
    double toX, double toY, Color color, double strokeWidth) {
  final angle = math.atan2(toY - fromY, toX - fromX);
  final len = 10 + strokeWidth * 2;
  const headAngle = 0.45;
  final path = Path()
    ..moveTo(toX, toY)
    ..lineTo(toX - len * math.cos(angle - headAngle),
        toY - len * math.sin(angle - headAngle))
    ..lineTo(toX - len * math.cos(angle + headAngle),
        toY - len * math.sin(angle + headAngle))
    ..close();
  canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.fill);
}

// ===== 各 shape 绘制实现 =====

void _drawRect(Canvas canvas, RectAnnotation a) {
  final rect = Rect.fromLTWH(a.x, a.y, a.w, a.h);

  // Build shape path first — fill and stroke share the same geometry
  Path path;
  switch (a.shapeKind) {
    case ShapeKind.rectangle:
      path = Path()..addRect(rect);
    case ShapeKind.roundedRectangle:
      final r = a.cornerRadius > 0 ? a.cornerRadius : 4.0;
      path = Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)));
    case ShapeKind.ellipse:
      path = Path()..addOval(rect);
  }

  // Fill — uses same path as stroke
  if (a.fillStyle == FillStyle.solid) {
    canvas.drawPath(
      path,
      Paint()
        ..color = (a.fillColor ?? a.color).withAlpha(
            a.fillColor != null ? 255 : 80)
        ..style = PaintingStyle.fill,
    );
  }

  // Stroke
  _strokePath(canvas, path, a.color, a.strokeWidth, a.lineStyle);
}

void _drawArrow(Canvas canvas, ArrowAnnotation a) {
  final dx = a.toX - a.fromX;
  final dy = a.toY - a.fromY;
  final dist = math.sqrt(dx * dx + dy * dy);
  if (dist == 0) return;
  final ux = dx / dist;
  final uy = dy / dist;
  final trim = _arrowTrimLength(a.strokeWidth);

  final fromX = a.startHead == ArrowHeadStyle.arrow
      ? a.fromX + ux * trim
      : a.fromX;
  final fromY = a.startHead == ArrowHeadStyle.arrow
      ? a.fromY + uy * trim
      : a.fromY;
  final toX = a.endHead == ArrowHeadStyle.arrow
      ? a.toX - ux * trim
      : a.toX;
  final toY = a.endHead == ArrowHeadStyle.arrow
      ? a.toY - uy * trim
      : a.toY;

  final path = Path()
    ..moveTo(fromX, fromY)
    ..lineTo(toX, toY);
  _strokePath(canvas, path, a.color, a.strokeWidth, a.lineStyle);

  if (a.startHead == ArrowHeadStyle.arrow) {
    drawArrowHead(canvas, toX, toY, a.fromX, a.fromY, a.color, a.strokeWidth);
  }
  if (a.endHead == ArrowHeadStyle.arrow) {
    drawArrowHead(canvas, fromX, fromY, a.toX, a.toY, a.color, a.strokeWidth);
  }
}

/// Compute an inverse color with reasonable contrast (black↔white, otherwise invert).
Color _inverseColor(Color c) {
  final luminance = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
  return luminance > 0.5 ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
}

void _drawText(Canvas canvas, TextAnnotation a) {
  final textColor = switch (a.textStyleKind) {
    TextStyleKind.filledInverse => _inverseColor(a.color),
    TextStyleKind.filledClear => Colors.white, // color irrelevant for dstOut
    _ => a.color,
  };

  final style = TextStyle(
    color: textColor,
    fontSize: a.fontSize,
    fontWeight: a.bold ? FontWeight.bold : FontWeight.normal,
    fontStyle: a.italic ? FontStyle.italic : FontStyle.normal,
    fontFamily: a.fontFamily,
  );

  final tp = TextPainter(
    text: TextSpan(text: a.text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final sz = tp.size;
  const pad = 4.0;
  final bgRect = RRect.fromRectAndRadius(
    Rect.fromLTWH(a.x - pad, a.y - pad, sz.width + pad * 2, sz.height + pad * 2),
    const Radius.circular(3),
  );

  if (a.textStyleKind == TextStyleKind.filledClear) {
    // Filled background + text cutout (transparent, reveals image behind).
    // Two saveLayer trick: inner layer captures text shape, composites with
    // dstOut to punch a hole through the filled background.
    canvas.saveLayer(bgRect.outerRect, Paint());
    canvas.drawRRect(bgRect, Paint()..color = a.color);
    canvas.saveLayer(bgRect.outerRect, Paint()..blendMode = BlendMode.dstOut);
    tp.paint(canvas, Offset(a.x, a.y));
    canvas.restore(); // inner: text ⇢ dstOut punch through fill
    canvas.restore(); // outer: composite result onto canvas
  } else {
    // Draw background for filledInverse
    if (a.textStyleKind == TextStyleKind.filledInverse) {
      canvas.drawRRect(bgRect, Paint()..color = a.color);
    }

    // Draw outline box
    if (a.textStyleKind == TextStyleKind.outlineBox) {
      canvas.drawRRect(
        bgRect,
        Paint()
          ..color = a.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    if (a.outline) {
      // 4-direction offset for outline effect
      final oStyle = style.copyWith(color: Colors.black);
      for (final o in [
        const Offset(-1, -1),
        const Offset(1, -1),
        const Offset(-1, 1),
        const Offset(1, 1)
      ]) {
        final otp = TextPainter(
          text: TextSpan(text: a.text, style: oStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        otp.paint(canvas, Offset(a.x, a.y) + o);
      }
    }

    tp.paint(canvas, Offset(a.x, a.y));
  }
}

void _drawFreehand(Canvas canvas, FreehandAnnotation a) {
  if (a.points.length < 2) return;
  final path = Path()..moveTo(a.points.first.dx, a.points.first.dy);
  for (int i = 1; i < a.points.length; i++) {
    path.lineTo(a.points[i].dx, a.points[i].dy);
  }
  _strokePath(canvas, path, a.color, a.strokeWidth, a.lineStyle, roundCap: true);
}

void _drawNumberTag(Canvas canvas, NumberTagAnnotation a) {
  final radius = a.fontSize;
  final center = Offset(a.x, a.y);

  if (a.style == NumberTagStyle.filledWhiteBorder) {
    // Colored fill + white outline + white number
    canvas.drawCircle(center, radius,
        Paint()..color = a.color..style = PaintingStyle.fill);
    canvas.drawCircle(center, radius,
        Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2.0);
  } else if (a.style == NumberTagStyle.solidCircle) {
    canvas.drawCircle(center, radius,
        Paint()..color = a.color..style = PaintingStyle.fill);
  } else {
    canvas.drawCircle(center, radius,
        Paint()..color = a.color..style = PaintingStyle.stroke..strokeWidth = 2.0);
  }

  final textColor =
      (a.style == NumberTagStyle.solidCircle || a.style == NumberTagStyle.filledWhiteBorder)
          ? Colors.white
          : a.color;
  final tp = TextPainter(
    text: TextSpan(
      text: '${a.number}',
      style: TextStyle(
        color: textColor,
        fontSize: a.fontSize,
        fontWeight: FontWeight.bold,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
}

void _drawMosaic(Canvas canvas, MosaicAnnotation a,
    {ui.Image? image, Size? widgetSize, Uint8List? imageRgba}) {
  final effect = a.effect;

  if (a.mode == MosaicMode.rect && a.rect != null) {
    final r = a.rect!;
    final cellSize = a.cellSize;
    if (effect == MosaicEffect.blur && image != null && widgetSize != null) {
      _drawBlurRect(canvas, r, cellSize, a.blurAmount, image, widgetSize);
      return;
    }
    for (double y = r.top; y < r.bottom; y += cellSize) {
      for (double x = r.left; x < r.right; x += cellSize) {
        final w = math.min(cellSize, r.right - x);
        final h = math.min(cellSize, r.bottom - y);
        final color = _samplePixel(image, imageRgba, x, y, cellSize);
        canvas.drawRect(
          Rect.fromLTWH(x, y, w, h),
          Paint()..color = color,
        );
      }
    }
  } else if (a.mode == MosaicMode.line &&
      a.points != null &&
      a.points!.length >= 2) {
    final cellSize = a.cellSize;
    final pts = a.points!;

    // Blur on brush path: clip to the thick stroke path, then blur inside.
    // Using clipPath ensures blur can never expand beyond the stroke band.
    if (effect == MosaicEffect.blur && image != null && widgetSize != null) {
      final halfW = cellSize / 2;

      // Build a thick filled outline from the freehand points.
      // For each segment from→to, construct a quad with perpendicular offsets.
      final thickPath = Path();
      for (int j = 1; j < pts.length; j++) {
        final from = pts[j - 1];
        final to = pts[j];
        final dx = to.dx - from.dx;
        final dy = to.dy - from.dy;
        final len = math.sqrt(dx * dx + dy * dy);
        if (len < 0.5) continue;
        final nx = -dy / len * halfW;
        final ny = dx / len * halfW;
        thickPath.addPolygon([
          Offset(from.dx + nx, from.dy + ny),
          Offset(from.dx - nx, from.dy - ny),
          Offset(to.dx - nx, to.dy - ny),
          Offset(to.dx + nx, to.dy + ny),
        ], true);
      }
      if (thickPath.getBounds().isEmpty) return;

      // Compute clip bounds = thick path bounds + blur padding
      final tb = thickPath.getBounds();
      final blurPad = cellSize * 1.5;
      final clipBounds = Rect.fromLTRB(
          tb.left - blurPad, tb.top - blurPad,
          tb.right + blurPad, tb.bottom + blurPad);

      final sx = image.width / widgetSize.width;
      final sy = image.height / widgetSize.height;
      final srcRect = Rect.fromLTWH(
        clipBounds.left * sx, clipBounds.top * sy,
        clipBounds.width * sx, clipBounds.height * sy,
      );

      final blurSigma = cellSize * a.blurAmount;
      final blurPaint = Paint()
        ..imageFilter = ui.ImageFilter.blur(
            sigmaX: blurSigma, sigmaY: blurSigma,
            tileMode: TileMode.clamp);

      // IMPORTANT order:
      //   clipPath → saveLayer(blur) → drawImageRect → restore → restore
      // clipPath hard-crops the blur so it stays inside the stroke band,
      // eliminating the "big AABB rectangle" artifact.
      canvas.save();
      canvas.clipPath(thickPath);
      canvas.saveLayer(clipBounds, blurPaint);
      canvas.drawImageRect(image, srcRect, clipBounds, Paint());
      canvas.restore(); // blur composited, clipped to thickPath
      canvas.restore(); // remove clip
      return;
    }

    // Pixelate brush: build thick-banded path (same quads as blur),
    // then iterate every grid cell covered by each quad.
    // This guarantees continuous band coverage — no centerline-only gaps.
    final covered = <int>{};
    final halfW = cellSize / 2;
    for (int i = 1; i < pts.length; i++) {
      final from = pts[i - 1];
      final to = pts[i];
      final dx = to.dx - from.dx;
      final dy = to.dy - from.dy;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len < 0.5) continue;
      final nx = -dy / len * halfW;
      final ny = dx / len * halfW;
      // Quad corners (same order as thickPath in blur)
      final q = [
        Offset(from.dx + nx, from.dy + ny), // top-left-ish
        Offset(from.dx - nx, from.dy - ny), // bottom-left-ish
        Offset(to.dx - nx, to.dy - ny),     // bottom-right-ish
        Offset(to.dx + nx, to.dy + ny),     // top-right-ish
      ];
      // Compute the AABB of this quad in grid space
      double ql = q[0].dx, qt = q[0].dy, qr = ql, qb = qt;
      for (final p in q) {
        ql = math.min(ql, p.dx); qt = math.min(qt, p.dy);
        qr = math.max(qr, p.dx); qb = math.max(qb, p.dy);
      }
      final gx0 = (ql / cellSize).floor();
      final gy0 = (qt / cellSize).floor();
      final gx1 = (qr / cellSize).floor();
      final gy1 = (qb / cellSize).floor();
      // For each grid cell, test if its center is inside the quad
      for (int gx = gx0; gx <= gx1; gx++) {
        for (int gy = gy0; gy <= gy1; gy++) {
          final key = gx * 100000 + gy;
          if (covered.contains(key)) continue;
          final cx = (gx + 0.5) * cellSize;
          final cy = (gy + 0.5) * cellSize;
          if (_pointInQuad(Offset(cx, cy), q)) {
            covered.add(key);
            final color = _samplePixel(image, imageRgba,
                gx * cellSize, gy * cellSize, cellSize);
            canvas.drawRect(
              Rect.fromLTWH(gx * cellSize, gy * cellSize, cellSize, cellSize),
              Paint()..color = color,
            );
          }
        }
      }
    }
  } else if (a.mode == MosaicMode.ellipse && a.rect != null) {
    final r = a.rect!;
    final cellSize = a.cellSize;
    final cx = r.center.dx, cy = r.center.dy;
    final rx = r.width / 2, ry = r.height / 2;
    if (effect == MosaicEffect.blur && image != null && widgetSize != null) {
      _drawBlurEllipse(canvas, r, cellSize, a.blurAmount, image, widgetSize);
      return;
    }
    for (double y = r.top; y < r.bottom; y += cellSize) {
      for (double x = r.left; x < r.right; x += cellSize) {
        final ex = (x + cellSize / 2 - cx) / rx;
        final ey = (y + cellSize / 2 - cy) / ry;
        if (ex * ex + ey * ey > 1.0) continue;
        final w = math.min(cellSize, r.right - x);
        final h = math.min(cellSize, r.bottom - y);
        final color = _samplePixel(image, imageRgba, x, y, cellSize);
        canvas.drawRect(
          Rect.fromLTWH(x, y, w, h),
          Paint()..color = color,
        );
      }
    }
  }
}

/// Deterministic random offset within a cell for image sampling.
/// Hash depends on cell grid index so color is stable across repaints.
int _cellHash(int gx, int gy) {
  int h = (gx * 0x1f1f1f1f) ^ gy;
  h = ((h >> 16) ^ h) * 0x45d9f3b;
  h = ((h >> 16) ^ h) * 0x45d9f3b;
  h = (h >> 16) ^ h;
  return h & 0x7FFFFFFF;
}

/// Sample source image pixel within the given cell, using deterministic
/// random offset based on cell grid index. Falls back to gray hash if
/// no imageRgba data is available.
ui.Color _samplePixel(ui.Image? image, Uint8List? rgba,
    double cellLeft, double cellTop, double cellSize) {
  if (rgba == null || image == null) {
    final gx = (cellLeft / cellSize).floor();
    final gy = (cellTop / cellSize).floor();
    final gray = ((gx * 31 + gy * 37).abs() % 200 + 30).clamp(0, 255);
    return ui.Color.fromARGB(220, gray, gray, gray);
  }
  final iw = image.width;
  final ih = image.height;
  if (iw <= 0 || ih <= 0) return const ui.Color.fromARGB(220, 128, 128, 128);

  final gx = (cellLeft / cellSize).floor();
  final gy = (cellTop / cellSize).floor();
  final hash = _cellHash(gx, gy);

  // Deterministic random offset within the cell [0, cellSize)
  final offX = (hash % 1000) / 1000.0 * cellSize;
  final offY = ((hash ~/ 1000) % 1000) / 1000.0 * cellSize;

  final px = (cellLeft + offX).round().clamp(0, iw - 1);
  final py = (cellTop + offY).round().clamp(0, ih - 1);
  final idx = (py * iw + px) * 4;
  if (idx + 3 >= rgba.length) return const ui.Color.fromARGB(220, 128, 128, 128);

  return ui.Color.fromARGB(255, rgba[idx], rgba[idx + 1], rgba[idx + 2]);
}

/// Draw a blurred rectangular region by drawing the source image portion
/// through an ImageFilter.blur.
void _drawBlurRect(Canvas canvas, Rect rect, double cellSize, double blurAmount,
    ui.Image image, Size widgetSize) {
  final srcW = image.width.toDouble();
  final srcH = image.height.toDouble();
  final sx = srcW / widgetSize.width;
  final sy = srcH / widgetSize.height;

  final srcRect = Rect.fromLTWH(
    rect.left * sx, rect.top * sy,
    rect.width * sx, rect.height * sy,
  );

  final sigma = blurAmount * 3.0;
  final blurPaint = Paint()
    ..imageFilter = ui.ImageFilter.blur(
        sigmaX: sigma, sigmaY: sigma,
        tileMode: TileMode.clamp);

  canvas.saveLayer(rect, blurPaint);
  canvas.drawImageRect(image, srcRect, rect, Paint());
  canvas.restore();
}

/// Draw a blurred elliptical region.
void _drawBlurEllipse(Canvas canvas, Rect rect, double cellSize, double blurAmount,
    ui.Image image, Size widgetSize) {
  final path = Path()..addOval(rect);

  final sigma = blurAmount * 3.0;
  final blurPaint = Paint()
    ..imageFilter = ui.ImageFilter.blur(
        sigmaX: sigma, sigmaY: sigma,
        tileMode: TileMode.clamp);

  final srcW = image.width.toDouble();
  final srcH = image.height.toDouble();
  final sx = srcW / widgetSize.width;
  final sy = srcH / widgetSize.height;

  final srcRect = Rect.fromLTWH(
    rect.left * sx, rect.top * sy,
    rect.width * sx, rect.height * sy,
  );

  canvas.saveLayer(rect, blurPaint);
  canvas.clipPath(path);
  canvas.drawImageRect(image, srcRect, rect, Paint());
  canvas.restore();
}

// ===== 虚线 / 点线 stroke 工具 =====

/// Draw [path] with the given [style], handling dashed/dotted via PathMetrics.
void _strokePath(Canvas canvas, Path path, Color color, double strokeWidth,
    LineStyle style,
    {bool roundCap = false}) {
  final paint = Paint()
    ..color = color
    ..strokeWidth = strokeWidth
    ..style = PaintingStyle.stroke;
  if (roundCap) paint.strokeCap = StrokeCap.round;

  if (style == LineStyle.solid) {
    canvas.drawPath(path, paint);
    return;
  }

  final dashLen = style == LineStyle.dashed ? 6.0 : 1.0;
  final gapLen = style == LineStyle.dashed ? 4.0 : 3.0;
  if (style == LineStyle.dotted) paint.strokeCap = StrokeCap.round;

  for (final metric in path.computeMetrics()) {
    double dist = 0;
    while (dist < metric.length) {
      final end = math.min(dist + dashLen, metric.length);
      canvas.drawPath(metric.extractPath(dist, end), paint);
      dist += dashLen + gapLen;
    }
  }
}
