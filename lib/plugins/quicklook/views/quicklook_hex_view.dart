import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/quicklook/quicklook_utils.dart';
import '../../../../core/theme/theme_colors.dart';

// ─── Magic bytes detection ──────────────────────────────────────────────────

class _MagicEntry {
  final List<int> bytes;
  final String label;
  const _MagicEntry(this.bytes, this.label);
}

/// Returns (label, first16Bytes) for display.
(List<String>?, List<int>) _detectMagic(Uint8List head) {
  for (final e in _kMagicSignatures) {
    if (e.bytes.length > head.length) continue;
    bool match = true;
    for (int i = 0; i < e.bytes.length; i++) {
      if (head[i] != e.bytes[i]) {
        match = false;
        break;
      }
    }
    if (match) return ([e.label], List.generate(min(16, head.length), (i) => head[i]));
  }
  return (null, List.generate(min(16, head.length), (i) => head[i]));
}

const _kMagicSignatures = [
  _MagicEntry([0x4D, 0x5A], 'PE / PE32+ executable'),
  _MagicEntry([0x7F, 0x45, 0x4C, 0x46], 'ELF executable'),
  _MagicEntry([0xFE, 0xED, 0xFA, 0xCE], 'Mach-O 32-bit'),
  _MagicEntry([0xFE, 0xED, 0xFA, 0xCF], 'Mach-O 64-bit'),
  _MagicEntry([0xCE, 0xFA, 0xED, 0xFE], 'Mach-O 32-bit (LE)'),
  _MagicEntry([0xCF, 0xFA, 0xED, 0xFE], 'Mach-O 64-bit (LE)'),
  _MagicEntry([0xCA, 0xFE, 0xBA, 0xBE], 'Java class file'),
  _MagicEntry([0x50, 0x4B, 0x03, 0x04], 'ZIP / JAR / APK / Office Open XML'),
  _MagicEntry([0x50, 0x4B, 0x05, 0x06], 'ZIP (empty)'),
  _MagicEntry([0x50, 0x4B, 0x07, 0x08], 'ZIP (spanned)'),
  _MagicEntry([0x1F, 0x8B], 'GZIP'),
  _MagicEntry([0x42, 0x5A, 0x68], 'BZip2'),
  _MagicEntry([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], '7-Zip'),
  _MagicEntry([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07], 'RAR v1.5+'),
  _MagicEntry([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00], 'RAR v5'),
  _MagicEntry([0x25, 0x50, 0x44, 0x46], 'PDF document'),
  _MagicEntry([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], 'PNG image'),
  _MagicEntry([0xFF, 0xD8, 0xFF], 'JPEG image'),
  _MagicEntry([0x47, 0x49, 0x46, 0x38], 'GIF image'),
  _MagicEntry([0x42, 0x4D], 'BMP image'),
  _MagicEntry([0x49, 0x49, 0x2A, 0x00], 'TIFF (LE)'),
  _MagicEntry([0x4D, 0x4D, 0x00, 0x2A], 'TIFF (BE)'),
  _MagicEntry([0x52, 0x49, 0x46, 0x46], 'RIFF container (WAV/AVI)'),
  _MagicEntry([0x00, 0x00, 0x01, 0xBA], 'MPEG-PS'),
  _MagicEntry([0x00, 0x00, 0x01, 0xB3], 'MPEG video'),
  _MagicEntry([0x49, 0x44, 0x33], 'MP3 (ID3 tag)'),
  _MagicEntry([0x4F, 0x67, 0x67, 0x53], 'Ogg container'),
  _MagicEntry([0x66, 0x4C, 0x61, 0x43], 'FLAC audio'),
  _MagicEntry([0x53, 0x51, 0x4C, 0x69, 0x74, 0x65], 'SQLite database'),
  _MagicEntry([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1], 'MS Office OLE2 (doc/xls/ppt)'),
  _MagicEntry([0x00, 0x01, 0x00, 0x00], 'TrueType font'),
  _MagicEntry([0x4F, 0x54, 0x54, 0x4F], 'OpenType font (OTTO)'),
  _MagicEntry([0x77, 0x4F, 0x46, 0x46], 'WOFF font'),
  _MagicEntry([0x77, 0x4F, 0x46, 0x32], 'WOFF2 font'),
  _MagicEntry([0x3C, 0x3F, 0x78, 0x6D, 0x6C], 'XML document'),
  _MagicEntry([0x3C, 0x21, 0x44, 0x4F, 0x43, 0x54, 0x59, 0x50, 0x45], 'HTML document'),
  _MagicEntry([0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A], 'KTX11 texture'),
];

// ─── Color helpers (replaced with theme-aware equivalents at call sites) ─────

// ─── Hex view widget ────────────────────────────────────────────────────────

class QuickLookHexView extends StatefulWidget {
  final String filePath;
  const QuickLookHexView({super.key, required this.filePath});

  @override
  State<QuickLookHexView> createState() => _QuickLookHexViewState();
}

class _QuickLookHexViewState extends State<QuickLookHexView> {
  RandomAccessFile? _raf;
  int _fileSize = 0;
  String? _errorMsg;

  // ── Chunk cache ────────────────────────────────────────────────────
  static const _bytesPerRow = 16;
  static const _rowHeight = 18.0;
  static const _chunkSize = 64 * 1024; // 64 KB
  int _chunkAlign(int offset) => offset ~/ _chunkSize * _chunkSize;

  final Map<int, Uint8List> _chunkCache = {};

  // ── Scroll ─────────────────────────────────────────────────────────
  final ScrollController _scrollCtrl = ScrollController();
  int _firstVisibleRow = 0;
  int _totalRows = 0;

  // ── Selection ──────────────────────────────────────────────────────
  int? _selOffset;

  // ── Search ─────────────────────────────────────────────────────────
  bool _showSearch = false;
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  bool _searchHex = true; // true=hex bytes, false=ASCII string
  List<int> _matches = []; // byte offsets of match starts
  int _curMatchIdx = -1;
  String? _searchError;

  // ── Magic bytes ────────────────────────────────────────────────────
  List<String>? _magicLabels;
  List<int> _magicHeadBytes = [];

  // ── Monospace font ─────────────────────────────────────────────────
  static const _monoFamily = 'Consolas';
  static const _monoSize = 13.0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(covariant QuickLookHexView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filePath != oldWidget.filePath) {
      _close();
      _open();
    }
  }

  @override
  void dispose() {
    _close();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ── File lifecycle ─────────────────────────────────────────────────────

  Future<void> _open() async {
    try {
      final file = File(widget.filePath);
      _fileSize = await file.length();
      if (_fileSize == 0) {
        if (!mounted) return;
        setState(() => _errorMsg = 'Empty file');
        return;
      }
      _raf = await file.open(mode: FileMode.read);
      _totalRows = (_fileSize + _bytesPerRow - 1) ~/ _bytesPerRow;

      // Read first chunk for magic bytes detection
      final head = await _readChunk(0);
      if (head != null) {
        final (labels, first16) = _detectMagic(head);
        _magicLabels = labels;
        _magicHeadBytes = first16;
      }

      if (!mounted) return;
      setState(() {}); // update UI
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMsg = 'Cannot open file: $e');
    }
  }

  void _close() {
    try { _raf?.closeSync(); } catch (_) {}
    _raf = null;
    _chunkCache.clear();
    _fileSize = 0;
    _totalRows = 0;
    _matches = [];
    _curMatchIdx = -1;
    _selOffset = null;
    _magicLabels = null;
    _magicHeadBytes = [];
    _errorMsg = null;
  }

  // ── Chunked file reading ────────────────────────────────────────────────

  Future<Uint8List?> _readChunk(int offset) async {
    if (_raf == null) return null;
    final aligned = _chunkAlign(offset);
    if (_chunkCache.containsKey(aligned)) return _chunkCache[aligned];
    try {
      await _raf!.setPosition(aligned);
      final size = min(_chunkSize, _fileSize - aligned);
      final buf = Uint8List(size);
      int total = 0;
      while (total < size) {
        final n = await _raf!.readInto(buf, total);
        if (n == 0) break; // EOF
        total += n;
      }
      if (total < size) {
        // Partial read — treat as error or truncate
      }
      _chunkCache[aligned] = buf;
      return buf;
    } catch (_) {
      return null;
    }
  }

  /// Get bytes at [offset] for [len] bytes. Returns empty list on failure.
  Uint8List _getBytes(int offset, int len) {
    if (offset >= _fileSize) return Uint8List(0);
    final actualLen = min(len, _fileSize - offset);
    final aligned = _chunkAlign(offset);
    final cached = _chunkCache[aligned];
    if (cached != null) {
      final start = offset - aligned;
      final end = min(start + actualLen, cached.length);
      if (start >= cached.length) return Uint8List(0);
      return Uint8List.sublistView(cached, start, end);
    }
    // Schedule a load for next frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _readChunk(offset).then((_) {
        if (mounted) setState(() {});
      });
    });
    return Uint8List(0);
  }

  // ── Scroll handling ─────────────────────────────────────────────────────

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.offset;
    final newFirst = (pos / _rowHeight).floor();
    if (newFirst != _firstVisibleRow) {
      _firstVisibleRow = newFirst;
      // Prefetch nearby chunks
      _prefetchVisible();
    }
  }

  void _prefetchVisible() {
    if (_raf == null) return;
    final visibleStart = _firstVisibleRow * _bytesPerRow;
    final visibleEnd = visibleStart + _bytesPerRow * 40; // ~40 rows visible
    // Load chunks covering the visible range (limit concurrent reads)
    for (int off = _chunkAlign(visibleStart);
         off <= _chunkAlign(visibleEnd);
         off += _chunkSize) {
      if (!_chunkCache.containsKey(off)) {
        _readChunk(off); // fire-and-forget
      }
    }
  }

  void _scrollToOffset(int offset) {
    final row = offset ~/ _bytesPerRow;
    final targetPx = row * _rowHeight;
    final viewportH = _scrollCtrl.hasClients
        ? _scrollCtrl.position.viewportDimension
        : 400.0;
    // Center the row in the viewport
    final scrollTo = max(0.0, targetPx - viewportH / 2 + _rowHeight / 2);
    _scrollCtrl.jumpTo(scrollTo);
    setState(() => _selOffset = offset);
  }

  void _gotoOffset(TextEditingController ctrl) {
    // Try hex first
    String text = ctrl.text.trim();
    if (text.isEmpty) return;
    text = text.replaceAll('0x', '').replaceAll('0X', '');
    final off = int.tryParse(text, radix: 16) ?? int.tryParse(text, radix: 10);
    if (off == null) return;
    final clamped = off.clamp(0, _fileSize - 1);
    _scrollToOffset(clamped);
  }

  // ── Search ───────────────────────────────────────────────────────────────

  void _toggleSearch() {
    setState(() {
      _showSearch = !_showSearch;
      if (_showSearch) {
        _searchFocus.requestFocus();
      } else {
        _searchFocus.unfocus();
        _matches = [];
        _curMatchIdx = -1;
        _searchError = null;
      }
    });
  }

  void _doSearch(String query) {
    setState(() {
      _matches = [];
      _curMatchIdx = -1;
      _searchError = null;
    });
    if (query.isEmpty) return;

    List<int> target;
    if (_searchHex) {
      // Parse hex bytes: allow "4D5A", "4D 5A", "4d 5a", etc.
      final cleaned = query.replaceAll(RegExp(r'\s+'), '');
      if (cleaned.length % 2 != 0) {
        setState(() => _searchError = 'Hex string must have even length');
        return;
      }
      target = [];
      for (int i = 0; i < cleaned.length; i += 2) {
        final b = int.tryParse(cleaned.substring(i, i + 2), radix: 16);
        if (b == null || b < 0 || b > 255) {
          setState(() => _searchError = 'Invalid hex byte: ${cleaned.substring(i, i + 2)}');
          return;
        }
        target.add(b);
      }
    } else {
      target = utf8.encode(query);
    }
    if (target.isEmpty) return;

    // Search through file in chunks
    _searchFile(target).then((matches) {
      if (!mounted) return;
      setState(() {
        _matches = matches;
        if (matches.isNotEmpty) {
          _curMatchIdx = 0;
          _scrollToOffset(matches[0]);
        }
        if (matches.isEmpty) {
          _searchError = 'Not found';
        }
      });
    });
  }

  Future<List<int>> _searchFile(List<int> pattern) async {
    if (_raf == null) return [];
    final matches = <int>[];
    const bufSize = 256 * 1024; // 256KB search buffer
    final overlap = pattern.length - 1; // overlap to catch cross-chunk matches
    int filePos = 0;
    Uint8List? prev;

    while (filePos < _fileSize) {
      await _raf!.setPosition(filePos);
      final readSize = min(bufSize, _fileSize - filePos);
      final buf = Uint8List(readSize);
      int total = 0;
      while (total < readSize) {
        final n = await _raf!.readInto(buf, total);
        if (n == 0) break;
        total += n;
      }
      if (total == 0) break;

      // Search in this chunk
      if (prev != null && filePos > 0) {
        // Check cross-chunk boundary: prev tail + buf head
        for (int k = 1; k <= overlap && k <= total; k++) {
          bool match = true;
          for (int j = 0; j < pattern.length; j++) {
            int b;
            if (j < k) {
              b = prev[prev.length - k + j];
            } else {
              final idx = j - k;
              if (idx >= total) { match = false; break; }
              b = buf[idx];
            }
            if (b != pattern[j]) { match = false; break; }
          }
          if (match) {
            matches.add(filePos - k);
          }
        }
      }

      // Standard search within buffer
      for (int i = 0; i <= total - pattern.length; i++) {
        bool match = true;
        for (int j = 0; j < pattern.length; j++) {
          if (buf[i + j] != pattern[j]) { match = false; break; }
        }
        if (match) {
          matches.add(filePos + i);
        }
      }

      filePos += total;
      prev = buf;
    }
    return matches;
  }

  void _nextMatch() {
    if (_matches.isEmpty) return;
    setState(() => _curMatchIdx = (_curMatchIdx + 1) % _matches.length);
    _scrollToOffset(_matches[_curMatchIdx]);
  }

  void _prevMatch() {
    if (_matches.isEmpty) return;
    setState(() => _curMatchIdx = (_curMatchIdx - 1 + _matches.length) % _matches.length);
    _scrollToOffset(_matches[_curMatchIdx]);
  }

  // ── Row rendering ────────────────────────────────────────────────────────

  Widget _buildRow(BuildContext context, int index) {
    final cs = Theme.of(context).colorScheme;
    final offset = index * _bytesPerRow;
    final bytes = _getBytes(offset, _bytesPerRow);

    // Determine background
    Color? bg;
    if (_selOffset != null &&
        offset <= _selOffset! &&
        _selOffset! < offset + _bytesPerRow) {
      bg = cs.primary.withAlpha(48);
    }

    // Check for search match highlights
    final matchRanges = <_Range>[];
    for (final m in _matches) {
      final mStart = m;
      final patLen = _searchHex
          ? _searchCtrl.text.replaceAll(RegExp(r'\s+'), '').length ~/ 2
          : utf8.encode(_searchCtrl.text).length;
      final mEnd = m + patLen;
      final isectStart = max(mStart, offset);
      final isectEnd = min(mEnd, offset + _bytesPerRow);
      if (isectStart < isectEnd) {
        matchRanges.add(_Range(isectStart - offset, isectEnd - offset));
      }
    }

    final currMatchRange = (_curMatchIdx >= 0 && _curMatchIdx < _matches.length)
        ? (){
            final mStart = _matches[_curMatchIdx];
            final patLen = _searchHex
                ? _searchCtrl.text.replaceAll(RegExp(r'\s+'), '').length ~/ 2
                : utf8.encode(_searchCtrl.text).length;
            final mEnd = mStart + patLen;
            final isectStart = max(mStart, offset);
            final isectEnd = min(mEnd, offset + _bytesPerRow);
            if (isectStart < isectEnd) {
              return _Range(isectStart - offset, isectEnd - offset);
            }
            return null;
          }()
        : null;

    return Container(
      height: _rowHeight,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              offset.toRadixString(16).padLeft(8, '0').toUpperCase(),
              style: TextStyle(
                fontFamily: _monoFamily,
                fontSize: _monoSize,
                color: cs.onSurface.withAlpha(179),
                height: 1.0,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _buildHexRow(bytes, offset, matchRanges, currMatchRange, cs),
          const SizedBox(width: 8),
          _buildAsciiRow(bytes, offset, matchRanges, currMatchRange, cs),
        ],
      ),
    );
  }

  Widget _buildHexRow(Uint8List bytes, int baseOffset,
      List<_Range> matchRanges, _Range? currMatch, ColorScheme cs) {
    final spans = <InlineSpan>[];
    for (int i = 0; i < _bytesPerRow; i++) {
      if (i == 8) {
        spans.add(TextSpan(text: ' ', style: TextStyle(fontFamily: _monoFamily, fontSize: _monoSize)));
      }
      if (i < bytes.length) {
        final hex = bytes[i].toRadixString(16).padLeft(2, '0').toUpperCase();
        Color color = cs.onSurface;
        bool isCurrMatch = currMatch != null && i >= currMatch.start && i < currMatch.end;
        bool isAnyMatch = matchRanges.any((r) => i >= r.start && i < r.end);
        if (isCurrMatch) {
          color = const Color(0xFFFFD54F);
        } else if (isAnyMatch) {
          color = const Color(0xFF90CAF9);
        }
        spans.add(TextSpan(
          text: '$hex ',
          style: TextStyle(fontFamily: _monoFamily, fontSize: _monoSize, color: color, height: 1.0),
        ));
      } else {
        spans.add(TextSpan(
          text: '   ',
          style: TextStyle(fontFamily: _monoFamily, fontSize: _monoSize, color: cs.onSurface),
        ));
      }
    }
    return RichText(
      text: TextSpan(children: spans),
      maxLines: 1,
    );
  }

  Widget _buildAsciiRow(Uint8List bytes, int baseOffset,
      List<_Range> matchRanges, _Range? currMatch, ColorScheme cs) {
    final spans = <InlineSpan>[];
    for (int i = 0; i < _bytesPerRow; i++) {
      if (i < bytes.length) {
        final b = bytes[i];
        final ch = (b >= 0x20 && b < 0x7F) ? String.fromCharCode(b) : '.';
        Color color = cs.onSurface.withAlpha(138);
        bool isCurrMatch = currMatch != null && i >= currMatch.start && i < currMatch.end;
        bool isAnyMatch = matchRanges.any((r) => i >= r.start && i < r.end);
        if (isCurrMatch) {
          color = const Color(0xFFFFD54F);
        } else if (isAnyMatch) {
          color = const Color(0xFF90CAF9);
        }
        spans.add(TextSpan(
          text: ch,
          style: TextStyle(fontFamily: _monoFamily, fontSize: _monoSize, color: color, height: 1.0),
        ));
      } else {
        spans.add(TextSpan(
          text: ' ',
          style: TextStyle(fontFamily: _monoFamily, fontSize: _monoSize, color: cs.onSurface.withAlpha(138)),
        ));
      }
    }
    return RichText(
      text: TextSpan(children: spans),
      maxLines: 1,
    );
  }

  // ── Header bar (column labels) ───────────────────────────────────────────

  Widget _buildColHeader(ColorScheme cs) {
    final headerSpans = <InlineSpan>[];
    for (int i = 0; i < _bytesPerRow; i++) {
      if (i == 8) {
        headerSpans.add(TextSpan(
          text: ' ',
          style: TextStyle(fontFamily: _monoFamily, fontSize: _monoSize, color: cs.primary),
        ));
      }
      final hex = i.toRadixString(16).padLeft(2, '0').toUpperCase();
      headerSpans.add(TextSpan(
        text: '$hex ',
        style: TextStyle(fontFamily: _monoFamily, fontSize: _monoSize, color: cs.primary, height: 1.0),
      ));
    }
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: cs.primary.withAlpha(26),
      child: Row(
        children: [
          SizedBox(width: 72, child: Text('Offset',
              style: TextStyle(fontFamily: _monoFamily, fontSize: _monoSize, color: cs.primary, height: 1.0))),
          const SizedBox(width: 8),
          RichText(text: TextSpan(children: headerSpans), maxLines: 1),
          const SizedBox(width: 8),
          Text('ASCII',
              style: TextStyle(fontFamily: _monoFamily, fontSize: _monoSize, color: cs.primary, height: 1.0)),
        ],
      ),
    );
  }

  // ── Magic / info bar ─────────────────────────────────────────────────────

  Widget _buildMagicBar(ColorScheme cs) {
    if (_magicLabels != null && _magicLabels!.isNotEmpty) {
      return Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: cs.primary.withAlpha(26),
        child: Row(
          children: [
            Icon(Icons.auto_awesome, size: 13, color: cs.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _magicLabels!.join('  |  '),
                style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(179)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              _magicHeadBytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' '),
              style: TextStyle(fontFamily: _monoFamily, fontSize: 11, color: cs.onSurface.withAlpha(97)),
            ),
          ],
        ),
      );
    }
    if (_magicHeadBytes.isNotEmpty) {
      return Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: cs.primary.withAlpha(26),
        child: Row(
          children: [
            Icon(Icons.help_outline, size: 13, color: cs.onSurface.withAlpha(97)),
            const SizedBox(width: 6),
            Text('Unknown signature', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(138))),
            const Spacer(),
            Text(
              _magicHeadBytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' '),
              style: TextStyle(fontFamily: _monoFamily, fontSize: 11, color: cs.onSurface.withAlpha(97)),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  // ── Status bar ───────────────────────────────────────────────────────────

  Widget _buildStatusBar(ColorScheme cs) {
    final sizeStr = fileSizeStr(_fileSize);
    String selStr = '';
    if (_selOffset != null) {
      selStr = '  |  Offset: 0x${_selOffset!.toRadixString(16).toUpperCase()}';
    }
    String matchStr = '';
    if (_matches.isNotEmpty) {
      matchStr = '  |  Match ${_curMatchIdx + 1}/${_matches.length}';
    }
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: cs.primary.withAlpha(26),
      child: Row(
        children: [
          Text(sizeStr, style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(138))),
          Text(selStr, style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(179))),
          Text(matchStr, style: TextStyle(fontSize: 11, color: cs.primary)),
          const Spacer(),
          Text('Ctrl+F Search  |  Ctrl+G Goto',
              style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(77))),
        ],
      ),
    );
  }

  // ── Search bar ───────────────────────────────────────────────────────────

  Widget _buildSearchBar(ColorScheme cs) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: XMateColors.toolbarBg(context),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              setState(() => _searchHex = !_searchHex);
              _doSearch(_searchCtrl.text);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: cs.onSurface.withAlpha(26),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                _searchHex ? 'HEX' : 'ASC',
                style: TextStyle(fontSize: 10, color: cs.primary, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              focusNode: _searchFocus,
              controller: _searchCtrl,
              style: TextStyle(fontSize: 13, color: cs.onSurface, fontFamily: _monoFamily),
              cursorColor: cs.primary,
              decoration: InputDecoration(
                hintText: _searchHex ? 'Hex bytes (e.g. 4D 5A)' : 'ASCII string',
                hintStyle: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(97)),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                suffixIcon: _searchError != null
                    ? Text(_searchError!, style: const TextStyle(fontSize: 10, color: Colors.redAccent))
                    : null,
              ),
              onChanged: _doSearch,
              onSubmitted: (_) => _nextMatch(),
            ),
          ),
          const SizedBox(width: 4),
          _searchIconBtn(Icons.keyboard_arrow_up, _prevMatch, 'Shift+Enter', cs),
          _searchIconBtn(Icons.keyboard_arrow_down, _nextMatch, 'Enter', cs),
          GestureDetector(
            onTap: _toggleSearch,
            child: Icon(Icons.close, size: 16, color: cs.onSurface.withAlpha(138)),
          ),
        ],
      ),
    );
  }

  Widget _searchIconBtn(IconData icon, VoidCallback onTap, String tooltip, ColorScheme cs) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Icon(icon, size: 16, color: cs.onSurface.withAlpha(138)),
        ),
      ),
    );
  }

  // ── Goto dialog ──────────────────────────────────────────────────────────

  void _showGotoDialog() {
    final ctrl = TextEditingController();
    final cs = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: XMateColors.dialogBg(context),
        title: Text('Go to Offset', style: TextStyle(color: cs.onSurface, fontSize: 15)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(fontFamily: _monoFamily, fontSize: 14, color: Colors.white),
          cursorColor: cs.primary,
          decoration: InputDecoration(
            hintText: '0x1000 or 4096',
            hintStyle: TextStyle(color: cs.onSurface.withAlpha(97), fontSize: 13),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: cs.onSurface.withAlpha(61))),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: cs.primary)),
          ),
          onSubmitted: (val) {
            Navigator.of(ctx).pop();
            _gotoOffset(ctrl);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: TextStyle(color: cs.onSurface.withAlpha(138))),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _gotoOffset(ctrl);
            },
            child: Text('Go', style: TextStyle(color: cs.primary)),
          ),
        ],
      ),
    );
  }

  // ── Keyboard ─────────────────────────────────────────────────────────────

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;

    if (event is KeyDownEvent && key == LogicalKeyboardKey.keyF &&
        (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed)) {
      _toggleSearch();
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent && key == LogicalKeyboardKey.keyG &&
        (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed)) {
      _showGotoDialog();
      return KeyEventResult.handled;
    }

    if (_showSearch && _searchFocus.hasFocus) {
      return KeyEventResult.ignored;
    }

    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      switch (key) {
        case LogicalKeyboardKey.arrowDown:
          _scrollBy(1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp:
          _scrollBy(-1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.pageDown:
          _scrollBy(20);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.pageUp:
          _scrollBy(-20);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.home:
          _scrollCtrl.jumpTo(0);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.end:
          _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
          return KeyEventResult.handled;
        default:
          break;
      }
    }

    return KeyEventResult.ignored;
  }

  void _scrollBy(int rows) {
    if (!_scrollCtrl.hasClients) return;
    final newPos = (_scrollCtrl.offset + rows * _rowHeight)
        .clamp(0.0, _scrollCtrl.position.maxScrollExtent);
    _scrollCtrl.jumpTo(newPos);
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_errorMsg != null) {
      return Center(
        child: Text(_errorMsg!,
            style: const TextStyle(fontSize: 14, color: Colors.redAccent)),
      );
    }

    return Container(
      color: XMateColors.panelBg(context),
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
          children: [
            if (_showSearch) _buildSearchBar(cs),
            _buildMagicBar(cs),
            _buildColHeader(cs),
            Divider(height: 1, color: cs.onSurface.withAlpha(31)),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  _onScroll();
                  return false;
                },
                child: ListView.builder(
                  controller: _scrollCtrl,
                  itemCount: _totalRows,
                  itemExtent: _rowHeight,
                  itemBuilder: _buildRow,
                ),
              ),
            ),
            Divider(height: 1, color: cs.onSurface.withAlpha(31)),
            _buildStatusBar(cs),
          ],
        ),
      ),
    );
  }
}

// ─── Helper: byte range ─────────────────────────────────────────────────────

class _Range {
  final int start; // inclusive
  final int end;   // exclusive
  const _Range(this.start, this.end);
}
