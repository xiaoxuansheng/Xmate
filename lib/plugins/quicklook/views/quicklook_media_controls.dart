/// Shared media playback controls extracted from QuickLookAudioView and
/// QuickLookVideoView.
///
/// Contains:
/// - `mediaTimeStr`     — portable Duration→MM:SS formatter
/// - `mediaHandleKey`   — portable keyboard handler (Space/arrows/Enter)
/// - `QuickLookMediaOverlay` — mixin: overlay insert/remove, popup scaffold, info row
/// - `QuickLookMediaTransportBar` — button row (loop/speed/play/volume/info)
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/theme/theme_colors.dart';

// ─── Shared constants ─────────────────────────────────────────────────────────

const kMediaSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

// ─── Time formatting ──────────────────────────────────────────────────────────

/// Format [d] as `MM:SS` — identical to the former `_fmt` helpers in audio
/// and video views.
String mediaTimeStr(Duration d) {
  final secs = d.inSeconds;
  final min = secs ~/ 60;
  final sec = secs % 60;
  return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
}

// ─── Speed stepping ───────────────────────────────────────────────────────────

/// Returns the next speed step, or null when already at max.
double? nextSpeed(double current) {
  final idx = kMediaSpeeds.indexOf(current);
  if (idx >= 0 && idx < kMediaSpeeds.length - 1) return kMediaSpeeds[idx + 1];
  return null;
}

/// Returns the previous speed step, or null when already at min.
double? prevSpeed(double current) {
  final idx = kMediaSpeeds.indexOf(current);
  if (idx > 0) return kMediaSpeeds[idx - 1];
  return null;
}

// ─── Seek relative ────────────────────────────────────────────────────────────

/// Compute a new position [seconds] away from [position], clamped to [duration].
Duration seekRelative(Duration position, Duration duration, int seconds) {
  final target = (position.inMilliseconds + seconds * 1000)
      .clamp(0, duration.inMilliseconds)
      .toInt();
  return Duration(milliseconds: target);
}

// ─── Keyboard handler ─────────────────────────────────────────────────────────

/// Portable keyboard handler for media views.
///
/// Space = play/pause (KeyDownEvent only — single-fire).
/// ← / → = seek ±1 s (repeat on hold).
/// ↑ / ↓ = speed up/down (repeat on hold).
/// Enter = open file (KeyDownEvent only).
KeyEventResult mediaHandleKey(
  KeyEvent event, {
  required VoidCallback onPlayPause,
  required VoidCallback onSeekBack,
  required VoidCallback onSeekForward,
  required VoidCallback onSpeedUp,
  required VoidCallback onSpeedDown,
  VoidCallback? onOpenFile,
}) {
  if (event is KeyDownEvent || event is KeyRepeatEvent) {
    final isDown = event is KeyDownEvent;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        if (isDown) onPlayPause();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        onSeekBack();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        onSeekForward();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        onSpeedUp();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        onSpeedDown();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        if (isDown) onOpenFile?.call();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }
  return KeyEventResult.ignored;
}

// ─── Overlay mixin ────────────────────────────────────────────────────────────

/// Mixin that provides shared overlay / popup helpers for audio and video
/// views.  The host [State] must have a `_popOverlay` field initialised to
/// `null` by its own `dispose()` logic.
mixin QuickLookMediaOverlay<T extends StatefulWidget> on State<T> {
  OverlayEntry? _mediaOverlay;

  /// Insert a popup built by [builder]; the builder receives a `dismiss`
  /// callback that the popup content should call to close itself.
  void showOverlay(Widget Function(VoidCallback dismiss) builder) {
    _mediaOverlay?.remove();
    OverlayEntry? entry;
    entry = OverlayEntry(
      builder: (_) => builder(() {
        entry?.remove();
        if (_mediaOverlay == entry) _mediaOverlay = null;
      }),
    );
    _mediaOverlay = entry;
    Overlay.of(context).insert(entry);
  }

  /// Force the overlay to rebuild (e.g. after volume / mute change).
  void refreshOverlay() {
    _mediaOverlay?.markNeedsBuild();
  }

  /// Remove the overlay (call from host's `dispose()`).
  void removeOverlay() {
    _mediaOverlay?.remove();
    _mediaOverlay = null;
  }

  /// Semi-transparent full-screen backdrop that dismisses on background tap.
  /// [child] is centred at the bottom with [bottomOffset] pixels of padding.
  Widget popupScaffold(
    VoidCallback dismiss, {
    required double bottomOffset,
    required Widget child,
  }) {
    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: dismiss,
            child: Container(color: Colors.transparent),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomOffset),
              child: child,
            ),
          ),
        ],
      ),
    );
  }

  /// Two-column row: label left, value right.
  Widget infoRow(String label, String value, ColorScheme cs) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(130))),
        Text(value, style: TextStyle(fontSize: 12, color: cs.onSurface)),
      ],
    );
  }
}

// ─── Transport bar ────────────────────────────────────────────────────────────

/// Shared transport button row (loop / speed / play-pause / volume / info).
///
/// All callbacks are invoked by the buttons; this widget has no internal
/// mutable state of its own — it relies entirely on the parameters passed
/// by the parent audio / video view.
class QuickLookMediaTransportBar extends StatelessWidget {
  final bool isPlaying, loading, looping, muted;
  final double speed, volume;
  final double playIconSize; // 36 (audio) or 32 (video)

  final VoidCallback onPlayPause, onToggleLoop, onToggleMute;
  final ValueChanged<double> onSetSpeed, onSetVolume;
  final VoidCallback onOpenVolume, onOpenInfo;

  const QuickLookMediaTransportBar({
    super.key,
    required this.isPlaying,
    required this.loading,
    required this.looping,
    required this.muted,
    required this.speed,
    required this.volume,
    this.playIconSize = 36,
    required this.onPlayPause,
    required this.onToggleLoop,
    required this.onToggleMute,
    required this.onSetSpeed,
    required this.onSetVolume,
    required this.onOpenVolume,
    required this.onOpenInfo,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _loopBtn(cs),
        const SizedBox(width: 10),
        _speedBtn(context, cs),
        const SizedBox(width: 10),
        _iconBtn(
          icon: loading
              ? Icons.hourglass_empty
              : isPlaying
                  ? Icons.pause
                  : Icons.play_arrow,
          size: playIconSize,
          onTap: onPlayPause,
          cs: cs,
        ),
        const SizedBox(width: 10),
        _volBtn(cs),
        const SizedBox(width: 10),
        _infoBtn(cs),
      ],
    );
  }

  // ── Individual buttons (private) ──────────────────────────────────────────

  Widget _iconBtn({
    required IconData icon,
    double size = 24,
    required VoidCallback onTap,
    required ColorScheme cs,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: cs.onSurface.withAlpha(20),
          border: Border.all(color: cs.onSurface.withAlpha(40), width: 1),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: size, color: cs.onSurface),
      ),
    );
  }

  Widget _loopBtn(ColorScheme cs) {
    return GestureDetector(
      onTap: onToggleLoop,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: looping
              ? cs.primary.withAlpha(30)
              : cs.onSurface.withAlpha(12),
          border: looping
              ? Border.all(color: cs.primary, width: 1)
              : null,
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.repeat,
          size: 18,
          color: looping ? cs.primary : cs.onSurface.withAlpha(138),
        ),
      ),
    );
  }

  Widget _speedBtn(BuildContext ctx, ColorScheme cs) {
    return PopupMenuButton<double>(
      initialValue: speed,
      offset: const Offset(0, -140),
      color: XMateColors.toolbarBg(ctx),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: cs.onSurface.withAlpha(61), width: 1),
      ),
      onSelected: onSetSpeed,
      itemBuilder: (_) => kMediaSpeeds
          .map((s) => PopupMenuItem<double>(
                value: s,
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      s == s.truncateToDouble()
                          ? '${s.toStringAsFixed(0)}×'
                          : '${s}x',
                      style: TextStyle(
                        fontSize: 13,
                        color: (speed - s).abs() < 0.01
                            ? cs.primary
                            : cs.onSurface.withAlpha(179),
                        fontWeight: (speed - s).abs() < 0.01
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                    if ((speed - s).abs() < 0.01) ...[
                      const SizedBox(width: 8),
                      Icon(Icons.check, size: 14, color: cs.primary),
                    ],
                  ],
                ),
              ))
          .toList(),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: cs.onSurface.withAlpha(12),
        ),
        alignment: Alignment.center,
        child: Text(
          speed == speed.truncateToDouble()
              ? '${speed.toStringAsFixed(0)}×'
              : '${speed}x',
          style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(179)),
        ),
      ),
    );
  }

  Widget _volBtn(ColorScheme cs) {
    final icon = muted || volume == 0
        ? Icons.volume_off
        : volume < 0.5
            ? Icons.volume_down
            : Icons.volume_up;
    return GestureDetector(
      onTap: onOpenVolume,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: cs.onSurface.withAlpha(12),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 18, color: cs.onSurface.withAlpha(179)),
      ),
    );
  }

  Widget _infoBtn(ColorScheme cs) {
    return GestureDetector(
      onTap: onOpenInfo,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: cs.onSurface.withAlpha(12),
        ),
        alignment: Alignment.center,
        child: Icon(Icons.info_outline, size: 18, color: cs.onSurface.withAlpha(179)),
      ),
    );
  }
}
