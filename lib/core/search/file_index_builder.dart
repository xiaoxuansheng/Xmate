/// XMate File Search — Isolate-safe segment builder (Index/Content split).
///
/// Outputs two files per segment:
///   {hash}.xmfi — Index: header + entry table + trigrams + contentCRC32 trailer
///   {hash}.xmfs — Content: raw string pool bytes (name/ext/path C-strings)
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'file_pinyin_data.dart';
import 'file_trigram_index.dart';

const _kMagic = 0x49464D58; // "XMFI" LE
const _kVersion = 1;
const _kEntrySize = 16;
const _kHeaderSize = 4 + 4 + 4 + 2; // magic+version+entryCount+rootPathLen (14B)

/// CRC-32 (IEEE 802.3 polynomial, matches zlib/gzip).
int _crc32(Uint8List data) {
  int crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (int i = 0; i < 8; i++) {
      if ((crc & 1) != 0) {
        crc = (crc >> 1) ^ 0xEDB88320;
      } else {
        crc >>= 1;
      }
    }
  }
  return crc ^ 0xFFFFFFFF;
}

Future<Map<String, dynamic>> buildSegmentInIsolate(
    Map<String, dynamic> args) async {
  final indexPath = args['indexPath'] as String;
  final contentPath = args['contentPath'] as String;
  final rootPath = args['rootPath'] as String;
  final rawList = args['rawEntries'] as List<dynamic>;
  final entryCount = rawList.length;

  final names = List<String>.filled(entryCount, '');
  final exts  = List<String>.filled(entryCount, '');
  final paths = List<String>.filled(entryCount, '');
  final isDirs = List<bool>.filled(entryCount, false);
  int fileCount = 0;

  for (int i = 0; i < entryCount; i++) {
    final raw = rawList[i] as Map<String, dynamic>;
    names[i]  = raw['n'] as String? ?? '';
    exts[i]   = raw['e'] as String? ?? '';
    paths[i]  = raw['p'] as String? ?? '';
    isDirs[i] = raw['d'] as bool? ?? false;
    if (names[i].isEmpty) { exts[i]=''; paths[i]=''; }
    if (!isDirs[i] && names[i].isNotEmpty) fileCount++;
  }

  // Build string pool + offsets + CRC
  final nameOffsets = Uint32List(entryCount);
  final extOffsets  = Uint32List(entryCount);
  final pathOffsets = Uint32List(entryCount);
  int poolOffset = 0;
  final poolBuf = BytesBuilder();

  for (int i = 0; i < entryCount; i++) {
    nameOffsets[i] = poolOffset;
    final nb = utf8.encode(names[i]);
    poolBuf.add(nb); poolBuf.addByte(0);
    poolOffset += nb.length + 1;

    extOffsets[i] = poolOffset;
    final eb = utf8.encode(exts[i]);
    poolBuf.add(eb); poolBuf.addByte(0);
    poolOffset += eb.length + 1;

    pathOffsets[i] = poolOffset;
    final pb = utf8.encode(paths[i]);
    poolBuf.add(pb); poolBuf.addByte(0);
    poolOffset += pb.length + 1;
  }

  final poolBytes = poolBuf.toBytes();
  final contentCrc = _crc32(poolBytes);

  // Write .xmfi: header + entry table + name trigrams + pinyin trigrams + CRC32 trailer
  final fi = File(indexPath);
  final rafI = await fi.open(mode: FileMode.write);
  try {
    _writeIndexSync(
      raf: rafI, rootPath: rootPath, entryCount: entryCount,
      names: names, exts: exts, paths: paths, isDirs: isDirs,
      nameOffsets: nameOffsets, extOffsets: extOffsets, pathOffsets: pathOffsets,
      contentCrc: contentCrc,
    );
  } finally {
    await rafI.close();
  }
  final indexSize = fi.lengthSync();

  // Write .xmfs: raw string pool
  final fs = File(contentPath);
  final rafC = await fs.open(mode: FileMode.write);
  try {
    rafC.writeFromSync(poolBytes);
  } finally {
    await rafC.close();
  }


  return {
    'entryCount': entryCount, 'fileCount': fileCount,
    'indexSize': indexSize, 'poolSize': poolOffset,
  };
}

void _writeIndexSync({
  required RandomAccessFile raf,
  required String rootPath,
  required int entryCount,
  required List<String> names,
  required List<String> exts,
  required List<String> paths,
  required List<bool> isDirs,
  required Uint32List nameOffsets,
  required Uint32List extOffsets,
  required Uint32List pathOffsets,
  required int contentCrc,
}) {
  final rootPathBytes = utf8.encode(rootPath);
  final totalHdrSize = _kHeaderSize + rootPathBytes.length + 2; // +2 reserved
  final hdr = ByteData(totalHdrSize);
  int pos = 0;
  hdr.setUint32(pos, _kMagic, Endian.little); pos += 4;
  hdr.setUint32(pos, _kVersion, Endian.little); pos += 4;
  hdr.setUint32(pos, entryCount, Endian.little); pos += 4;
  hdr.setUint16(pos, rootPathBytes.length, Endian.little); pos += 2;
  hdr.buffer.asUint8List().setAll(pos, rootPathBytes); pos += rootPathBytes.length;
  hdr.setUint16(pos, 0, Endian.little);
  raf.writeFromSync(Uint8List.sublistView(hdr.buffer.asUint8List(), 0, totalHdrSize));

  // Entry table
  final entryBuf = ByteData(entryCount * _kEntrySize);
  for (int i = 0; i < entryCount; i++) {
    final base = i * _kEntrySize;
    entryBuf.setUint32(base,     nameOffsets[i], Endian.little);
    entryBuf.setUint32(base + 4, extOffsets[i],  Endian.little);
    entryBuf.setUint32(base + 8, pathOffsets[i], Endian.little);
    entryBuf.setUint16(base + 12, 0xFFFF, Endian.little);
    entryBuf.setUint8(base + 14, isDirs[i] ? 1 : 0);
    entryBuf.setUint8(base + 15, 0);
  }
  raf.writeFromSync(entryBuf.buffer.asUint8List());

  // Name trigrams
  final nameEntries = <(int, String)>[];
  for (int i = 0; i < entryCount; i++) {
    if (names[i].isNotEmpty) nameEntries.add((i, names[i].toLowerCase()));
  }
  FileTrigramIndex.buildAndWrite(raf, nameEntries);

  // Pinyin trigrams
  final pinyinEntries = <(int, String)>[];
  for (int i = 0; i < entryCount; i++) {
    if (names[i].isNotEmpty) {
      final p = toPinyinInitials(names[i]);
      if (p.isNotEmpty) pinyinEntries.add((i, p));
    }
  }
  FileTrigramIndex.buildAndWrite(raf, pinyinEntries);

  // CRC32 trailer (4 bytes LE) — reader can verify .xmfs integrity
  final crcBuf = ByteData(4);
  crcBuf.setUint32(0, contentCrc, Endian.little);
  raf.writeFromSync(crcBuf.buffer.asUint8List());

}
