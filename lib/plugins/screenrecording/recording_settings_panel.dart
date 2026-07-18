/// Compact settings panel for the recording indicator bar.
/// Visually merges with the indicator bar when opened.
library;

import 'dart:io';
import 'package:flutter/material.dart';
import '../../../core/settings/settings_service.dart';
import '../../../core/utils/filename_template.dart';
import '../../../core/theme/theme_colors.dart';

class RecordingSettingsPanel extends StatefulWidget {
  final String encoder;
  final int fps;
  final int crf;
  final List<String> audioDevices;
  final int audioBitrate;
  final String ffmpegPath;
  final void Function(String encoder) onEncoderChanged;
  final void Function(int fps) onFpsChanged;
  final void Function(int crf) onCrfChanged;
  final void Function(List<String> devices) onAudioDevicesChanged;
  final void Function(int bitrate) onAudioBitrateChanged;

  const RecordingSettingsPanel({
    super.key,
    required this.encoder,
    required this.fps,
    required this.crf,
    required this.audioDevices,
    required this.audioBitrate,
    required this.ffmpegPath,
    required this.onEncoderChanged,
    required this.onFpsChanged,
    required this.onCrfChanged,
    required this.onAudioDevicesChanged,
    required this.onAudioBitrateChanged,
  });

  @override State<RecordingSettingsPanel> createState() =>
      _RecordingSettingsPanelState();
}

class _RecordingSettingsPanelState extends State<RecordingSettingsPanel> {
  late int _fps;
  late int _crf;
  List<String> _audioDeviceIds = <String>[];
  List<String> _audioDeviceLabels = <String>[];
  late Set<String> _selectedIds;
  bool _loadingAudio = false;

  @override void initState() {
    super.initState();
    _fps = widget.fps;
    _crf = widget.crf;
    _selectedIds = Set<String>.from(widget.audioDevices);
    WidgetsBinding.instance.addPostFrameCallback((_) => _enumerateAudio());
  }

  @override void didUpdateWidget(RecordingSettingsPanel old) {
    super.didUpdateWidget(old);
    if (old.fps != widget.fps) _fps = widget.fps;
    if (old.crf != widget.crf) _crf = widget.crf;
  }

  void _toggleDevice(String deviceId) {
    setState(() {
      if (_selectedIds.contains(deviceId)) {
        _selectedIds.remove(deviceId);
      } else {
        _selectedIds.add(deviceId);
      }
      widget.onAudioDevicesChanged(_selectedIds.toList());
    });
  }

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accentBorder = BorderSide(color: cs.primary.withAlpha(64));
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      decoration: BoxDecoration(
        color: XMateColors.panelBg(context),
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(6),
          bottomRight: Radius.circular(6),
        ),
        border: Border(
          left: accentBorder,
          right: accentBorder,
          bottom: accentBorder,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _encoderRow(),
          const SizedBox(height: 6),
          _fpsRow(),
          const SizedBox(height: 4),
          _crfRow(),
          const SizedBox(height: 6),
          _audioDeviceRow(),
          const SizedBox(height: 4),
          _audioBitrateRow(),
        ],
      ),
    );
  }

  // ── Encoder ──

  Widget _encoderRow() {
    final cs = Theme.of(context).colorScheme;
    final ddStyle = TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(179));
    return _rowShell('Encoder', SizedBox(
      height: 28,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: XMateColors.inputBorder(context),
          borderRadius: BorderRadius.circular(4),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: widget.encoder,
            isExpanded: true,
            dropdownColor: XMateColors.toolbarBg(context),
            style: ddStyle,
            items: [
              DropdownMenuItem(value: 'libx264', child: Text('H.264', style: ddStyle)),
              DropdownMenuItem(value: 'libx265', child: Text('H.265', style: ddStyle)),
              DropdownMenuItem(value: 'libvpx', child: Text('VP8', style: ddStyle)),
              DropdownMenuItem(value: 'libvpx-vp9', child: Text('VP9', style: ddStyle)),
            ],
            onChanged: (v) { if (v != null) { widget.onEncoderChanged(v); SettingsService().set('screenrecording.encoder', v); setState(() {}); } },
          ),
        ),
      ),
    ));
  }

  // ── FPS ──

  Widget _fpsRow() {
    final cs = Theme.of(context).colorScheme;
    final optimal = _fps >= 10 && _fps <= 15;
    final c = optimal ? const Color(0xFF40C057) : cs.onSurface.withAlpha(179);
    return _rowShell('FPS (Hz)', Row(children: [
      Expanded(
        child: SliderTheme(data: _sliderTheme, child: Slider(
          value: _fps.toDouble(), min: 1, max: 40,
          activeColor: cs.primary,
          inactiveColor: XMateColors.divider(context),
          onChanged: (v) {
            _fps = v.round();
            widget.onFpsChanged(_fps);
            SettingsService().set('screenrecording.fps', _fps);
            setState(() {});
          },
        )),
      ),
      const SizedBox(width: 4),
      SizedBox(width: 28, child: Text('$_fps', textAlign: TextAlign.right,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c))),
      const SizedBox(width: 4),
      SizedBox(width: 44, child: Text(optimal ? 'optimal' : '', textAlign: TextAlign.right,
          style: const TextStyle(fontSize: 9, color: Color(0xFF40C057)))),
    ]));
  }

  // ── CRF ──

  Color _crfColor(int v) {
    if (v >= 24 && v <= 28) return const Color(0xFF40C057);
    if (v < 18) return Theme.of(context).colorScheme.primary;
    if (v > 28) return Theme.of(context).colorScheme.onSurface.withAlpha(97);
    return Theme.of(context).colorScheme.onSurface.withAlpha(179);
  }

  String _crfLabel(int v) {
    if (v < 18) return 'High';
    if (v >= 24 && v <= 28) return 'Optimal';
    if (v > 28) return 'Lower';
    return '';
  }

  Widget _crfRow() {
    final cs = Theme.of(context).colorScheme;
    final c = _crfColor(_crf);
    final label = _crfLabel(_crf);
    return _rowShell('CRF', Row(children: [
      Expanded(
        child: SliderTheme(data: _sliderTheme, child: Slider(
          value: _crf.toDouble(), min: 1, max: 50,
          activeColor: cs.primary,
          inactiveColor: XMateColors.divider(context),
          onChanged: (v) {
            _crf = v.round();
            widget.onCrfChanged(_crf);
            SettingsService().set('screenrecording.crf', _crf);
            setState(() {});
          },
        )),
      ),
      const SizedBox(width: 4),
      SizedBox(width: 28, child: Text('$_crf', textAlign: TextAlign.right,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c))),
      const SizedBox(width: 4),
      SizedBox(width: 44, child: Text(label, textAlign: TextAlign.right,
          style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: c))),
    ]));
  }

  // ── Audio device enumeration ──

  Future<void> _enumerateAudio() async {
    setState(() => _loadingAudio = true);
    try {
      final ff = widget.ffmpegPath.isNotEmpty ? widget.ffmpegPath : 'ffmpeg.exe';
      final ffFile = File(ff);
      if (ff != 'ffmpeg.exe' && !ffFile.existsSync()) {
        if (mounted) setState(() => _loadingAudio = false);
        return;
      }
      final result = await Process.run(ff, [
        '-list_devices', 'true', '-f', 'dshow', '-i', 'dummy',
      ], stdoutEncoding: null, stderrEncoding: null);
      final stderrBytes = (result.stderr as List<int>?) ?? <int>[];
      final stderr = decodeWinConsole(stderrBytes);
      final lines = stderr.split('\n');
      final ids = <String>[];
      final labels = <String>[];

      // FFmpeg dshow -list_devices can output multiple device-category
      // sections.  We capture ALL audio devices regardless of section:
      //   DirectShow audio devices
      //   DirectShow audio capture devices
      //   DirectShow audio-only capture sources
      //   etc.
      // Each device appears as:
      //   "Friendly Name" (audio)          ← the label
      //   Alternative name "@device_..."   ← the FFmpeg-safe key
      String? pendingLabel;
      for (final line in lines) {
        final mFriendly = RegExp(r'"([^"]+)"\s*\(audio\)').firstMatch(line);
        if (mFriendly != null) {
          if (pendingLabel != null) {
            ids.add(pendingLabel); labels.add(pendingLabel);
          }
          pendingLabel = mFriendly.group(1)!;
          continue;
        }
        if (pendingLabel != null) {
          final mAlt = RegExp(r'Alternative name "(@[^"]+)"').firstMatch(line);
          if (mAlt != null) {
            ids.add(mAlt.group(1)!);
            labels.add(pendingLabel);
            pendingLabel = null;
          }
        }
      }
      if (pendingLabel != null) {
        ids.add(pendingLabel); labels.add(pendingLabel);
      }
      // Always offer system audio (WASAPI loopback) as a synthetic device.
      ids.add('__system_audio__');
      labels.add('System Audio (WASAPI)');
      // Restore selections that are still valid.
      final newSel = Set<String>.from(widget.audioDevices);
      newSel.removeWhere((d) => !ids.contains(d));
      _selectedIds = newSel;
      if (mounted) setState(() {
        _audioDeviceIds = ids;
        _audioDeviceLabels = labels;
        _loadingAudio = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingAudio = false);
    }
  }

  // ── Audio device row (tap to open picker) ──

  Widget _audioDeviceRow() {
    final cs = Theme.of(context).colorScheme;
    final count = _selectedIds.length;
    final label = _loadingAudio
        ? 'Scanning...'
        : count == 0 ? 'None' : '$count selected';
    return _rowShell('Audio', GestureDetector(
      onTap: () {
        if (_audioDeviceIds.isNotEmpty) _showAudioPicker();
      },
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: XMateColors.inputBorder(context),
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.centerLeft,
        child: Row(children: [
          Expanded(child: Text(label,
              style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(179)),
              overflow: TextOverflow.ellipsis)),
          Icon(Icons.arrow_drop_down, size: 16, color: cs.onSurface.withAlpha(138)),
        ]),
      ),
    ));
  }

  void _showAudioPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: XMateColors.toolbarBg(context),
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSheetState) {
          return Container(
            constraints: const BoxConstraints(maxHeight: 400),
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(children: [
                    Text('Audio devices (${_selectedIds.length} selected)',
                        style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface.withAlpha(138))),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => Navigator.pop(ctx),
                      child: Icon(Icons.close, size: 18, color: Theme.of(context).colorScheme.onSurface.withAlpha(138)),
                    ),
                  ]),
                ),
                const SizedBox(height: 4),
                Divider(color: XMateColors.divider(context), height: 1),
                Expanded(
                  child: ListView(
                    children: [
                      for (int i = 0; i < _audioDeviceIds.length && i < _audioDeviceLabels.length; i++)
                        CheckboxListTile(
                          dense: true,
                          value: _selectedIds.contains(_audioDeviceIds[i]),
                          activeColor: Theme.of(context).colorScheme.primary,
                          title: Text(_audioDeviceLabels[i],
                              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withAlpha(179))),
                          onChanged: (_) {
                            setState(() => _toggleDevice(_audioDeviceIds[i]));
                            setSheetState(() {});
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        });
      },
    );
  }

  // ── Audio bitrate ──

  static const _bitrateSteps = [48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];

  Color _bitrateColor(int v) {
    final cs = Theme.of(context).colorScheme;
    if (v >= 128 && v <= 192) return const Color(0xFF40C057);
    if (v < 128) return cs.onSurface.withAlpha(97);
    return cs.primary;
  }

  String _bitrateLabel(int v) {
    if (v >= 128 && v <= 192) return 'Optimal';
    if (v < 128) return 'Low';
    return 'High';
  }

  Widget _audioBitrateRow() {
    final cs = Theme.of(context).colorScheme;
    final idx = _nearestBitrateIndex(widget.audioBitrate);
    final v = _bitrateSteps[idx];
    final c = _bitrateColor(v);
    final label = _bitrateLabel(v);
    return _rowShell('Audio kbps', Row(children: [
      Expanded(
        child: SliderTheme(data: _sliderTheme, child: Slider(
          value: idx.toDouble(), min: 0, max: (_bitrateSteps.length - 1).toDouble(),
          divisions: _bitrateSteps.length - 1,
          activeColor: cs.primary,
          inactiveColor: XMateColors.divider(context),
          onChanged: (vi) {
            final bv = _bitrateSteps[vi.round()];
            widget.onAudioBitrateChanged(bv);
            setState(() {});
          },
        )),
      ),
      const SizedBox(width: 4),
      SizedBox(width: 28, child: Text('$v k', textAlign: TextAlign.right,
          style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: c))),
      const SizedBox(width: 4),
      SizedBox(width: 44, child: Text(label, textAlign: TextAlign.right,
          style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: c))),
    ]));
  }

  int _nearestBitrateIndex(int target) {
    int best = 0;
    for (int i = 0; i < _bitrateSteps.length; i++) {
      if ((_bitrateSteps[i] - target).abs() < (_bitrateSteps[best] - target).abs()) best = i;
    }
    return best;
  }

  // ── Shared ──

  static const _labelW = 80.0;
  static const _sliderTheme = SliderThemeData(
    trackHeight: 3,
    thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
    overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
  );

  Widget _rowShell(String label, Widget child) {
    return SizedBox(
      height: 32,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(width: _labelW, child: Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withAlpha(138)))),
          Expanded(child: child),
        ],
      ),
    );
  }
}
