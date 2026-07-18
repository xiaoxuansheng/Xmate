/// Simple ZIP central-directory reader for EPUB container access.
///
/// Uses `u16le` / `u32le` from archive_parser (now public) for little-endian
/// reads.  Supports stored (method 0) and deflate (method 8) entries only —
/// sufficient for EPUB which mandates those two methods.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'archive_parser.dart' show u16le, u32le;

// ══════════════════════════════════════════════════════════════════════════════
// Entry model
// ══════════════════════════════════════════════════════════════════════════════

class EpubZipEntry {
  final String name;
  final int localOffset, compSize, uncompSize, method;
  const EpubZipEntry(this.name, this.localOffset, this.compSize, this.uncompSize, this.method);
}

// ══════════════════════════════════════════════════════════════════════════════
// ZIP reader
// ══════════════════════════════════════════════════════════════════════════════

/// Read the central directory of a ZIP and return entries keyed by lower-case
/// file name.  Only reads the last 64K + 22 bytes for the EOCD marker.
Future<Map<String, EpubZipEntry>> readEpubZipDir(RandomAccessFile raf, int fileSize) async {
  final entries = <String, EpubZipEntry>{};
  final searchLen = (65535 + 22).clamp(0, fileSize);
  await raf.setPosition(fileSize - searchLen);
  final buf = await raf.read(searchLen);
  int eocd = -1;
  for (int i = buf.length - 22; i >= 0; i--) {
    if (buf[i]==0x50 && buf[i+1]==0x4b && buf[i+2]==0x05 && buf[i+3]==0x06) {
      eocd = fileSize - searchLen + i; break;
    }
  }
  if (eocd < 0) return entries;
  await raf.setPosition(eocd);
  final eb = await raf.read(22);
  final cdOff = u32le(eb, 16), cdSz = u32le(eb, 12);
  if (cdOff + cdSz > fileSize) return entries;
  await raf.setPosition(cdOff);
  final cd = await raf.read(cdSz);
  int pos = 0;
  while (pos + 46 <= cd.length) {
    if (u32le(cd, pos) != 0x02014b50) break;
    final nameLen = u16le(cd, pos + 28);
    final name = utf8.decode(cd.sublist(pos + 46, pos + 46 + nameLen), allowMalformed: true);
    entries[name.toLowerCase()] = EpubZipEntry(
        name, u32le(cd, pos + 42), u32le(cd, pos + 20), u32le(cd, pos + 24), u16le(cd, pos + 10));
    pos += 46 + nameLen + u16le(cd, pos + 30) + u16le(cd, pos + 32);
  }
  return entries;
}

/// Extract and decompress a single entry from [raf].
Future<Uint8List> extractEpubEntry(RandomAccessFile raf, EpubZipEntry e) async {
  await raf.setPosition(e.localOffset);
  final lh = await raf.read(30);
  if (u32le(lh, 0) != 0x04034b50) throw FormatException('Bad local header');
  final nl = u16le(lh, 26), el = u16le(lh, 28);
  await raf.setPosition(e.localOffset + 30 + nl + el);
  final comp = await raf.read(e.compSize);
  if (e.method == 0) return comp;
  if (e.method == 8) return _inflate(comp);
  throw FormatException('Unsupported method ${e.method}');
}

Uint8List _inflate(Uint8List d) {
  try { return Uint8List.fromList(zlib.decode(d)); } catch (_) {}
  return Uint8List.fromList(ZLibCodec(raw: true).decode(d));
}
