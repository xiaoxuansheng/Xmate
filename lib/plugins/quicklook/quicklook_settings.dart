import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/quicklook/quicklook_utils.dart';
import '../../core/theme/theme_colors.dart';

// ── Format registry ──────────────────────────────────────────────────────────

class _FormatGroup {
  final IconData icon;
  final String label;
  final List<String> exts;
  const _FormatGroup(this.icon, this.label, this.exts);
}

const _kFormatGroups = [
  _FormatGroup(Icons.image,           'Image',     ['png','jpg','jpeg','webp','bmp','gif','svg','ico','tiff','tif','heic','heif','avif']),
  _FormatGroup(Icons.videocam,        'Video',     ['mp4','mkv','webm','avi','mov','wmv','flv','m4v','mpg','mpeg','3gp','3g2','ts','m2ts','vob','ogv']),
  _FormatGroup(Icons.headphones,      'Audio',     ['mp3','wav','flac','ogg','aac','m4a','wma','opus']),
  _FormatGroup(Icons.picture_as_pdf,  'PDF',       ['pdf']),
  _FormatGroup(Icons.article,         'Word',      ['doc','docx','docm']),
  _FormatGroup(Icons.slideshow,       'PowerPoint',['ppt','pptx','pptm']),
  _FormatGroup(Icons.table_chart,     'Excel',     ['xls','xlsx','xlsm']),
  _FormatGroup(Icons.folder_zip,      'Archive',   ['zip','7z','rar','tar','gz','bz2','xz','zst','lz','lz4','tgz','tbz2','txz']),
  _FormatGroup(Icons.email,           'Email',     ['eml']),
  _FormatGroup(Icons.menu_book,        'E-book',    ['epub']),
  _FormatGroup(Icons.code,            'Code',      ['json','xml','yaml','yml','toml','bat','sh','ps1','sql','py','js','ts','jsx','tsx','dart','html','css','scss','less','cpp','c','h','hpp','java','kt','rs','go','swift','cs','php','rb','lua','r','m','mm','pl','groovy','scala','elm','ex','exs','eex','heex','hs','nim','zig','v','fs','fsx']),
  _FormatGroup(Icons.text_snippet,    'Markdown',  ['md','markdown','mdx']),
  _FormatGroup(Icons.description,     'Plain Text',['txt','log','csv','ini','cfg','conf','env','gitignore','gitattributes','gitmodules','npmrc','editorconfig','prettierrc','eslintrc','metadata','properties','manifest','lock','diff','patch','nfo','rst','tex','bib']),
];

// ── Format list widget ────────────────────────────────────────────────────────

class _FormatList extends StatelessWidget {
  const _FormatList();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(color: cs.onSurface.withAlpha(32), height: 1),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Center(
            child: Text('Supported Formats',
                style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(138))),
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _kFormatGroups.map((g) => _FormatTile(g)).toList(),
          ),
        ),
      ],
    );
  }
}

class _FormatTile extends StatelessWidget {
  final _FormatGroup group;
  const _FormatTile(this.group);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final exts = group.exts;
    final tooltip = exts.isEmpty
        ? 'Directories'
        : exts.map((e) => '.$e').join('  ');
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: cs.onSurface.withAlpha(12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(group.icon, size: 14, color: cs.onSurface.withAlpha(138)),
          const SizedBox(width: 6),
          Text('${group.label}${exts.isNotEmpty ? "  (${exts.length})" : ""}',
              style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(179))),
        ]),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════


class QuickLookSettings extends StatefulWidget {
  final String hotkeyLabel;
  final bool Function(int mods, int keyId, String label)? onHotkeyChanged;
  final void Function(String source, bool active)? onCaptureStateChanged;

  // Key echo display toggles
  final bool keyEchoHotkey;
  final bool keyEchoStatus;
  final ValueChanged<bool>? onKeyEchoHotkeyChanged;
  final ValueChanged<bool>? onKeyEchoStatusChanged;

  // File Converter section
  final String fcFfmpegPath;
  final String fcDefaultOutputDir;
  final int fcMaxParallel;
  final String fcHwAccel;
  final ValueChanged<String>? onFcFfmpegPathChanged;
  final ValueChanged<String>? onFcOutputDirChanged;
  final ValueChanged<int>? onFcMaxParallelChanged;
  final ValueChanged<String>? onFcHwAccelChanged;

  const QuickLookSettings({
    super.key,
    this.hotkeyLabel = 'Alt+Q',
    this.onHotkeyChanged,
    this.onCaptureStateChanged,
    this.keyEchoHotkey = true,
    this.keyEchoStatus = true,
    this.onKeyEchoHotkeyChanged,
    this.onKeyEchoStatusChanged,
    this.fcFfmpegPath = '',
    this.fcDefaultOutputDir = '',
    this.fcMaxParallel = 1,
    this.fcHwAccel = 'off',
    this.onFcFfmpegPathChanged,
    this.onFcOutputDirChanged,
    this.onFcMaxParallelChanged,
    this.onFcHwAccelChanged,
  });
  @override State<QuickLookSettings> createState() => _QuickLookSettingsState();
}

class _QuickLookSettingsState extends State<QuickLookSettings> {
  static const _captureSource = 'settings.quicklook';

  bool _capturing = false;
  bool _conflict = false;
  String _displayLabel = 'Alt+Q';
  late final FocusNode _captureFocus = FocusNode();

  // Local key echo toggle state
  late bool _keyEchoHotkey;
  late bool _keyEchoStatus;

  // File Converter state
  late TextEditingController _fcFfmpegCtrl;
  String _ffStatus = '';
  bool _ffOk = false;
  late int _fcMaxParallel;
  late String _fcHwAccel;

  @override void initState() {
    super.initState();
    _displayLabel = widget.hotkeyLabel;
    _keyEchoHotkey = widget.keyEchoHotkey;
    _keyEchoStatus = widget.keyEchoStatus;
    _fcFfmpegCtrl = TextEditingController(text: widget.fcFfmpegPath);
    _fcMaxParallel = widget.fcMaxParallel;
    _fcHwAccel = widget.fcHwAccel;
    _captureFocus.addListener(_onCaptureFocusChange);
    _detectFfmpeg();
  }

  @override void didUpdateWidget(covariant QuickLookSettings old) {
    super.didUpdateWidget(old);
    if (widget.hotkeyLabel != old.hotkeyLabel) {
      _displayLabel = widget.hotkeyLabel;
    }
    if (widget.keyEchoHotkey != old.keyEchoHotkey) {
      _keyEchoHotkey = widget.keyEchoHotkey;
    }
    if (widget.keyEchoStatus != old.keyEchoStatus) {
      _keyEchoStatus = widget.keyEchoStatus;
    }
    if (widget.fcFfmpegPath != old.fcFfmpegPath && widget.fcFfmpegPath != _fcFfmpegCtrl.text) {
      _fcFfmpegCtrl.text = widget.fcFfmpegPath;
      _detectFfmpeg();
    }
    if (widget.fcDefaultOutputDir != old.fcDefaultOutputDir) {
    }
    if (widget.fcMaxParallel != old.fcMaxParallel) {
      setState(() => _fcMaxParallel = widget.fcMaxParallel);
    }
    if (widget.fcHwAccel != old.fcHwAccel) {
      setState(() => _fcHwAccel = widget.fcHwAccel);
    }
  }

  @override void dispose() {
    if (_capturing) {
      widget.onCaptureStateChanged?.call(_captureSource, false);
    }
    _captureFocus.dispose();
    _fcFfmpegCtrl.dispose();
    super.dispose();
  }

  void _onCaptureFocusChange() {
    if (!_captureFocus.hasFocus && _capturing) {
      setState(() => _capturing = false);
      widget.onCaptureStateChanged?.call(_captureSource, false);
    }
  }

  void _startCapture() {
    setState(() {
      _capturing = true;
      _conflict = false;
    });
    widget.onCaptureStateChanged?.call(_captureSource, true);
    _captureFocus.requestFocus();
  }

  void _onCaptureKey(KeyEvent event) {
    if (!_capturing || event is! KeyDownEvent) return;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.altLeft || key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.controlLeft || key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.shiftLeft || key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.metaLeft || key == LogicalKeyboardKey.metaRight) {
      return;
    }

    final mods = HardwareKeyboard.instance.logicalKeysPressed;
    int mask = 0;
    if (mods.contains(LogicalKeyboardKey.altLeft) || mods.contains(LogicalKeyboardKey.altRight)) mask |= 1;
    if (mods.contains(LogicalKeyboardKey.controlLeft) || mods.contains(LogicalKeyboardKey.controlRight)) mask |= 2;
    if (mods.contains(LogicalKeyboardKey.shiftLeft) || mods.contains(LogicalKeyboardKey.shiftRight)) mask |= 4;
    if (mods.contains(LogicalKeyboardKey.metaLeft) || mods.contains(LogicalKeyboardKey.metaRight)) mask |= 8;

    if (mask == 0) {
      setState(() => _capturing = false);
      widget.onCaptureStateChanged?.call(_captureSource, false);
      _captureFocus.unfocus();
      return;
    }

    final newLabel = formatHotkey(mask, key.keyId);
    final ok = widget.onHotkeyChanged?.call(mask, key.keyId, newLabel) ?? true;
    setState(() {
      _capturing = false;
      if (ok) {
        _displayLabel = newLabel;
        _conflict = false;
      } else {
        _conflict = true;
      }
    });
    widget.onCaptureStateChanged?.call(_captureSource, false);
    _captureFocus.unfocus();
  }

  // ── FFmpeg detection ──

  Future<void> _detectFfmpeg() async {
    final up = _fcFfmpegCtrl.text.trim();
    if (up.isNotEmpty) {
      if (File(up).existsSync()) {
        setState(() { _ffStatus = 'Found'; _ffOk = true; });
      } else {
        setState(() { _ffStatus = 'Not found'; _ffOk = false; });
      }
      return;
    }
    // Try screenrecording's stored path as fallback
    try {
      final d = await const MethodChannel('com.xmate/screenrecording')
          .invokeMethod<String>('findFFmpegPath');
      if (d != null && d.isNotEmpty && d != 'ffmpeg.exe' && mounted) {
        if (File(d).existsSync()) {
          setState(() { _ffStatus = 'Auto-detected'; _ffOk = true; });
          return;
        }
      }
    } catch (_) {}
    if (mounted) setState(() { _ffStatus = 'Not configured'; _ffOk = false; });
  }

  void _pickFfmpeg() async {
    // Use a simple file open dialog via platform channel
    try {
      final path = await const MethodChannel('com.xmate/picker')
          .invokeMethod<String>('pickFile', {'title': 'Select FFmpeg executable', 'filter': '*.exe'});
      if (!mounted) return;
      if (path != null && path.isNotEmpty) {
        _fcFfmpegCtrl.text = path;
        widget.onFcFfmpegPathChanged?.call(path);
        _detectFfmpeg();
      }
    } catch (_) {}
  }

  // ── Build row helpers ──

  Widget _row(Widget child) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: child,
    );
  }

  Widget _div() => Divider(height: 1, thickness: 1, indent: 14, endIndent: 14, color: XMateColors.divider(context));

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

  Widget _hotkeyBtn() {
    final cs = Theme.of(context).colorScheme;
    return KeyboardListener(
      focusNode: _captureFocus,
      onKeyEvent: _onCaptureKey,
      child: GestureDetector(
        onTap: _startCapture,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _capturing
                ? cs.primary.withAlpha(60)
                : cs.onSurface.withAlpha(15),
            borderRadius: BorderRadius.circular(6),
            border: _capturing
                ? Border.all(color: cs.primary, width: 1.5)
                : null,
          ),
          child: Text(
            _capturing ? 'Press keys...' : _displayLabel,
            style: TextStyle(
              fontSize: 13,
              color: _capturing ? cs.primary : cs.onSurface.withAlpha(179),
              fontWeight: _capturing ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labelStyle = TextStyle(fontSize: 14, color: cs.onSurface);

    return Column(mainAxisSize: MainAxisSize.min, children: [
      // ═══ File ═══
      _sectionTitle('File', Icons.insert_drive_file),
      _sectionCard(Column(mainAxisSize: MainAxisSize.min, children: [
        _row(Row(children: [
          Text('Shortcut', style: labelStyle),
          const Spacer(),
          _hotkeyBtn(),
        ])),
        if (_conflict)
          Padding(
            padding: const EdgeInsets.only(left: 14, right: 14, bottom: 4),
            child: Text(
              'Conflict — this hotkey is already in use.',
              style: TextStyle(fontSize: 11, color: Colors.orangeAccent.withAlpha(200)),
            ),
          ),
        const _FormatList(),
      ])),

      const SizedBox(height: 14),

      // ═══ Hotkey & Lock ═══
      _sectionTitle('Hotkey & Lock', Icons.keyboard_alt),
      _sectionCard(Column(mainAxisSize: MainAxisSize.min, children: [
        _row(Row(children: [
          Text('Key echo - Hotkey', style: labelStyle),
          const Spacer(),
          SizedBox(
            height: 28,
            child: Transform.scale(
              scale: 0.7,
              child: Switch(
                value: _keyEchoHotkey,
                onChanged: (v) {
                  setState(() => _keyEchoHotkey = v);
                  widget.onKeyEchoHotkeyChanged?.call(v);
                },
                activeTrackColor: cs.primary,
              ),
            ),
          ),
        ])),
        _div(),
        _row(Row(children: [
          Text('Key echo - Status', style: labelStyle),
          const Spacer(),
          SizedBox(
            height: 28,
            child: Transform.scale(
              scale: 0.7,
              child: Switch(
                value: _keyEchoStatus,
                onChanged: (v) {
                  setState(() => _keyEchoStatus = v);
                  widget.onKeyEchoStatusChanged?.call(v);
                },
                activeTrackColor: cs.primary,
              ),
            ),
          ),
        ])),
      ])),

      const SizedBox(height: 14),

      // ═══ File Converter ═══
      _sectionTitle('File Converter', Icons.swap_horiz),
      _sectionCard(Column(mainAxisSize: MainAxisSize.min, children: [
        // FFmpeg path
        _row(Row(children: [
          Text('FFmpeg', style: labelStyle),
          const Spacer(),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_ffOk ? Icons.check_circle : Icons.warning_amber, size: 14,
                color: _ffOk ? Colors.green : Colors.orangeAccent),
            const SizedBox(width: 6),
            Text(_ffStatus, style: TextStyle(fontSize: 11,
                color: _ffOk ? cs.onSurface.withAlpha(150) : Colors.orangeAccent)),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: _pickFfmpeg,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: XMateColors.highlight(context),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('Browse', style: TextStyle(fontSize: 11, color: cs.primary)),
              ),
            ),
          ]),
        ])),
        _div(),
        // Max simultaneous conversions
        _row(Row(children: [
          Text('Max Simultaneous', style: labelStyle),
          const Spacer(),
          Row(mainAxisSize: MainAxisSize.min, children: [
            _StepperBtn(icon: Icons.remove, onTap: () {
              final v = _fcMaxParallel;
              if (v > 1) {
                setState(() => _fcMaxParallel = v - 1);
                widget.onFcMaxParallelChanged?.call(v - 1);
              }
            }),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text('$_fcMaxParallel',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.primary)),
            ),
            _StepperBtn(icon: Icons.add, onTap: () {
              final v = _fcMaxParallel;
              if (v < 8) {
                setState(() => _fcMaxParallel = v + 1);
                widget.onFcMaxParallelChanged?.call(v + 1);
              }
            }),
          ]),
        ])),
        _div(),
        // Hardware acceleration
        _row(Row(children: [
          Text('Hardware Acceleration', style: labelStyle),
          const Spacer(),
          DropdownButton<String>(
            value: _fcHwAccel,
            isDense: true,
            underline: const SizedBox.shrink(),
            style: TextStyle(fontSize: 13, color: cs.primary),
            items: const [
              DropdownMenuItem(value: 'off', child: Text('Off')),
              DropdownMenuItem(value: 'cuda', child: Text('CUDA')),
              DropdownMenuItem(value: 'amf', child: Text('AMF')),
            ],
            onChanged: (v) {
              if (v != null) {
                setState(() => _fcHwAccel = v);
                widget.onFcHwAccelChanged?.call(v);
              }
            },
          ),
        ])),
        _div(),
        // Supported formats (QuickLook style)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
          child: Column(children: [
            Center(
              child: Text('Supported Output Formats',
                  style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(138))),
            ),
            const SizedBox(height: 10),
            Center(
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                _FcFormatTile(cs, Icons.headphones, 'Audio', ['AAC', 'FLAC', 'MP3', 'OGG', 'WAV']),
                _FcFormatTile(cs, Icons.videocam, 'Video', ['AVI', 'MKV', 'MP4', 'OGV', 'WebM']),
                _FcFormatTile(cs, Icons.image, 'Image', ['AVIF', 'GIF', 'ICO', 'JPEG', 'PNG', 'WebP']),
                _FcFormatTile(cs, Icons.description, 'Document', ['PDF']),
              ]),
            ),
          ]),
        ),
        _div(),
        // Copyright
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Center(
            child: Text('File Converter — open-source file conversion framework. FFmpeg-powered.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(70))),
          ),
        ),
      ])),
    ]);
  }
}

class _StepperBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _StepperBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 26, height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: cs.primary.withAlpha(30),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 14, color: cs.primary),
      ),
    );
  }
}

class _FcFormatTile extends StatelessWidget {
  final ColorScheme cs;
  final IconData icon;
  final String label;
  final List<String> exts;
  const _FcFormatTile(this.cs, this.icon, this.label, this.exts);

  @override
  Widget build(BuildContext context) {
    final tooltip = exts.map((e) => '.$e').join('  ');
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: cs.onSurface.withAlpha(12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: cs.onSurface.withAlpha(138)),
          const SizedBox(width: 6),
          Text('$label  (${exts.length})',
              style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(179))),
        ]),
      ),
    );
  }
}
