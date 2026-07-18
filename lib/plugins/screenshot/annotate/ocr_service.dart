// OCR service — ONNX Runtime native bridge (V2.0.0: det→rec per-quad output)
library;

import 'dart:convert';
import 'package:flutter/services.dart';

/// A single recognised text quad with its bounding polygon and text.
class OcrBox {
  final String text;       // recognized text
  final double score;      // rec confidence (logit score)
  final List<Offset> quad; // 4 corner points [TL, TR, BR, BL] in original-image pixels

  const OcrBox({required this.text, required this.score, required this.quad});

  factory OcrBox.fromJson(Map<String, dynamic> json) {
    final q = json['quad'] as List<dynamic>? ?? [];
    return OcrBox(
      text: (json['text'] as String?) ?? '',
      score: (json['score'] as num?)?.toDouble() ?? 0.0,
      quad: q.map((p) {
        final a = p as List<dynamic>;
        return Offset(
          (a[0] as num).toDouble(),
          (a[1] as num).toDouble(),
        );
      }).toList(),
    );
  }

  /// Legacy axis-aligned bounding rect (for backward compat with OcrBlock consumers).
  Rect get box {
    if (quad.isEmpty) return Rect.zero;
    final xs = quad.map((p) => p.dx);
    final ys = quad.map((p) => p.dy);
    final l = xs.reduce((a, b) => a < b ? a : b);
    final t = ys.reduce((a, b) => a < b ? a : b);
    return Rect.fromLTWH(l, t,
      xs.reduce((a, b) => a > b ? a : b) - l,
      ys.reduce((a, b) => a > b ? a : b) - t);
  }
}

/// Legacy block type — kept for existing translate-service consumers.
class OcrBlock {
  final String text;
  final Rect box;
  const OcrBlock({required this.text, required this.box});
}

class OcrResult {
  /// V2.0.0: per-box results — one entry per detected text quad.
  final List<OcrBox> boxes;

  /// Language tag from engine (e.g. "ch", "en").
  final String language;

  /// Diagnostic info (for toolbar badge).
  final Map<String, dynamic>? diag;

  const OcrResult({this.boxes = const [], this.language = 'ch', this.diag});

  factory OcrResult.fromJson(Map<String, dynamic> json) => OcrResult(
    boxes: (json['boxes'] as List<dynamic>?)
        ?.map((e) => OcrBox.fromJson(e as Map<String, dynamic>))
        .toList() ?? const [],
    language: (json['language'] as String?) ?? 'ch',
    diag: json['diag'] as Map<String, dynamic>?,
  );

  /// Backward compat: joined all recognized texts with newlines.
  String get fullText => boxes.map((b) => b.text).join('\n');

  /// Backward compat: axis-aligned bounding rects as OcrBlock list.
  List<OcrBlock> get blocks => boxes
      .map((b) => OcrBlock(text: b.text, box: b.box))
      .toList();

  /// Convenience: all texts joined with newlines.
  String get text => fullText;
}

class OcrService {
  static const _channel = MethodChannel('com.xmate/ocr');

  /// Send [pngBytes] to native OCR engine.
  ///
  /// [cropX] / [cropY] are the image-pixel offset of this crop within
  /// the original screenshot image.
  /// [enableUnwarp] toggles UVDoc text-image unwarping (PP-OCRv6 only).
  /// [engine] selects backend: "ppocrv6" (default) or "winrt".
  /// [language] BCP-47 language tag for the engine, e.g. "ch", "en", "zh-Hans".
  Future<OcrResult> recognize(Uint8List pngBytes, {
    int cropX = 0,
    int cropY = 0,
    bool enableUnwarp = false,
    String engine = 'ppocrv6',
    String language = 'ch',
  }) async {
    final jsonStr = await _channel.invokeMethod<String>('recognize', {
      'pngBytes': pngBytes,
      'cropX': cropX,
      'cropY': cropY,
      'enableUnwarp': enableUnwarp,
      'engine': engine,
      'language': language,
    });
    if (jsonStr == null || jsonStr.isEmpty) {
      throw Exception('OCR returned empty result');
    }
    final json = jsonDecode(jsonStr) as Map<String, dynamic>;
    if (json.containsKey('error')) {
      throw Exception(jsonStr);
    }
    return OcrResult.fromJson(json);
  }
}
