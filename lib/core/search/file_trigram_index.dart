/// XMate File Search — Trigram Inverted Index
///
/// UTF-8 bytes trigram generation with `$$` padding, cross Dart/C++ consistent.
/// Lazy postings: offset table in memory, postings read from disk on demand.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

// ══════════════════════════════════════════════════════════════════════════════

int packTrigram(int b0, int b1, int b2) {
  return ((b0 & 0xFF) << 16) | ((b1 & 0xFF) << 8) | (b2 & 0xFF);
}

(int, int, int) unpackTrigram(int packed) {
  return ((packed >> 16) & 0xFF, (packed >> 8) & 0xFF, packed & 0xFF);
}

List<int> extractTrigrams(String s) {
  if (s.isEmpty) return [];
  final bytes = utf8.encode(s);
  return _extractFromBytes(bytes);
}

List<int> extractTrigramsFromBytes(List<int> utf8Bytes) {
  if (utf8Bytes.isEmpty) return [];
  return _extractFromBytes(utf8Bytes);
}

List<int> _extractFromBytes(List<int> bytes) {
  final padded = <int>[0x24, 0x24, ...bytes, 0x24];
  final result = <int>[];
  for (int i = 0; i < padded.length - 2; i++) {
    result.add(packTrigram(padded[i], padded[i + 1], padded[i + 2]));
  }
  return result;
}

// ══════════════════════════════════════════════════════════════════════════════

class _TrigramOffset {
  final int trigram;
  final int count;
  final int fileOffset; // byte offset in .xmfi where uint32[] postings start

  const _TrigramOffset(this.trigram, this.count, this.fileOffset);
}

// ══════════════════════════════════════════════════════════════════════════════

class FileTrigramIndex {
  final List<_TrigramOffset> _offsets;

  FileTrigramIndex._(this._offsets);

  /// Empty index.
  FileTrigramIndex.empty() : _offsets = const [];

  int get trigramCount => _offsets.length;

  // ── Build + Write ──────────────────────────────────────────────────────

  static (FileTrigramIndex, int) buildAndWrite(
    RandomAccessFile raf,
    List<(int, String)> entries,
  ) {
    final map = <int, List<int>>{};
    for (final (id, text) in entries) {
      final trigrams = extractTrigrams(text);
      for (final t in trigrams) {
        map.putIfAbsent(t, () => []).add(id);
      }
    }
    final sortedKeys = map.keys.toList()..sort();
    final postingsData = <int, Uint8List>{};
    for (final t in sortedKeys) {
      final list = map[t]!;
      list.sort();
      final deduped = <int>[];
      for (int i = 0; i < list.length; i++) {
        if (i == 0 || list[i] != list[i - 1]) deduped.add(list[i]);
      }
      final buf = ByteData(deduped.length * 4);
      int prev = 0;
      for (int i = 0; i < deduped.length; i++) {
        buf.setUint32(i * 4, deduped[i] - prev, Endian.little);
        prev = deduped[i];
      }
      postingsData[t] = buf.buffer.asUint8List();
    }

    final hdr = ByteData(4);
    hdr.setUint32(0, sortedKeys.length, Endian.little);
    raf.writeFromSync(hdr.buffer.asUint8List());

    final offsets = <_TrigramOffset>[];
    for (final t in sortedKeys) {
      final data = postingsData[t]!;
      final count = data.length ~/ 4;
      hdr.setUint32(0, t, Endian.little);
      raf.writeFromSync(hdr.buffer.asUint8List());
      hdr.setUint32(0, count, Endian.little);
      raf.writeFromSync(hdr.buffer.asUint8List());
      final offset = raf.positionSync();
      raf.writeFromSync(data);
      offsets.add(_TrigramOffset(t, count, offset));
    }
    return (FileTrigramIndex._(offsets), raf.positionSync());
  }

  // ── In-memory parse (zero I/O, bounds-checked) ───────────────────────────

  /// Parse a trigram index entirely from a [Uint8List] (already in memory).
  /// Zero I/O, zero seeks. Used when the trigram area end is known.
  ///
  /// [baseOffset] is the absolute byte offset in the .xmfi file where [data]
  /// starts. It is added to every posting's fileOffset so that
  /// [readPostings] can seek to the correct position directly.
  ///
  /// Throws [FormatException] with detailed diagnostics on corruption.
  static FileTrigramIndex loadFromBytes(Uint8List data, {int baseOffset = 0}) {
    if (data.length < 4) {
      throw FormatException('trigram data too short: ${data.length}B');
    }
    final view = ByteData.sublistView(data);
    final trigramCount = view.getUint32(0, Endian.little);

    if (trigramCount == 0) return FileTrigramIndex._([]);
    if (trigramCount > 5_000_000) {
      throw FormatException('unreasonable trigramCount=$trigramCount in loadFromBytes');
    }

    // Compute total size: walk through and sum up postings
    final offsets = <_TrigramOffset>[];
    int cursor = 4; // after trigramCount
    for (int i = 0; i < trigramCount; i++) {
      if (cursor + 8 > data.length) {
        throw FormatException(
            'trigram header overflow at index $i/$trigramCount: '
            'cursor=$cursor need 8 bytes, data=${data.length}B');
      }
      final trigram = view.getUint32(cursor, Endian.little);
      final postingCount = view.getUint32(cursor + 4, Endian.little);
      cursor += 8;
      if (postingCount < 0 || postingCount > 100_000_000) {
        throw FormatException(
            'invalid postingCount=$postingCount at trigram 0x${trigram.toRadixString(16)} '
            'index $i/$trigramCount cursor=$cursor');
      }
      final postingStart = cursor;
      cursor += postingCount * 4;
      if (cursor > data.length) {
        throw FormatException(
            'postings overflow at trigram 0x${trigram.toRadixString(16)} '
            'index $i/$trigramCount count=$postingCount '
            'start=$postingStart end=$cursor data=${data.length}B');
      }
      offsets.add(_TrigramOffset(trigram, postingCount, postingStart + baseOffset));
    }

    if (cursor != data.length) {
      // Trailing bytes — warn but don't fail (future extensions)
      debugPrint('[TrigramIndex] warning: ${data.length - cursor}B trailing after '
          '$trigramCount trigrams (cursor=$cursor data=${data.length})');
    }

    return FileTrigramIndex._(offsets);
  }

  // ── Disk load (seek-based, for sections with unknown end offset) ────────

  /// Load trigram offsets from disk with per-trigram seeks.
  /// Only use when the end offset is unknown. Prefer [loadFromBytes] when
  /// the section end is known (e.g. last section before EOF).
  static (FileTrigramIndex, int) loadWithEnd(
    RandomAccessFile raf,
    int startOffset,
  ) {
    final fileLen = raf.lengthSync();
    raf.setPositionSync(startOffset);

    final hdr = Uint8List(4);
    raf.readIntoSync(hdr);
    final trigramCount = ByteData.sublistView(hdr).getUint32(0, Endian.little);

    if (trigramCount == 0) {
      return (FileTrigramIndex._([]), startOffset + 4);
    }

    // Guard: if trigramCount is unreasonably large, something is wrong
    if (trigramCount > 5_000_000) {
      throw FormatException(
          'unreasonable trigramCount=$trigramCount at offset $startOffset '
          'fileLen=$fileLen');
    }

    final offsets = <_TrigramOffset>[];
    final itemBuf = Uint8List(8);
    for (int i = 0; i < trigramCount; i++) {
      final before = raf.positionSync();

      raf.readIntoSync(itemBuf);
      final item = ByteData.sublistView(itemBuf);
      final trigram = item.getUint32(0, Endian.little);
      final postingCount = item.getUint32(4, Endian.little);
      final postingOffset = raf.positionSync();

      // Bounds check
      final skipTarget = postingOffset + postingCount * 4;
      if (skipTarget > fileLen) {
        throw FormatException(
            'postings overflow in .xmfi: trigram 0x${trigram.toRadixString(16)} '
            'index $i/$trigramCount count=$postingCount '
            'skipTarget=$skipTarget fileLen=$fileLen start=$startOffset');
      }
      if (postingCount < 0) {
        throw FormatException(
            'negative postingCount=$postingCount at trigram 0x${trigram.toRadixString(16)} '
            'index $i/$trigramCount');
      }

      offsets.add(_TrigramOffset(trigram, postingCount, postingOffset));
      raf.setPositionSync(skipTarget);

      // Assert forward progress
      final after = raf.positionSync();
      if (after <= before && postingCount > 0) {
        throw FormatException(
            'seek stall at trigram index $i: before=$before after=$after '
            'skipTarget=$skipTarget postingCount=$postingCount');
      }
    }

    return (FileTrigramIndex._(offsets), raf.positionSync());
  }

  // ── Query ────────────────────────────────────────────────────────────────

  int _findOffsetIndex(int trigram) {
    int lo = 0, hi = _offsets.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final v = _offsets[mid].trigram;
      if (v < trigram) {
        lo = mid + 1;
      } else if (v > trigram) {
        hi = mid - 1;
      } else {
        return mid;
      }
    }
    return -1;
  }

  Uint32List? readPostings(RandomAccessFile raf, int trigram) {
    final idx = _findOffsetIndex(trigram);
    if (idx == -1) return null;
    final off = _offsets[idx];
    raf.setPositionSync(off.fileOffset);
    final data = Uint8List(off.count * 4);
    raf.readIntoSync(data);
    return _deltaDecode(data, off.count);
  }

  int? postingCount(int trigram) {
    final idx = _findOffsetIndex(trigram);
    if (idx == -1) return null;
    return _offsets[idx].count;
  }

  bool contains(int trigram) => _findOffsetIndex(trigram) != -1;

  static Uint32List _deltaDecode(Uint8List data, int count) {
    final result = Uint32List(count);
    final view = ByteData.sublistView(data);
    int prev = 0;
    for (int i = 0; i < count; i++) {
      prev = view.getUint32(i * 4, Endian.little) + prev;
      result[i] = prev;
    }
    return result;
  }

  int get offsetCount => _offsets.length;
}

// ══════════════════════════════════════════════════════════════════════════════

class TrigramSearchResult {
  final Map<int, int> matchCounts;
  final int queryTrigramCount;
  const TrigramSearchResult(this.matchCounts, this.queryTrigramCount);
  bool get isEmpty => matchCounts.isEmpty;
}

TrigramSearchResult searchTrigrams(
  RandomAccessFile raf,
  FileTrigramIndex index,
  List<int> queryTrigrams,
) {
  final unique = queryTrigrams.toSet().toList();
  final pairs = <(int, Uint32List)>[];
  for (final t in unique) {
    final postings = index.readPostings(raf, t);
    if (postings != null) pairs.add((t, postings));
  }
  if (pairs.isEmpty) return TrigramSearchResult({}, unique.length);

  pairs.sort((a, b) => a.$2.length.compareTo(b.$2.length));
  final nIntersect =
      unique.length <= 2 ? 0 : (unique.length < 4 ? unique.length : 4);

  final matchCounts = <int, int>{};
  for (int pi = 0; pi < pairs.length; pi++) {
    final (_, postings) = pairs[pi];
    final isIntersect = pi < nIntersect;
    for (int j = 0; j < postings.length; j++) {
      final entryId = postings[j];
      final prev = matchCounts[entryId];
      if (prev != null) {
        matchCounts[entryId] = prev + 1;
      } else if (nIntersect == 0 || isIntersect) {
        matchCounts[entryId] = 1;
      }
    }
  }
  if (nIntersect > 0) {
    final minRequired = (nIntersect + 1) ~/ 2;
    matchCounts.removeWhere((_, count) => count < minRequired);
  }
  return TrigramSearchResult(matchCounts, unique.length);
}
