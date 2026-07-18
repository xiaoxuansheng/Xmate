/// Shared annotation data models for XMate.
///
/// Used by both screenshot plugin and QuickLook image annotator.
library;

import 'dart:ui' as ui;

// ===== Tool/Shape enums =====

/// Annotation shape types.
enum AnnotationType { rectangle, arrow, text, freehand, mosaic, numberTag }

/// Fill style for shape annotations.
enum FillStyle { none, solid }

/// Line style for strokes.
enum LineStyle { solid, dashed, dotted }

/// Arrow head style.
enum ArrowHeadStyle { none, arrow }

/// Rectangle shape kind.
enum ShapeKind { rectangle, roundedRectangle, ellipse }

/// Number-tag visual style.
enum NumberTagStyle { circleOutline, solidCircle, filledWhiteBorder }

/// Mosaic operation mode.
enum MosaicMode { line, rect, ellipse }

/// Text background / box style.
enum TextStyleKind { plain, outlineBox, filledInverse, filledClear }

/// Mosaic visual effect.
enum MosaicEffect { pixelate, blur }

// ===== Annotation shape hierarchy =====

/// Base annotation shape.
///
/// [id] is a unique auto-generated identifier.
/// [rotation] is the 2D planar rotation angle in radians.
abstract class AnnotationShape {
  final AnnotationType type;
  final String id;
  bool selected = false;
  double rotation = 0.0;

  static int _counter = 0;

  AnnotationShape(this.type, {String? id})
      : id = id ?? 'a${++_counter}_${DateTime.now().microsecondsSinceEpoch}';
}

/// Rectangular / rounded-rect / ellipse annotation.
class RectAnnotation extends AnnotationShape {
  final double x, y, w, h;
  final ui.Color color;
  final double strokeWidth;
  final ShapeKind shapeKind;
  final double cornerRadius;
  final FillStyle fillStyle;
  final ui.Color? fillColor;
  final LineStyle lineStyle;

  RectAnnotation({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.color,
    this.strokeWidth = 2.0,
    this.shapeKind = ShapeKind.rectangle,
    this.cornerRadius = 0.0,
    this.fillStyle = FillStyle.none,
    this.fillColor,
    this.lineStyle = LineStyle.solid,
    String? id,
  }) : super(AnnotationType.rectangle, id: id);
}

/// Arrow / line annotation.
class ArrowAnnotation extends AnnotationShape {
  final double fromX, fromY, toX, toY;
  final ui.Color color;
  final double strokeWidth;
  final ArrowHeadStyle startHead;
  final ArrowHeadStyle endHead;
  final LineStyle lineStyle;

  ArrowAnnotation({
    required this.fromX,
    required this.fromY,
    required this.toX,
    required this.toY,
    required this.color,
    this.strokeWidth = 2.0,
    this.startHead = ArrowHeadStyle.none,
    this.endHead = ArrowHeadStyle.arrow,
    this.lineStyle = LineStyle.solid,
    String? id,
  }) : super(AnnotationType.arrow, id: id);
}

/// Text annotation.
class TextAnnotation extends AnnotationShape {
  final double x, y;
  final String text;
  final ui.Color color;
  final double fontSize;
  final bool bold;
  final bool italic;
  final bool outline;
  final String? fontFamily;
  final TextStyleKind textStyleKind;

  TextAnnotation({
    required this.x,
    required this.y,
    required this.text,
    required this.color,
    this.fontSize = 16,
    this.bold = false,
    this.italic = false,
    this.outline = false,
    this.fontFamily,
    this.textStyleKind = TextStyleKind.plain,
    String? id,
  }) : super(AnnotationType.text, id: id);
}

/// Freehand / brush annotation.
class FreehandAnnotation extends AnnotationShape {
  final List<ui.Offset> points;
  final ui.Color color;
  final double strokeWidth;
  final LineStyle lineStyle;

  FreehandAnnotation({
    required this.points,
    required this.color,
    this.strokeWidth = 2.0,
    this.lineStyle = LineStyle.solid,
    String? id,
  }) : super(AnnotationType.freehand, id: id);
}

/// Number-tag annotation (numbered circle placed with a click).
class NumberTagAnnotation extends AnnotationShape {
  final double x, y;
  final int number;
  final ui.Color color;
  final NumberTagStyle style;
  final double fontSize;

  NumberTagAnnotation({
    required this.x,
    required this.y,
    required this.number,
    required this.color,
    this.style = NumberTagStyle.circleOutline,
    this.fontSize = 14,
    String? id,
  }) : super(AnnotationType.numberTag, id: id);
}

/// Mosaic (pixelate/blur) annotation.
class MosaicAnnotation extends AnnotationShape {
  final MosaicMode mode;
  final ui.Rect? rect;
  final List<ui.Offset>? points;
  final double cellSize;
  final MosaicEffect effect;
  final double blurAmount;

  MosaicAnnotation({
    required this.mode,
    this.rect,
    this.points,
    this.cellSize = 10.0,
    this.effect = MosaicEffect.pixelate,
    this.blurAmount = 1.0,
    String? id,
  }) : super(AnnotationType.mosaic, id: id);
}

// ===== Window partition entry (used by screenshot and canvas) =====

/// A screen-absolute window rectangle with rank for partition overlay.
class WindowRectEntry {
  final ui.Rect rect;
  final int rank;
  const WindowRectEntry({required this.rect, required this.rank});
}

