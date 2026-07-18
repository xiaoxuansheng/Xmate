/// Video preview for QuickLook.
///
/// Supports common video formats via fvp (mdk-sdk backend).
/// UI layout mirrors audio preview: filename + video area + transport bar.
/// First frame renders as poster before playback.
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart';
import 'package:video_player/video_player.dart';
import 'quicklook_media_controls.dart';
import '../../../../core/theme/theme_colors.dart';

class QuickLookVideoView extends StatefulWidget {
  final String filePath;
  final VoidCallback? onOpenFile;
  final void Function(Size naturalSize)? onVideoSizeReady;

  const QuickLookVideoView({
    super.key,
    required this.filePath,
    this.onOpenFile,
    this.onVideoSizeReady,
  });

  @override
  State<QuickLookVideoView> createState() => _QuickLookVideoViewState();
}

class _QuickLookVideoViewState extends State<QuickLookVideoView>
    with QuickLookMediaOverlay {
  late final VideoPlayerController _ctrl;

  bool _ready = false;
  bool _playing = false;
  double _speed = 1.0;
  double _volume = 1.0;
  bool _muted = false;
  double _preMuteVol = 1.0;
  bool _looping = false;

  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.file(File(widget.filePath));
    _init();
  }

  @override
  void dispose() {
    removeOverlay();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant QuickLookVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filePath != oldWidget.filePath) {
      _ctrl.pause();
      _init();
    }
  }

  Future<void> _init() async {
    final ctrl = _ctrl;
    try {
      ctrl.addListener(_onCtrlUpdate);
      ctrl.setLooping(_looping);
      await ctrl.initialize();
      if (!mounted || ctrl != _ctrl) return;
      setState(() => _ready = true);
      widget.onVideoSizeReady?.call(Size(
        ctrl.value.size.width.toDouble(),
        ctrl.value.size.height.toDouble(),
      ));
      await ctrl.play();
      await Future.delayed(const Duration(milliseconds: 50));
      if (!mounted || ctrl != _ctrl) return;
      await ctrl.pause();
    } catch (_) {
      if (!mounted || ctrl != _ctrl) return;
      setState(() => _ready = true);
    }
  }

  void _onCtrlUpdate() {
    if (!mounted) return;
    final v = _ctrl.value;
    setState(() {
      _playing = v.isPlaying;
      if (!v.isInitialized) _ready = false;
    });
    if (v.position >= v.duration && v.duration > Duration.zero && !v.isLooping) {
      if (v.isPlaying) _ctrl.pause();
    }
  }

  // ─── Actions ───

  void _togglePlayPause() {
    if (!_ready) return;
    if (_ctrl.value.isPlaying) {
      if (_ctrl.value.position >= _ctrl.value.duration &&
          _ctrl.value.duration > Duration.zero) {
        _ctrl.seekTo(Duration.zero);
        _ctrl.play();
      } else {
        _ctrl.pause();
      }
    } else {
      _ctrl.play();
    }
  }

  void _seek(Duration pos) {
    _ctrl.seekTo(pos);
    setState(() {});
  }

  void _seekRelative(int seconds) {
    final pos = seekRelative(
      _ctrl.value.position, _ctrl.value.duration, seconds);
    _seek(pos);
  }

  void _setSpeed(double speed) {
    _speed = speed;
    _ctrl.setPlaybackSpeed(speed);
    setState(() {});
  }

  void _speedUp() {
    final n = nextSpeed(_speed);
    if (n != null) _setSpeed(n);
  }

  void _speedDown() {
    final p = prevSpeed(_speed);
    if (p != null) _setSpeed(p);
  }

  void _toggleMute() {
    if (_muted) {
      _muted = false; _volume = _preMuteVol;
    } else {
      _muted = true; _preMuteVol = _volume; _volume = 0;
    }
    _ctrl.setVolume(_volume);
    refreshOverlay();
    setState(() {});
  }

  void _setVolume(double v) {
    _volume = v; _muted = v == 0;
    if (!_muted) _preMuteVol = v;
    _ctrl.setVolume(v);
    refreshOverlay();
    setState(() {});
  }

  void _toggleLoop() {
    _looping = !_looping;
    _ctrl.setLooping(_looping);
    setState(() {});
  }

  // ─── Keyboard ───

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    return mediaHandleKey(
      event,
      onPlayPause: _togglePlayPause,
      onSeekBack: () => _seekRelative(-1),
      onSeekForward: () => _seekRelative(1),
      onSpeedUp: _speedUp,
      onSpeedDown: _speedDown,
      onOpenFile: widget.onOpenFile,
    );
  }

  // ─── Volume popup ───

  void _openVolume() => showOverlay(_buildVolumeOverlay);

  Widget _buildVolumeOverlay(VoidCallback dismiss) {
    final cs = Theme.of(context).colorScheme;
    return popupScaffold(dismiss, bottomOffset: 72,
      child: Container(
        width: 160, height: 36,
        decoration: BoxDecoration(
          color: XMateColors.toolbarBg(context), borderRadius: BorderRadius.circular(18),
          border: Border.all(color: cs.onSurface.withAlpha(61), width: 1),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          GestureDetector(
            onTap: _toggleMute,
            child: Icon(
              _muted || _volume == 0 ? Icons.volume_off
                  : _volume < 0.5 ? Icons.volume_down : Icons.volume_up,
              size: 18, color: cs.onSurface.withAlpha(179)),
          ),
          Expanded(child: SliderTheme(data: _sliderTheme(cs, 2.5, 5),
            child: Slider(min: 0, max: 1, value: _volume, onChanged: _setVolume),
          )),
          SizedBox(width: 36, child: Text('${(_volume * 100).round()}',
            style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(138)),
            textAlign: TextAlign.center)),
        ]),
      ),
    );
  }

  // ─── Info popup ───

  void _openInfo() => showOverlay(_buildInfoOverlay);

  Widget _buildInfoOverlay(VoidCallback dismiss) {
    final cs = Theme.of(context).colorScheme;
    final info = _getVideoInfo();
    return popupScaffold(dismiss, bottomOffset: 72,
      child: Container(
        width: 200,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: XMateColors.toolbarBg(context), borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.onSurface.withAlpha(61), width: 1),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          infoRow('Codec', info['codec'] ?? '—', cs),
          const SizedBox(height: 4),
          infoRow('Resolution', info['resolution'] ?? '—', cs),
          const SizedBox(height: 4),
          infoRow('Frame rate', info['fps'] ?? '—', cs),
          const SizedBox(height: 4),
          infoRow('Bitrate', info['bitrate'] ?? '—', cs),
        ]),
      ),
    );
  }

  Map<String, String> _getVideoInfo() {
    final v = _ctrl.value;
    final result = <String, String>{};
    try {
      final media = _ctrl.getMediaInfo();
      if (media != null && media.video != null && media.video!.isNotEmpty) {
        final vinfo = media.video!.first;
        result['codec'] = vinfo.codec.codec.isNotEmpty ? vinfo.codec.codec : '—';
        result['resolution'] = '${vinfo.codec.width} × ${vinfo.codec.height}';
        final fps = vinfo.codec.frameRate;
        result['fps'] = fps > 0 ? '${fps.toStringAsFixed(2)} fps' : '—';
        final br = vinfo.codec.bitRate;
        if (br > 0) {
          result['bitrate'] = '${(br / 1000).toStringAsFixed(0)} kbps';
        } else if (media.bitRate > 0) {
          result['bitrate'] = '${(media.bitRate / 1000).toStringAsFixed(0)} kbps';
        } else {
          result['bitrate'] = '—';
        }
        return result;
      }
    } catch (_) {}
    result['codec'] = '—';
    result['resolution'] = '${v.size.width.toInt()} × ${v.size.height.toInt()}';
    result['fps'] = '—';
    result['bitrate'] = '—';
    return result;
  }

  // ─── UI helpers ───

  static SliderThemeData _sliderTheme(ColorScheme cs, double trackH, double thumbR) {
    return SliderThemeData(
      trackHeight: trackH,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: thumbR),
      overlayShape: RoundSliderOverlayShape(overlayRadius: thumbR * 2),
      activeTrackColor: cs.primary, inactiveTrackColor: cs.onSurface.withAlpha(61),
      thumbColor: cs.primary, overlayColor: cs.primary.withAlpha(40),
    );
  }

  // ─── Build ───

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = _ctrl.value;
    final name = widget.filePath.split(RegExp(r'[/\\]')).last;
    final duration = v.duration;
    final position = v.position;
    final loading = !_ready || !v.isInitialized;

    return Focus(
      autofocus: true,
      onKeyEvent: _handleKey,
      child: Container(
        color: XMateColors.panelBg(context),
        child: Column(
          children: [
            // ── File name ──
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Row(children: [
                Icon(Icons.videocam, size: 16, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(name,
                  style: TextStyle(fontSize: 13, color: cs.onSurface, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis)),
              ]),
            ),

            // ── Video area ──
            Expanded(
              child: _ready && v.isInitialized
                  ? GestureDetector(
                      onTap: _togglePlayPause,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Center(child: AspectRatio(
                            aspectRatio: v.aspectRatio,
                            child: VideoPlayer(_ctrl),
                          )),
                          if (!_playing)
                            Icon(Icons.play_arrow, size: 48,
                                color: cs.onSurface.withAlpha(170)),
                        ],
                      ),
                    )
                  : Center(child: CircularProgressIndicator(
                      strokeWidth: 2, color: cs.primary)),
            ),

            // ── Transport bar ──
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              color: XMateColors.panelBg(context),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                // Progress bar
                Row(children: [
                  Text(mediaTimeStr(position), style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(138))),
                  Expanded(child: SliderTheme(data: _sliderTheme(cs, 3, 6),
                    child: Slider(
                      min: 0,
                      max: duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 1.0,
                      value: position.inMilliseconds.toDouble()
                          .clamp(0, duration.inMilliseconds > 0
                              ? duration.inMilliseconds.toDouble() : 1.0),
                      onChangeStart: (_) {},
                      onChanged: (v) {
                        _ctrl.seekTo(Duration(milliseconds: v.toInt()));
                        setState(() {});
                      },
                      onChangeEnd: (v) {
                        _seek(Duration(milliseconds: v.toInt()));
                      },
                    ),
                  )),
                  Text(mediaTimeStr(duration), style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(138))),
                ]),
                const SizedBox(height: 4),
                // Transport button row
                QuickLookMediaTransportBar(
                  isPlaying: _playing,
                  loading: loading,
                  looping: _looping,
                  muted: _muted,
                  speed: _speed,
                  volume: _volume,
                  playIconSize: 32,
                  onPlayPause: _togglePlayPause,
                  onToggleLoop: _toggleLoop,
                  onToggleMute: _toggleMute,
                  onSetSpeed: _setSpeed,
                  onSetVolume: _setVolume,
                  onOpenVolume: _openVolume,
                  onOpenInfo: _openInfo,
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}
