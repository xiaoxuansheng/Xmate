import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:http/http.dart' as http;
import 'server_manager.dart';
import 'model_manager.dart';
import 'translate_service.dart';
import '../../core/drag/drag_out_helper.dart';
import '../../core/picker/picker_service.dart';
import '../../core/search/search_engine_service.dart';
import '../../core/settings/settings_service.dart';
import '../../core/theme/theme_colors.dart';

/// Language option used in source/target dropdowns.
class _Lang {
  final String code;
  final String name;
  const _Lang(this.code, this.name);

  @override
  bool operator ==(Object other) => other is _Lang && other.code == code;

  @override
  int get hashCode => code.hashCode;
}

const _kFallback = [
  _Lang('auto', '自动检测'),
  _Lang('en', '英语'),
  _Lang('zh', '简体中文'),
];

const _kSupportedExts = '.txt .html .srt .pdf .docx .pptx .epub .odt .odp';
const _kSupportedHint = 'Supported: $_kSupportedExts';

/// Per-file state for multi-file translation.
enum _FileStatus { pending, translating, done, error }

class _FileItem {
  final String path;
  final String name;
  _FileStatus status = _FileStatus.pending;
  String? resultUrl;
  String? resultName;
  String? errorMsg;

  _FileItem({required this.path, required this.name});

  String get resultFileName {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    return '${base}_zh$ext'; // placeholder, updated at translate time
  }
}

class TranslatePage extends StatefulWidget {
  final String? initialText;
  final List<String>? initialFiles; // paths to auto-add on init
  final VoidCallback onClose;

  const TranslatePage({
    super.key,
    this.initialText,
    this.initialFiles,
    required this.onClose,
  });

  @override
  State<TranslatePage> createState() => _TranslatePageState();
}

class _TranslatePageState extends State<TranslatePage> {
  final _srcCtrl = TextEditingController();
  final _resultCtrl = TextEditingController();
  final _srv = ServerManager();
  final _searchService = SearchEngineService();

  List<_Lang> _langs = List.from(_kFallback);
  _Lang _srcLang = _kFallback[0];
  _Lang _tgtLang = _kFallback[2];
  bool _translating = false;

  // File translation — multi-file queue
  final List<_FileItem> _files = [];
  int _translatingFileIndex = -1; // -1 = not translating
  int _downloadingIndex = -1;

  bool _topmost = false;

  static const _kTopmostKey = 'translate.topmost';

  static const _green = Color(0xFF40C057);
  static const _red = Color(0xFFE84040);
  static const _orange = Color(0xFFE8A440);

  static const _dragChannel = MethodChannel('com.xmate/dragdrop');

  bool get _inFileMode => _files.isNotEmpty;
  bool get _allDone => _files.isNotEmpty && _files.every((f) => f.status == _FileStatus.done);

  @override
  void initState() {
    super.initState();
    // Load saved topmost state
    _topmost = SettingsService().getWithDefault(_kTopmostKey, false);
    if (_topmost) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await windowManager.setAlwaysOnTop(true);
      });
    }
    if (widget.initialText != null && widget.initialText!.isNotEmpty) {
      _srcCtrl.text = widget.initialText!;
    }
    if (widget.initialFiles != null && widget.initialFiles!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _addFiles(widget.initialFiles!);
      });
    }
    _loadLangs();
    _initDragDrop();
  }

  void _initDragDrop() {
    _dragChannel.setMethodCallHandler((call) async {
      if (call.method != 'onDrop' || !mounted) return;
      final args = call.arguments as Map<dynamic, dynamic>?;
      if (args == null) return;
      final type = args['type'] as String?;
      if (type == 'text') {
        final text = args['text'] as String? ?? '';
        if (text.isNotEmpty && mounted) {
          setState(() => _srcCtrl.text = text);
        }
      } else if (type == 'files') {
        final raw = args['files'] as List<dynamic>?;
        if (raw == null || raw.isEmpty) return;
        _addFiles(raw.cast<String>());
      }
    });
  }

  void _addFiles(List<String> paths, {bool silent = false}) {
    int added = 0;
    final unsupported = <String>[];
    for (final path in paths) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final name = file.uri.pathSegments.last;
      final ext = name.contains('.') ? name.substring(name.lastIndexOf('.')) : '';
      if (!_kSupportedExts.contains(ext.toLowerCase())) {
        unsupported.add(name);
        continue;
      }
      if (_files.any((f) => f.path == path)) continue;
      _files.add(_FileItem(path: path, name: name));
      added++;
    }
    if (added > 0) {
      setState(() {});
      if (!silent) _showSnack('Added $added file${added > 1 ? "s" : ""}');
    }
    if (unsupported.isNotEmpty) {
      final names = unsupported.length <= 3
          ? unsupported.join(', ')
          : '${unsupported.take(3).join(', ')} and ${unsupported.length - 3} more';
      _showSnack('Unsupported: $names');
    }
  }

  Future<void> _loadLangs() async {
    final mgr = ModelManager();
    final installed = await mgr.listInstalledPairs();
    if (!mounted) return;

    final codes = <String>{'en'};
    String norm(String c) => c == 'zh-Hans' ? 'zh' : c;
    for (final m in installed) {
      codes.add(norm(m.code1));
      codes.add(norm(m.code2));
    }

    final langs = <_Lang>[_Lang('auto', '自动检测')];
    for (final c in codes) {
      langs.add(_Lang(c, langNameZh(c)));
    }
    langs.sort((a, b) {
      if (a.code == 'auto') return -1;
      if (b.code == 'auto') return 1;
      return a.name.compareTo(b.name);
    });

    if (!mounted) return;
    setState(() {
      _langs = langs;
      if (!langs.any((l) => l.code == _srcLang.code)) _srcLang = langs[0];
      if (!langs.any((l) => l.code == _tgtLang.code)) {
        final zh = langs.cast<_Lang?>().firstWhere((l) => l?.code == 'zh', orElse: () => null);
        _tgtLang = zh ?? (langs.length > 1 ? langs[1] : langs[0]);
      }
    });
  }

  @override
  void dispose() {
    _srcCtrl.dispose();
    _resultCtrl.dispose();
    super.dispose();
  }

  // ── Translate dispatcher ──────────────────────────────────────

  Future<void> _onTranslate() async {
    if (_inFileMode) {
      await _doTranslateFiles();
    } else {
      await _doTranslateText();
    }
  }

  Future<void> _doTranslateText() async {
    final text = _srcCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _translating = true);

    try {
      final service = TranslateService(baseUrl: _srv.baseUrl, timeout: const Duration(seconds: 15));
      final result = await service.translateWithDetail(
        text, from: _srcLang.code, to: _tgtLang.code,
      );
      if (!mounted) return;
      if (result.ok) {
        _resultCtrl.text = result.text ?? '';
      } else {
        _resultCtrl.text = '${result.errorType}: ${result.errorMessage}';
      }
    } catch (e) {
      if (!mounted) return;
      _resultCtrl.text = 'Error: $e';
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  // ── Multi-file translation ────────────────────────────────────

  String _resultFileName(String name) {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    return '${base}_${_tgtLang.code}$ext';
  }

  /// Add files via system picker (supports multi-select).
  Future<void> _pickFiles() async {
    try {
      final raw = await const MethodChannel('com.xmate/filesearch').invokeMethod<String>('pickFiles');
      if (raw == null || raw.isEmpty || raw == '[]') return;
      if (!mounted) return;
      final paths = (jsonDecode(raw) as List<dynamic>).cast<String>();
      _addFiles(paths);
    } catch (_) {}
  }

  /// Translate all pending files sequentially.
  Future<void> _doTranslateFiles() async {
    for (int i = 0; i < _files.length; i++) {
      final f = _files[i];
      if (f.status == _FileStatus.done) continue;
      if (!mounted) return;

      setState(() {
        f.status = _FileStatus.translating;
        _translatingFileIndex = i;
      });

      try {
        final uri = Uri.parse('${_srv.baseUrl}/translate_file');
        final request = http.MultipartRequest('POST', uri);
        request.fields['source'] = _srcLang.code == 'auto' ? 'en' : _srcLang.code;
        request.fields['target'] = _tgtLang.code;
        request.files.add(await http.MultipartFile.fromPath('file', f.path));

        final streamed = await request.send().timeout(const Duration(seconds: 120));
        if (!mounted) return;

        final body = await streamed.stream.bytesToString();
        if (streamed.statusCode == 200) {
          final decoded = jsonDecode(body) as Map<String, dynamic>;
          final fileUrl = decoded['translatedFileUrl'] as String?;
          final resultName = _resultFileName(f.name);
          setState(() {
            f.status = _FileStatus.done;
            f.resultUrl = fileUrl;
            f.resultName = resultName;
          });
        } else {
          setState(() {
            f.status = _FileStatus.error;
            f.errorMsg = 'HTTP ${streamed.statusCode}: $body';
          });
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          f.status = _FileStatus.error;
          f.errorMsg = '$e';
        });
      }
    }
    if (mounted) {
      setState(() {
        _translatingFileIndex = -1;
        if (_allDone) _showSnack('All files translated');
      });
    }
  }

  // ── Download ──────────────────────────────────────────────────

  /// Save to source directory (same folder as original file).
  Future<void> _saveToSource(int index) async {
    final f = _files[index];
    if (f.resultUrl == null) return;

    setState(() => _downloadingIndex = index);
    try {
      final srcDir = File(f.path).parent.path;
      final dst = '$srcDir/${f.resultName ?? "translated"}';
      await _downloadFile(f.resultUrl!, dst);
      if (!mounted) return;
      _showSnack('Saved to $dst');
    } catch (e) {
      if (mounted) _showSnack('Download failed: $e');
    } finally {
      if (mounted) setState(() => _downloadingIndex = -1);
    }
  }

  /// Save to a user-chosen folder.
  Future<void> _saveToFolder(int index) async {
    final f = _files[index];
    if (f.resultUrl == null) return;

    final folder = await PickerService().pickFolder();
    if (folder == null) return;

    setState(() => _downloadingIndex = index);
    try {
      final dst = '$folder/${f.resultName ?? "translated"}';
      await _downloadFile(f.resultUrl!, dst);
      if (!mounted) return;
      _showSnack('Saved to $dst');
    } catch (e) {
      if (mounted) _showSnack('Download failed: $e');
    } finally {
      if (mounted) setState(() => _downloadingIndex = -1);
    }
  }

  /// Save to source dir, then open the file.
  Future<void> _openFile(int index) async {
    final f = _files[index];
    if (f.resultUrl == null) return;
    setState(() => _downloadingIndex = index);
    try {
      final srcDir = File(f.path).parent.path;
      final dst = '$srcDir/${f.resultName ?? "translated"}';
      await _downloadFile(f.resultUrl!, dst);
      if (!mounted) return;
      // Open the file with default app
      await Process.run('cmd', ['/c', 'start', '', dst.replaceAll('/', '\\')], runInShell: true);
      _showSnack('Opened ${f.resultName}');
    } catch (e) {
      if (mounted) _showSnack('Open failed: $e');
    } finally {
      if (mounted) setState(() => _downloadingIndex = -1);
    }
  }

  Future<void> _downloadFile(String url, String dst) async {
    final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
    if (response.statusCode == 200) {
      await File(dst).writeAsBytes(response.bodyBytes);
    } else {
      throw Exception('HTTP ${response.statusCode}');
    }
  }

  // ── Actions ───────────────────────────────────────────────────

  void _swapLanguages() {
    if (_srcLang.code == 'auto') return;
    setState(() {
      final s = _srcLang;
      _srcLang = _tgtLang;
      _tgtLang = s;
    });
    final oldRes = _resultCtrl.text;
    _resultCtrl.text = '';
    if (oldRes.isNotEmpty) _srcCtrl.text = oldRes;
  }

  void _copyResult() {
    if (_resultCtrl.text.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: _resultCtrl.text));
      _showSnack('Copied');
    }
  }

  Future<void> _toggleTopmost() async {
    _topmost = !_topmost;
    await windowManager.setAlwaysOnTop(_topmost);
    await SettingsService().set(_kTopmostKey, _topmost);
    setState(() {});
  }

  void _translateInWeb(SearchEngine? engine) {
    final text = _srcCtrl.text.trim();
    if (text.isEmpty) return;
    final e = engine ?? _searchService.getDefaultEngine(SearchEngineCategory.translate);
    if (e == null) return;
    _searchService.execute(e, text);
  }

  void _showTranslateEngineMenu(Offset position) {
    final engines = _searchService.loadEnginesByCategory(SearchEngineCategory.translate);
    if (engines.isEmpty) return;
    final screen = MediaQuery.of(context).size;
    const menuW = 200.0;
    const rowH = 42.0; // padding 10*2 + fontSize 13 ≈ 42
    final menuH = engines.length * rowH;
    final left = (position.dx + menuW > screen.width)
        ? position.dx - menuW
        : position.dx;
    final top = (position.dy + menuH > screen.height)
        ? position.dy - menuH
        : position.dy;
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(builder: (ctx) {
      final cs = Theme.of(context).colorScheme;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => entry.remove(),
        child: Stack(children: [
          Positioned(
            left: left,
            top: top,
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 220),
                decoration: BoxDecoration(
                  color: XMateColors.dialogBg(context),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.primary.withAlpha(60), width: 1),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: engines.map((engine) => InkWell(
                    onTap: () {
                      entry.remove();
                      _translateInWeb(engine);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(children: [
                        Icon(Icons.language, size: 14, color: cs.onSurface.withAlpha(138)),
                        const SizedBox(width: 8),
                        Text(engine.name, style: TextStyle(fontSize: 13, color: cs.onSurface)),
                      ]),
                    ),
                  )).toList(),
                ),
              ),
            ),
          ),
        ]),
      );
    });
    overlay.insert(entry);
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: TextStyle(fontSize: 12, color: cs.onSurface)),
        duration: const Duration(seconds: 2),
        backgroundColor: XMateColors.pageBg(context),
      ),
    );
  }

  // ── Title bar ─────────────────────────────────────────────────

  Widget _titleBar() {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: XMateColors.panelBg(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Row(
          children: [
            const SizedBox(width: 14),
            Icon(Icons.translate, size: 16, color: cs.primary),
            const SizedBox(width: 8),
            Text('Translate', style: TextStyle(fontSize: 13, color: cs.onSurface, fontWeight: FontWeight.w500)),
            const Spacer(),
            _titleBtn(Icons.vertical_align_top, _toggleTopmost, active: _topmost),
            _titleBtn(Icons.minimize, () => windowManager.minimize()),
            _titleBtn(Icons.close, widget.onClose),
          ],
        ),
      ),
    );
  }

  Widget _titleBtn(IconData icon, VoidCallback onTap, {bool active = false}) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42, height: 36, alignment: Alignment.center,
        child: Icon(icon, size: 16, color: active ? cs.primary : cs.onSurface.withAlpha(138)),
      ),
    );
  }

  // ── Language bar ──────────────────────────────────────────────

  Widget _langBar() {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _langDropdown(_srcLang, (v) => setState(() => _srcLang = v), true),
          const SizedBox(width: 8),
          Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: XMateColors.cardFill(context)),
            child: IconButton(
              icon: Icon(Icons.swap_horiz, size: 18, color: cs.onSurface.withAlpha(179)),
              onPressed: _swapLanguages,
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(),
              splashRadius: 14,
            ),
          ),
          const SizedBox(width: 8),
          _langDropdown(_tgtLang, (v) => setState(() => _tgtLang = v), false),
        ],
      ),
    );
  }

  Widget _langDropdown(_Lang value, ValueChanged<_Lang> onChanged, bool isSource) {
    final cs = Theme.of(context).colorScheme;
    final items = isSource ? _langs : _langs.where((l) => l.code != 'auto').toList();
    return Expanded(
      child: Container(
        height: 34,
        decoration: BoxDecoration(color: XMateColors.cardFill(context), borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<_Lang>(
            value: items.any((l) => l.code == value.code) ? value : items.first,
            isExpanded: true,
            dropdownColor: XMateColors.dialogBg(context),
            style: TextStyle(fontSize: 13, color: cs.onSurface),
            icon: Icon(Icons.arrow_drop_down, color: cs.onSurface.withAlpha(138), size: 18),
            items: items
                .map((l) => DropdownMenuItem(value: l, child: Text(l.name, style: const TextStyle(fontSize: 13))))
                .toList(),
            onChanged: (v) { if (v != null) onChanged(v); },
          ),
        ),
      ),
    );
  }

  // ── Text panes ────────────────────────────────────────────────

  Widget _textPanes() {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: _inFileMode ? _fileList() : _textPaneRow(),
      ),
    );
  }

  Widget _textPaneRow() {
    return Row(children: [
      Expanded(child: _srcPane()),
      const SizedBox(width: 8),
      Expanded(child: _tgtPane()),
    ]);
  }

  Widget _srcPane() {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4, left: 4),
          child: Row(children: [
            Text(_srcLang.name, style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(97))),
            if (_inFileMode) ...[
              const Spacer(),
              _miniBtn('Clear all', () => setState(() {
                _files.clear();
                _resultCtrl.text = '';
              })),
            ],
          ]),
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(color: XMateColors.cardFill(context), borderRadius: BorderRadius.circular(10)),
            child: DragOutTextField(
              controller: _srcCtrl,
              maxLines: null, expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: TextStyle(fontSize: 14, color: cs.onSurface),
              decoration: InputDecoration(
                hintText: _inFileMode ? 'Add files below...' : 'Enter text...',
                hintStyle: TextStyle(fontSize: 14, color: cs.onSurface.withAlpha(50)),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.all(12),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _tgtPane() {
    final cs = Theme.of(context).colorScheme;
    final accent = cs.primary;
    final hasText = _resultCtrl.text.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4, left: 4),
          child: Row(children: [
            Text(_tgtLang.name, style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(97))),
            const Spacer(),
            if (hasText)
              GestureDetector(
                onTap: _copyResult,
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(Icons.copy, size: 14, color: cs.onSurface.withAlpha(97)),
                ),
              ),
          ]),
        ),
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(color: XMateColors.cardFill(context), borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.all(12),
            child: _translating
                ? Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: accent)))
                : SingleChildScrollView(
                    child: DragOutSelectableText(
                      hasText ? _resultCtrl.text : 'Translation will appear here',
                      style: TextStyle(fontSize: 14, color: hasText ? cs.onSurface : cs.onSurface.withAlpha(60)),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  // ── File list ─────────────────────────────────────────────────

  Widget _fileList() {
    final cs = Theme.of(context).colorScheme;
    final scrollCtrl = ScrollController();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Summary row
        Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 4),
          child: Text(
            '${_files.length} file${_files.length > 1 ? "s" : ""} — $_tgtLang name',
            style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(97)),
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: scrollCtrl,
            itemCount: _files.length,
            itemBuilder: (_, i) => _fileRow(i),
          ),
        ),
      ],
    );
  }

  Widget _fileRow(int i) {
    final cs = Theme.of(context).colorScheme;
    final accent = cs.primary;
    final f = _files[i];
    final downloading = _downloadingIndex == i;

    Color dotColor;
    IconData dotIcon;
    switch (f.status) {
      case _FileStatus.pending:
        dotColor = cs.onSurface.withAlpha(24);
        dotIcon = Icons.circle;
      case _FileStatus.translating:
        dotColor = _orange;
        dotIcon = Icons.circle;
      case _FileStatus.done:
        dotColor = _green;
        dotIcon = Icons.check_circle;
      case _FileStatus.error:
        dotColor = _red;
        dotIcon = Icons.error;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: XMateColors.cardFill(context), borderRadius: BorderRadius.circular(6),
          border: Border.all(color: XMateColors.inputBorder(context)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(dotIcon, size: 14, color: dotColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(f.name, style: TextStyle(fontSize: 12, color: cs.onSurface)),
                if (f.status == _FileStatus.error && f.errorMsg != null)
                  Text(f.errorMsg!, style: const TextStyle(fontSize: 9, color: _red), maxLines: 2, overflow: TextOverflow.ellipsis)
                else if (f.status == _FileStatus.done && f.resultName != null)
                  Text(f.resultName!, style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(97))),
                if (f.status == _FileStatus.translating)
                  const Text('Translating...', style: TextStyle(fontSize: 10, color: _orange)),
              ]),
            ),
            if (f.status == _FileStatus.done && f.resultUrl != null) ...[
              if (downloading)
                SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: accent))
              else ...[
                _smallBtn('Open', () => _openFile(i)),
                const SizedBox(width: 4),
                _smallBtn('Save', () => _saveToSource(i)),
                const SizedBox(width: 4),
                _smallBtn('As...', () => _saveToFolder(i)),
              ],
            ],
            _smallBtn('X', () => setState(() => _files.removeAt(i))),
          ]),
        ]),
      ),
    );
  }

  // ── Bottom bar ────────────────────────────────────────────────

  Widget _bottomBar() {
    final cs = Theme.of(context).colorScheme;
    final accent = cs.primary;
    final canTranslate = _inFileMode
        ? _files.any((f) => f.status == _FileStatus.pending)
        : _srcCtrl.text.trim().isNotEmpty;
    final busy = _translating || _translatingFileIndex >= 0;

    return Container(
      decoration: BoxDecoration(
        color: XMateColors.panelBg(context),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            OutlinedButton.icon(
              onPressed: busy ? null : _pickFiles,
              icon: const Icon(Icons.upload_file, size: 15),
              label: Text(_inFileMode ? 'Add file' : 'Select file', style: const TextStyle(fontSize: 11)),
              style: OutlinedButton.styleFrom(
                foregroundColor: cs.onSurface.withAlpha(138),
                side: BorderSide(color: cs.onSurface.withAlpha(24)),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_kSupportedHint, style: TextStyle(fontSize: 9, color: cs.onSurface.withAlpha(24)), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            if (_inFileMode && _files.isNotEmpty)
              Text('${_files.where((f) => f.status == _FileStatus.done).length}/${_files.length} done ',
                  style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(97))),
            const Spacer(),
            // ── Translate in web (translate engines) ──
            GestureDetector(
              onTap: () => _translateInWeb(null),
              onSecondaryTapUp: (d) => _showTranslateEngineMenu(d.globalPosition),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: accent.withAlpha(120), width: 1),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.open_in_browser, size: 16, color: accent),
                  const SizedBox(width: 4),
                  Text('Web', style: TextStyle(fontSize: 12, color: accent)),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: busy || !canTranslate ? null : _onTranslate,
              icon: Icon(busy ? Icons.hourglass_empty : Icons.translate, size: 16),
              label: Text(busy ? 'Please wait' : 'Translate', style: const TextStyle(fontSize: 12)),
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: XMateColors.dialogBg(context),
                disabledBackgroundColor: XMateColors.divider(context),
                disabledForegroundColor: cs.onSurface.withAlpha(97),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────

  Widget _miniBtn(String label, VoidCallback onTap) {
    final accent = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), color: XMateColors.inputFill(context)),
        child: Text(label, style: TextStyle(fontSize: 10, color: accent)),
      ),
    );
  }

  Widget _smallBtn(String label, VoidCallback onTap) {
    final accent = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), color: XMateColors.inputFill(context)),
        child: Text(label, style: TextStyle(fontSize: 10, color: accent)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(
          color: XMateColors.panelBg(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Theme.of(context).colorScheme.primary.withAlpha(60), width: 1.5),
        ),
        child: Column(children: [
          _titleBar(),
          _langBar(),
          _textPanes(),
          _bottomBar(),
        ]),
      ),
    );
  }
}
