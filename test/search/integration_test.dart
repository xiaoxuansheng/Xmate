/// Integration test: trigram index write → load → search round-trip.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xmate/core/search/file_trigram_index.dart';
import 'package:xmate/core/search/file_pinyin_data.dart';
import 'package:xmate/core/search/file_search_query.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory testDir;
  final _tmpFiles = <File>[]; // track .xmfs files for cleanup

  setUp(() {
    final tmp = Directory.systemTemp;
    testDir = Directory('${tmp.path}/xmate_test_search');
    if (testDir.existsSync()) testDir.deleteSync(recursive: true);
    testDir.createSync(recursive: true);

    File('${testDir.path}/readme.txt').writeAsStringSync('test');
    File('${testDir.path}/hello_world.dart').writeAsStringSync('test');
    File('${testDir.path}/sd_utils.dart').writeAsStringSync('test');
    File('${testDir.path}/a_single_file.log').writeAsStringSync('test');
    File('${testDir.path}/sdbg_report.pdf').writeAsStringSync('test');
    File('${testDir.path}/cssj_data.csv').writeAsStringSync('test');
    Directory('${testDir.path}/src').createSync();
    File('${testDir.path}/src/main_app.dart').writeAsStringSync('test');
    File('${testDir.path}/src/utils_utils.dart').writeAsStringSync('test');
  });

  tearDown(() {
    // Close any lingering xmfs files
    for (final f in _tmpFiles) {
      try { f.deleteSync(); } catch (_) {}
    }
    _tmpFiles.clear();
    if (testDir.existsSync()) {
      try { testDir.deleteSync(recursive: true); } catch (_) {}
    }
  });

  // ── Helpers ──────────────────────────────────────────────────────────

  /// Write test index to temp (outside testDir to avoid locking) and return
  /// the loaded index + file handle.
  (FileTrigramIndex, RandomAccessFile) writeAndLoad(
    String tag,
    List<(int, String)> entries,
  ) {
    final tmpDir = Directory.systemTemp;
    final tmpFile = File('${tmpDir.path}/xmate_test_$tag.xmfs');
    _tmpFiles.add(tmpFile);

    // Write
    final rafW = tmpFile.openSync(mode: FileMode.write);
    FileTrigramIndex.buildAndWrite(rafW, entries);
    rafW.closeSync();

    // Load
    final rafR = tmpFile.openSync(mode: FileMode.read);
    final (index, _) = FileTrigramIndex.loadWithEnd(rafR, 0);
    return (index, rafR);
  }

  List<(int, String)> makeNameEntries(List<String> names) {
    return names.asMap().entries
        .map((e) => (e.key, e.value.toLowerCase()))
        .toList();
  }

  List<(int, String)> makePinyinEntries(List<String> names) {
    final result = <(int, String)>[];
    for (int i = 0; i < names.length; i++) {
      final p = toPinyinInitials(names[i]);
      if (p.isNotEmpty) result.add((i, p));
    }
    return result;
  }

  // ══════════════════════════════════════════════════════════════════════

  group('Trigram round-trip', () {
    test('write → load → search by trigram', () {
      final names = ['readme', 'hello_world', 'sd_utils', 'a_single_file'];
      final entries = makeNameEntries(names);
      final (index, raf) = writeAndLoad('rt', entries);

      expect(index.trigramCount, greaterThan(0));

      // Search "readme" trigrams — all must exist in index
      final query = extractTrigrams('readme');
      expect(query, isNotEmpty);
      for (final t in query) {
        final postings = index.readPostings(raf, t);
        expect(postings, isNotNull, reason: 'trigram 0x${t.toRadixString(16)} missing');
      }

      raf.closeSync();
    });
  });

  group('Pinyin initials', () {
    test('toPinyinInitials("山东") == "sd"', () {
      expect(toPinyinInitials('山东'), 'sd');
    });
    test('toPinyinInitials("测试") == "cs"', () {
      expect(toPinyinInitials('测试'), 'cs');
    });
    test('toPinyinInitials("文件") == "wj"', () {
      expect(toPinyinInitials('文件'), 'wj');
    });
  });

  group('Query parsing', () {
    test('parseQuery("sd") has trigrams', () {
      final q = parseQuery('sd');
      expect(q.hasTextTrigrams, isTrue);
    });
    test('parseQuery("山东") has pinyin', () {
      final q = parseQuery('山东');
      expect(q.pinyinText, 'sd');
    });
    test('parseQuery ext: filter', () {
      final q = parseQuery('readme ext:md');
      expect(q.extFilters, contains('md'));
    });
  });

  group('Search strategy', () {
    test('search("a") → short query UNION mode → non-empty', () {
      final names = ['readme', 'hello_world', 'sd_utils', 'a_single_file',
                     'main_app', '山东报告', '测试数据'];
      final entries = makeNameEntries(names);
      final (index, raf) = writeAndLoad('short', entries);

      final query = extractTrigrams('a');
      final result = searchTrigrams(raf, index, query);

      expect(result.isEmpty, isFalse,
          reason: 'search("a") UNION mode should produce candidates');
      expect(result.matchCounts.length, greaterThanOrEqualTo(1));

      raf.closeSync();
    });

    test('search("sd") → pinyin index matches Chinese initials', () {
      // Simulates real scenario: filenames "sd_utils" and "山东报告"
      // Pinyin: "sd_utils" → "sd_utils", "山东报告" → "sdbg"
      // "sd" should match both via pinyin trigrams
      final names = ['sd_utils', '山东报告', '测试数据', 'hello'];
      final pinyinEntries = makePinyinEntries(names);
      final (index, raf) = writeAndLoad('pinyin', pinyinEntries);

      final query = extractTrigrams('sd');
      final result = searchTrigrams(raf, index, query);

      // With ceil(N/2) filtering: 3 trigrams, need >=2
      // "sd_utils" matches $$s and $sd (2 of 3) → passes
      // "sdbg"/"山东报告" matches $$s and $sd (2 of 3) → passes
      expect(result.isEmpty, isFalse,
          reason: 'search("sd") should find Chinese pinyin matches');
      expect(result.matchCounts.length, greaterThanOrEqualTo(1));

      raf.closeSync();
    });

    test('search("测试") → Chinese name index match', () {
      final names = ['山东报告', '测试数据', 'utils_utils', 'hello'];
      final entries = makeNameEntries(names);
      final (index, raf) = writeAndLoad('cn', entries);

      final query = extractTrigrams('测试');
      final result = searchTrigrams(raf, index, query);

      // "测试" → 7 unique trigrams, N=4 intersect, need >=2
      // "测试数据" should match most of the 测试 trigrams
      expect(result.isEmpty, isFalse,
          reason: 'search("测试") should produce non-empty results');
      expect(result.matchCounts.length, greaterThanOrEqualTo(1));

      raf.closeSync();
    });
  });
}
