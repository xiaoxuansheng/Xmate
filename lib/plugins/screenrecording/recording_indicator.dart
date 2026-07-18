/// Floating recording indicator bar for the recording subprocess.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/quicklook/quicklook_utils.dart';
import '../../core/theme/theme_colors.dart';
import 'recording_state.dart';
import 'recording_service.dart';

class RecordingIndicator extends StatefulWidget {
  final RecordingService service;
  final RecordingStatus status;
  final VoidCallback onRecord;
  final VoidCallback onPause;
  final VoidCallback onToggleSettings;
  final VoidCallback onClose;
  final VoidCallback? onOpenFolder;
  final VoidCallback? onDeleteFile;
  final VoidCallback? onDismissFileBar;
  final bool showFileBar;
  final String? savedFilePath;
  final int fileSize;
  final bool settingsOpen;
  final bool collapsed; // when true, render as a thin strip (auto-hide mode)
  final VoidCallback? onToggleMouse;
  final bool showMouse;
  final VoidCallback? onToggleAllMonitors;
  final bool allMonitors;

  const RecordingIndicator({
    super.key,
    required this.service,
    required this.status,
    required this.onRecord,
    required this.onPause,
    required this.onToggleSettings,
    required this.onClose,
    this.onOpenFolder,
    this.onDeleteFile,
    this.onDismissFileBar,
    this.showFileBar = false,
    this.savedFilePath,
    this.fileSize = 0,
    this.settingsOpen = false,
    this.collapsed = false,
    this.onToggleMouse,
    this.showMouse = true,
    this.onToggleAllMonitors,
    this.allMonitors = false,
  });

  @override State<RecordingIndicator> createState() =>
      _RecordingIndicatorState();
}

class _RecordingIndicatorState extends State<RecordingIndicator> {
  Timer? _elapsedTimer;
  int _displayMs = 0;
  bool _recDotOn = true;
  Timer? _dotTimer;

  @override void initState() {
    super.initState();
    _startTimers();
  }

  @override void didUpdateWidget(RecordingIndicator old) {
    super.didUpdateWidget(old);
    final wasActive = old.status == RecordingStatus.recording;
    final isActive = widget.status == RecordingStatus.recording;
    if (!wasActive && isActive) _startTimers();
    if (wasActive && !isActive) _stopTimers();
  }

  void _startTimers() {
    _stopTimers();
    _elapsedTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() => _displayMs = widget.service.elapsedMs);
    });
    _dotTimer = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (mounted) setState(() => _recDotOn = !_recDotOn);
    });
  }

  void _stopTimers() {
    _elapsedTimer?.cancel(); _elapsedTimer = null;
    _dotTimer?.cancel(); _dotTimer = null;
  }

  String _fmtDuration(int ms) {
    final totalSec = ms ~/ 1000;
    final m = totalSec ~/ 60, s = totalSec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  bool get _isIdle => widget.status == RecordingStatus.idle;
  bool get _isRec => widget.status == RecordingStatus.recording;
  bool get _isStopping => widget.status == RecordingStatus.stopping;
  bool get _isPaused => widget.status == RecordingStatus.paused;
  bool get _isDone => widget.status == RecordingStatus.stopped;
  bool get _isErr => widget.status == RecordingStatus.error;

  bool get _canRecord => _isIdle || _isDone || _isErr;
  bool get _canPause => _isRec || _isPaused;

  // ── Status icon + label ──

  Widget _statusSection() {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 72,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (_isIdle || _isStopping) ...[
          _statusDot(Colors.grey),
          const SizedBox(width: 3),
          const Text('IDLE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.grey)),
        ] else if (_isRec) ...[
          _statusDot(_recDotOn ? Colors.red : Colors.red.withAlpha(80)),
          const SizedBox(width: 3),
          Text('REC', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: cs.onSurface)),
        ] else if (_isPaused) ...[
          Icon(Icons.pause, size: 10, color: cs.primary),
          const SizedBox(width: 2),
          Text('PAUSE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: cs.primary)),
        ] else if (_isDone) ...[
          const Icon(Icons.check_circle, size: 11, color: Color(0xFF40C057)),
          const SizedBox(width: 2),
          const Text('SAVED', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF40C057))),
        ] else if (_isErr) ...[
          const Icon(Icons.error, size: 11, color: Colors.redAccent),
          const SizedBox(width: 2),
          const Text('ERROR', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.redAccent)),
        ],
      ]),
    );
  }

  Widget _statusDot(Color color) {
    return Container(
      width: 8, height: 8,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }

  // ── Timer section ──

  Widget _timerSection() {
    final cs = Theme.of(context).colorScheme;
    final text = _isIdle ? '--:--' : _fmtDuration(_displayMs);
    return SizedBox(
      width: 52,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface,
          fontFamily: 'monospace',
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  // ── Buttons ──

  static const _btnSize = 22.0;
  static const _btnRadius = 4.0;

  Widget _recordBtn() {
    if (_canRecord) {
      return _iconBtn(
        Icons.fiber_manual_record, Colors.red,
        widget.onRecord, active: true,
      );
    }
    return _iconBtn(
      Icons.stop, Colors.red,
      widget.onRecord, active: true,
      bgColor: const Color(0x88FF4444),
    );
  }

  Widget _pauseBtn() {
    final cs = Theme.of(context).colorScheme;
    final Color fg = _canPause ? cs.onSurface.withAlpha(179) : cs.onSurface.withAlpha(40);
    final icon = _isPaused ? Icons.play_arrow : Icons.pause;
    return _iconBtn(icon, fg, _canPause ? widget.onPause : () {});
  }

  Widget _kbMouseBtn() {
    final cs = Theme.of(context).colorScheme;
    final on = widget.showMouse;
    return _iconBtn(
      Icons.keyboard_alt_outlined,
      on ? cs.onSurface.withAlpha(179) : cs.onSurface.withAlpha(40),
      widget.onToggleMouse ?? () {},
      active: on,
      bgColor: on ? null : cs.onSurface.withAlpha(10),
    );
  }

  Widget _settingsBtn() {
    return _iconBtn(
      Icons.settings, Theme.of(context).colorScheme.onSurface.withAlpha(179), widget.onToggleSettings,
    );
  }

  Widget _allMonitorsBtn() {
    final cs = Theme.of(context).colorScheme;
    final on = widget.allMonitors;
    return _iconBtn(
      Icons.screenshot_monitor,
      on ? cs.onSurface.withAlpha(179) : cs.onSurface.withAlpha(40),
      widget.onToggleAllMonitors ?? () {},
      active: on,
      bgColor: on ? null : cs.onSurface.withAlpha(10),
    );
  }

  Widget _closeBtn() {
    final cs = Theme.of(context).colorScheme;
    return _iconBtn(
      Icons.close, cs.onSurface.withAlpha(179), widget.onClose,
    );
  }

  Widget _iconBtn(IconData icon, Color fg, VoidCallback onTap, {bool active = true, Color? bgColor}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: _btnSize, height: _btnSize,
        decoration: BoxDecoration(
          color: bgColor ?? (active ? XMateColors.cardFill(context) : Colors.transparent),
          borderRadius: BorderRadius.circular(_btnRadius),
        ),
        child: Icon(icon, size: active ? 14 : 13, color: fg),
      ),
    );
  }

  // ── File bar (shown after recording completes) ──

  Widget _fileBar() {
    if (!widget.showFileBar || widget.savedFilePath == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final path = widget.savedFilePath!;
    final name = path.split('\\').last;
    final sizeStr = fileSizeStr(widget.fileSize);
    return Container(
      width: 360,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: XMateColors.panelBg(context),
        border: Border(
          top: BorderSide(color: cs.onSurface.withAlpha(48)),
          bottom: BorderSide(color: cs.onSurface.withAlpha(48)),
        ),
      ),
      child: Row(children: [
        Icon(Icons.movie, size: 13, color: cs.onSurface.withAlpha(138)),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(name, style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(179)),
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 1),
              Text(sizeStr, style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(97))),
            ],
          ),
        ),
        _fileBarBtn(Icons.folder_open, 'Open folder', widget.onOpenFolder ?? () {}),
        const SizedBox(width: 2),
        _fileBarBtn(Icons.delete_outline, 'Delete', widget.onDeleteFile ?? () {}),
        const SizedBox(width: 2),
        _fileBarBtn(Icons.close, 'Close', widget.onDismissFileBar ?? () {}),
      ]),
    );
  }

  Widget _fileBarBtn(IconData icon, String tooltip, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: tooltip,
        preferBelow: true,
        child: Container(
          width: 22, height: 22,
          decoration: BoxDecoration(
            color: XMateColors.inputBorder(context),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Icon(icon, size: 13, color: Theme.of(context).colorScheme.onSurface.withAlpha(138)),
        ),
      ),
    );
  }

  // ── Build ──

  @override void dispose() {
    _stopTimers();
    super.dispose();
  }

  @override Widget build(BuildContext context) {
    if (widget.collapsed) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _indicatorBar(),
        _fileBar(),
      ],
    );
  }

  Widget _indicatorBar() {
    final cs = Theme.of(context).colorScheme;
    final accentBorder = BorderSide(color: cs.primary.withAlpha(64));
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        height: 30, width: 360,
        decoration: BoxDecoration(
          color: XMateColors.panelBg(context),
          borderRadius: widget.settingsOpen
              ? BorderRadius.zero
              : const BorderRadius.only(
                  bottomLeft: Radius.circular(6),
                  bottomRight: Radius.circular(6)),
          border: Border(
            top: accentBorder,
            left: accentBorder,
            right: accentBorder,
            bottom: widget.settingsOpen
                ? BorderSide.none
                : accentBorder,
          ),
        ),
        child: Row(children: [
          const SizedBox(width: 6),
          _statusSection(),
          _timerSection(),
          const Spacer(),
          _recordBtn(),
          const SizedBox(width: 3),
          _pauseBtn(),
          const SizedBox(width: 3),
          _kbMouseBtn(),
          const SizedBox(width: 3),
          _allMonitorsBtn(),
          const SizedBox(width: 3),
          _settingsBtn(),
          const SizedBox(width: 3),
          _closeBtn(),
          const SizedBox(width: 6),
        ]),
      ),
    );
  }
}
