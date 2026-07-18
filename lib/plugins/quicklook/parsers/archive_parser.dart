import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Single entry in an archive.
class ArchiveEntry {
  final String name;
  final bool isDir;
  final int size;         // uncompressed size
  final int? compressedSize;
  final int? crc32;
  final DateTime? modified;
  const ArchiveEntry({
    required this.name, required this.isDir, required this.size,
    this.compressedSize, this.crc32, this.modified,
  });
}

/// Parsed archive listing.
class ArchiveListing {
  final List<ArchiveEntry> entries;
  final String format;          // e.g. "ZIP 2.0", "TAR (ustar)", "GZIP"
  final String? compression;    // e.g. "Deflate", "Store", "gzip"
  final String? hint;           // e.g. "Install 7-Zip for full listing"
  const ArchiveListing({
    required this.entries, required this.format,
    this.compression, this.hint,
  });

  int get fileCount => entries.where((e) => !e.isDir).length;
  int get folderCount => entries.where((e) => e.isDir).length;
  int get totalSize => entries.fold(0, (s, e) => s + e.size);
}

/// Parse any supported archive. Returns null if the file is not an archive.
Future<ArchiveListing?> parseArchive(String path) async {
  final file = File(path);
  if (!await file.exists()) return null;
  final raf = await file.open(mode: FileMode.read);
  try {
    final fileSize = await raf.length();
    final head = Uint8List(8);
    if (await raf.readInto(head) < 4) return null;

    // ZIP magic: PK\x03\x04 (local file header)
    if (head[0] == 0x50 && head[1] == 0x4B && head[2] == 0x03 && head[3] == 0x04) {
      return await _parseZip(raf, fileSize);
    }
    // GZIP magic: 1F 8B
    if (head[0] == 0x1F && head[1] == 0x8B) {
      return await _parseGz(raf, fileSize);
    }
    // TAR magic: "ustar" at offset 257
    if (fileSize >= 512) {
      await raf.setPosition(257);
      final ustar = Uint8List(5);
      if (await raf.readInto(ustar) == 5) {
        final s = String.fromCharCodes(ustar);
        if (s == 'ustar') return await _parseTar(raf, fileSize);
      }
      // POSIX tar: no ustar magic, but all entries are 512-byte aligned.
      await raf.setPosition(0);
      final first = Uint8List(512);
      if (await raf.readInto(first) == 512) {
        // Tar header: name at 0-99, checksum at 148-155.
        final chkStr = _readNullTerm(first, 148, 8);
        if (chkStr.isNotEmpty && RegExp(r'^[0-7 ]+$').hasMatch(chkStr)) {
          final nameStr = _readNullTerm(first, 0, 100);
          if (nameStr.isNotEmpty && RegExp(r'^[\x20-\x7E/\\\-_.]+$').hasMatch(nameStr)) {
            return await _parseTar(raf, fileSize);
          }
        }
      }
    }

    // Pure-Dart parsing didn't match — try 7za.exe for unrecognised formats.
    // Close the RAF first so 7za.exe can read the file without sharing issues.
    raf.closeSync();
    final ext = path.split('.').last.toLowerCase();
    if (_via7zaExts.contains(ext)) {
      return await _parseVia7za(path);
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    try { raf.closeSync(); } catch (_) {}
  }
}

/// Extensions that we route through 7za.exe when pure-Dart parsers fail.
/// 7za.exe also handles ZIP/TAR/GZ, but those are covered by pure Dart.
const _via7zaExts = {'7z', 'rar', 'bz2', 'xz', 'zst', 'lz', 'lz4'};

// ═══════════════════════════════════════════════════════════════════════════
// 7za.exe proxy parser — fallback for formats pure Dart can't handle
// ═══════════════════════════════════════════════════════════════════════════

/// Find the 7za.exe binary.  Looks next to the running executable first,
/// then falls back to PATH.
String? _find7za() {
  try {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final local = '$exeDir\\7za.exe';
    if (File(local).existsSync()) return local;
  } catch (_) {}
  // Try PATH
  for (final dir in (Platform.environment['PATH'] ?? '').split(';')) {
    final p = '$dir\\7za.exe';
    if (File(p).existsSync()) return p;
  }
  return null;
}

/// Parse a 7za.exe "l -slt" listing line by line.
/// We use `l -slt` (technical listing) because its key-value output is
/// trivial to parse compared to the tabular `l` output.
Future<ArchiveListing?> _parseVia7za(String path) async {
  final exe = _find7za();
  if (exe == null) return null;

  try {
    final result = await Process.run(exe, ['l', '-slt', path],
        runInShell: false);
    if (result.exitCode != 0) return null;

    final output = result.stdout is String
        ? result.stdout as String
        : SystemEncoding().decode(result.stdout as List<int>);

    // 7za -slt output looks like:
    //
    //   7z 23.01  ...  (header lines)
    //   ----------
    //   Path = file1.txt
    //   Size = 1234
    //   Packed Size = 567
    //   Modified = 2023-01-15 14:30:00
    //   Attributes = A
    //   CRC = ...
    //   Method = LZMA2:24
    //   ...
    //   Path = dir1/
    //   Size = 0
    //   ...
    //
    // Entries are separated by blank lines.  We parse line-by-line.

    final entries = <ArchiveEntry>[];
    var currentName = <String>[];
    var currentSize = 0;
    var currentPacked = -1;
    DateTime? currentMtime;
    String? method;
    String? solid; // "Solid" field = compression info

    final lines = output.split('\n');
    bool inEntries = false;

    for (final raw in lines) {
      var line = raw.trim();
      if (line.isEmpty) {
        // End of one record
        if (inEntries && currentName.isNotEmpty) {
          final fullName = currentName.join('/');
          final isDir = currentSize == 0 && fullName.endsWith('/') ||
              fullName.endsWith('\\');
          final cleanName = isDir && (fullName.endsWith('/') || fullName.endsWith('\\'))
              ? fullName.substring(0, fullName.length - 1)
              : fullName;
          entries.add(ArchiveEntry(
            name: cleanName,
            isDir: isDir,
            size: currentSize,
            compressedSize: currentPacked >= 0 ? currentPacked : null,
            modified: currentMtime,
          ));
        }
        currentName = <String>[];
        currentSize = 0;
        currentPacked = -1;
        currentMtime = null;
        continue;
      }

      // Skip the header section before entries begin.  The 7za -slt output
      // starts with an archive metadata block (Path = archive.7z, Size = ...)
      // followed by "----------" — only after that separator do the actual
      // file entries begin.  We MUST NOT treat the archive metadata Path as a
      // file entry.
      if (!inEntries) {
        if (line.startsWith('----------')) {
          inEntries = true;
        }
        // Collect Method / Solid from headers while we're here
        if (line.startsWith('Method = ')) {
          final val = line.substring(line.indexOf('= ') + 2);
          if (val.isNotEmpty) method = val;
        }
        if (line.startsWith('Solid = ') && line.contains('+')) {
          solid = 'Solid';
        }
        continue;
      }

      if (line.startsWith('Path = ')) {
        currentName.add(line.substring(7));
      } else if (line.startsWith('Size = ')) {
        currentSize = int.tryParse(line.substring(7)) ?? 0;
      } else if (line.startsWith('Packed Size = ')) {
        currentPacked = int.tryParse(line.substring(14)) ?? -1;
      } else if (line.startsWith('Modified = ')) {
        final ts = line.substring(11);
        try {
          currentMtime = DateTime.parse(ts);
        } catch (_) {}
      }
    }

    // Last entry (no trailing blank line)
    if (inEntries && currentName.isNotEmpty) {
      final fullName = currentName.join('/');
      final isDir = currentSize == 0 && fullName.endsWith('/');
      final cleanName = isDir
          ? fullName.substring(0, fullName.length - 1)
          : fullName;
      entries.add(ArchiveEntry(
        name: cleanName, isDir: isDir, size: currentSize,
        compressedSize: currentPacked >= 0 ? currentPacked : null,
        modified: currentMtime,
      ));
    }

    // Sort: directories first
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    final compression = method != null
        ? (solid != null ? '$method ($solid)' : method)
        : null;

    final ext = path.split('.').last.toUpperCase();
    return ArchiveListing(
      entries: entries,
      format: ext == 'BZ2' || ext == 'XZ' || ext == 'ZST' || ext == 'LZ' || ext == 'LZ4'
          ? ext : ext,
      compression: compression ?? '7-Zip',
    );
  } catch (_) {
    return null;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// ZIP parser — EOCD → Central Directory

// ═══════════════════════════════════════════════════════════════════════════
// ZIP parser — EOCD → Central Directory
// ═══════════════════════════════════════════════════════════════════════════

Future<ArchiveListing> _parseZip(RandomAccessFile raf, int fileSize) async {
  // Search backwards from end for EOCD signature 0x06054b50
  const eocdSig = [0x50, 0x4B, 0x05, 0x06];
  const searchLen = 65536 + 22; // max comment + EOCD
  final searchStart = fileSize > searchLen ? fileSize - searchLen : 0;

  int eocdOff = -1;
  for (int off = fileSize - 22; off >= searchStart; off--) {
    await raf.setPosition(off);
    final b = Uint8List(4);
    if (await raf.readInto(b) < 4) break;
    if (b[0] == eocdSig[0] && b[1] == eocdSig[1] &&
        b[2] == eocdSig[2] && b[3] == eocdSig[3]) {
      eocdOff = off;
      break;
    }
  }
  if (eocdOff < 0) return _emptyListing('ZIP (corrupt)');

  await raf.setPosition(eocdOff + 4);
  final eocd = Uint8List(22); // disk#(2)+cdDisk(2)+entriesDisk(2)+total(2)+cdSize(4)+cdOff(4)+commentLen(2)
  await raf.readInto(eocd);

  // EOCD fields (offset from EOCD start at eocdOff+4):
  //   0: disk #      2: cd disk     4: entries this disk
  //   6: total entries (2B)        8: cd size (4B)
  //  12: cd offset (4B)           16: comment len (2B)
  final totalEntries = u16le(eocd, 6);
  final cdOffset = u32le(eocd, 12);

  if (totalEntries == 0 || cdOffset == 0) return _emptyListing('ZIP (empty)');

  // Read central directory
  await raf.setPosition(cdOffset);
  final entries = <ArchiveEntry>[];
  int versions = 0;
  final compMethods = <int>{};
  final pendingDecodes = <int, Uint8List>{}; // raw bytes that need system codec

  for (int i = 0; i < totalEntries; i++) {
    final sig = Uint8List(4);
    if (await raf.readInto(sig) < 4) break;
    if (sig[0] != 0x50 || sig[1] != 0x4B || sig[2] != 0x01 || sig[3] != 0x02) break;

    final fixed = Uint8List(42);
    if (await raf.readInto(fixed) < 42) break;

    final versionNeed = u16le(fixed, 2);
    final gpFlags = u16le(fixed, 4);
    final method = u16le(fixed, 6);
    final modTime = u16le(fixed, 8);
    final modDate = u16le(fixed, 10);
    final crc32 = u32le(fixed, 12);
    final compSize = u32le(fixed, 16);
    final uncompSize = u32le(fixed, 20);
    final nameLen = u16le(fixed, 24);
    final extraLen = u16le(fixed, 26);
    final commentLen = u16le(fixed, 28);

    final nameBytes = Uint8List(nameLen);
    if (nameLen > 0) await raf.readInto(nameBytes);

    // Parse extra field for 0x7075 (Unicode Path)
    String? extraUnicodeName;
    if (extraLen > 0) {
      final extraBytes = Uint8List(extraLen);
      await raf.readInto(extraBytes);
      int epos = 0;
      while (epos + 4 <= extraLen) {
        final eid = u16le(extraBytes, epos);
        final esize = u16le(extraBytes, epos + 2);
        epos += 4;
        if (epos + esize > extraLen) break;
        if (eid == 0x7075 && esize >= 5) {
          // version(1B) + nameCrc32(4B) + utf8Name(N B)
          final unameLen = esize - 5;
          if (unameLen > 0) {
            try {
              extraUnicodeName = utf8.decode(
                Uint8List.view(extraBytes.buffer, extraBytes.offsetInBytes + epos + 5, unameLen),
                allowMalformed: false,
              );
            } catch (_) {}
          }
        }
        epos += esize;
      }
    } else {
      // no extra field to read
    }

    // Skip file comment
    if (commentLen > 0) {
      await raf.setPosition(raf.positionSync() + commentLen);
    }

    // ── Decode name — strict tiered fallback ──────────────────────────
    //     1. GP bit 11 (= UTF-8)
    //     2. Extra field 0x7075 Unicode Path
    //     3. System ANSI codec (CP_ACP → GBK on Chinese Windows, etc.)
    //     4. CP437 (best-effort for old DOS zips)
    // NEVER guess UTF-8 from byte patterns — valid decode ≠ correct decode.

    final isUtf8 = (gpFlags & 0x0800) != 0;
    String name;
    if (isUtf8 || extraUnicodeName != null) {
      final utf8Bytes = extraUnicodeName != null
          ? utf8.encode(extraUnicodeName)
          : nameBytes;
      try {
        name = utf8.decode(utf8Bytes, allowMalformed: false);
      } catch (_) {
        name = String.fromCharCodes(utf8Bytes.map(_cp437toUnicode));
      }
    } else if (nameBytes.any((b) => b > 0x7F)) {
      // Non-ASCII bytes without UTF-8 flag → likely local ANSI codepage.
      // Use CP437 as a temporary placeholder; deferred to system-codec below.
      name = String.fromCharCodes(nameBytes.map(_cp437toUnicode));
      pendingDecodes[entries.length] = nameBytes;
    } else {
      // Pure ASCII — CP437 is fine (it's identical for 0x00-0x7F).
      name = String.fromCharCodes(nameBytes);
    }

    final isDir = name.endsWith('/') || name.endsWith('\\');
    final cleanName = isDir ? name.substring(0, name.length - 1) : name;

    DateTime? modified;
    if (modDate != 0 && modTime != 0) {
      final year = (modDate >> 9) + 1980;
      final month = (modDate >> 5) & 0x0F;
      final day = modDate & 0x1F;
      final hour = (modTime >> 11) & 0x1F;
      final min = (modTime >> 5) & 0x3F;
      final sec = (modTime & 0x1F) * 2;
      modified = DateTime(year, month.clamp(1, 12), day.clamp(1, 28),
          hour.clamp(0, 23), min.clamp(0, 59), sec.clamp(0, 59));
    }

    entries.add(ArchiveEntry(
      name: cleanName, isDir: isDir,
      size: uncompSize, compressedSize: compSize, crc32: crc32,
      modified: modified,
    ));

    versions |= versionNeed;
    compMethods.add(method);
  }

  // Resolve names that need system-codec (GBK etc.) decoding.
  if (pendingDecodes.isNotEmpty) {
    for (final e in pendingDecodes.entries) {
      final result = await _decodeSystemEncoding(e.value);
      final a = entries[e.key];
      entries[e.key] = ArchiveEntry(
        name: a.isDir && result.endsWith('/')
            ? result.substring(0, result.length - 1)
            : result,
        isDir: a.isDir, size: a.size,
        compressedSize: a.compressedSize, crc32: a.crc32,
        modified: a.modified,
      );
    }
    pendingDecodes.clear();
  }

  // versionNeed = (major * 10 + minor) in low byte; high byte = host OS
  final lowVer = versions & 0xFF;
  final zipVer = (lowVer / 10).toStringAsFixed(1);

  String compStr = 'Unknown';
  if (compMethods.isEmpty || (compMethods.length == 1 && compMethods.contains(0))) {
    compStr = 'Store';
  } else if (compMethods.length == 1 && compMethods.contains(8)) {
    compStr = 'Deflate';
  } else {
    final parts = <String>[];
    if (compMethods.contains(8)) parts.add('Deflate');
    if (compMethods.contains(14)) parts.add('LZMA');
    if (compMethods.contains(93)) parts.add('Zstandard');
    if (compMethods.contains(98)) parts.add('PPMd');
    compStr = parts.join('+');
  }

  // Sort: directories first, then by name
  entries.sort((a, b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });

  return ArchiveListing(
    entries: entries,
    format: 'ZIP $zipVer',
    compression: compStr,
  );
}

ArchiveListing _emptyListing(String format) {
  return ArchiveListing(entries: [], format: format);
}

// ═══════════════════════════════════════════════════════════════════════════
// TAR parser — 512B header blocks
// ═══════════════════════════════════════════════════════════════════════════

Future<ArchiveListing> _parseTar(RandomAccessFile raf, int fileSize) async {
  await raf.setPosition(0);
  final entries = <ArchiveEntry>[];
  bool isUstar = false;
  int pos = 0;

  while (pos + 512 <= fileSize) {
    final block = Uint8List(512);
    if (await raf.readInto(block) < 512) break;

    // Check for end-of-archive: two consecutive zero blocks
    bool allZero = true;
    for (int i = 0; i < 512; i++) {
      if (block[i] != 0) { allZero = false; break; }
    }
    if (allZero) break;

    final name = _readNullTerm(block, 0, 100);
    final sizeStr = _readNullTerm(block, 124, 12);
    final mtimeStr = _readNullTerm(block, 136, 12);
    final typeFlag = block[156];
    final ustarCheck = _readNullTerm(block, 257, 6);
    if (ustarCheck == 'ustar') isUstar = true;
    final prefix = _readNullTerm(block, 345, 155);

    if (name.isEmpty) break;

    final size = int.tryParse(sizeStr, radix: 8) ?? 0;

    // Determine entry type
    bool isDir = typeFlag == 0x35;
    final fullName = prefix.isNotEmpty ? '$prefix/$name' : name;

    DateTime? mtime;
    final mtimeSec = int.tryParse(mtimeStr, radix: 8);
    if (mtimeSec != null && mtimeSec > 0) {
      mtime = DateTime.fromMillisecondsSinceEpoch(mtimeSec * 1000);
    }

    entries.add(ArchiveEntry(
      name: fullName, isDir: isDir, size: size,
      modified: mtime,
    ));

    pos += 512 + ((size + 511) ~/ 512) * 512;
    await raf.setPosition(pos);
  }

  entries.sort((a, b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });

  return ArchiveListing(
    entries: entries,
    format: isUstar ? 'TAR (ustar)' : 'TAR',
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// GZIP — name from header, size from footer
// ═══════════════════════════════════════════════════════════════════════════

Future<ArchiveListing> _parseGz(RandomAccessFile raf, int fileSize) async {
  await raf.setPosition(0);
  final head = Uint8List(10);
  await raf.readInto(head);

  // Byte 3 = flags: FTEXT=1 FHCRC=2 FEXTRA=4 FNAME=8 FCOMMENT=16
  final flags = head[3];
  int pos = 10;

  // Skip extra field
  if ((flags & 4) != 0) {
    await raf.setPosition(pos);
    final ex = Uint8List(2);
    await raf.readInto(ex);
    final xlen = u16le(ex, 0);
    pos += 2 + xlen;
  }

  // Read filename
  String? name;
  if ((flags & 8) != 0) {
    await raf.setPosition(pos);
    final nameBytes = <int>[];
    while (true) {
      final b = await raf.readByte();
      if (b == 0) break;
      nameBytes.add(b);
      pos++;
    }
    pos++;
    name = String.fromCharCodes(nameBytes);
  }

  // Original size is last 4 bytes (ISIZE), modulo 2^32
  int uncompSize = 0;
  if (fileSize >= 4) {
    await raf.setPosition(fileSize - 4);
    final isize = Uint8List(4);
    if (await raf.readInto(isize) == 4) {
      uncompSize = u32le(isize, 0);
    }
  }

  final entries = <ArchiveEntry>[
    ArchiveEntry(name: name ?? '(unknown)', isDir: false, size: uncompSize),
  ];

  return ArchiveListing(
    entries: entries,
    format: 'GZIP',
    compression: 'Deflate',
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// Byte helpers — little-endian
// ═══════════════════════════════════════════════════════════════════════════

int u16le(Uint8List b, int off) => (b[off + 1] << 8) | b[off];
int u32le(Uint8List b, int off) =>
    (b[off + 3] << 24) | (b[off + 2] << 16) | (b[off + 1] << 8) | b[off];

/// Read a null-terminated (or space-padded) ASCII string from [b] at [off]
/// of at most [maxLen] bytes.  Stops at NUL or first 0x00 byte.
String _readNullTerm(Uint8List b, int off, int maxLen) {
  final end = off + maxLen > b.length ? b.length : off + maxLen;
  int i = off;
  while (i < end && b[i] != 0) {
    i++;
  }
  return String.fromCharCodes(b.skip(off).take(i - off));
}

// ═══════════════════════════════════════════════════════════════════════════
// System ANSI codec decode (GBK on Chinese Windows, etc.)
// ═══════════════════════════════════════════════════════════════════════════

const _fileOpsChannel = MethodChannel('com.xmate/fileops');

Future<String> _decodeSystemEncoding(Uint8List bytes) async {
  try {
    // decodeFilename uses MultiByteToWideChar(CP_ACP) → WideCharToMultiByte(UTF-8)
    final result = await _fileOpsChannel.invokeMethod<String>(
      'decodeFilename',
      {'bytes': bytes.toList()}, // MethodChannel needs a List<int>
    );
    if (result != null && result.isNotEmpty) return result;
  } catch (_) {}
  // Fallback: keep the CP437-decoded name
  return String.fromCharCodes(bytes.map(_cp437toUnicode));
}

// ═══════════════════════════════════════════════════════════════════════════
// CP437 → Unicode mapping (the upper 128 codepoints)
// ═══════════════════════════════════════════════════════════════════════════

const _cp437 = [
  0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7, // 80-87
  0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5, // 88-8F
  0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9, // 90-97
  0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192, // 98-9F
  0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA, // A0-A7
  0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB, // A8-AF
  0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556, // B0-B7
  0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510, // B8-BF
  0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F, // C0-C7
  0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567, // C8-CF
  0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B, // D0-D7
  0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580, // D8-DF
  0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4, // E0-E7
  0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229, // E8-EF
  0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248, // F0-F7
  0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0, // F8-FF
];

int _cp437toUnicode(int b) {
  if (b < 0x80) return b;
  return _cp437[b - 0x80];
}
