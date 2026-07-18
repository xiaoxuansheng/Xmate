library;

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/picker/picker_service.dart';
import '../../core/utils/filename_template.dart';
import '../../core/theme/theme_colors.dart';

/// USB HID key ID fallback for keyboard capture.
String _usbHidKeyName(int keyId) {
  if (keyId >= 0x04 && keyId <= 0x1D) return String.fromCharCode(0x41 + (keyId - 0x04));
  if (keyId >= 0x1E && keyId <= 0x27) return String.fromCharCode(0x31 + (keyId - 0x1E));
  if (keyId >= 0x3A && keyId <= 0x45) return 'F${keyId - 0x39}';
  switch (keyId) {
    case 0x2C: return 'Space'; case 0x28: return 'Enter'; case 0x29: return 'Esc';
    case 0x2A: return 'Backspace'; case 0x2B: return 'Tab';
    case 0x4F: return 'Right'; case 0x50: return 'Left'; case 0x51: return 'Down'; case 0x52: return 'Up';
    default:  return 'Key($keyId)';
  }
}

class ScreenshotSettings extends StatefulWidget {
  final String savePath, format;
  final ValueChanged<String> onSavePathChanged, onFormatChanged;
  final String hotkeyLabel;
  final bool Function(int mods, int keyId, String label)? onHotkeyChanged;
  final void Function(String source, bool active)? onCaptureStateChanged;

  // Screenshot filename template
  final String ssFilenameTemplate;
  final ValueChanged<String> onSsFilenameTemplateChanged;

  // Recording settings
  final String recSavePath;
  final ValueChanged<String> onRecSavePathChanged;
  final String recFfmpegPath;
  final ValueChanged<String> onRecFfmpegPathChanged;
  final String recEncoder;
  final int recFps, recCrf;
  final ValueChanged<String> onRecEncoderChanged;
  final ValueChanged<int> onRecFpsChanged, onRecCrfChanged;
  final List<String> recAudioDevices;
  final ValueChanged<List<String>> onRecAudioDevicesChanged;
  final int recAudioBitrate;
  final ValueChanged<int> onRecAudioBitrateChanged;
  final bool recShowMouse;
  final ValueChanged<bool> onRecShowMouseChanged;
  final String recFilenameTemplate;
  final ValueChanged<String> onRecFilenameTemplateChanged;
  final String recHotkeyLabel;
  final bool Function(int mods, int keyId, String label)? onRecHotkeyChanged;
  final void Function(String source, bool active)? onRecCaptureStateChanged;

  const ScreenshotSettings({
    super.key,
    required this.savePath,
    required this.format,
    required this.onSavePathChanged,
    required this.onFormatChanged,
    this.hotkeyLabel = 'Not set',
    this.onHotkeyChanged,
    this.onCaptureStateChanged,
    this.ssFilenameTemplate = '',
    required this.onSsFilenameTemplateChanged,
    this.recSavePath = '',
    required this.onRecSavePathChanged,
    this.recFfmpegPath = '',
    required this.onRecFfmpegPathChanged,
    this.recEncoder = 'libx264',
    this.recFps = 30,
    this.recCrf = 23,
    this.onRecEncoderChanged = _noopStr,
    this.onRecFpsChanged = _noopInt,
    this.onRecCrfChanged = _noopInt,
    this.recAudioDevices = const [],
    this.onRecAudioDevicesChanged = _noopList,
    this.recAudioBitrate = 128,
    this.onRecAudioBitrateChanged = _noopInt,
    this.recShowMouse = true,
    this.onRecShowMouseChanged = _noopBool,
    this.recFilenameTemplate = '',
    required this.onRecFilenameTemplateChanged,
    this.recHotkeyLabel = 'Not set',
    this.onRecHotkeyChanged,
    this.onRecCaptureStateChanged,
  });

  static void _noopStr(String _) {}
  static void _noopInt(int _) {}
  static void _noopBool(bool _) {}
  static void _noopList(List<String> _) {}

  @override State<ScreenshotSettings> createState() => _ScreenshotSettingsState();
}

class _ScreenshotSettingsState extends State<ScreenshotSettings> {
  static const _ssCS = 'settings.screenshot';
  static const _srCS = 'settings.screenrecording';

  // Screenshot
  late TextEditingController _pathCtrl;
  late String _format;
  bool _ssCap = false, _ssConflict = false;
  String _ssLabel = 'Not set';
  final _ssFocus = FocusNode();
  late TextEditingController _ssTmplCtrl;

  // Recording
  late TextEditingController _recPathCtrl, _recFfmpegCtrl;
  bool _recCap = false, _recConflict = false;
  String _recLabel = 'Not set';
  final _recFocus = FocusNode();
  late String _recEncoder;
  late int _recFps, _recCrf, _recAudioBitrate;
  late bool _recShowMouse;
  late List<String> _recAudioDevices;
  late TextEditingController _recTmplCtrl;

  // Audio device enumeration
  List<String> _audioDevices = <String>[];
  List<String> _audioLabels = <String>[];
  bool _loadingDevices = false;

  @override void initState() {
    super.initState();
    _pathCtrl = TextEditingController(text: widget.savePath);
    _format = widget.format;
    _ssLabel = widget.hotkeyLabel;
    _ssTmplCtrl = TextEditingController(text: widget.ssFilenameTemplate.isNotEmpty
        ? widget.ssFilenameTemplate : kDefaultScreenshotTemplate);

    _recPathCtrl = TextEditingController(text: widget.recSavePath);
    _recFfmpegCtrl = TextEditingController(text: widget.recFfmpegPath);
    _recLabel = widget.recHotkeyLabel;
    _recEncoder = widget.recEncoder;
    _recFps = widget.recFps.clamp(1, 40);
    _recCrf = widget.recCrf.clamp(1, 50);
    _recAudioBitrate = widget.recAudioBitrate;
    _recShowMouse = widget.recShowMouse;
    _recAudioDevices = List<String>.from(widget.recAudioDevices);
    _recTmplCtrl = TextEditingController(text: widget.recFilenameTemplate.isNotEmpty
        ? widget.recFilenameTemplate : kDefaultRecordingTemplate);

    _ssFocus.addListener(_onSsFocus);
    _recFocus.addListener(_onRecFocus);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) { _enumerateAudioDevices(); }
    });
  }

  @override void didUpdateWidget(covariant ScreenshotSettings old) {
    super.didUpdateWidget(old);
    if (widget.savePath != old.savePath && widget.savePath != _pathCtrl.text) _pathCtrl.text = widget.savePath;
    if (widget.hotkeyLabel != old.hotkeyLabel) _ssLabel = widget.hotkeyLabel;
    if (widget.recSavePath != old.recSavePath && widget.recSavePath != _recPathCtrl.text) _recPathCtrl.text = widget.recSavePath;
    if (widget.recHotkeyLabel != old.recHotkeyLabel) _recLabel = widget.recHotkeyLabel;
  }

  Color _crfColor(int crf) {
    final cs = Theme.of(context).colorScheme;
    if (crf >= 24 && crf <= 28) return const Color(0xFF40C057);
    if (crf < 18) return cs.primary;
    if (crf > 28) return cs.onSurface.withAlpha(97);
    return cs.onSurface.withAlpha(179);
  }

  String _crfQualityLabel(int crf) {
    if (crf < 18) return 'High quality';
    if (crf >= 24 && crf <= 28) return 'Optimal';
    if (crf > 28) return 'Lower quality';
    return '';
  }

  static const _bitrateSteps = [48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];
  int _bitrateIndex(int target) {
    int best = 0;
    for (int i = 0; i < _bitrateSteps.length; i++) {
      if ((_bitrateSteps[i] - target).abs() < (_bitrateSteps[best] - target).abs()) best = i;
    }
    return best;
  }

  // ── Audio multi-select ──

  Widget _audioMultiSelect() {
    final cs = Theme.of(context).colorScheme;
    final selCount = _recAudioDevices.length;
    final label = _loadingDevices
        ? 'Scanning...'
        : selCount == 0 ? 'None' : '$selCount selected';
    return GestureDetector(
      onTap: _showAudioPickerMain,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: XMateColors.inputBorder(context),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(179))),
          const SizedBox(width: 4),
          Icon(Icons.arrow_drop_down, size: 18, color: cs.onSurface.withAlpha(138)),
        ]),
      ),
    );
  }

  void _showAudioPickerMain() {
    if (_audioDevices.isEmpty) return;
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, sbSetState) {
          final cs = Theme.of(ctx).colorScheme;
          return AlertDialog(
            backgroundColor: XMateColors.toolbarBg(ctx),
            title: Text('Audio devices', style: TextStyle(fontSize: 14, color: cs.onSurface.withAlpha(179))),
            content: SizedBox(
              width: 280,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (int i = 0; i < _audioDevices.length && i < _audioLabels.length; i++)
                      CheckboxListTile(
                        dense: true,
                        value: _recAudioDevices.contains(_audioDevices[i]),
                        activeColor: cs.primary,
                        title: Text(_audioLabels[i],
                            style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(179))),
                        onChanged: (_) {
                          setState(() {
                            final devId = _audioDevices[i];
                            if (_recAudioDevices.contains(devId)) {
                              _recAudioDevices.remove(devId);
                            } else {
                              _recAudioDevices.add(devId);
                            }
                            widget.onRecAudioDevicesChanged(List.from(_recAudioDevices));
                          });
                          sbSetState(() {});
                        },
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Done', style: TextStyle(color: cs.primary)),
              ),
            ],
          );
        });
      },
    );
  }

  @override void dispose() {
    if (_ssCap) widget.onCaptureStateChanged?.call(_ssCS, false);
    if (_recCap) widget.onRecCaptureStateChanged?.call(_srCS, false);
    _pathCtrl.dispose(); _recPathCtrl.dispose(); _recFfmpegCtrl.dispose();
    _ssTmplCtrl.dispose(); _recTmplCtrl.dispose();
    _ssFocus.dispose(); _recFocus.dispose();
    super.dispose();
  }

  void _onSsFocus() { if (!_ssFocus.hasFocus && _ssCap && mounted) { setState(() => _ssCap = false); widget.onCaptureStateChanged?.call(_ssCS, false); } }
  void _onRecFocus() { if (!_recFocus.hasFocus && _recCap && mounted) { setState(() => _recCap = false); widget.onRecCaptureStateChanged?.call(_srCS, false); } }

  // ── Audio device enumeration ──

  Future<void> _enumerateAudioDevices() async {
    setState(() => _loadingDevices = true);
    try {
      final ffPath = _recFfmpegCtrl.text.trim().isNotEmpty
          ? _recFfmpegCtrl.text.trim() : 'ffmpeg.exe';
      // Use raw bytes — FFmpeg outputs UTF-8 regardless of system locale.
      final result = await Process.run(ffPath, [
        '-list_devices', 'true', '-f', 'dshow', '-i', 'dummy',
      ], stdoutEncoding: null, stderrEncoding: null);
      final stderrBytes = (result.stderr as List<int>?) ?? <int>[];
      final stderr = decodeWinConsole(stderrBytes);
      final lines = stderr.split('\n');
      final devices = <String>[];
      final deviceLabels = <String>[];
      String? pendingLabel;
      for (final line in lines) {
        final mFriendly = RegExp(r'"([^"]+)"\s*\(audio\)').firstMatch(line);
        if (mFriendly != null) {
          // Flush previous device before starting a new one.
          if (pendingLabel != null) {
            devices.add(pendingLabel);
            deviceLabels.add(pendingLabel);
          }
          pendingLabel = mFriendly.group(1)!;
          continue;
        }
        if (pendingLabel != null) {
          final mAlt = RegExp(r'Alternative name "(@[^"]+)"').firstMatch(line);
          if (mAlt != null) {
            // Use the GUID alternative name as the VALUE (ASCII-safe),
            // friendly name as the DISPLAY LABEL.
            devices.add(mAlt.group(1)!);
            deviceLabels.add(pendingLabel);
            pendingLabel = null;
          }
        }
      }
      // Flush any remaining pending device without alternative name.
      if (pendingLabel != null) {
        devices.add(pendingLabel);
        deviceLabels.add(pendingLabel);
      }
      // Always offer system audio (WASAPI loopback) as a synthetic device.
      devices.add('__system_audio__');
      deviceLabels.add('System Audio (WASAPI)');
      if (mounted) setState(() {
        _audioDevices = devices; _audioLabels = deviceLabels;
        _loadingDevices = false;
      });
    } catch (_) {
      if (mounted) setState(() { _loadingDevices = false; });
    }
  }

  // ── Pickers ──

  Future<void> _pickFolder(TextEditingController c, ValueChanged<String> cb) async {
    final p = await PickerService().pickFolder();
    if (p != null && p.isNotEmpty) { c.text = p; cb(p); }
  }
  Future<void> _pickFfmpeg() async {}

  // ── Hotkey helpers ──

  String _fmt(int mods, int key) {
    final p = <String>[];
    if (mods & 1 != 0) p.add('Alt'); if (mods & 2 != 0) p.add('Ctrl');
    if (mods & 4 != 0) p.add('Shift'); if (mods & 8 != 0) p.add('Win');
    final k = LogicalKeyboardKey.findKeyByKeyId(key);
    p.add(k != null ? _kN(k) : _usbHidKeyName(key));
    return p.isEmpty ? 'Unset' : p.join('+');
  }
  String _kN(LogicalKeyboardKey k) { final n = k.keyLabel; if (n.length == 1 && n.codeUnitAt(0) >= 0x41 && n.codeUnitAt(0) <= 0x5A) return n; if (n == ' ') return 'Space'; return n; }
  bool _isMod(LogicalKeyboardKey k) => k == LogicalKeyboardKey.altLeft || k == LogicalKeyboardKey.altRight || k == LogicalKeyboardKey.controlLeft || k == LogicalKeyboardKey.controlRight || k == LogicalKeyboardKey.shiftLeft || k == LogicalKeyboardKey.shiftRight || k == LogicalKeyboardKey.metaLeft || k == LogicalKeyboardKey.metaRight;
  int _mask() { final m = HardwareKeyboard.instance.logicalKeysPressed; int v = 0; if (m.contains(LogicalKeyboardKey.altLeft) || m.contains(LogicalKeyboardKey.altRight)) v |= 1; if (m.contains(LogicalKeyboardKey.controlLeft) || m.contains(LogicalKeyboardKey.controlRight)) v |= 2; if (m.contains(LogicalKeyboardKey.shiftLeft) || m.contains(LogicalKeyboardKey.shiftRight)) v |= 4; if (m.contains(LogicalKeyboardKey.metaLeft) || m.contains(LogicalKeyboardKey.metaRight)) v |= 8; return v; }

  // ── Screenshot hotkey capture ──

  void _startSs() { setState(() { _ssCap = true; _ssConflict = false; }); widget.onCaptureStateChanged?.call(_ssCS, true); _ssFocus.requestFocus(); }
  void _onSsKey(KeyEvent e) { if (!_ssCap || e is! KeyDownEvent) return; if (_isMod(e.logicalKey)) return; final m = _mask(); if (m == 0) { _xSs(); return; } final l = _fmt(m, e.logicalKey.keyId); final ok = widget.onHotkeyChanged?.call(m, e.logicalKey.keyId, l) ?? true; setState(() { _ssCap = false; if (ok) { _ssLabel = l; _ssConflict = false; } else { _ssConflict = true; } }); widget.onCaptureStateChanged?.call(_ssCS, false); _ssFocus.unfocus(); }
  void _xSs() { setState(() => _ssCap = false); widget.onCaptureStateChanged?.call(_ssCS, false); _ssFocus.unfocus(); }

  // ── Recording hotkey capture ──

  void _startRec() { setState(() { _recCap = true; _recConflict = false; }); widget.onRecCaptureStateChanged?.call(_srCS, true); _recFocus.requestFocus(); }
  void _onRecKey(KeyEvent e) { if (!_recCap || e is! KeyDownEvent) return; if (_isMod(e.logicalKey)) return; final m = _mask(); if (m == 0) { _xRec(); return; } final l = _fmt(m, e.logicalKey.keyId); final ok = widget.onRecHotkeyChanged?.call(m, e.logicalKey.keyId, l) ?? true; setState(() { _recCap = false; if (ok) { _recLabel = l; _recConflict = false; } else { _recConflict = true; } }); widget.onRecCaptureStateChanged?.call(_srCS, false); _recFocus.unfocus(); }
  void _xRec() { setState(() => _recCap = false); widget.onRecCaptureStateChanged?.call(_srCS, false); _recFocus.unfocus(); }

  // ── Build row helpers ──

  Widget _row(Widget child) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: child,
    );
  }

  Widget _div() => Divider(height: 1, thickness: 1, indent: 14, endIndent: 14, color: XMateColors.divider(context));

  Widget _pathField(TextEditingController ctrl, VoidCallback onPick) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(width: 280, height: 36,
      child: TextField(
        controller: ctrl, readOnly: true,
        style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(179)),
        decoration: InputDecoration(
          isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          filled: true, fillColor: XMateColors.inputBorder(context),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
          suffixIcon: IconButton(
            icon: Icon(Icons.folder_open, size: 16, color: cs.primary),
            onPressed: onPick, tooltip: 'Choose folder',
          ),
        ),
      ),
    );
  }

  Widget _textField(TextEditingController ctrl, ValueChanged<String> onChange, {double width = 280}) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(width: width, height: 36,
      child: TextField(
        controller: ctrl,
        style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(179)),
        decoration: InputDecoration(
          isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          filled: true, fillColor: XMateColors.inputBorder(context),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
        ),
        onSubmitted: onChange,
      ),
    );
  }

  Widget _hotkeyBtn(String display, bool cap, VoidCallback onTap, FocusNode fn, void Function(KeyEvent) onKey) {
    final cs = Theme.of(context).colorScheme;
    return KeyboardListener(focusNode: fn, onKeyEvent: onKey,
      child: GestureDetector(onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: cap ? cs.primary.withAlpha(60) : XMateColors.highlight(context),
            borderRadius: BorderRadius.circular(6),
            border: cap ? Border.all(color: cs.primary, width: 1.5) : null,
          ),
          child: Text(cap ? 'Press keys...' : display,
            style: TextStyle(fontSize: 13, color: cap ? cs.primary : cs.onSurface.withAlpha(179),
                fontWeight: cap ? FontWeight.w600 : FontWeight.normal)),
        )));
  }

  // ── Build ──

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = cs.primary;
    final onSurface70 = cs.onSurface.withAlpha(179);
    final onSurface54 = cs.onSurface.withAlpha(138);
    final onSurface38 = cs.onSurface.withAlpha(97);

    final _label = TextStyle(fontSize: 14, color: cs.onSurface);

    final templateHelp = SelectableText.rich(
      TextSpan(children: [
        TextSpan(text: 'Placeholders: ', style: TextStyle(color: onSurface38)),
        TextSpan(text: '%yyyy%', style: TextStyle(color: accent, fontFamily: 'monospace')),
        const TextSpan(text: ' ', style: TextStyle(color: Colors.white38)),
        TextSpan(text: '%MM%', style: TextStyle(color: accent, fontFamily: 'monospace')),
        const TextSpan(text: ' ', style: TextStyle(color: Colors.white38)),
        TextSpan(text: '%dd%', style: TextStyle(color: accent, fontFamily: 'monospace')),
        const TextSpan(text: ' ', style: TextStyle(color: Colors.white38)),
        TextSpan(text: '%HH%', style: TextStyle(color: accent, fontFamily: 'monospace')),
        const TextSpan(text: ' ', style: TextStyle(color: Colors.white38)),
        TextSpan(text: '%mm%', style: TextStyle(color: accent, fontFamily: 'monospace')),
        const TextSpan(text: ' ', style: TextStyle(color: Colors.white38)),
        TextSpan(text: '%ss%', style: TextStyle(color: accent, fontFamily: 'monospace')),
      ]),
      style: const TextStyle(fontSize: 11),
    );

    return Column(mainAxisSize: MainAxisSize.min, children: [
      // ═══ Screenshot ═══
      _sectionTitle('Screenshot', Icons.crop),
      _sectionCard(Column(mainAxisSize: MainAxisSize.min, children: [
        _row(Row(children: [
          Text('Save path', style: _label),
          const Spacer(),
          _pathField(_pathCtrl, () => _pickFolder(_pathCtrl, widget.onSavePathChanged)),
        ])),
        _div(),
        _row(Row(children: [
          Text('Format', style: _label),
          const Spacer(),
          _dd(['png','jpeg','webp'], ['PNG','JPEG','WebP'], _format,
              (v) { setState(() => _format = v); widget.onFormatChanged(v); }),
        ])),
        _div(),
        _row(Row(children: [
          Text('File name', style: _label),
          const Spacer(),
          _textField(_ssTmplCtrl, (v) => widget.onSsFilenameTemplateChanged(v)),
        ])),
        Padding(
          padding: const EdgeInsets.only(left: 14, right: 14, bottom: 6),
          child: Align(alignment: Alignment.centerRight, child: templateHelp),
        ),
        _div(),
        _row(Row(children: [
          Text('Shortcut', style: _label),
          const Spacer(),
          _hotkeyBtn(_ssLabel, _ssCap, _startSs, _ssFocus, _onSsKey),
        ])),
        if (_ssConflict)
          Padding(
            padding: const EdgeInsets.only(left: 14, right: 14, bottom: 4),
            child: Text('This shortcut conflicts with Command Palette.',
                style: TextStyle(fontSize: 11, color: Colors.orangeAccent.withAlpha(200))),
          ),
      ])),

      const SizedBox(height: 14),

      // ═══ Recording ═══
      _sectionTitle('Recording', Icons.videocam),
      _sectionCard(Column(mainAxisSize: MainAxisSize.min, children: [
        _row(Row(children: [
          Text('Save path', style: _label),
          const Spacer(),
          _pathField(_recPathCtrl, () => _pickFolder(_recPathCtrl, widget.onRecSavePathChanged)),
        ])),
        _div(),
        _row(Row(children: [
          Text('File name', style: _label),
          const Spacer(),
          _textField(_recTmplCtrl, (v) => widget.onRecFilenameTemplateChanged(v)),
        ])),
        Padding(
          padding: const EdgeInsets.only(left: 14, right: 14, bottom: 6),
          child: Align(alignment: Alignment.centerRight, child: templateHelp),
        ),
        _row(Row(children: [
          Text('Encoder', style: _label),
          const Spacer(),
          _dd(
            ['libx264','libx265','libvpx','libvpx-vp9'],
            ['H.264 (libx264)','H.265 (libx265)','VP8 (libvpx)','VP9 (libvpx-vp9)'],
            _recEncoder,
            (v) { setState(() => _recEncoder = v); widget.onRecEncoderChanged(v); },
          ),
        ])),
        _div(),
        _row(Row(children: [
          Text('FPS (Hz)', style: _label),
          const Spacer(),
          SizedBox(
            width: 160,
            child: Slider(
              value: _recFps.toDouble(), min: 1, max: 40, divisions: 39,
              activeColor: accent, inactiveColor: XMateColors.divider(context),
              onChanged: (v) => setState(() => _recFps = v.round()),
              onChangeEnd: (v) => widget.onRecFpsChanged(v.round()),
            ),
          ),
          SizedBox(width: 36, child: Text('$_recFps', textAlign: TextAlign.right, style: TextStyle(
            fontSize: 14, fontWeight: FontWeight.w700,
            color: (_recFps >= 10 && _recFps <= 15) ? const Color(0xFF40C057) : onSurface70,
          ))),
        ])),
        Padding(
          padding: const EdgeInsets.only(left: 14, right: 14, bottom: 2),
          child: Align(alignment: Alignment.center,
            child: Text((_recFps >= 10 && _recFps <= 15) ? 'Optimal' : ' ',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF40C057)))),
        ),
        _div(),
        _row(Column(children: [
          Row(children: [
            Text('Quality (CRF)', style: _label), const Spacer(),
            SizedBox(width: 160, child: Slider(
              value: _recCrf.toDouble(), min: 1, max: 50, divisions: 49,
              activeColor: accent, inactiveColor: XMateColors.divider(context),
              onChanged: (v) => setState(() => _recCrf = v.round()),
              onChangeEnd: (v) => widget.onRecCrfChanged(v.round()),
            )),
            SizedBox(width: 36, child: Text('$_recCrf', textAlign: TextAlign.right, style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.w700, color: _crfColor(_recCrf)))),
          ]),
          const SizedBox(height: 2),
          Row(children: [
            const SizedBox(width: 2),
            Text('← Higher quality', style: TextStyle(fontSize: 10, color: accent)),
            const Spacer(),
            Text(_crfQualityLabel(_recCrf), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _crfColor(_recCrf))),
            const Spacer(),
            Text('Lower quality →', style: TextStyle(fontSize: 10, color: onSurface38)),
            const SizedBox(width: 2),
          ]),
        ])),
        _div(),
        _row(Row(children: [
          Text('Audio', style: _label),
          const Spacer(),
          _audioMultiSelect(),
        ])),
        _div(),
        // ── Audio bitrate ──
        _row(Column(children: [
          Row(children: [
            Text('Audio bitrate', style: _label), const Spacer(),
            SizedBox(width: 160, child: Slider(
              value: _bitrateIndex(_recAudioBitrate).toDouble(),
              min: 0, max: (_bitrateSteps.length - 1).toDouble(),
              divisions: _bitrateSteps.length - 1,
              activeColor: accent,
              inactiveColor: XMateColors.divider(context),
              onChanged: (v) => setState(() => _recAudioBitrate = _bitrateSteps[v.round()]),
              onChangeEnd: (v) => widget.onRecAudioBitrateChanged(_bitrateSteps[v.round()]),
            )),
            SizedBox(width: 40, child: Text('${_recAudioBitrate}k', textAlign: TextAlign.right, style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.w700,
              color: (_recAudioBitrate >= 128 && _recAudioBitrate <= 192)
                  ? const Color(0xFF40C057)
                  : _recAudioBitrate > 192 ? accent : onSurface38,
            ))),
          ]),
          const SizedBox(height: 2),
          Row(children: [
            const SizedBox(width: 2),
            Text('← Smaller', style: TextStyle(fontSize: 10, color: onSurface38)),
            const Spacer(),
            Text((_recAudioBitrate >= 128 && _recAudioBitrate <= 192) ? 'Optimal' : '',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF40C057))),
            const Spacer(),
            Text('Better →', style: TextStyle(fontSize: 10, color: accent)),
            const SizedBox(width: 2),
          ]),
        ])),
        _div(),
        // ── Show mouse ──
        _row(Row(children: [
          Text('Mouse', style: _label),
          const Spacer(),
          Transform.scale(
            scale: 0.7,
            child:Switch(
            value: _recShowMouse,
            activeTrackColor: accent,
            onChanged: (v) {
              setState(() => _recShowMouse = v);
              widget.onRecShowMouseChanged(v);
            },
          ),
          ),
          const SizedBox(width: 4),
          Text(_recShowMouse ? 'Show' : 'Hide',
              style: TextStyle(fontSize: 13, color: onSurface54)),
        ])),
        _div(),
        _row(Row(children: [
          Text('Shortcut', style: _label),
          const Spacer(),
          _hotkeyBtn(_recLabel, _recCap, _startRec, _recFocus, _onRecKey),
        ])),
        if (_recConflict)
          Padding(
            padding: const EdgeInsets.only(left: 14, right: 14, bottom: 4),
            child: Text('This shortcut conflicts with another hotkey.',
                style: TextStyle(fontSize: 11, color: Colors.orangeAccent.withAlpha(200))),
          ),
      ])),
    ]);
  }

  // ── Shared widgets ──

  Widget _sectionTitle(String text, IconData icon) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Icon(icon, size: 16, color: cs.primary),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(fontSize: 13, color: cs.primary, fontWeight: FontWeight.w500)),
      ]),
    );
  }

  Widget _sectionCard(Widget child) {
    return Container(
      decoration: BoxDecoration(
        color: XMateColors.cardFill(context),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: child,
      ),
    );
  }

  Widget _dd(List<String> values, List<String> labels, String current, ValueChanged<String> onChanged) {
    if (values.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final _label = TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(179));
    // Guard: DropdownButton throws if `value` is not in `items`.
    final safeValue = values.contains(current) ? current : values.first;
    final items = <DropdownMenuItem<String>>[];
    for (int i = 0; i < values.length; i++) {
      items.add(DropdownMenuItem(value: values[i], child: Text(labels[i], style: _label)));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: XMateColors.inputBorder(context), borderRadius: BorderRadius.circular(6)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: safeValue, dropdownColor: XMateColors.toolbarBg(context),
          style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(179)),
          items: items,
          onChanged: (v) { if (v != null) onChanged(v); },
        ),
      ),
    );
  }
}
