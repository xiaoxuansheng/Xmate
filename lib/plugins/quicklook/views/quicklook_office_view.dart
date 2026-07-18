/// Office document preview via native Windows IPreviewHandler.
///
/// Embeds the system preview handler as a child HWND overlaid on the Flutter
/// content area — supports Word (.doc/.docx/.docm), PowerPoint (.ppt/.pptx/.pptm),
/// and Excel (.xls/.xlsx/.xlsm).  The native office_preview_handler
/// infrastructure dynamically resolves the CLSID for each extension via
/// AssocQueryString, so the Dart code is extension-agnostic.
///
/// State machine: creating → ready | error (→ parent fallback)
/// The parent (_doLoad) already confirmed the preview handler is registered
/// via a lightweight registry check, so we skip that and go straight to
/// creating the native instance.  If creation fails we fall back.
library;

import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/theme/theme_colors.dart';

/// Merged Office preview widget — replaces the previously separate
/// QuickLookWordView / QuickLookPptView / QuickLookExcelView classes
/// (which were 100 % identical except for their class names).
class QuickLookOfficeView extends StatefulWidget {
  final String filePath;
  final VoidCallback onFallback;

  const QuickLookOfficeView({
    super.key,
    required this.filePath,
    required this.onFallback,
  });

  @override
  State<QuickLookOfficeView> createState() => _QuickLookOfficeViewState();
}

enum _State { creating, ready, error }

class _QuickLookOfficeViewState extends State<QuickLookOfficeView> {
  static const _channel = MethodChannel('com.xmate/officepreview');

  _State _state = _State.creating;
  int _instance = 0;
  final GlobalKey _areaKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Parent already confirmed handler availability — go straight to create.
    WidgetsBinding.instance.addPostFrameCallback((_) => _create());
  }

  @override
  void dispose() {
    _destroy();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant QuickLookOfficeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filePath != oldWidget.filePath) {
      _destroy();
      _instance = 0;
      _state = _State.creating;
      WidgetsBinding.instance.addPostFrameCallback((_) => _create());
    }
  }

  // ── State machine ─────────────────────────────────────────────────────────

  Future<void> _create() async {
    if (!mounted || _state != _State.creating) return;

    final box = _areaKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      // Layout not ready — retry next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => _create());
      return;
    }

    final dpr = ui.PlatformDispatcher.instance.displays.first.devicePixelRatio;
    final offset = box.localToGlobal(Offset.zero);
    final x = (offset.dx * dpr).round();
    final y = (offset.dy * dpr).round();
    final w = (box.size.width * dpr).round();
    final h = (box.size.height * dpr).round();

    if (w <= 0 || h <= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _create());
      return;
    }

    int instance = 0;
    try {
      instance = await _channel.invokeMethod<int>('create', {
        'path': widget.filePath.replaceAll('/', '\\'),
        'x': x, 'y': y, 'w': w, 'h': h,
      }) ?? 0;
    } catch (_) {}

    if (!mounted) return;
    if (instance == 0) {
      _state = _State.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onFallback();
      });
      return;
    }

    _instance = instance;
    setState(() => _state = _State.ready);

    // Keep syncing rect on subsequent frames (e.g. window resize).
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncRect());
  }

  void _syncRect() {
    if (!mounted || _state != _State.ready || _instance == 0) return;

    final box = _areaKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    final dpr = ui.PlatformDispatcher.instance.displays.first.devicePixelRatio;
    final offset = box.localToGlobal(Offset.zero);
    final newRect = ui.Rect.fromLTWH(
      offset.dx * dpr, offset.dy * dpr,
      box.size.width * dpr, box.size.height * dpr,
    );

    // Always sync — needed not only for resize but also to maintain z-order
    // (Flutter may push its child HWND above the native preview child during
    // title-bar mouse interaction).  SetWordPreviewRect re-asserts HWND_TOP.
    _channel.invokeMethod('setRect', {
      'instance': _instance,
      'x': newRect.left.round(),
      'y': newRect.top.round(),
      'w': newRect.width.round(),
      'h': newRect.height.round(),
    });

    // Continue watching (layout may change again).
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncRect());
  }

  void _destroy() {
    if (_instance != 0) {
      _channel.invokeMethod('destroy', {'instance': _instance});
      _instance = 0;
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Stack(children: [
      Container(key: _areaKey, color: XMateColors.panelBg(context)),
      if (_state != _State.ready)
        Center(
          child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
        ),
    ]);
  }
}
