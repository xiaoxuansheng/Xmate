/// OLE drag-out helpers.
///
/// Provides unified widgets that add "drag selected text / file paths
/// out of XMate → Explorer / other apps" on top of existing Flutter
/// text widgets.  Uses the [com.xmate/dragout] method channel (native
/// C++ OLE DoDragDrop → CF_HDROP / CF_UNICODETEXT).
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ── Channel singleton ──────────────────────────────────────────────

class DragOutChannel {
  static const _channel = MethodChannel('com.xmate/dragout');

  /// Start a file drag (CF_HDROP).  [paths] may contain files or
  /// directories — the native side copies the path strings, it does
  /// not read file contents.
  static Future<bool?> dragFile(List<String> paths) =>
      _channel.invokeMethod<bool>('start', {'mode': 'file', 'files': paths});

  /// Start a plain-text drag (CF_UNICODETEXT).
  static Future<bool?> dragText(String text) =>
      _channel.invokeMethod<bool>('start', {'mode': 'text', 'text': text});
}

// ── Shared mixin for the drag-out state machine ───────────────────

mixin _DragOutStateMixin<T extends StatefulWidget> on State<T> {
  int? _dragPtrId;
  Offset? _dragOrigin;
  bool _dragFired = false;

  /// Frozen at [onPointerDown].  Must be computed before the pointer
  /// interaction starts — subsequent selection changes during the
  /// gesture MUST NOT flip this flag.
  bool _dragAllow = false;

  /// The text payload to drag, frozen at [onPointerDown].  This is
  /// the key fix: [SelectableText] keeps updating its selection
  /// range during a pointer-move gesture, so we must capture the
  /// selected text **before** the move has a chance to mutate it.
  /// Once frozen this string is immutable for the duration of the
  /// pointer interaction.
  String? _dragTextSnapshot;

  static const double _dragThreshold = 8.0;

  void _onDragPointerDown(PointerDownEvent e) {
    // Guard against concurrent pointers
    if (_dragPtrId != null && _dragPtrId != e.pointer) return;
    _dragPtrId = e.pointer;
    _dragOrigin = e.position;
    _dragFired = false;
    freezeDragState(); // ← snapshots both _dragAllow and _dragTextSnapshot
  }

  void _onDragPointerMove(PointerMoveEvent e) {
    if (e.pointer != _dragPtrId) return;
    if (_dragOrigin == null || _dragFired) return;
    if (!_dragAllow) return;
    if (_dragTextSnapshot == null || _dragTextSnapshot!.trim().isEmpty) return;
    if ((e.buttons & kPrimaryMouseButton) == 0) return;
    if ((e.position - _dragOrigin!).distance < _dragThreshold) return;

    _dragFired = true;
    // Use the frozen snapshot — NOT a live selection read.
    doDrag(_dragTextSnapshot!).whenComplete(_resetDrag);
  }

  void _onDragPointerUp(PointerUpEvent e) {
    if (e.pointer == _dragPtrId) _resetDrag();
  }

  void _onDragPointerCancel(PointerCancelEvent e) {
    if (e.pointer == _dragPtrId) _resetDrag();
  }

  void _resetDrag() {
    _dragPtrId = null;
    _dragOrigin = null;
    _dragFired = false;
    _dragAllow = false;
    _dragTextSnapshot = null;
  }

  /// Called once in [onPointerDown].  Subclasses MUST set both
  /// [_dragAllow] and [_dragTextSnapshot] before returning.
  void freezeDragState();

  /// Subclasses override to start the actual drag.
  Future<bool?> doDrag(String payload) => DragOutChannel.dragText(payload);
}

// ── DragOutSelectableText ──────────────────────────────────────────

/// Drop-in replacement for [SelectableText] that adds OLE drag-out of
/// selected text when the user presses the left mouse button and drags
/// past the threshold.
///
/// Semantics: "select first, then drag out".  The currently selected
/// text is frozen at the moment of [PointerDownEvent]; subsequent
/// selection changes during the pointer gesture are ignored so the
/// drag always carries the text the user originally selected.
class DragOutSelectableText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final Color? selectionColor;
  final Color? cursorColor;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final FocusNode? focusNode;
  final bool enableDragOut;
  final double dragThreshold;

  const DragOutSelectableText(
    this.text, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.selectionColor,
    this.cursorColor,
    this.contextMenuBuilder,
    this.focusNode,
    this.enableDragOut = true,
    this.dragThreshold = 8.0,
  });

  @override
  State<DragOutSelectableText> createState() => _DragOutSelectableTextState();
}

class _DragOutSelectableTextState extends State<DragOutSelectableText>
    with _DragOutStateMixin<DragOutSelectableText> {
  TextSelection _sel = TextSelection.collapsed(offset: -1);

  void _onSelectionChanged(TextSelection sel, SelectionChangedCause? cause) {
    // Only store the live selection for the next pointer-down freeze.
    // Never use _sel directly inside onPointerMove.
    _sel = sel;
  }

  @override
  void freezeDragState() {
    if (_sel.isValid && !_sel.isCollapsed) {
      final selected = _sel.textInside(widget.text);
      if (selected.trim().isNotEmpty) {
        _dragAllow = true;
        _dragTextSnapshot = selected; // ★ frozen here — never mutated
        return;
      }
    }
    _dragAllow = false;
    _dragTextSnapshot = null;
  }

  @override
  Widget build(BuildContext context) {
    final selText = SelectableText(
      widget.text,
      style: widget.style,
      textAlign: widget.textAlign,
      maxLines: widget.maxLines,
      selectionColor: widget.selectionColor,
      cursorColor: widget.cursorColor,
      contextMenuBuilder: widget.contextMenuBuilder,
      focusNode: widget.focusNode,
      onSelectionChanged: _onSelectionChanged,
    );

    if (!widget.enableDragOut) return selText;

    return Listener(
      onPointerDown: _onDragPointerDown,
      onPointerMove: _onDragPointerMove,
      onPointerUp: _onDragPointerUp,
      onPointerCancel: _onDragPointerCancel,
      child: selText,
    );
  }
}

// ── DragOutTextField ───────────────────────────────────────────────

/// Drop-in replacement for a single [TextField] that adds OLE drag-out
/// of selected text.  Reads the selection from the [controller] via
/// [TextEditingController.addListener] (the equivalent of
/// [SelectableText.onSelectionChanged]).
///
/// Same semantics as [DragOutSelectableText]: "select first, then drag".
class DragOutTextField extends StatefulWidget {
  final TextEditingController controller;
  final bool enableDragOut;
  final double dragThreshold;

  // Forwarded TextField params — the subset we commonly use.
  // Add more as needed.  Omit obscure ones that are never passed.
  final int? maxLines;
  final bool expands;
  final TextAlignVertical? textAlignVertical;
  final TextStyle? style;
  final InputDecoration? decoration;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  const DragOutTextField({
    super.key,
    required this.controller,
    this.enableDragOut = true,
    this.dragThreshold = 8.0,
    this.maxLines,
    this.expands = false,
    this.textAlignVertical,
    this.style,
    this.decoration,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
  });

  @override
  State<DragOutTextField> createState() => _DragOutTextFieldState();
}

class _DragOutTextFieldState extends State<DragOutTextField>
    with _DragOutStateMixin<DragOutTextField> {
  void _onControllerChanged() {
    // Controller selection tracking for the next pointer-down freeze.
    // The actual snapshot happens in freezeDragState().
  }

  @override
  void freezeDragState() {
    final sel = widget.controller.selection;
    if (sel.isValid && !sel.isCollapsed) {
      final selected = sel.textInside(widget.controller.text);
      if (selected.trim().isNotEmpty) {
        _dragAllow = true;
        _dragTextSnapshot = selected; // ★ frozen at pointer-down time
        return;
      }
    }
    _dragAllow = false;
    _dragTextSnapshot = null;
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tf = TextField(
      controller: widget.controller,
      maxLines: widget.maxLines,
      expands: widget.expands,
      textAlignVertical: widget.textAlignVertical,
      style: widget.style,
      decoration: widget.decoration,
      focusNode: widget.focusNode,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      autofocus: widget.autofocus,
    );

    if (!widget.enableDragOut) return tf;

    return Listener(
      onPointerDown: _onDragPointerDown,
      onPointerMove: _onDragPointerMove,
      onPointerUp: _onDragPointerUp,
      onPointerCancel: _onDragPointerCancel,
      child: tf,
    );
  }
}
