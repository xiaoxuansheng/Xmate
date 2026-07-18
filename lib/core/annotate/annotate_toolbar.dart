library;

import 'package:flutter/material.dart';
import 'annotate_models.dart';
import '../../core/theme/theme_colors.dart';

// ===== Tool enum =====

enum AnnotationTool {
  mouse,
  rectangle,
  arrow,
  freehand,
  text,
  mosaic,
  numberTag,
  eraser,
  magnifier,
  crop,
  bgRemove,
  ocr,
  translate,
}

// ===== Tool options (sub-option state) =====

class ToolOptions {
  final Color color;
  final double strokeWidth;
  final LineStyle lineStyle;
  final ShapeKind shapeKind;
  final double cornerRadius;
  final FillStyle fillStyle;
  final ArrowHeadStyle startHead;
  final ArrowHeadStyle endHead;
  final bool bold;
  final bool italic;
  final bool outline;
  final double fontSize;
  final String? fontFamily;
  final NumberTagStyle numberTagStyle;
  final double numberTagSize;
  final MosaicMode mosaicMode;
  final double mosaicCellSize;
  final MosaicEffect mosaicEffect;
  final double mosaicBlurAmount;
  final TextStyleKind textStyleKind;

  const ToolOptions({
    this.color = Colors.red,
    this.strokeWidth = 2.0,
    this.lineStyle = LineStyle.solid,
    this.shapeKind = ShapeKind.rectangle,
    this.cornerRadius = 8.0,
    this.fillStyle = FillStyle.none,
    this.startHead = ArrowHeadStyle.none,
    this.endHead = ArrowHeadStyle.arrow,
    this.bold = false,
    this.italic = false,
    this.outline = false,
    this.fontSize = 18,
    this.fontFamily,
    this.numberTagStyle = NumberTagStyle.circleOutline,
    this.numberTagSize = 16,
    this.mosaicMode = MosaicMode.line,
    this.mosaicCellSize = 10.0,
    this.mosaicEffect = MosaicEffect.pixelate,
    this.mosaicBlurAmount = 1.0,
    this.textStyleKind = TextStyleKind.plain,
  });

  ToolOptions copyWith({
    Color? color,
    double? strokeWidth,
    LineStyle? lineStyle,
    ShapeKind? shapeKind,
    double? cornerRadius,
    FillStyle? fillStyle,
    ArrowHeadStyle? startHead,
    ArrowHeadStyle? endHead,
    bool? bold,
    bool? italic,
    bool? outline,
    double? fontSize,
    String? fontFamily,
    NumberTagStyle? numberTagStyle,
    double? numberTagSize,
    MosaicMode? mosaicMode,
    double? mosaicCellSize,
    MosaicEffect? mosaicEffect,
    double? mosaicBlurAmount,
    TextStyleKind? textStyleKind,
  }) =>
      ToolOptions(
        color: color ?? this.color,
        strokeWidth: strokeWidth ?? this.strokeWidth,
        lineStyle: lineStyle ?? this.lineStyle,
        shapeKind: shapeKind ?? this.shapeKind,
        cornerRadius: cornerRadius ?? this.cornerRadius,
        fillStyle: fillStyle ?? this.fillStyle,
        startHead: startHead ?? this.startHead,
        endHead: endHead ?? this.endHead,
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        outline: outline ?? this.outline,
        fontSize: fontSize ?? this.fontSize,
        fontFamily: fontFamily ?? this.fontFamily,
        numberTagStyle: numberTagStyle ?? this.numberTagStyle,
        numberTagSize: numberTagSize ?? this.numberTagSize,
        mosaicMode: mosaicMode ?? this.mosaicMode,
        mosaicCellSize: mosaicCellSize ?? this.mosaicCellSize,
        mosaicEffect: mosaicEffect ?? this.mosaicEffect,
        mosaicBlurAmount: mosaicBlurAmount ?? this.mosaicBlurAmount,
        textStyleKind: textStyleKind ?? this.textStyleKind,
      );
}

// ===== Toolbar widget =====

class AnnotateToolbar extends StatelessWidget {
  final AnnotationTool currentTool;
  final ToolOptions options;
  final bool hasSelection;
  final bool canUndo;
  final bool canRedo;
  final ValueChanged<AnnotationTool> onToolChanged;
  final ValueChanged<ToolOptions> onOptionsChanged;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onCopy;
  final VoidCallback onSave;
  final VoidCallback onPin;
  final VoidCallback onClose;
  final VoidCallback onClearAll;
  /// Where PopupMenuButton dropdowns appear. Default [PopupMenuPosition.under].
  final PopupMenuPosition popupMenuPosition;
  /// If true, the color/stroke/tool-options row appears above the tool buttons
  /// row (QuickLook style). Default false (screenshot style: tools on top).
  final bool optionsRowFirst;
  /// Tool buttons to hide. Default empty (all tools shown). QuickLook uses this
  /// to hide OCR/Translate which are screenshot-specific.
  final Set<AnnotationTool> hiddenTools;
  /// Action buttons to hide. Default empty. Values: 'copy','save','pin'.
  final Set<String> hiddenActions;

  const AnnotateToolbar({
    super.key,
    required this.currentTool,
    required this.options,
    required this.hasSelection,
    required this.canUndo,
    this.canRedo = false,
    required this.onToolChanged,
    required this.onOptionsChanged,
    required this.onUndo,
    this.onRedo = _noop,
    required this.onCopy,
    required this.onSave,
    required this.onPin,
    required this.onClose,
    required this.onClearAll,
    this.popupMenuPosition = PopupMenuPosition.under,
    this.optionsRowFirst = false,
    this.hiddenTools = const {},
    this.hiddenActions = const {},
  });

  static void _noop() {}

  // ─── Preset colors ───

  static const _presetColors = [
    Colors.red, Colors.orange, Colors.green,
    Colors.blue, Colors.purple, Colors.white, Colors.black,
  ];

  // ─── Sizing constants (1.2× scale) ───

  static const _iconSz = 19.0;
  static const _toolPadH = 6.0;
  static const _toolPadV = 4.0;
  static const _actIconSz = 19.0;
  static const _actMinW = 28.0;
  static const _actMinH = 28.0;
  static const _swatchD = 17.0;
  static const _strokeBtnW = 28.0;
  static const _strokeBtnH = 24.0;

  // ─── Build ───

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final showColorRow = currentTool != AnnotationTool.mouse &&
        currentTool != AnnotationTool.eraser &&
        currentTool != AnnotationTool.ocr &&
        currentTool != AnnotationTool.translate &&
        currentTool != AnnotationTool.mosaic &&
        currentTool != AnnotationTool.magnifier &&
        currentTool != AnnotationTool.crop &&
        currentTool != AnnotationTool.bgRemove;

    final showStrokeRow = currentTool == AnnotationTool.rectangle ||
        currentTool == AnnotationTool.arrow ||
        currentTool == AnnotationTool.freehand ||
        currentTool == AnnotationTool.mosaic;

    final spacer = (showColorRow || currentTool == AnnotationTool.eraser ||
        currentTool == AnnotationTool.mosaic)
        ? const SizedBox(height: 3)
        : null;

    final optionsRow = showColorRow
        ? Row(mainAxisSize: MainAxisSize.min, children: [
            // Color swatches
            ..._presetColors.map((c) => _colorSwatch(c, cs)),
            _currentColorDisplay(cs),
            _moreColorBtn(context),
            const SizedBox(width: 6),
            _sep(cs),
            const SizedBox(width: 6),
            // Stroke width (conditional)
            if (showStrokeRow) ...[
              _strokeDot(2.0, 3.0, cs),
              _strokeDot(4.0, 5.0, cs),
              _strokeDot(6.0, 7.0, cs),
              _customStrokeInput(cs),
              const SizedBox(width: 6),
              _sep(cs),
              const SizedBox(width: 6),
            ],
            // Tool-specific
            if (showStrokeRow || currentTool == AnnotationTool.text ||
                currentTool == AnnotationTool.numberTag)
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: _toolSpecificOptions(context, cs)),
                ),
              ),
          ])
        : null;

    final toolRow = _buildToolRow(cs);

    final children = <Widget>[];
    if (optionsRowFirst) {
      if (optionsRow != null) children.add(optionsRow);
      if (currentTool == AnnotationTool.eraser) children.add(_buildEraserRow(cs));
      if (currentTool == AnnotationTool.mosaic) children.add(_buildMosaicRow(cs));
      if (spacer != null) children.add(spacer);
      children.add(toolRow);
    } else {
      children.add(toolRow);
      if (spacer != null) children.add(spacer);
      if (optionsRow != null) children.add(optionsRow);
      if (currentTool == AnnotationTool.eraser) children.add(_buildEraserRow(cs));
      if (currentTool == AnnotationTool.mosaic) children.add(_buildMosaicRow(cs));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  // ─── Row 1: Tool buttons | undo/redo | actions ───

  Widget _buildToolRow(ColorScheme cs) {
    // Build tool buttons, filtering out hidden tools.
    final allTools = <({IconData icon, AnnotationTool tool})>[
      (icon: Icons.near_me, tool: AnnotationTool.mouse),
      (icon: Icons.rectangle_outlined, tool: AnnotationTool.rectangle),
      (icon: Icons.arrow_forward, tool: AnnotationTool.arrow),
      (icon: Icons.brush, tool: AnnotationTool.freehand),
      (icon: Icons.text_fields, tool: AnnotationTool.text),
      (icon: Icons.blur_on, tool: AnnotationTool.mosaic),
      (icon: Icons.looks_one, tool: AnnotationTool.numberTag),
      (icon: Icons.backspace, tool: AnnotationTool.eraser),
      (icon: Icons.zoom_in, tool: AnnotationTool.magnifier),
      (icon: Icons.crop, tool: AnnotationTool.crop),
      (icon: Icons.auto_fix_high, tool: AnnotationTool.bgRemove),
      (icon: Icons.article_outlined, tool: AnnotationTool.ocr),
      (icon: Icons.translate, tool: AnnotationTool.translate),
    ];
    final visTools = allTools.where((t) => !hiddenTools.contains(t.tool)).toList();
    final showCopy = !hiddenActions.contains('copy');
    final showSave = !hiddenActions.contains('save');
    final showPin = !hiddenActions.contains('pin');

    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final t in visTools) _toolBtn(t.icon, t.tool, cs),
      // Separator
      const SizedBox(width: 6), _sep(cs), const SizedBox(width: 6),
      // Section 2: undo/redo
      _actBtn(Icons.undo, onUndo, canUndo, cs),
      _actBtn(Icons.redo, onRedo, canRedo, cs),
      // Separator
      const SizedBox(width: 6), _sep(cs), const SizedBox(width: 6),
      // Section 3: copy/save/pin/close
      if (showCopy) _actBtn(Icons.copy, onCopy, hasSelection, cs),
      if (showSave) _actBtn(Icons.save, onSave, hasSelection, cs),
      if (showPin) _actBtn(Icons.push_pin, onPin, hasSelection, cs),
      _actBtn(Icons.close, onClose, true, cs),
    ]);
  }

  Widget _sep(ColorScheme cs) =>
      Container(width: 1, height: 22, color: cs.onSurface.withAlpha(51));

  // ─── Row 2 header helpers ───

  Widget _currentColorDisplay(ColorScheme cs) {
    return Container(
      width: _swatchD,
      height: _swatchD,
      margin: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        color: options.color,
        shape: BoxShape.circle,
        border: Border.all(color: cs.onSurface.withAlpha(138), width: 1.5),
      ),
    );
  }

  // ─── Tool-specific options ───

  List<Widget> _toolSpecificOptions(BuildContext context, ColorScheme cs) {
    final o = options;
    switch (currentTool) {
      case AnnotationTool.rectangle:
        return [
          _optBtn('▣', o.shapeKind == ShapeKind.rectangle,
              () => _update(shapeKind: ShapeKind.rectangle), cs),
          _optBtn('▢', o.shapeKind == ShapeKind.roundedRectangle,
              () => _update(shapeKind: ShapeKind.roundedRectangle), cs),
          _optBtn('○', o.shapeKind == ShapeKind.ellipse,
              () => _update(shapeKind: ShapeKind.ellipse), cs),
          const SizedBox(width: 4),
          _optBtn('◼', o.fillStyle == FillStyle.solid,
              () => _update(
                  fillStyle: o.fillStyle == FillStyle.solid
                      ? FillStyle.none
                      : FillStyle.solid), cs),
          const SizedBox(width: 4),
          _lineStyleDropdown(context),
        ];
      case AnnotationTool.arrow:
        return [
          _optBtn('◁', o.startHead == ArrowHeadStyle.arrow,
              () => _update(
                  startHead: o.startHead == ArrowHeadStyle.arrow
                      ? ArrowHeadStyle.none
                      : ArrowHeadStyle.arrow), cs),
          _optBtn('▷', o.endHead == ArrowHeadStyle.arrow,
              () => _update(
                  endHead: o.endHead == ArrowHeadStyle.arrow
                      ? ArrowHeadStyle.none
                      : ArrowHeadStyle.arrow), cs),
          const SizedBox(width: 4),
          _lineStyleDropdown(context),
        ];
      case AnnotationTool.freehand:
        return [_lineStyleDropdown(context)];
      case AnnotationTool.text:
        return [
          _optBtn('B', o.bold, () => _update(bold: !o.bold), cs, bold: true),
          _optBtn('I', o.italic, () => _update(italic: !o.italic), cs,
              italic: true),
          const SizedBox(width: 6),
          _fontSizeStepper(cs),
          const SizedBox(width: 6),
          _fontFamilyDropdown(context),
          const SizedBox(width: 6),
          _sep(cs),
          const SizedBox(width: 6),
          _optBtn('Aa', o.textStyleKind == TextStyleKind.plain,
              () => _update(textStyleKind: TextStyleKind.plain), cs),
          _optBtn('◫', o.textStyleKind == TextStyleKind.outlineBox,
              () => _update(textStyleKind: TextStyleKind.outlineBox), cs),
          _optBtn('◼', o.textStyleKind == TextStyleKind.filledInverse,
              () => _update(textStyleKind: TextStyleKind.filledInverse), cs),
          _optBtn('◻', o.textStyleKind == TextStyleKind.filledClear,
              () => _update(textStyleKind: TextStyleKind.filledClear), cs),
        ];
      // mosaic handled by _buildMosaicRow() (no color row)
      case AnnotationTool.numberTag:
        return [
          _optBtn('○1',
              o.numberTagStyle == NumberTagStyle.circleOutline,
              () => _update(
                  numberTagStyle: NumberTagStyle.circleOutline), cs),
          _optBtn('●1',
              o.numberTagStyle == NumberTagStyle.solidCircle,
              () => _update(numberTagStyle: NumberTagStyle.solidCircle), cs),
          _optBtn('◎1',
              o.numberTagStyle == NumberTagStyle.filledWhiteBorder,
              () => _update(numberTagStyle: NumberTagStyle.filledWhiteBorder), cs),
          const SizedBox(width: 8),
          _sep(cs),
          const SizedBox(width: 6),
          _numberTagCircleBtn(16, 4, cs),   // small
          _numberTagCircleBtn(22, 6, cs),   // medium
          _numberTagCircleBtn(28, 8, cs),   // large
          _numberTagCustomSize(),
        ];
      default:
        return const [];
    }
  }

  // ─── Line style dropdown ───

  Widget _lineStyleDropdown(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labels = {
      LineStyle.solid: '━ Solid',
      LineStyle.dashed: '╌ Dash',
      LineStyle.dotted: '· Dot',
    };
    return PopupMenuButton<LineStyle>(
      initialValue: options.lineStyle,
      color: XMateColors.dialogBg(context),
      constraints: const BoxConstraints(minWidth: 80),
      position: popupMenuPosition,
      offset: const Offset(0, 4),
      onSelected: (v) => _update(lineStyle: v),
      itemBuilder: (_) => LineStyle.values.map((ls) =>
          PopupMenuItem(value: ls, height: 28,
            child: Text(labels[ls]!, style: TextStyle(fontSize: 12,
                color: options.lineStyle == ls ? cs.onSurface : cs.onSurface.withAlpha(153))),
          )).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        decoration: BoxDecoration(
          color: cs.onSurface.withAlpha(15),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: cs.onSurface.withAlpha(61), width: 0.5),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(labels[options.lineStyle]!.substring(0, 1),
              style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(179))),
          Icon(Icons.arrow_drop_down, size: 14, color: cs.onSurface.withAlpha(138)),
        ]),
      ),
    );
  }

  // ─── Mosaic row (no color) ───

  Widget _buildMosaicRow(ColorScheme cs) {
    final isBrush = options.mosaicMode == MosaicMode.line;
    final isBlur = options.mosaicEffect == MosaicEffect.blur;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      // Brush cell-size buttons (only when brush mode active)
      if (isBrush) ...[
        _mosaicSizeBtn(10, cs), _mosaicSizeBtn(20, cs), _mosaicSizeBtn(30, cs),
        _mosaicCustomPx(),
        const SizedBox(width: 6),
        _sep(cs),
        const SizedBox(width: 6),
      ],
      _optBtn('~', options.mosaicMode == MosaicMode.line,
          () => _update(mosaicMode: MosaicMode.line), cs),
      _optBtn('▭', options.mosaicMode == MosaicMode.rect,
          () => _update(mosaicMode: MosaicMode.rect), cs),
      _optBtn('○', options.mosaicMode == MosaicMode.ellipse,
          () => _update(mosaicMode: MosaicMode.ellipse), cs),
      const SizedBox(width: 8),
      _sep(cs),
      const SizedBox(width: 6),
      _effectIconBtn(Icons.grid_4x4, options.mosaicEffect == MosaicEffect.pixelate,
          () => _update(mosaicEffect: MosaicEffect.pixelate), cs),
      _effectIconBtn(Icons.blur_circular, options.mosaicEffect == MosaicEffect.blur,
          () => _update(mosaicEffect: MosaicEffect.blur), cs),
      // Blur amount slider (only when blur effect active)
      if (isBlur) ...[
        const SizedBox(width: 6),
        _sep(cs),
        const SizedBox(width: 6),
        _blurAmountSlider(cs),
        const SizedBox(width: 2),
        _blurAmountCustom(),
      ],
    ]);
  }

  Widget _blurAmountSlider(ColorScheme cs) {
    return SizedBox(
      width: 60,
      height: _strokeBtnH,
      child: SliderTheme(
        data: SliderThemeData(
          trackHeight: 2,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 0),
          activeTrackColor: cs.onSurface.withAlpha(138),
          inactiveTrackColor: cs.onSurface.withAlpha(31),
          thumbColor: cs.onSurface.withAlpha(179),
        ),
        child: Slider(
          value: options.mosaicBlurAmount.clamp(0.3, 5.0),
          min: 0.3, max: 5.0,
          onChanged: (v) => _update(mosaicBlurAmount: v),
        ),
      ),
    );
  }

  Widget _blurAmountCustom() {
    return Builder(builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return GestureDetector(
        onTap: () {
          final v = options.mosaicBlurAmount.toStringAsFixed(1);
          final ctrl = TextEditingController(text: v);
          showDialog(
            context: ctx,
            builder: (c) {
              final dialogCs = Theme.of(c).colorScheme;
              return AlertDialog(
                backgroundColor: XMateColors.dialogBg(c),
                title: Text('Blur amount', style: TextStyle(color: dialogCs.onSurface, fontSize: 15)),
                content: TextField(
                  controller: ctrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  autofocus: true,
                  style: TextStyle(color: dialogCs.onSurface, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '0.3-5.0',
                    hintStyle: TextStyle(color: dialogCs.onSurface.withAlpha(77)),
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (s) {
                    final a = double.tryParse(s);
                    if (a != null && a >= 0.3 && a <= 5.0) _update(mosaicBlurAmount: a);
                    Navigator.pop(c);
                  },
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c),
                    child: Text('Cancel', style: TextStyle(color: dialogCs.onSurface.withAlpha(138))),
                  ),
                  TextButton(
                    onPressed: () {
                      final a = double.tryParse(ctrl.text);
                      if (a != null && a >= 0.3 && a <= 5.0) _update(mosaicBlurAmount: a);
                      Navigator.pop(c);
                    },
                    child: Text('OK', style: TextStyle(color: dialogCs.onSurface)),
                  ),
                ],
              );
            },
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          height: _strokeBtnH,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: cs.onSurface.withAlpha(10),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: cs.onSurface.withAlpha(61), width: 0.5),
          ),
          alignment: Alignment.center,
          child: Text(options.mosaicBlurAmount.toStringAsFixed(1),
              style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(153))),
        ),
      );
    });
  }

  Widget _mosaicCustomPx() {
    return Builder(builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return GestureDetector(
        onTap: () {
          final ctrl = TextEditingController(text: '${options.mosaicCellSize.round()}');
          showDialog(
            context: ctx,
            builder: (c) {
              final dialogCs = Theme.of(c).colorScheme;
              return AlertDialog(
                backgroundColor: XMateColors.dialogBg(c),
                title: Text('Mosaic cell size (px)', style: TextStyle(color: dialogCs.onSurface, fontSize: 15)),
                content: TextField(
                  controller: ctrl,
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  style: TextStyle(color: dialogCs.onSurface, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '2-200',
                    hintStyle: TextStyle(color: dialogCs.onSurface.withAlpha(77)),
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (v) {
                    final sz = double.tryParse(v);
                    if (sz != null && sz >= 2 && sz <= 200) _update(mosaicCellSize: sz);
                    Navigator.pop(c);
                  },
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      final sz = double.tryParse(ctrl.text);
                      if (sz != null && sz >= 2 && sz <= 200) _update(mosaicCellSize: sz);
                      Navigator.pop(c);
                    },
                    child: Text('OK', style: TextStyle(color: dialogCs.onSurface)),
                  ),
                ],
              );
            },
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          height: _strokeBtnH,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: cs.onSurface.withAlpha(10),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: cs.onSurface.withAlpha(61), width: 0.5),
          ),
          alignment: Alignment.center,
          child: Text('${options.mosaicCellSize.round()}px',
              style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(153))),
        ),
      );
    });
  }

  Widget _mosaicSizeBtn(double size, ColorScheme cs) {
    final active = options.mosaicCellSize == size;
    return GestureDetector(
      onTap: () => _update(mosaicCellSize: size),
      child: Container(
        width: _strokeBtnW,
        height: _strokeBtnH,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          color: active ? cs.onSurface.withAlpha(30) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
              color: active ? cs.onSurface.withAlpha(138) : cs.onSurface.withAlpha(61), width: 0.5),
        ),
        alignment: Alignment.center,
        child: Text('${size.toInt()}',
            style: TextStyle(
                fontSize: 11,
                color: active ? cs.onSurface : cs.onSurface.withAlpha(153))),
      ),
    );
  }

  Widget _effectIconBtn(IconData icon, bool active, VoidCallback onTap, ColorScheme cs) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          color: active ? cs.onSurface.withAlpha(30) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
              color: active ? cs.onSurface.withAlpha(138) : cs.onSurface.withAlpha(61), width: 0.5),
        ),
        child: Icon(icon, size: 14,
            color: active ? cs.onSurface : cs.onSurface.withAlpha(153)),
      ),
    );
  }

  // ─── Eraser row ───

  Widget _buildEraserRow(ColorScheme cs) {
    final isBrush = options.mosaicMode == MosaicMode.line;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (isBrush) ...[
        _mosaicSizeBtn(10, cs), _mosaicSizeBtn(20, cs), _mosaicSizeBtn(30, cs),
        _mosaicCustomPx(),
        const SizedBox(width: 6),
        _sep(cs),
        const SizedBox(width: 6),
      ],
      _optBtn('~', options.mosaicMode == MosaicMode.line,
          () => _update(mosaicMode: MosaicMode.line), cs),
      _optBtn('▭', options.mosaicMode == MosaicMode.rect,
          () => _update(mosaicMode: MosaicMode.rect), cs),
      _optBtn('○', options.mosaicMode == MosaicMode.ellipse,
          () => _update(mosaicMode: MosaicMode.ellipse), cs),
      const SizedBox(width: 8),
      _eraserClearBtn(),
    ]);
  }

  // ─── Helpers ───

  void _update({
    Color? color,
    double? strokeWidth,
    LineStyle? lineStyle,
    ShapeKind? shapeKind,
    double? cornerRadius,
    FillStyle? fillStyle,
    ArrowHeadStyle? startHead,
    ArrowHeadStyle? endHead,
    bool? bold,
    bool? italic,
    bool? outline,
    double? fontSize,
    String? fontFamily,
    NumberTagStyle? numberTagStyle,
    double? numberTagSize,
    MosaicMode? mosaicMode,
    double? mosaicCellSize,
    MosaicEffect? mosaicEffect,
    double? mosaicBlurAmount,
    TextStyleKind? textStyleKind,
  }) {
    onOptionsChanged(options.copyWith(
      color: color,
      strokeWidth: strokeWidth,
      lineStyle: lineStyle,
      shapeKind: shapeKind,
      cornerRadius: cornerRadius,
      fillStyle: fillStyle,
      startHead: startHead,
      endHead: endHead,
      bold: bold,
      italic: italic,
      outline: outline,
      fontSize: fontSize,
      fontFamily: fontFamily,
      numberTagStyle: numberTagStyle,
      numberTagSize: numberTagSize,
      mosaicMode: mosaicMode,
      mosaicCellSize: mosaicCellSize,
      mosaicEffect: mosaicEffect,
      mosaicBlurAmount: mosaicBlurAmount,
      textStyleKind: textStyleKind,
    ));
  }

  // ─── Buttons ───

  Widget _toolBtn(IconData icon, AnnotationTool tool, ColorScheme cs) {
    final active = currentTool == tool;
    return GestureDetector(
      onTap: () => onToolChanged(tool),
      child: Container(
        padding:
            EdgeInsets.symmetric(horizontal: _toolPadH, vertical: _toolPadV),
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          color: active ? cs.onSurface.withAlpha(30) : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Icon(icon,
            size: _iconSz, color: active ? cs.onSurface : cs.onSurface.withAlpha(153)),
      ),
    );
  }

  Widget _actBtn(IconData icon, VoidCallback onTap, bool ok, ColorScheme cs) {
    return IconButton(
      icon: Icon(icon,
          size: _actIconSz, color: ok ? cs.onSurface.withAlpha(179) : cs.onSurface.withAlpha(61)),
      onPressed: ok ? onTap : null,
      padding: EdgeInsets.zero,
      constraints:
          const BoxConstraints(minWidth: _actMinW, minHeight: _actMinH),
    );
  }

  Widget _colorSwatch(Color c, ColorScheme cs) {
    final active = options.color.toARGB32() == c.toARGB32();
    return GestureDetector(
      onTap: () => _update(color: c),
      child: Container(
        width: _swatchD,
        height: _swatchD,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: active
              ? Border.all(color: cs.onSurface, width: 2)
              : Border.all(color: cs.onSurface.withAlpha(61), width: 0.5),
        ),
      ),
    );
  }

  Widget _moreColorBtn(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => _showColorPicker(context),
      child: Container(
        width: _swatchD,
        height: _swatchD,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: cs.onSurface.withAlpha(97), width: 1),
        ),
        child: Icon(Icons.add, size: 12, color: cs.onSurface.withAlpha(97)),
      ),
    );
  }

  void _showColorPicker(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => _ColorPickerDialog(
        initialColor: options.color,
        onColorPicked: (c) => _update(color: c),
      ),
    );
  }

  Widget _strokeDot(double strokeWidth, double dotRadius, ColorScheme cs) {
    final active = options.strokeWidth == strokeWidth;
    return GestureDetector(
      onTap: () => _update(strokeWidth: strokeWidth),
      child: Container(
        width: _strokeBtnW,
        height: _strokeBtnH,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          color: active ? cs.onSurface.withAlpha(30) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
              color: active ? cs.onSurface.withAlpha(138) : cs.onSurface.withAlpha(61), width: 0.5),
        ),
        alignment: Alignment.center,
        child: Container(
          width: dotRadius * 2,
          height: dotRadius * 2,
          decoration: BoxDecoration(
            color: active ? cs.onSurface : cs.onSurface.withAlpha(153),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  Widget _customStrokeInput(ColorScheme cs) {
    return GestureDetector(
      onTap: () {
        final sw = options.strokeWidth;
        final next = sw < 2 ? 3.0 : sw < 6 ? 8.0 : sw < 10 ? 12.0 : sw < 16 ? 18.0 : sw < 22 ? 24.0 : 1.0;
        _update(strokeWidth: next);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        height: _strokeBtnH,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          color: cs.onSurface.withAlpha(10),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: cs.onSurface.withAlpha(61), width: 0.5),
        ),
        alignment: Alignment.center,
        child: Text('${options.strokeWidth.round()} px',
            style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(153))),
      ),
    );
  }

  Widget _optBtn(String label, bool active, VoidCallback onTap, ColorScheme cs,
      {bool bold = false, bool italic = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          color: active ? cs.onSurface.withAlpha(30) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
              color: active ? cs.onSurface.withAlpha(138) : cs.onSurface.withAlpha(61), width: 0.5),
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: 13,
              color: active ? cs.onSurface : cs.onSurface.withAlpha(153),
              fontWeight: bold
                  ? FontWeight.bold
                  : active
                      ? FontWeight.w600
                      : FontWeight.normal,
              fontStyle: italic ? FontStyle.italic : FontStyle.normal,
            )),
      ),
    );
  }

  Widget _fontSizeStepper(ColorScheme cs) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      GestureDetector(
        onTap: () {
          final v = (options.fontSize - 2).clamp(8.0, 72.0).toDouble();
          _update(fontSize: v);
        },
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: cs.onSurface.withAlpha(15),
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text('−',
              style: TextStyle(fontSize: 14, color: cs.onSurface.withAlpha(153))),
        ),
      ),
      Container(
        width: 30,
        alignment: Alignment.center,
        child: Text('${options.fontSize.round()}',
            style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(179))),
      ),
      GestureDetector(
        onTap: () {
          final v = (options.fontSize + 2).clamp(8.0, 72.0).toDouble();
          _update(fontSize: v);
        },
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: cs.onSurface.withAlpha(15),
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text('+',
              style: TextStyle(fontSize: 14, color: cs.onSurface.withAlpha(153))),
        ),
      ),
    ]);
  }

  static const _fontFamilies = ['Arial', 'Times New Roman', 'Courier New',
    'Segoe UI', 'Consolas', 'Microsoft YaHei',
    'Calibri', 'SimHei', 'SimSun'];

  Widget _fontFamilyDropdown(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ff = options.fontFamily ?? 'Arial';
    return PopupMenuButton<String>(
      initialValue: ff,
      color: XMateColors.dialogBg(context),
      constraints: const BoxConstraints(minWidth: 100),
      position: popupMenuPosition,
      offset: const Offset(0, 4),
      onSelected: (v) => _update(fontFamily: v),
      itemBuilder: (_) => _fontFamilies.map((f) =>
          PopupMenuItem(value: f, height: 28,
            child: Text(f, style: TextStyle(fontSize: 12,
                fontFamily: f,
                color: (options.fontFamily ?? 'Arial') == f
                    ? cs.onSurface : cs.onSurface.withAlpha(153))),
          )).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        decoration: BoxDecoration(
          color: cs.onSurface.withAlpha(15),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: cs.onSurface.withAlpha(61), width: 0.5),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(ff, style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(179))),
          Icon(Icons.arrow_drop_down, size: 14, color: cs.onSurface.withAlpha(138)),
        ]),
      ),
    );
  }

  Widget _numberTagCircleBtn(double size, double circleRadius, ColorScheme cs) {
    final active = options.numberTagSize == size;
    return GestureDetector(
      onTap: () => _update(numberTagSize: size),
      child: Container(
        width: _strokeBtnW,
        height: _strokeBtnH,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          color: active ? cs.onSurface.withAlpha(30) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
              color: active ? cs.onSurface.withAlpha(138) : cs.onSurface.withAlpha(61), width: 0.5),
        ),
        alignment: Alignment.center,
        child: Container(
          width: circleRadius * 2,
          height: circleRadius * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
                color: active ? cs.onSurface : cs.onSurface.withAlpha(153), width: 1.5),
          ),
        ),
      ),
    );
  }

  Widget _numberTagCustomSize() {
    return Builder(builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return GestureDetector(
        onTap: () {
          final ctrl = TextEditingController(
              text: '${options.numberTagSize.round()}');
          showDialog(
            context: ctx,
            builder: (c) {
              final dialogCs = Theme.of(c).colorScheme;
              return AlertDialog(
                backgroundColor: XMateColors.dialogBg(c),
                title: Text('Tag size (radius px)',
                    style: TextStyle(color: dialogCs.onSurface, fontSize: 15)),
                content: TextField(
                  controller: ctrl,
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  style: TextStyle(color: dialogCs.onSurface, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '4-100',
                    hintStyle: TextStyle(color: dialogCs.onSurface.withAlpha(77)),
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (v) {
                    final sz = double.tryParse(v);
                    if (sz != null && sz >= 4 && sz <= 100) {
                      _update(numberTagSize: sz);
                    }
                    Navigator.pop(c);
                  },
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      final sz = double.tryParse(ctrl.text);
                      if (sz != null && sz >= 4 && sz <= 100) {
                        _update(numberTagSize: sz);
                      }
                      Navigator.pop(c);
                    },
                    child: Text('OK',
                        style: TextStyle(color: dialogCs.onSurface)),
                  ),
                ],
              );
            },
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          height: _strokeBtnH,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: cs.onSurface.withAlpha(10),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: cs.onSurface.withAlpha(61), width: 0.5),
          ),
          alignment: Alignment.center,
          child: Text('${options.numberTagSize.round()}px',
              style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(153))),
        ),
      );
    });
  }

  Widget _eraserClearBtn() {
    return GestureDetector(
      onTap: onClearAll,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.red.withAlpha(40),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.red.withAlpha(100), width: 0.5),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.delete_outline, size: 14, color: Colors.redAccent),
          SizedBox(width: 3),
          Text('Clear',
              style: TextStyle(fontSize: 12, color: Colors.redAccent)),
        ]),
      ),
    );
  }
}

// ===== Color picker dialog =====

class _ColorPickerDialog extends StatefulWidget {
  final Color initialColor;
  final ValueChanged<Color> onColorPicked;
  const _ColorPickerDialog({required this.initialColor, required this.onColorPicked});
  @override State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late double _r, _g, _b;
  late final TextEditingController _hexCtrl;
  Color _preview = Colors.red;

  @override void initState() {
    super.initState();
    _r = (widget.initialColor.r * 255).round().toDouble();
    _g = (widget.initialColor.g * 255).round().toDouble();
    _b = (widget.initialColor.b * 255).round().toDouble();
    _preview = widget.initialColor;
    _hexCtrl = TextEditingController(text: _toHex(widget.initialColor));
  }

  @override void dispose() { _hexCtrl.dispose(); super.dispose(); }

  String _toHex(Color c) => '#${(c.r * 255).round().toRadixString(16).padLeft(2, '0')}${(c.g * 255).round().toRadixString(16).padLeft(2, '0')}${(c.b * 255).round().toRadixString(16).padLeft(2, '0')}'.toUpperCase();

  void _update() {
    final c = Color.fromARGB(255, _r.round().clamp(0, 255), _g.round().clamp(0, 255), _b.round().clamp(0, 255));
    setState(() { _preview = c; _hexCtrl.text = _toHex(c); });
  }

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: XMateColors.dialogBg(context),
      title: Text('Pick Color', style: TextStyle(color: cs.onSurface, fontSize: 16)),
      content: SizedBox(width: 260, child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Container(width: 40, height: 40,
            decoration: BoxDecoration(color: _preview, borderRadius: BorderRadius.circular(6), border: Border.all(color: cs.onSurface.withAlpha(77)))),
          const SizedBox(width: 12),
          Expanded(child: TextField(
            controller: _hexCtrl,
            style: TextStyle(color: cs.onSurface, fontSize: 14, fontFamily: 'Consolas'),
            decoration: InputDecoration(labelText: 'HEX', labelStyle: TextStyle(color: cs.onSurface.withAlpha(138)), border: const OutlineInputBorder(), isDense: true),
            onSubmitted: (v) {
              final hex = v.replaceFirst('#', '');
              if (hex.length == 6) {
                final r = int.tryParse(hex.substring(0, 2), radix: 16);
                final g = int.tryParse(hex.substring(2, 4), radix: 16);
                final b = int.tryParse(hex.substring(4, 6), radix: 16);
                if (r != null && g != null && b != null) {
                  _r = r.toDouble(); _g = g.toDouble(); _b = b.toDouble(); _update();
                }
              }
            },
          )),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 5, runSpacing: 5, children: [
          Colors.red, Colors.pink, Colors.purple, Colors.deepPurple,
          Colors.indigo, Colors.blue, Colors.lightBlue, Colors.cyan,
          Colors.teal, Colors.green, Colors.lightGreen, Colors.lime,
          Colors.yellow, Colors.amber, Colors.orange, Colors.deepOrange,
          Colors.brown, Colors.grey, Colors.blueGrey, Colors.white,
        ].map((c) => GestureDetector(
          onTap: () {
            _r = (c.r * 255).round().toDouble();
            _g = (c.g * 255).round().toDouble();
            _b = (c.b * 255).round().toDouble();
            _update();
          },
          child: Container(width: 24, height: 24,
            decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(4), border: Border.all(color: cs.onSurface.withAlpha(61))),
          ),
        )).toList()),
        const SizedBox(height: 12),
        _slider('R', _r, Colors.red, cs, (v) { _r = v; _update(); }),
        _slider('G', _g, Colors.green, cs, (v) { _g = v; _update(); }),
        _slider('B', _b, Colors.blue, cs, (v) { _b = v; _update(); }),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel', style: TextStyle(color: cs.onSurface.withAlpha(138)))),
        TextButton(onPressed: () { widget.onColorPicked(_preview); Navigator.pop(context); }, child: Text('Apply', style: TextStyle(color: cs.onSurface))),
      ],
    );
  }

  Widget _slider(String label, double val, Color color, ColorScheme cs, ValueChanged<double> onChanged) {
    return Row(children: [
      SizedBox(width: 16, child: Text(label, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold))),
      Expanded(child: SliderTheme(data: SliderThemeData(trackHeight: 4, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8)), child: Slider(
        value: val, min: 0, max: 255, activeColor: color, onChanged: onChanged,
      ))),
      SizedBox(width: 36, child: Text(val.round().toString(), style: TextStyle(color: cs.onSurface.withAlpha(153), fontSize: 12))),
    ]);
  }
}
