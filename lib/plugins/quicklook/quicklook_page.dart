import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'quicklook_image_annotator.dart';
import 'views/quicklook_rich_view.dart';
import 'views/quicklook_folder_view.dart';
import 'views/quicklook_fallback_view.dart';
import 'views/quicklook_pdf_view.dart';
import 'views/quicklook_audio_view.dart';
import 'views/quicklook_video_view.dart';
import 'views/quicklook_office_view.dart';
import 'views/quicklook_hex_view.dart';
import 'views/quicklook_archive_view.dart';
import 'quicklook_eml_view.dart';
import 'quicklook_epub_view.dart';
import '../../core/quicklook/quicklook_utils.dart';
import '../../core/theme/theme_colors.dart';

/// Preview types based on file extension.
enum _PreviewType { loading, image, text, code, markdown, folder, pdf, audio, video, word, ppt, xls, archive, eml, epub, fallback, error }

// ─── Persisted QuickLook window state ─────────────────────────────

class QlWindowState {
  final double? x, y;
  final bool topmost;  // "置顶" — always-on-top (persisted)
  final bool showFileSize; // folder view: compute & show folder sizes
  const QlWindowState({this.x, this.y, this.topmost = false, this.showFileSize = false});

  static Future<String> get _path async {
    final dir = '${Platform.environment['APPDATA']}\\XMate';
    await Directory(dir).create(recursive: true);
    return '$dir\\ql_state.json';
  }

  static Future<void> save({double? x, double? y, bool? topmost, bool? showFileSize}) async {
    try {
      final prev = await load();
      await File(await _path)
          .writeAsString(jsonEncode({
            'x': x ?? prev.x,
            'y': y ?? prev.y,
            'topmost': topmost ?? prev.topmost,
            'showFileSize': showFileSize ?? prev.showFileSize,
          }));
    } catch (_) {}
  }

  static Future<QlWindowState> load() async {
    try {
      final f = File(await _path);
      if (!await f.exists()) return const QlWindowState();
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      // Read new 'topmost' key; fall back to legacy 'pinned' key.
      final tm = m['topmost'] == true || m['pinned'] == true;
      final sfs = m['showFileSize'] == true;
      return QlWindowState(
        x: (m['x'] as num?)?.toDouble(),
        y: (m['y'] as num?)?.toDouble(),
        topmost: tm,
        showFileSize: sfs,
      );
    } catch (_) {
      return const QlWindowState();
    }
  }
}

// ───────────────────────────────────────────────────────────────────

class QuickLookPage extends StatefulWidget {
  final String? filePath;
  final void Function(Size targetSize) onReady;
  final VoidCallback onClose;
  final bool initialTopmost;

  const QuickLookPage({
    super.key,
    this.filePath,
    required this.onReady,
    required this.onClose,
    this.initialTopmost = false,
  });

  @override
  State<QuickLookPage> createState() => _QuickLookPageState();
}

class _QuickLookPageState extends State<QuickLookPage> with WindowListener {
  String? _filePath;
  _PreviewType _type = _PreviewType.loading;
  String? _errorMsg;
  Uint8List? _imageBytes;
  bool _topmost = false;   // "置顶" — always-on-top
  bool _locked = false;    // "Pin" — lock file, immune to Alt+Q
  bool _editingLocked = false; // locked while editing (not user-controlled, not pin button)
  bool _folderSel = false; // folder view has a selection → suppress global Enter
  bool _fullscreen = false;
  Rect? _preFullscreenRect;
  bool _showFileSize = false; // folder view: compute & show recursive folder sizes
  Timer? _pollTimer;
  bool _hexMode = false; // hex view toggle — orthogonal to _PreviewType

  // Extension sets.
  static const _imageExts = {
    'png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif', 'svg', 'ico', 'tiff', 'tif',
    'heic', 'heif', 'avif',
  };
  // Code files — syntax highlighting via WebView2 (Phase C).
  static const _codeExts = {
    'json', 'xml', 'yaml', 'yml', 'toml', 'bat', 'sh', 'ps1', 'sql',
    'py', 'js', 'ts', 'jsx', 'tsx', 'dart', 'html', 'css', 'scss', 'less',
    'cpp', 'c', 'h', 'hpp', 'java', 'kt', 'rs', 'go', 'swift',
    'cs', 'php', 'rb', 'lua', 'r', 'm', 'mm', 'pl',
    'groovy', 'scala', 'elm', 'ex', 'exs', 'eex', 'heex',
    'hs', 'nim', 'zig', 'v', 'fs', 'fsx',
  };
  // Markdown files — rendered via WebView2 + marked.js (Phase C).
  static const _mdExts = {'md', 'markdown', 'mdx'};
  // Plain text files — line numbers + selectable text.
  static const _textExts = {
    'txt', 'log', 'csv', 'ini', 'cfg', 'conf',
    'env', 'gitignore', 'gitattributes', 'gitmodules',
    'npmrc', 'editorconfig', 'prettierrc', 'eslintrc',
    'metadata', 'properties', 'manifest', 'lock', 'diff', 'patch', 'nfo',
    'rst', 'tex', 'bib',
  };
  // Audio files — playback with waveform + speed controls.
  static const _audioExts = {
    'mp3', 'wav', 'flac', 'ogg', 'aac', 'm4a', 'wma', 'opus',
  };

  // Video files — playback via fvp (mdk-sdk).
  static const _videoExts = {
    'mp4', 'mkv', 'webm', 'avi', 'mov', 'wmv', 'flv', 'm4v', 'mpg', 'mpeg',
    '3gp', '3g2', 'ts', 'm2ts', 'vob', 'ogv',
  };

  // Word documents — preview via native IPreviewHandler.
  static const _wordExts = {'doc', 'docx', 'docm'};

  // PowerPoint — same IPreviewHandler embed as Word.
  static const _pptExts = {'ppt', 'pptx', 'pptm'};

  // Excel — same IPreviewHandler embed.
  static const _xlsExts = {'xls', 'xlsx', 'xlsm'};

  // Archive files.
  static const _archiveExts = {
    'zip', '7z', 'rar', 'tar', 'gz', 'bz2', 'xz', 'zst', 'lz', 'lz4',
    'tgz', 'tbz2', 'txz',
  };

  // Email files.
  static const _emlExts = {'eml'};

  // EPUB e-book files.
  static const _epubExts = {'epub'};

  // Extension-less file *names* (lowercased) that are plain text.
  static const _noExtTextFiles = {
    'dockerfile', 'makefile', 'license', 'readme', 'changelog',
    'gemfile', 'rakefile', 'vagrantfile', 'procfile', 'brewfile', 'justfile',
    'jenkinsfile', 'gradlew', 'mvnw',
  };

  /// Classify a file path into one of [_PreviewType] image/text/code/markdown/folder.
  String _classify(String path) {
    // Check if it's a directory first — uses async but _classify is used
    // synchronously in _doLoad.  We check in _doLoad before calling _classify.
    final name = path.split(RegExp(r'[/\\]')).last;
    final dotIdx = name.lastIndexOf('.');
    // No dot or dot at position 0 (dotfile like .gitignore):
    // the whole name after leading dot(s) is the extension.
    if (dotIdx <= 0) {
      if (dotIdx == 0 && name.length > 1) {
        final ext = name.substring(1).toLowerCase();
        if (_textExts.contains(ext)) return 'text';
        if (_codeExts.contains(ext)) return 'code';
        if (_mdExts.contains(ext)) return 'markdown';
        if (_imageExts.contains(ext)) return 'image';
        // Unknown dotfile — treat as text (likely config file).
        return 'text';
      }
      // No dot at all — check known extension-less names.
      if (_noExtTextFiles.contains(name.toLowerCase())) return 'text';
      // Default unknown extension-less files to text.
      return 'text';
    }
    final ext = name.substring(dotIdx + 1).toLowerCase();
    if (ext.isEmpty) return 'text'; // trailing dot
    if (ext == 'pdf') return 'pdf';
    if (_wordExts.contains(ext)) return 'word';
    if (_pptExts.contains(ext)) return 'ppt';
    if (_xlsExts.contains(ext)) return 'xls';
    if (_archiveExts.contains(ext)) return 'archive';
    if (_emlExts.contains(ext)) return 'eml';
    if (_epubExts.contains(ext)) return 'epub';
    if (_audioExts.contains(ext)) return 'audio';
    if (_videoExts.contains(ext)) return 'video';
    if (_imageExts.contains(ext)) return 'image';
    if (_codeExts.contains(ext)) return 'code';
    if (_mdExts.contains(ext)) return 'markdown';
    if (_textExts.contains(ext)) return 'text';
    return 'unknown';
  }

  static const _titleBarH = 36.0;
  static const _padding = 16.0;
  static const _pollMs = 400;

  @override
  void initState() {
    super.initState();
    _topmost = widget.initialTopmost;
    _locked = false;  // Pin is never persisted
    if (_topmost) {
      windowManager.setAlwaysOnTop(true);
    }
    windowManager.addListener(this);
    _init();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  void onWindowMoved() async {
    if (_fullscreen) return;
    try {
      final r = await windowManager.getBounds();
      await QlWindowState.save(x: r.left, y: r.top, topmost: _topmost);
    } catch (_) {}
  }

  // ─── Init ───

  Future<void> _init() async {
    // Load persisted showFileSize preference.
    try {
      final st = await QlWindowState.load();
      if (mounted) _showFileSize = st.showFileSize;
    } catch (_) {}
    final rawPath = widget.filePath;
    if (!mounted) return;

    if (rawPath == null || rawPath.isEmpty) {
      _filePath = null;
      // Palette mode: command palette may be open.  Poll both.
      setState(() {
        _type = _PreviewType.error;
        _errorMsg = 'Select a file in Explorer or the command palette';
      });
      _onReady(const Size(400, 180));
      _startPolling();
      return;
    }

    // Normalize slashes and trim — the path arrives from several sources
    // (command-line parsing, JSON state file, COM Explorer) and may carry
    // forward slashes or trailing whitespace that confuse Windows APIs.
    final path = rawPath.trim().replaceAll('/', '\\');

    // NOTE: File(path).exists() can return false for valid directories on
    // Windows (Dart SDK edge case).  Use FileSystemEntity.type() instead —
    // it correctly identifies both files and directories.
    final entityType = await FileSystemEntity.type(path, followLinks: false);
    if (entityType == FileSystemEntityType.notFound) {
      _filePath = null;
      setState(() {
        _type = _PreviewType.error;
        _errorMsg = 'File not found\n\nPath: $path';
      });
      _onReady(const Size(400, 180));
      _startPolling();
      return;
    }

    _filePath = path;
    await _doLoad(path, File(path));
    _startPolling();
  }

  Future<void> _doLoad(String path, File file) async {
    // Reset image cache on reload.
    _imageBytes = null;
    setState(() { _type = _PreviewType.loading; _folderSel = false; });

    // Check for directory first (before file-based classification).
    // Note: File.exists() can return false for valid directories on Windows.
    // Use FileSystemEntity.isDirectory() directly — it's reliable.
    final isDir = await FileSystemEntity.isDirectory(path);
    if (isDir) {
      if (!mounted) return;
      setState(() => _type = _PreviewType.folder);
      final maxSize = _computeMaxSize();
      _onReady(Size(700.0.clamp(400.0, maxSize.width),
                    500.0.clamp(300.0, maxSize.height)));
      return;
    }

    final kind = _classify(path);

    if (kind == 'image') {
      try {
        final bytes = await file.readAsBytes();
        try {
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          final img = frame.image;
          if (!mounted) return;
          _imageBytes = bytes;
          setState(() => _type = _PreviewType.image);
          _onReady(_computeImageSize(img.width, img.height));
          return;
        } catch (_) {}
      } catch (_) {}
      if (!mounted) return;
      setState(() => _type = _PreviewType.fallback);
      _onReady(const Size(420, 320));
      return;
    }

    if (kind == 'code') {
      if (!mounted) return;
      setState(() => _type = _PreviewType.code);
      final maxSize = _computeMaxSize();
      _onReady(Size(800.0.clamp(400.0, maxSize.width),
                    550.0.clamp(300.0, maxSize.height)));
      return;
    }

    if (kind == 'pdf') {
      if (!mounted) return;
      setState(() => _type = _PreviewType.pdf);
      // PDF uses its own screen-centring strategy — don't call _onReady.
      return;
    }

    if (kind == 'audio') {
      if (!mounted) return;
      setState(() => _type = _PreviewType.audio);
      // Fixed window: 440×240 fits play/pause + progress bar + transport row.
      _onReady(const Size(440, 240));
      return;
    }

    if (kind == 'video') {
      if (!mounted) return;
      setState(() => _type = _PreviewType.video);
      // Don't pre-set a size — let _onVideoSizeReady be the sole source.
      // This avoids a 480×360→real jump when initialize() is async.
      return;
    }

    if (kind == 'word') {
      // Check whether a Word preview handler is registered.
      final ext = path.split('.').last.toLowerCase();
      bool available = false;
      try {
        available = await const MethodChannel('com.xmate/officepreview')
            .invokeMethod<bool>('check', {'ext': '.$ext'}) ?? false;
      } catch (_) {}
      if (!mounted) return;
      if (!available) {
        _toFallback();
        return;
      }
      setState(() => _type = _PreviewType.word);
      final maxSize = _computeMaxSize();
      _onReady(Size(900.0.clamp(400.0, maxSize.width),
                    1100.0.clamp(300.0, maxSize.height)));
      return;
    }

    if (kind == 'ppt') {
      final ext = path.split('.').last.toLowerCase();
      bool available = false;
      try {
        available = await const MethodChannel('com.xmate/officepreview')
            .invokeMethod<bool>('check', {'ext': '.$ext'}) ?? false;
      } catch (_) {}
      if (!mounted) return;
      if (!available) {
        _toFallback();
        return;
      }
      setState(() => _type = _PreviewType.ppt);
      final maxSize = _computeMaxSize();
      _onReady(Size(960.0.clamp(400.0, maxSize.width),
                    640.0.clamp(300.0, maxSize.height)));
      return;
    }

    if (kind == 'xls') {
      final ext = path.split('.').last.toLowerCase();
      bool available = false;
      try {
        available = await const MethodChannel('com.xmate/officepreview')
            .invokeMethod<bool>('check', {'ext': '.$ext'}) ?? false;
      } catch (_) {}
      if (!mounted) return;
      if (!available) {
        _toFallback();
        return;
      }
      setState(() => _type = _PreviewType.xls);
      final maxSize = _computeMaxSize();
      _onReady(Size(960.0.clamp(400.0, maxSize.width),
                    720.0.clamp(300.0, maxSize.height)));
      return;
    }

    if (kind == 'archive') {
      if (!mounted) return;
      setState(() => _type = _PreviewType.archive);
      final maxSize = _computeMaxSize();
      _onReady(Size(700.0.clamp(400.0, maxSize.width),
                    500.0.clamp(300.0, maxSize.height)));
      return;
    }

    if (kind == 'eml') {
      if (!mounted) return;
      setState(() => _type = _PreviewType.eml);
      final maxSize = _computeMaxSize();
      _onReady(Size(700.0.clamp(400.0, maxSize.width),
                    550.0.clamp(300.0, maxSize.height)));
      return;
    }

    if (kind == 'epub') {
      if (!mounted) return;
      setState(() => _type = _PreviewType.epub);
      final maxSize = _computeMaxSize();
      _onReady(Size(800.0.clamp(400.0, maxSize.width),
                    600.0.clamp(300.0, maxSize.height)));
      return;
    }

    if (kind == 'markdown') {
      if (!mounted) return;
      setState(() => _type = _PreviewType.markdown);
      final maxSize = _computeMaxSize();
      _onReady(Size(800.0.clamp(400.0, maxSize.width),
                    550.0.clamp(300.0, maxSize.height)));
      return;
    }

    if (kind == 'text') {
      if (!mounted) return;
      setState(() => _type = _PreviewType.text);
      final maxSize = _computeMaxSize();
      _onReady(Size(700.0.clamp(400.0, maxSize.width),
                    500.0.clamp(300.0, maxSize.height)));
      return;
    }

    if (!mounted) return;
    // Safety net: some directories with dotted names (e.g. "my.project")
    // fall through _classify → 'unknown'.  The async isDir check at the
    // top should catch most, but check again synchronously.
    try {
      if (file.statSync().type == FileSystemEntityType.directory) {
        if (!mounted) return;
        setState(() => _type = _PreviewType.folder);
        final maxSize = _computeMaxSize();
        _onReady(Size(700.0.clamp(400.0, maxSize.width),
                      500.0.clamp(300.0, maxSize.height)));
        return;
      }
    } catch (_) {}
    setState(() => _type = _PreviewType.fallback);
    final maxSize = _computeMaxSize();
    _onReady(Size(420.0.clamp(400.0, maxSize.width),
                  320.0.clamp(300.0, maxSize.height)));
  }

  void _onReady(Size size) {
    // When hex mode is active, _doLoad-triggered resizes must not override
    // the hex view's own window size.  _toggleHex calls widget.onReady directly.
    if (_hexMode) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onReady(size);
    });
  }

  /// Resize window to fit the video at its natural size.
  /// Called once from VideoView._init() after initialize().
  Future<void> _onVideoSizeReady(Size naturalSize) async {
    if (!mounted) return;
    const barH = 130.0;
    final display = ui.PlatformDispatcher.instance.displays.first;
    final sw = display.size.width / display.devicePixelRatio;
    final sh = display.size.height / display.devicePixelRatio;
    final margin = 0.01;

    final maxW = sw * (1 - margin * 2);
    final maxH = sh * (1 - margin * 2);
    double w = naturalSize.width.clamp(200.0, maxW);
    double h = w / naturalSize.width * naturalSize.height + barH;
    if (h > maxH) {
      h = maxH;
      w = (h - barH) * naturalSize.width / naturalSize.height;
    }
    w = w.clamp(200.0, maxW);
    h = h.clamp(200.0, maxH);

    _onReady(Size(w, h));
  }

  /// Max window size: ~1/4 screen area (half width × half height).
  Size _computeMaxSize() {
    final display = ui.PlatformDispatcher.instance.displays.first;
    final screenW = display.size.width / display.devicePixelRatio;
    final screenH = display.size.height / display.devicePixelRatio;
    return Size(screenW * 0.5, screenH * 0.5);
  }

  Size _computeImageSize(int imgW, int imgH) {
    final maxSize = _computeMaxSize();
    const minW = 400.0, minH = 300.0;
    final maxW = maxSize.width;
    final maxH = maxSize.height;

    double w = imgW.toDouble().clamp(minW, maxW);
    double h = imgH * (w / imgW);
    if (h > maxH) { h = maxH; w = imgW * (h / imgH); }
    w = w.clamp(minW, maxW);
    h = h.clamp(minH, maxH);

    return Size(w + _padding * 2, h + _titleBarH + _padding * 2);
  }

  // ─── Polling: follow Explorer selection ───

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: _pollMs), (_) {
      _pollSelection();
    });
  }

  /// Poll for file selection changes.  Priority order:
  /// 1. Palette state file (command palette file navigation)
  /// 2. Explorer COM selection (CabinetWClass / ExploreWClass)
  /// 3. Desktop selection (Progman / WorkerW)
  Future<void> _pollSelection() async {
    // Don't follow new selections when the file is locked (pinned).
    if (_locked || _editingLocked || !mounted) return;

    // 1-2. Unified selection query (palette state → Explorer COM).
    String? newPath = await getSelectedFilePath();

    if (!mounted) return;

    // No file selected — keep showing the last file.
    if (newPath == null || newPath.isEmpty) return;

    // Normalise BEFORE comparison: COM returns forward slashes but
    // _filePath is stored with backslashes.  Without normalisation the
    // comparison always fails → _doLoad every 400 ms → large-image flicker.
    newPath = newPath.trim().replaceAll('/', '\\');

    // Same file — nothing to do.
    if (newPath == _filePath) return;

    _filePath = newPath;
    if ((await FileSystemEntity.type(newPath, followLinks: false)) ==
        FileSystemEntityType.notFound) {
      if (!mounted) return;
      setState(() {
        _type = _PreviewType.error;
        _errorMsg = 'File not found';
      });
      _onReady(const Size(400, 180));
      return;
    }

    if (!mounted) return;
    await _doLoad(newPath, File(newPath));
  }

  // ─── Actions ───

  Future<void> _openFile() async {
    if (_filePath == null) return;
    try {
      await Process.run('cmd', ['/c', 'start', '', _filePath!.replaceAll('/', '\\')]);
    } catch (_) {}
    widget.onClose();
  }

  /// Enter / double-click from folder view → open file or reload folder.
  Future<void> _openFolderItem(String path) async {
    // Normalize — path from folder view entries uses forward slashes.
    final norm = path.trim().replaceAll('/', '\\');
    final entityType = await FileSystemEntity.type(norm, followLinks: false);
    if (entityType == FileSystemEntityType.notFound) return;
    final isDir = entityType == FileSystemEntityType.directory;
    if (isDir) {
      // Reload this page with the subfolder path.
      _filePath = norm;
      _doLoad(norm, File(norm));
    } else {
      // Open file in default handler.
      try {
        await Process.run('cmd', ['/c', 'start', '', norm]);
      } catch (_) {}
      widget.onClose();
    }
  }

  void _onEnter() {
    // PDF, audio and video views handle their own keyboard; don't open externally.
    if (_type == _PreviewType.pdf || _type == _PreviewType.audio || _type == _PreviewType.video) return;
    // Folder view with selection → let the folder view handle it
    if (_type == _PreviewType.folder && _folderSel) return;
    _openFile();
  }

  Future<void> _toggleTopmost() async {
    _topmost = !_topmost;
    await windowManager.setAlwaysOnTop(_topmost);
    try {
      final r = await windowManager.getBounds();
      await QlWindowState.save(x: r.left, y: r.top, topmost: _topmost);
    } catch (_) {}
    setState(() {});
  }

  Future<void> _toggleLocked() async {
    _locked = !_locked;
    _stopPolling();
    // Update HWND title so C++ can distinguish pinned/unpinned.
    try {
      await const MethodChannel('com.xmate/quicklook')
          .invokeMethod('setPinned', {'pinned': _locked});
    } catch (_) {}
    if (_locked) {
      // Locked: stop following file changes.
    } else {
      _startPolling();
      _pollSelection();
    }
    setState(() {});
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _toggleShowFileSize() async {
    _showFileSize = !_showFileSize;
    await QlWindowState.save(showFileSize: _showFileSize);
    setState(() {});
  }

  Future<void> _toggleFullscreen() async {
    _fullscreen = !_fullscreen;
    if (_fullscreen) {
      final rect = await windowManager.getBounds();
      _preFullscreenRect = rect;
      final display = ui.PlatformDispatcher.instance.displays.first;
      final screenSize = display.size / display.devicePixelRatio;
      await windowManager.setPosition(const Offset(0, 0));
      await windowManager.setSize(screenSize);
    } else {
      if (_preFullscreenRect != null) {
        await windowManager.setPosition(
          Offset(_preFullscreenRect!.left, _preFullscreenRect!.top));
        await windowManager.setSize(
          Size(_preFullscreenRect!.width, _preFullscreenRect!.height));
      }
    }
    setState(() {});
  }

  Future<void> _openWith() async {
    if (_filePath == null) return;
    try {
      await const MethodChannel('com.xmate/fileops').invokeMethod(
        'openWithDialog',
        {'path': _filePath},
      );
    } catch (_) {}
  }

  void _toggleHex() {
    setState(() => _hexMode = !_hexMode);
    if (_hexMode) {
      // Enter hex view → resize to a hex-appropriate window.
      final maxSize = _computeMaxSize();
      // Bypass _onReady because it guards against hex mode (to prevent
      // _doLoad-triggered resizes from overriding the hex view size).
      widget.onReady(Size(700.0.clamp(400.0, maxSize.width),
                         550.0.clamp(300.0, maxSize.height)));
    } else {
      // Exit hex view → re-run _doLoad to restore the original view's window size.
      if (_filePath != null) {
        _doLoad(_filePath!, File(_filePath!));
      }
    }
  }

  /// Called by QuickLookOfficeView when preview is unavailable or
  /// creating the native preview handler failed.  Falls back to the generic
  /// file info view.
  void _toFallback() {
    if (!mounted) return;
    setState(() => _type = _PreviewType.fallback);
    final maxSize = _computeMaxSize();
    _onReady(Size(420.0.clamp(400.0, maxSize.width),
                  320.0.clamp(300.0, maxSize.height)));
  }

  // ─── UI ───

  String get _fileName {
    if (_filePath == null) return 'QuickLook';
    return _filePath!.split(RegExp(r'[/\\]')).last;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Focus without autofocus — keyboard shortcuts (ESC/Enter) work only
    // when the user clicks into the window. Explorer keeps focus by default.
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        // Only handle Enter at the page level if no deeper Focus consumed it.
        // The folder view's inner Focus handles its own Enter.
        if (event.logicalKey == LogicalKeyboardKey.enter) {
          _onEnter();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
        },
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: XMateColors.panelBg(context),
              borderRadius: const BorderRadius.all(Radius.circular(16)),
              border: Border.all(color: cs.primary.withAlpha(60), width: 1.5),
            ),
            child: Column(
              children: [
                _titleBar(),
                Expanded(child: _buildContent()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _titleBar() {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: _titleBarH,
        decoration: BoxDecoration(
          color: XMateColors.panelBg(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Row(
          children: [
            const SizedBox(width: 14),
            Icon(Icons.preview, size: 16, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'QuickLook - $_fileName',
                style: TextStyle(fontSize: 13, color: cs.onSurface, fontWeight: FontWeight.normal),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _titleBtn(Icons.vertical_align_top, _toggleTopmost, active: _topmost, tooltip: '置顶'),
            _titleBtn(Icons.push_pin, _toggleLocked, active: _locked, tooltip: '固定文件'),
            _titleBtn(Icons.fullscreen, _toggleFullscreen, tooltip: 'Fullscreen'),
            _titleBtn(Icons.grid_on, _toggleHex, active: _hexMode, tooltip: 'Hex view'),
            _titleBtn(Icons.open_in_new, _openWith, tooltip: 'Open with'),
            if (_type == _PreviewType.word || _type == _PreviewType.ppt || _type == _PreviewType.xls)
              _titleBtn(Icons.exit_to_app, _openFile, tooltip: 'Open (Enter)'),
            _titleBtn(Icons.close, widget.onClose, tooltip: 'Close'),
          ],
        ),
      ),
    );
  }

  Widget _titleBtn(IconData icon, VoidCallback onTap, {bool active = false, String? tooltip}) {
    return Tooltip(
      message: tooltip ?? '',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34, height: _titleBarH, alignment: Alignment.center,
          child: Icon(icon, size: 15, color: active ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurface.withAlpha(138)),
        ),
      ),
    );
  }

  Widget _buildContent() {
    final cs = Theme.of(context).colorScheme;
    if (_hexMode) {
      return QuickLookHexView(filePath: _filePath!);
    }
    switch (_type) {
      case _PreviewType.loading:
        return Center(
          child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
        );
      case _PreviewType.image:
        return QuickLookImageAnnotator(filePath: _filePath!, cachedBytes: _imageBytes,
          onEditingChanged: (editing) { _editingLocked = editing; });
      case _PreviewType.text:
        return QuickLookRichView(filePath: _filePath!, mode: RichViewMode.text);
      case _PreviewType.code:
        return QuickLookRichView(filePath: _filePath!, mode: RichViewMode.code);
      case _PreviewType.markdown:
        return QuickLookRichView(filePath: _filePath!, mode: RichViewMode.markdown);
      case _PreviewType.fallback:
        return QuickLookFallbackView(filePath: _filePath!);
      case _PreviewType.pdf:
        return QuickLookPdfView(filePath: _filePath!, onClose: widget.onClose);
      case _PreviewType.audio:
        return QuickLookAudioView(filePath: _filePath!, onOpenFile: _openFile);
      case _PreviewType.video:
        return QuickLookVideoView(
          filePath: _filePath!,
          onOpenFile: _openFile,
          onVideoSizeReady: _onVideoSizeReady,
        );
      case _PreviewType.word:
      case _PreviewType.ppt:
      case _PreviewType.xls:
        return QuickLookOfficeView(
          filePath: _filePath!,
          onFallback: _toFallback,
        );
      case _PreviewType.archive:
        return QuickLookArchiveView(filePath: _filePath!);
      case _PreviewType.eml:
        return QuickLookEmlView(filePath: _filePath!);
      case _PreviewType.epub:
        return QuickLookEpubView(filePath: _filePath!);
      case _PreviewType.folder:
        return QuickLookFolderView(
          folderPath: _filePath!,
          onOpenItem: (path) => _openFolderItem(path),
          onSelectionChanged: (hasSel) {
            if (_folderSel != hasSel) setState(() => _folderSel = hasSel);
          },
          showFileSize: _showFileSize,
          onToggleShowFileSize: _toggleShowFileSize,
        );
      case _PreviewType.error:
        return Center(
          child: Text(_errorMsg ?? 'Error',
              style: TextStyle(fontSize: 15, color: cs.onSurface.withAlpha(138))),
        );
    }
  }
}
