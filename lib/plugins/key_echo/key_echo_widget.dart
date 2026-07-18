/// Key echo overlay widgets — Hotkey panel (key combo notifications) and
/// Status panel (lock-key state indicator).
///
/// Sizing parameters (itemH, fontSize) are passed from the parent
/// (NotificationApp) which calculates them from screen dimensions so that
/// widgets render at the correct size regardless of the window size.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/theme/theme_colors.dart';

class _KeyEntry {
  final String label;
  final int? volume; // current system volume 0-100, only for Vol Up/Down
  Timer? timer;
  _KeyEntry(this.label, {this.volume});
}

// ─── Hotkey panel: key combo echo ──────────────────────────────────────

class KeyEchoHotkeyPanel extends StatefulWidget {
  final double itemH;
  final double fontSize;
  final VoidCallback? onChanged;
  const KeyEchoHotkeyPanel({
    super.key,
    required this.itemH,
    required this.fontSize,
    this.onChanged,
  });

  @override
  State<KeyEchoHotkeyPanel> createState() => KeyEchoHotkeyPanelState();
}

class KeyEchoHotkeyPanelState extends State<KeyEchoHotkeyPanel> {
  final List<_KeyEntry> _entries = [];
  static const int _maxEntries = 5;
  static const Duration _baseDuration = Duration(seconds: 1);

  int get entryCount => _entries.length;

  void addKey(String label, {int? volume}) {
    if (!mounted) return;

    final entry = _KeyEntry(label, volume: volume);
    _entries.insert(0, entry);
    if (_entries.length > _maxEntries) {
      _entries.removeLast().timer?.cancel();
    }
    setState(() {});
    widget.onChanged?.call();

    entry.timer = Timer(_baseDuration, () => _removeEntry(entry));
  }

  void _removeEntry(_KeyEntry entry) {
    if (!mounted) return;
    _entries.remove(entry);
    setState(() {});
    widget.onChanged?.call();
  }

  @override
  void dispose() {
    for (final e in _entries) {
      e.timer?.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_entries.isEmpty) return const SizedBox.shrink();

    final h = widget.itemH;
    final fs = widget.fontSize;
    final gap = h * 0.15;
    final padH = h * 0.5;
    final padV = h * 0.15;
    final radius = h * 0.35;

    return IgnorePointer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: _entries.map((e) {
          return Container(
            height: h,
            margin: EdgeInsets.only(bottom: gap),
            padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
            decoration: BoxDecoration(
              color: XMateColors.panelBg(context),
              borderRadius: BorderRadius.circular(radius),
            ),
            child: Center(
              child: _RowLabel(label: e.label, volume: e.volume, fontSize: fs),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _RowLabel extends StatelessWidget {
  final String label;
  final int? volume;
  final double fontSize;
  const _RowLabel({required this.label, this.volume, required this.fontSize});

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: XMateColors.textPrimary(context),
          height: 1.0,
        ),
        children: [
          TextSpan(text: label),
          if (volume != null)
            TextSpan(
              text: '  $volume%',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Status panel: lock keys ───────────────────────────────────────────

class KeyEchoStatusPanel extends StatefulWidget {
  final double itemH;
  final double fontSize;
  final VoidCallback? onChanged;
  const KeyEchoStatusPanel({
    super.key,
    required this.itemH,
    required this.fontSize,
    this.onChanged,
  });

  @override
  State<KeyEchoStatusPanel> createState() => KeyEchoStatusPanelState();
}

class KeyEchoStatusPanelState extends State<KeyEchoStatusPanel> {
  bool _caps = false, _num = true, _scroll = false, _insert = false;

  int get visibleCount =>
      (_caps ? 1 : 0) +
      (!_num ? 1 : 0) +
      (_scroll ? 1 : 0) +
      (_insert ? 1 : 0);

  void updateLockStates({
    required bool caps,
    required bool num,
    required bool scroll,
    required bool insert,
  }) {
    if (!mounted) return;
    _caps = caps;
    _num = num;
    _scroll = scroll;
    _insert = insert;
    setState(() {});
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (visibleCount == 0) return const SizedBox.shrink();

    final h = widget.itemH;
    final fs = widget.fontSize;
    final gap = h * 0.15;
    final padH = h * 0.5;
    final padV = h * 0.15;
    final radius = h * 0.35;

    final items = <Widget>[];
    if (_caps) items.add(_lbl('Caps Lock', h, fs, gap, padH, padV, radius));
    if (!_num) items.add(_lbl('Num Lock', h, fs, gap, padH, padV, radius));
    if (_scroll) items.add(_lbl('Scroll Lock', h, fs, gap, padH, padV, radius));
    if (_insert) items.add(_lbl('Insert', h, fs, gap, padH, padV, radius));

    return IgnorePointer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: items,
      ),
    );
  }

  Widget _lbl(
    String t,
    double h,
    double fs,
    double gap,
    double padH,
    double padV,
    double radius,
  ) {
    return Container(
      height: h,
      margin: EdgeInsets.only(bottom: gap),
      padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
      decoration: BoxDecoration(
        color: XMateColors.panelBg(context),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Center(
        child: Text(
          t,
          style: TextStyle(
            fontSize: fs,
            fontWeight: FontWeight.w600,
            color: XMateColors.textPrimary(context),
            height: 1.0,
          ),
        ),
      ),
    );
  }
}
