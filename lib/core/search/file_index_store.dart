/// XMate File Search — Binary segment read/write (Index/Content split).
///
/// Index (.xmfi): header + entry table + trigram indexes + postings.
/// Content (.xmfs): raw string pool bytes — never decoded during load.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../utils/logger.dart';
import 'file_index_entry.dart';
import 'file_trigram_index.dart';

const _kMagic = 0x49464D58; // "XMFI" LE
const _kVersion = 1;
const _kEntrySize = 16;
const _kHeaderSize = 4 + 4 + 4 + 2; // magic+version+entryCount+rootPathLen

int _hashString(String s) {
  int h = 5381;
  for (int i = 0; i < s.length; i++) {
    h = ((h << 5) + h + s.codeUnitAt(i)) & 0x7FFFFFFF;
  }
  return h;
}

String _segmentHash(String rootPath) =>
    _hashString(rootPath).toRadixString(16).padLeft(8, '0');

// ══════════════════════════════════════════════════════════════════════════════

class LoadedSegment {
  final String rootPath;
  final int entryCount;
  final int fileCount;

  final Uint8List entryTable; // raw 16B/entry
  final String contentPath;
  final int? contentCrc; // CRC32 of .xmfs (null if legacy file without CRC)
  final FileTrigramIndex nameIndex;
  final FileTrigramIndex pinyinIndex;
  final RandomAccessFile raf; // .xmfi kept open for lazy postings
  final DateTime builtAt;

  /// Segment priority: 0 = base (full rebuild), 1+ = incremental update.
  /// Higher priority wins when same file path appears in multiple segments.
  final int priority;

  /// Cached .xmfs bytes — read once on first decodeEntry, then reused.
  Uint8List? _contentBytes;

  LoadedSegment({
    required this.rootPath,
    required this.entryCount,
    required this.fileCount,
    required this.entryTable,
    required this.contentPath,
    this.contentCrc,
    required this.nameIndex,
    required this.pinyinIndex,
    required this.raf,
    required this.builtAt,
    this.priority = 0,
  });

  void dispose() {
    try { raf.closeSync(); } catch (_) {}
  }

  /// Read .xmfs bytes once into memory (no per-string seeks).
  void _ensureContentBytes() {
    if (_contentBytes != null) return;
    final f = File(contentPath);
    if (!f.existsSync()) return;
    _contentBytes = f.readAsBytesSync();
  }

  /// Decode name/ext/path/flags for entry [id].
  /// Phase B only — must NOT be called during load or Phase A.
  /// Returns empty entry if [id] is out of range (trashy postings guard).
  FileIndexEntry decodeEntry(int id) {
    if (id < 0 || id >= entryCount) {
      return FileIndexEntry(id: id, name: '', ext: '', path: '', isDir: false);
    }
    _ensureContentBytes();
    final cb = _contentBytes;
    if (cb == null) {
      return FileIndexEntry(id: id, name: '', ext: '', path: '', isDir: false);
    }

    final base = id * _kEntrySize;
    final ev = ByteData.sublistView(entryTable);
    final no = ev.getUint32(base, Endian.little);
    final eo = ev.getUint32(base + 4, Endian.little);
    final po = ev.getUint32(base + 8, Endian.little);
    final isDir = (ev.getUint8(base + 14) & 0x01) != 0;

    return FileIndexEntry(
      id: id,
      name: _readCString(cb, no),
      ext: _readCString(cb, eo),
      path: _readCString(cb, po),
      isDir: isDir,
    );
  }

  /// Read null-terminated UTF-8 from in-memory [data] at [offset].
  static String _readCString(Uint8List data, int offset) {
    int end = offset;
    while (end < data.length && data[end] != 0) {
      end++;
    }
    return utf8.decode(data.sublist(offset, end));
  }

  void disposeAll() {
    dispose();
    _contentBytes = null;
  }
}

// ══════════════════════════════════════════════════════════════════════════════

class FileIndexStore {
  Future<String> get _indexDir async {
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory('${appDir.path}/xmate/index');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  Future<(String, String)> segmentPathsFor(String rootPath) async {
    final dir = await _indexDir;
    final h = _segmentHash(rootPath);
    return ('$dir/$h.xmfi', '$dir/$h.xmfs');
  }

  Future<String> indexPathFor(String rootPath) async {
    final (i, _) = await segmentPathsFor(rootPath);
    return i;
  }

  // ── Load (.xmfi metadata only, NO .xmfs I/O) ──────────────────────────

  /// Load all segments for [rootPath]: base + incrementals.
  Future<List<LoadedSegment>> loadSegments(String rootPath) async {
    final segments = <LoadedSegment>[];
    final (baseIndex, baseContent) = await segmentPathsFor(rootPath);

    // Load base segment (priority 0)
    final base = await _loadSegmentFile(baseIndex, baseContent, rootPath);
    if (base != null) {
      segments.add(LoadedSegment(
        rootPath: base.rootPath,
        entryCount: base.entryCount,
        fileCount: base.fileCount,
        entryTable: base.entryTable,
        contentPath: base.contentPath,
        contentCrc: base.contentCrc,
        nameIndex: base.nameIndex,
        pinyinIndex: base.pinyinIndex,
        raf: base.raf,
        builtAt: base.builtAt,
        priority: 0,
      ));
    }

    // Load incremental segments (glob {hash}_*.xmfi)
    final dir = await _indexDir;
    final h = _segmentHash(rootPath);
    final pattern = RegExp('^${RegExp.escape(h)}_(\\d+)\\.xmfi\$');
    try {
      for (final f in Directory(dir).listSync()) {
        final name = f.uri.pathSegments.last;
        final m = pattern.firstMatch(name);
        if (m != null) {
          final n = int.parse(m.group(1)!);
          final incIndex = f.path;
          final incContent = incIndex.replaceAll('.xmfi', '.xmfs');
          final inc = await _loadSegmentFile(incIndex, incContent, rootPath);
          if (inc != null) {
            segments.add(LoadedSegment(
              rootPath: inc.rootPath,
              entryCount: inc.entryCount,
              fileCount: inc.fileCount,
              entryTable: inc.entryTable,
              contentPath: inc.contentPath,
              contentCrc: inc.contentCrc,
              nameIndex: inc.nameIndex,
              pinyinIndex: inc.pinyinIndex,
              raf: inc.raf,
              builtAt: inc.builtAt,
              priority: n,
            ));
          }
        }
      }
    } catch (_) {}

    logger.info('[loadSegments] $rootPath → ${segments.length} segments '
        '(base + ${segments.length - 1} inc)');
    return segments;
  }

  Future<String> delFilePathFor(String rootPath) async {
    final dir = await _indexDir;
    final h = _segmentHash(rootPath);
    return '$dir/${h}_del.txt';
  }

  /// Next incremental number (max existing N + 1, or 1 if none).
  Future<int> nextIncrementalNumber(String rootPath) async {
    final dir = await _indexDir;
    final h = _segmentHash(rootPath);
    final pattern = RegExp('^${RegExp.escape(h)}_(\\d+)\\.xmfi\$');
    int maxN = 0;
    try {
      for (final f in Directory(dir).listSync()) {
        final m = pattern.firstMatch(f.uri.pathSegments.last);
        if (m != null) {
          final n = int.parse(m.group(1)!);
          if (n > maxN) maxN = n;
        }
      }
    } catch (_) {}
    return maxN + 1;
  }

  /// Incremental segment paths.
  Future<(String, String)> incrementalPathsFor(String rootPath, int n) async {
    final dir = await _indexDir;
    final h = _segmentHash(rootPath);
    return ('$dir/${h}_$n.xmfi', '$dir/${h}_$n.xmfs');
  }

  /// Load a single segment file (base or incremental).
  Future<LoadedSegment?> _loadSegmentFile(
      String indexPath, String contentPath, String rootPath) async {
    final fi = File(indexPath);
    if (!fi.existsSync()) return null;
    try {
      final raf = await fi.open(mode: FileMode.read);
      return _loadIndex(raf, rootPath, indexPath, contentPath);
    } catch (e, st) {
      logger.error('[_loadSegmentFile] FAILED: $indexPath → $e');
      logger.error('[_loadSegmentFile] stack: $st');
      try {
        logger.error('[_loadSegmentFile] fileSize=${fi.lengthSync()}');
      } catch (_) {}
      return null;
    }
  }

  /// Keep for backward compatibility (loads base only).
  Future<LoadedSegment?> loadSegment(String rootPath) async {
    final (indexPath, contentPath) = await segmentPathsFor(rootPath);
    return _loadSegmentFile(indexPath, contentPath, rootPath);
  }

  LoadedSegment _loadIndex(
    RandomAccessFile raf,
    String rootPath,
    String indexPath,
    String contentPath,
  ) {
    final sw = Stopwatch()..start();
    final fileLen = raf.lengthSync();
    logger.debug('[_loadIndex] start fileLen=$fileLen');

    // ── Header ────────────────────────────────────────────────────────
    final hdrBytes = Uint8List(_kHeaderSize);
    raf.readIntoSync(hdrBytes);
    final hdr = ByteData.sublistView(hdrBytes);
    final magic = hdr.getUint32(0, Endian.little);
    if (magic != _kMagic) {
      throw FormatException(
          'Bad magic: 0x${magic.toRadixString(16)} expected 0x${_kMagic.toRadixString(16)} (XMFI) '
          'file=$indexPath fileLen=$fileLen');
    }
    final version = hdr.getUint32(4, Endian.little);
    if (version != _kVersion) {
      throw FormatException('Unsupported version: $version file=$indexPath');
    }
    final entryCount = hdr.getUint32(8, Endian.little);
    final rootPathLen = hdr.getUint16(12, Endian.little);

    final rpBytes = Uint8List(rootPathLen);
    raf.readIntoSync(rpBytes);
    final storedRootPath = utf8.decode(rpBytes);
    raf.setPositionSync(_kHeaderSize + rootPathLen + 2);
    logger.debug('[_loadIndex] header OK: entries=$entryCount root=$storedRootPath'
        ' (${sw.elapsedMilliseconds}ms)');

    // ── Entry table ────────────────────────────────────────────────────
    final entryTable = Uint8List(entryCount * _kEntrySize);
    raf.readIntoSync(entryTable);
    logger.debug('[_loadIndex] entryTable read: ${entryTable.length}B'
        ' (${sw.elapsedMilliseconds}ms)');

    // Pre-compute fileCount (bit-scan, zero decode)
    int fc = 0;
    final ev = ByteData.sublistView(entryTable);
    for (int i = 0; i < entryCount; i++) {
      if ((ev.getUint8(i * _kEntrySize + 14) & 0x01) == 0) fc++;
    }
    logger.debug('[_loadIndex] fileCount=$fc (${sw.elapsedMilliseconds}ms)');

    // ── Name trigrams ─────────────────────────────────────────────────
    // Peek 4 bytes at nameStart to verify we're at a trigram count header,
    // not offset by header/entry-table parsing bugs.
    final nameStart = raf.positionSync();
    {
      final save = raf.positionSync();
      raf.setPositionSync(nameStart);
      final peek4 = Uint8List(4);
      raf.readIntoSync(peek4);
      final peekU32LE = ByteData.sublistView(peek4).getUint32(0, Endian.little);
      final peekU32BE = ByteData.sublistView(peek4).getUint32(0, Endian.big);
      logger.debug('[_loadIndex] nameStart=$nameStart'
          ' peekU32LE=$peekU32LE peekU32BE=$peekU32BE'
          ' entryCount=$entryCount fileLen=$fileLen'
          ' expected: ~${entryCount ~/ 1000}+k entries → trigramCount ~50-100k');
      raf.setPositionSync(save);
    }

    final t1 = sw.elapsedMilliseconds;
    final (nameIndex, nameEnd) = FileTrigramIndex.loadWithEnd(raf, nameStart);
    final t2 = sw.elapsedMilliseconds;
    logger.debug('[_loadIndex] name trigrams: ${nameIndex.trigramCount} offsets'
        ' start=$nameStart end=$nameEnd (${t2 - t1}ms)');

    // ── Pinyin trigrams + CRC32 trailer (last 4 bytes) ─
    final pinyinStart = raf.positionSync();
    final totalTail = fileLen - pinyinStart;
    // Last 4 bytes are CRC32 of .xmfs content
    final crcSize = 4;
    final pinyinByteCount = totalTail > crcSize ? totalTail - crcSize : 0;
    final hasCrc = totalTail >= crcSize;

    int? fileCrc;
    if (hasCrc) {
      raf.setPositionSync(fileLen - crcSize);
      final crcBytes = Uint8List(crcSize);
      raf.readIntoSync(crcBytes);
      fileCrc = ByteData.sublistView(crcBytes).getUint32(0, Endian.little);
      raf.setPositionSync(pinyinStart); // back to pinyin start
    }

    logger.debug('[_loadIndex] pinyin: start=$pinyinStart bytes=$pinyinByteCount'
        ' crc=0x${fileCrc?.toRadixString(16) ?? "none"}');

    FileTrigramIndex pinyinIndex;
    if (pinyinByteCount > 0 && pinyinByteCount <= 200_000_000) {
      final pinyinData = Uint8List(pinyinByteCount);
      raf.readIntoSync(pinyinData);
      final t3 = sw.elapsedMilliseconds;
      logger.debug('[_loadIndex] pinyin data read: ${pinyinData.length}B (${t3 - t2}ms)');
      try {
        pinyinIndex = FileTrigramIndex.loadFromBytes(pinyinData, baseOffset: pinyinStart);
      } catch (e) {
        logger.error('[_loadIndex] pinyin parse failed ($e), falling back to empty');
        pinyinIndex = FileTrigramIndex.empty();
      }
      logger.debug('[_loadIndex] pinyin parsed: ${pinyinIndex.trigramCount} trigrams'
          ' (${sw.elapsedMilliseconds - t3}ms)');
    } else {
      logger.debug('[_loadIndex] pinyin section empty or too large ($pinyinByteCount), skipping');
      pinyinIndex = FileTrigramIndex.empty();
    }

    final builtAt = File(indexPath).lastModifiedSync();
    logger.debug('[_loadIndex] complete: entries=$entryCount files=$fc'
        ' nameTrigrams=${nameIndex.trigramCount}'
        ' pinyinTrigrams=${pinyinIndex.trigramCount}'
        ' total=${sw.elapsedMilliseconds}ms');

    return LoadedSegment(
      rootPath: storedRootPath,
      entryCount: entryCount,
      fileCount: fc,
      entryTable: entryTable,
      contentPath: contentPath,
      contentCrc: fileCrc,
      nameIndex: nameIndex,
      pinyinIndex: pinyinIndex,
      raf: raf,
      builtAt: builtAt,
    );
  }

  // ── Delete ──────────────────────────────────────────────────────────

  /// Delete base pair (backward compatible).
  Future<void> deleteSegment(String rootPath) async {
    final (ip, cp) = await segmentPathsFor(rootPath);
    for (final p in [ip, cp]) {
      final f = File(p);
      if (f.existsSync()) await f.delete();
    }
  }

  /// Delete ALL segments for a rootPath: base + incrementals + del.txt.
  Future<void> deleteAllSegments(String rootPath) async {
    final dir = await _indexDir;
    final h = _segmentHash(rootPath);
    try {
      for (final f in Directory(dir).listSync()) {
        final name = f.uri.pathSegments.last;
        if (name.startsWith(h) &&
            (name.endsWith('.xmfi') || name.endsWith('.xmfs') || name.endsWith('_del.txt'))) {
          await f.delete();
        }
      }
    } catch (_) {}
    logger.info('[deleteAllSegments] $rootPath cleared');
  }
}
