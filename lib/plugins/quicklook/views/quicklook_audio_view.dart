/// Audio preview for QuickLook.
///
/// Supports: mp3, wav, flac, ogg, aac, m4a, wma, opus.
/// Features: play/pause, seek, speed selector, volume slider, loop toggle,
///           audio info (codec, sample rate, channels, bitrate from Windows Shell).
library;

import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'quicklook_media_controls.dart';
import '../../../../core/theme/theme_colors.dart';

// ─── Audio metadata model ────────────────────────────────────────

class _AudioInfo {
  final String codec;
  final int? sampleRate;   // Hz
  final int? channels;
  final int? bitrate;      // bps
  final int? bitsPerSample;
  final Duration duration;

  const _AudioInfo({
    required this.codec,
    this.sampleRate,
    this.channels,
    this.bitrate,
    this.bitsPerSample,
    required this.duration,
  });

  String get sampleRateStr =>
      sampleRate != null ? '${(sampleRate! / 1000).toStringAsFixed(1)} kHz' : '—';

  String get channelsStr {
    if (channels == null) return '—';
    if (channels == 1) return 'Mono';
    if (channels == 2) return 'Stereo';
    return '$channels ch';
  }

  String get bitrateStr {
    if (bitrate != null && bitrate! >= 1000) {
      return '${(bitrate! / 1000).toStringAsFixed(0)} kbps';
    }
    if (bitrate != null) return '$bitrate bps';
    return '—';
  }

  String get bitsStr =>
      bitsPerSample != null ? '$bitsPerSample bit' : '—';

  factory _AudioInfo.fromJson(Map<String, dynamic> json, Duration dur) {
    return _AudioInfo(
      codec: (json['codec'] as String?) ?? '—',
      sampleRate: (json['sampleRate'] as int?) ?? (json['sampleRate'] as num?)?.toInt(),
      channels: (json['channels'] as int?) ?? (json['channels'] as num?)?.toInt(),
      bitrate: (json['bitrate'] as int?) ?? (json['bitrate'] as num?)?.toInt(),
      bitsPerSample: (json['bitsPerSample'] as int?) ?? (json['bitsPerSample'] as num?)?.toInt(),
      duration: dur,
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// QuickLookAudioView
// ══════════════════════════════════════════════════════════════════

class QuickLookAudioView extends StatefulWidget {
  final String filePath;
  final VoidCallback? onOpenFile;
  const QuickLookAudioView({super.key, required this.filePath, this.onOpenFile});

  @override
  State<QuickLookAudioView> createState() => _QuickLookAudioViewState();
}

class _QuickLookAudioViewState extends State<QuickLookAudioView>
    with QuickLookMediaOverlay {
  static const _channel = MethodChannel('com.xmate/fileops');

  late final AudioPlayer _player;

  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  PlayerState _playerState = PlayerState.stopped;
  double _speed = 1.0;
  double _volume = 1.0;
  bool _muted = false;
  double _preMuteVol = 1.0;
  bool _looping = false;
  bool _seeking = false;
  _AudioInfo? _info;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _player.setReleaseMode(ReleaseMode.stop);
    _init();
  }

  @override
  void dispose() {
    removeOverlay();
    _player.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant QuickLookAudioView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filePath != oldWidget.filePath) {
      _player.stop();
      _init();
    }
  }

  Future<void> _init() async {
    _fetchAudioInfo();

    try {
      _player.onDurationChanged.listen((d) {
        if (mounted) {
          setState(() {
            _duration = d;
            if (_info != null && _info!.duration == Duration.zero && d != Duration.zero) {
              _info = _AudioInfo(
                codec: _info!.codec,
                sampleRate: _info!.sampleRate,
                channels: _info!.channels,
                bitrate: _info!.bitrate,
                bitsPerSample: _info!.bitsPerSample,
                duration: d,
              );
            }
          });
        }
      });
      _player.onPositionChanged.listen((p) {
        if (mounted && !_seeking) setState(() => _position = p);
      });
      _player.onPlayerStateChanged.listen((s) {
        if (mounted) setState(() => _playerState = s);
      });
      _player.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _position = _duration);
      });

      await _player.setSource(DeviceFileSource(widget.filePath));
      if (mounted) {
        setState(() {
          _position = Duration.zero;
          _playerState = PlayerState.stopped;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _playerState = PlayerState.stopped);
    }
  }

  Future<void> _fetchAudioInfo() async {
    try {
      final path = widget.filePath.replaceAll('/', '\\');
      final jsonStr =
          await _channel.invokeMethod<String>('getAudioProperties', {'path': path});
      if (jsonStr != null && jsonStr != '{}' && mounted) {
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        if (map.isNotEmpty) {
          final durMs = (map['durationMs'] as num?)?.toInt() ?? 0;
          setState(() => _info = _AudioInfo.fromJson(
              map, Duration(milliseconds: durMs)));
          return;
        }
      }
    } catch (_) {}
    if (mounted) {
      setState(() => _info = _AudioInfo(
            codec: _extCodecName(widget.filePath),
            duration: Duration.zero,
          ));
    }
  }

  static String _extCodecName(String path) {
    final dotIdx = path.lastIndexOf('.');
    if (dotIdx <= 0) return 'Audio';
    final ext = path.substring(dotIdx + 1).toLowerCase();
    const map = {
      'mp3': 'MP3', 'wav': 'WAV', 'flac': 'FLAC', 'ogg': 'OGG Vorbis',
      'opus': 'OPUS', 'aac': 'AAC', 'm4a': 'AAC (M4A)', 'wma': 'WMA',
    };
    return map[ext] ?? ext.toUpperCase();
  }

  // ─── Actions ───

  void _togglePlayPause() {
    if (_playerState == PlayerState.completed) {
      _player.seek(Duration.zero);
      _player.resume();
    } else if (_playerState == PlayerState.playing) {
      _player.pause();
    } else {
      _player.resume();
    }
  }

  void _seek(Duration pos) {
    _player.seek(pos);
    setState(() => _position = pos);
  }

  void _setSpeed(double speed) {
    _speed = speed;
    _player.setPlaybackRate(speed);
    setState(() {});
  }

  void _toggleMute() {
    if (_muted) {
      _muted = false;
      _volume = _preMuteVol;
      _player.setVolume(_volume);
    } else {
      _muted = true;
      _preMuteVol = _volume;
      _volume = 0;
      _player.setVolume(0);
    }
    refreshOverlay();
    setState(() {});
  }

  void _setVolume(double v) {
    _volume = v;
    _muted = v == 0;
    if (!_muted) _preMuteVol = v;
    _player.setVolume(v);
    refreshOverlay();
    setState(() {});
  }

  void _toggleLoop() {
    _looping = !_looping;
    _player.setReleaseMode(_looping ? ReleaseMode.loop : ReleaseMode.stop);
    setState(() {});
  }

  void _seekRelative(int seconds) {
    final target = seekRelative(_position, _duration, seconds);
    _seek(target);
  }

  void _speedUp() {
    final n = nextSpeed(_speed);
    if (n != null) _setSpeed(n);
  }

  void _speedDown() {
    final p = prevSpeed(_speed);
    if (p != null) _setSpeed(p);
  }

  // ─── Keyboard shortcuts ───

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

  // ─── Overlay helpers ───

  void _openVolume() => showOverlay(_buildVolumeOverlay);

  Widget _buildVolumeOverlay(VoidCallback dismiss) {
    final cs = Theme.of(context).colorScheme;
    return popupScaffold(
      dismiss,
      bottomOffset: 72,
      child: Container(
        width: 160,
        height: 36,
        decoration: BoxDecoration(
          color: XMateColors.toolbarBg(context),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: cs.onSurface.withAlpha(61), width: 1),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            GestureDetector(
              onTap: _toggleMute,
              child: Icon(
                _muted || _volume == 0
                    ? Icons.volume_off
                    : _volume < 0.5
                        ? Icons.volume_down
                        : Icons.volume_up,
                size: 18,
                color: cs.onSurface.withAlpha(179),
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 2.5,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 10),
                  activeTrackColor: cs.primary,
                  inactiveTrackColor: cs.onSurface.withAlpha(61),
                  thumbColor: cs.primary,
                  overlayColor: cs.primary.withAlpha(40),
                ),
                child: Slider(
                  min: 0,
                  max: 1,
                  value: _volume,
                  onChanged: _setVolume,
                ),
              ),
            ),
            SizedBox(
              width: 36,
              child: Text(
                '${(_volume * 100).round()}',
                style:
                    TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(138)),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Info popup ───

  void _openInfo() => showOverlay((dismiss) => _buildInfoOverlay(dismiss));

  Widget _buildInfoOverlay(VoidCallback dismiss) {
    final cs = Theme.of(context).colorScheme;
    final info = _info;
    return popupScaffold(
      dismiss,
      bottomOffset: 72,
      child: Container(
        width: 200,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: XMateColors.toolbarBg(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.onSurface.withAlpha(61), width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            infoRow('Codec', info?.codec ?? '—', cs),
            const SizedBox(height: 4),
            infoRow('Sample rate', info?.sampleRateStr ?? '—', cs),
            const SizedBox(height: 4),
            infoRow('Channels', info?.channelsStr ?? '—', cs),
            const SizedBox(height: 4),
            infoRow('Bitrate', info?.bitrateStr ?? '—', cs),
            if (info?.bitsPerSample != null) ...[
              const SizedBox(height: 4),
              infoRow('Bit depth', info!.bitsStr, cs),
            ],
          ],
        ),
      ),
    );
  }

  // ─── Build ───

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final name = widget.filePath.split(RegExp(r'[/\\]')).last;
    final playing = _playerState == PlayerState.playing;
    final loading =
        _playerState == PlayerState.stopped && _duration == Duration.zero;

    return Focus(
      autofocus: true,
      onKeyEvent: _handleKey,
      child: Container(
        color: XMateColors.panelBg(context),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
        child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(Icons.multitrack_audio, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    fontSize: 14,
                    color: cs.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ── Progress bar ──
          Row(
            children: [
              Text(mediaTimeStr(_position),
                  style:
                      TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(138))),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: cs.primary,
                    inactiveTrackColor: cs.onSurface.withAlpha(61),
                    thumbColor: cs.primary,
                    overlayColor: cs.primary.withAlpha(40),
                  ),
                  child: Slider(
                    min: 0,
                    max: _duration.inMilliseconds > 0
                        ? _duration.inMilliseconds.toDouble()
                        : 1.0,
                    value: _position.inMilliseconds
                        .toDouble()
                        .clamp(0, _duration.inMilliseconds > 0
                            ? _duration.inMilliseconds.toDouble()
                            : 1.0),
                    onChangeStart: (_) => _seeking = true,
                    onChanged: (v) {
                      setState(() =>
                          _position = Duration(milliseconds: v.toInt()));
                    },
                    onChangeEnd: (v) {
                      _seeking = false;
                      _seek(Duration(milliseconds: v.toInt()));
                    },
                  ),
                ),
              ),
              Text(mediaTimeStr(_duration),
                  style:
                      TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(138))),
            ],
          ),

          const SizedBox(height: 12),

          // ── Transport ──
          QuickLookMediaTransportBar(
            isPlaying: playing,
            loading: loading,
            looping: _looping,
            muted: _muted,
            speed: _speed,
            volume: _volume,
            playIconSize: 36,
            onPlayPause: _togglePlayPause,
            onToggleLoop: _toggleLoop,
            onToggleMute: _toggleMute,
            onSetSpeed: _setSpeed,
            onSetVolume: _setVolume,
            onOpenVolume: _openVolume,
            onOpenInfo: _openInfo,
          ),
        ],
      ),
      ),
    );
  }
}
