/// XMate Dictionary Service — SQLite-backed English-Chinese dictionary.
///
/// Based on ECDICT schema (skywind3000/ECDICT).
/// Manages database lifecycle, queries, and CSV import.
///
/// Usage:
/// ```dart
/// final ds = DictionaryService();
/// await ds.init();                          // init FFI + DB
/// await ds.openDatabase('/path/to/ecdict.db');
/// final result = ds.query('hello');           // exact match
/// final suggestions = ds.match('percei');     // prefix match
/// final stats = ds.getStats();               // entry count
/// ```
library;

import 'dart:async';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/utils/logger.dart';
import 'dictionary_models.dart';

class DictionaryService {
  static final DictionaryService _instance = DictionaryService._();
  factory DictionaryService() => _instance;
  DictionaryService._();

  Database? _db;
  String? _activeDbPath;
  bool _initialized = false;
  final LemmaDB _lemma = LemmaDB();

  /// Whether a database is currently open and ready.
  bool get isOpen => _db != null && _db!.isOpen;

  /// Path to the currently open database file.
  String? get activeDbPath => _activeDbPath;

  // ─── Lifecycle ────────────────────────────────────────────────

  /// Initialize SQLite FFI and the service. Call once at startup.
  Future<void> init() async {
    if (_initialized) return;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _initialized = true;
    logger.info('DictionaryService: FFI initialized');
  }

  /// Open a dictionary database file. Creates table + indexes if needed.
  Future<void> openDatabase(String dbPath) async {
    _ensureInit();
    // Close any previously open database.
    await closeDatabase();

    final normPath = _normalizePath(dbPath);
    logger.info('DictionaryService: opening $normPath');

    _db = await databaseFactoryFfi.openDatabase(
      normPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) => _createSchema(db),
        onConfigure: (db) async {
          await db.execute('PRAGMA journal_mode = WAL');
          await db.execute('PRAGMA synchronous = NORMAL');
        },
      ),
    );

    // Ensure schema exists even if file was pre-existing.
    await _ensureSchema();
    await _ensureFts();

    _activeDbPath = normPath;
    logger.info('DictionaryService: database opened ($normPath)');
  }

  /// Create a new empty database at the service-managed directory.
  /// If [dbPath] is omitted, creates at {appSupportDir}/xmate/dictionaries/ecdict.db.
  Future<String> createDatabase([String? dbPath]) async {
    _ensureInit();

    String path;
    if (dbPath != null) {
      path = dbPath;
    } else {
      final dir = await getApplicationSupportDirectory();
      final dictDir = Directory('${dir.path}/xmate/dictionaries');
      if (!await dictDir.exists()) {
        await dictDir.create(recursive: true);
      }
      path = '${dictDir.path}/ecdict.db';
    }

    await openDatabase(path);
    return path;
  }

  /// Close the currently open database.
  Future<void> closeDatabase() async {
    if (_db != null && _db!.isOpen) {
      await _db!.close();
      logger.info('DictionaryService: database closed');
    }
    _db = null;
    _activeDbPath = null;
  }

  /// Release all resources. Call on app exit.
  Future<void> dispose() async {
    await closeDatabase();
    _initialized = false;
  }

  // ─── Schema ──────────────────────────────────────────────────

  void _ensureInit() {
    if (!_initialized) {
      throw StateError('DictionaryService not initialized. Call init() first.');
    }
  }

  Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS "stardict" (
        "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL UNIQUE,
        "word" VARCHAR(64) COLLATE NOCASE NOT NULL UNIQUE,
        "sw" VARCHAR(64) COLLATE NOCASE NOT NULL,
        "phonetic" VARCHAR(64),
        "definition" TEXT,
        "translation" TEXT,
        "pos" VARCHAR(16),
        "collins" INTEGER DEFAULT(0),
        "oxford" INTEGER DEFAULT(0),
        "tag" VARCHAR(64),
        "bnc" INTEGER DEFAULT(NULL),
        "frq" INTEGER DEFAULT(NULL),
        "exchange" TEXT,
        "detail" TEXT,
        "audio" TEXT
      )
    ''');
    await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS "stardict_2" ON stardict (id)');
    await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS "stardict_3" ON stardict (word)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS "stardict_4" ON stardict (sw, word collate nocase)');
    logger.info('DictionaryService: schema created');
  }

  /// Ensure schema exists on a pre-existing DB that might not have it yet.
  Future<void> _ensureSchema() async {
    if (_db == null) return;
    final result = await _db!.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='stardict'",
    );
    if (result.isEmpty) {
      await _createSchema(_db!);
    }
  }

  /// Ensure FTS5 index exists for bidirectional search.
  /// Creates the virtual table if missing, and populates it from existing data
  /// if the table is empty (handles pre-FTS5 DBs and import).
  Future<void> _ensureFts() async {
    if (_db == null || !_db!.isOpen) return;

    // Create FTS5 table if missing.
    await _db!.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS stardict_fts USING fts5(
        word,
        translation,
        definition,
        tokenize='unicode61 remove_diacritics 1'
      )
    ''');

    // Check if FTS is empty (first run or after import).
    final cnt = await _db!.rawQuery(
      'SELECT COUNT(*) as c FROM stardict_fts',
    );
    final ftsCount = cnt.first['c'] as int? ?? 0;
    final totalCount =
        (await _db!.rawQuery('SELECT COUNT(*) as c FROM stardict'))
            .first['c'] as int? ?? 0;

    if (ftsCount < totalCount) {
      logger.info(
          'DictionaryService: populating FTS5 index ($ftsCount/$totalCount)...');
      await _db!.execute('DELETE FROM stardict_fts');
      await _db!.execute(
        'INSERT INTO stardict_fts(rowid, word, translation, definition) '
        'SELECT id, word, translation, definition FROM stardict',
      );
      logger.info('DictionaryService: FTS5 index ready');
    }
  }

  // ─── Query ───────────────────────────────────────────────────

  /// Exact word lookup (case-insensitive).
  /// Returns null if not found.
  Future<WordEntry?> query(String word) async {
    if (_db == null || !_db!.isOpen) return null;
    final results = await _db!.query(
      'stardict',
      where: 'word = ? COLLATE NOCASE',
      whereArgs: [word.trim()],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return WordEntry.fromMap(results.first);
  }

  /// Prefix match — words starting with [prefix] (case-insensitive).
  /// Returns up to [limit] suggestions sorted alphabetically.
  Future<List<WordEntry>> match(String prefix, {int limit = 20}) async {
    if (_db == null || !_db!.isOpen) return [];
    final results = await _db!.rawQuery(
      'SELECT * FROM stardict WHERE word >= ? '
      'ORDER BY word COLLATE NOCASE LIMIT ?',
      [prefix.trim(), limit],
    );
    return results.map((r) => WordEntry.fromMap(r)).toList();
  }

  /// FTS5 full-text search across word, translation, and definition.
  ///
  /// Used for Chinese→English search and fuzzy English search.
  /// Ranks by BM25 relevance, boosted by dictionary quality signals
  /// (Collins stars, BNC frequency, Frq) so common words surface first.
  Future<List<WordEntry>> searchFts(String query, {int limit = 50}) async {
    if (_db == null || !_db!.isOpen) return [];
    final results = await _db!.rawQuery(
      'SELECT s.* FROM stardict s '
      'JOIN stardict_fts fts ON s.id = fts.rowid '
      'WHERE stardict_fts MATCH ? '
      'ORDER BY '
      '  s.collins DESC, '      // Collins stars (5=best) first
      '  s.frq DESC, '          // higher frequency = more common
      '  s.bnc ASC, '           // lower BNC rank = more common
      '  rank '                 // BM25 tiebreaker
      'LIMIT ?',
      [_ftsQuery(query), limit],
    );
    return results.map((r) => WordEntry.fromMap(r)).toList();
  }

  /// Get a random word entry with a Chinese translation.
  /// Optionally filtered to one or more exam tags (e.g. ["cet4", "cet6"]).
  /// Pass an empty list to get words with no tags at all.
  /// Pass null to get any random word (no tag filter).
  Future<WordEntry?> randomWord({List<String>? tags}) async {
    if (_db == null || !_db!.isOpen) return null;

    if (tags != null && tags.isEmpty) {
      // User selected "No Tag" — find words with no exam tags.
      final results = await _db!.rawQuery(
        "SELECT * FROM stardict WHERE translation != '' AND (tag IS NULL OR tag = '') "
        "ORDER BY RANDOM() LIMIT 1",
      );
      if (results.isEmpty) return null;
      return WordEntry.fromMap(results.first);
    }

    if (tags != null && tags.isNotEmpty) {
      // Build OR conditions for each tag.
      final conditions = tags.map((_) => 'tag LIKE ?').join(' OR ');
      final params = tags.map((t) => '%$t%').toList();
      final results = await _db!.rawQuery(
        "SELECT * FROM stardict WHERE translation != '' AND ($conditions) "
        "ORDER BY RANDOM() LIMIT 1",
        params,
      );
      if (results.isEmpty) return null;
      return WordEntry.fromMap(results.first);
    }

    // No filter — any word with a Chinese translation.
    final results = await _db!.rawQuery(
      "SELECT * FROM stardict WHERE translation != '' "
      "ORDER BY RANDOM() LIMIT 1",
    );
    if (results.isEmpty) return null;
    return WordEntry.fromMap(results.first);
  }

  /// Smart search: routes Chinese queries to FTS, English queries to
  /// exact → lemma → prefix chain. Automatically falls back to FTS if
  /// English prefix search returns nothing.
  Future<List<WordEntry>> smartSearch(String query, {int limit = 20}) async {
    if (_db == null || !_db!.isOpen) return [];

    final q = query.trim();
    if (q.isEmpty) return [];

    // ── Chinese input → FTS full-text search ──
    if (_isChinese(q)) {
      return searchFts(q, limit: limit);
    }

    // ── English input: exact → lemma → prefix → FTS fallback ──

    // 1. Exact match
    final exact = await this.query(q);

    // 2. Lemma lookup (inflected forms)
    WordEntry? lemmaEntry;
    if (exact == null && _lemma.isLoaded) {
      final stems = _lemma.wordStem(q);
      for (final stem in stems) {
        if (stem == q.toLowerCase()) continue;
        final e = await this.query(stem);
        if (e != null) {
          lemmaEntry = e;
          break;
        }
      }
    }

    // 3. Prefix match
    final prefix = await match(q, limit: limit);

    final seenIds = <int>{};
    final results = <WordEntry>[];
    if (exact != null) {
      results.add(exact);
      seenIds.add(exact.id);
    }
    if (lemmaEntry != null && !seenIds.contains(lemmaEntry.id)) {
      results.add(lemmaEntry);
      seenIds.add(lemmaEntry.id);
    }
    for (final p in prefix) {
      if (results.length >= limit) break;
      if (!seenIds.contains(p.id)) {
        results.add(p);
        seenIds.add(p.id);
      }
    }

    // 4. FTS fallback: if prefix + exact yielded too few results,
    //    fill remaining slots with FTS matches (catches partial matches)
    if (results.length < limit) {
      final ftsResults = await searchFts(q, limit: limit);
      for (final f in ftsResults) {
        if (results.length >= limit) break;
        if (!seenIds.contains(f.id)) {
          results.add(f);
          seenIds.add(f.id);
        }
      }
    }

    return results;
  }

  // ─── Lemma ───────────────────────────────────────────────────

  /// Load the lemma database from a ECDICT `lemma.en.txt` file.
  /// Enables lemmatized search (e.g. "gave" → "give").
  void loadLemmaFromFile(String path) {
    _lemma.loadFromFile(path);
    logger.info('DictionaryService: lemma loaded (${_lemma.wordCount} words)');
  }

  /// Load lemma data from the bundled asset file.
  /// Called automatically by [init()]. No-op if already loaded.
  Future<void> loadLemmaFromAsset() async {
    if (_lemma.isLoaded) return;
    try {
      final content = await rootBundle.loadString('assets/dict/lemma.en.txt');
      _lemma.loadFromString(content);
      logger.info('DictionaryService: lemma loaded from assets (${_lemma.wordCount} words)');
    } catch (e) {
      logger.warn('DictionaryService: failed to load lemma from assets: $e');
    }
  }

  /// Check if lemmatizer is loaded.
  bool get lemmaLoaded => _lemma.isLoaded;

  /// Number of word→stem mappings in the lemmatizer.
  int get lemmaWordCount => _lemma.wordCount;

  /// Get the set of all distinct exam tags in the current database.
  Future<List<String>> getTags() async {
    if (_db == null || !_db!.isOpen) return [];
    final results = await _db!.rawQuery(
      "SELECT DISTINCT tag FROM stardict WHERE tag IS NOT NULL AND tag != ''",
    );
    final tags = <String>{};
    for (final r in results) {
      final raw = r['tag'] as String? ?? '';
      tags.addAll(raw.split(RegExp(r'\s+')).where((t) => t.isNotEmpty));
    }
    final sorted = tags.toList()..sort();
    return sorted;
  }

  // ─── Stats ───────────────────────────────────────────────────

  /// Get total entry count and DB file size.
  Future<({int entryCount, int fileSize})> getStats() async {
    if (_db == null || !_db!.isOpen) return (entryCount: 0, fileSize: 0);
    final countResult =
        await _db!.rawQuery('SELECT COUNT(*) as cnt FROM stardict');
    final entryCount = countResult.first['cnt'] as int? ?? 0;

    int fileSize = 0;
    if (_activeDbPath != null) {
      try {
        fileSize = File(_activeDbPath!).lengthSync();
      } catch (_) {}
    }
    return (entryCount: entryCount, fileSize: fileSize);
  }

  // ─── CSV Import ──────────────────────────────────────────────

  /// Import entries from an ECDICT CSV file.
  ///
  /// CSV format (13 columns):
  ///   word, phonetic, definition, translation, pos, collins, oxford,
  ///   tag, bnc, frq, exchange, detail, audio
  ///
  /// Optimized for speed: parses all rows in one pass, then bulk-inserts
  /// in large batches within a single transaction.
  ///
  /// [onProgress] is called periodically with import status.
  /// Returns the number of imported entries.
  Future<int> importCsv(
    String csvPath, {
    void Function(ImportProgress)? onProgress,
  }) async {
    if (_db == null || !_db!.isOpen) {
      throw StateError('No database open. Call openDatabase() first.');
    }

    final normPath = _normalizePath(csvPath);
    final file = File(normPath);
    if (!await file.exists()) {
      throw Exception('CSV file not found: $normPath');
    }

    final fileSize = await file.length();

    onProgress?.call(ImportProgress(
      state: ImportState.parsing,
      totalLines: fileSize ~/ 80,
      message: 'Reading CSV file...',
    ));

    // Read entire file (66 MB is fine for a desktop app on modern hardware).
    final content = await file.readAsString();
    final rows = const CsvToListConverter(
      fieldDelimiter: ',',
      textDelimiter: '"',
    ).convert(content);

    if (rows.isEmpty) {
      throw Exception('CSV file is empty or could not be parsed');
    }

    // Skip header row.
    int start = 0;
    if (rows.first.length >= 3 &&
        rows.first[0].toString().trim().toLowerCase() == 'word') {
      start = 1;
    }

    final total = rows.length - start;

    onProgress?.call(ImportProgress(
      state: ImportState.importing,
      totalLines: total,
      message: 'Parsed $total rows. Inserting...',
    ));

    // Drop indexes before bulk insert for massive speed gain.
    await _db!.execute('DROP INDEX IF EXISTS "stardict_2"');
    await _db!.execute('DROP INDEX IF EXISTS "stardict_3"');
    await _db!.execute('DROP INDEX IF EXISTS "stardict_4"');

    int imported = 0;
    int skipped = 0;
    const batchSize = 5000;

    // Single transaction for the entire import.
    await _db!.transaction((txn) async {
      for (int i = start; i < rows.length; i += batchSize) {
        final end = (i + batchSize).clamp(0, rows.length);
        final buf = StringBuffer();
        buf.write('INSERT OR IGNORE INTO stardict '
            '(word, sw, phonetic, definition, translation, pos, '
            'collins, oxford, tag, bnc, frq, exchange, detail, audio) VALUES ');

        final values = <String>[];
        for (int j = i; j < end; j++) {
          final fields = rows[j];
          if (fields.length < 4) continue;
          final word = _q(fields, 0);
          if (word.isEmpty) continue;
          final sw =
              _q(fields, 0).replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
          values.add(
            "(${_qv(word)},${_qv(sw)},${_qv2(fields, 1)},${_qv2(fields, 2)},"
            "${_qv2(fields, 3)},${_qv2(fields, 4)},"
            "${_qint(fields, 5)},${_qint(fields, 6)},${_qv2(fields, 7)},"
            "${_qnull(fields, 8)},${_qnull(fields, 9)},${_qv2(fields, 10)},"
            "${_qv2(fields, 11)},${_qv2(fields, 12)})",
          );
        }

        if (values.isEmpty) continue;

        buf.write(values.join(','));
        buf.write(';');

        try {
          await txn.execute(buf.toString());
          imported += values.length;
        } catch (_) {
          skipped += values.length;
        }

        // Progress every 5 batches.
        if (i % (batchSize * 5) == 0 || end >= rows.length) {
          onProgress?.call(ImportProgress(
            state: ImportState.importing,
            parsedLines: end,
            importedLines: imported,
            totalLines: total,
            skippedLines: skipped,
            message: 'Imported $imported / $total entries...',
          ));
        }
      }
    });

    // Re-create indexes after bulk import.
    onProgress?.call(ImportProgress(
      state: ImportState.indexing,
      parsedLines: total,
      importedLines: imported,
      totalLines: total,
      skippedLines: skipped,
      message: 'Creating indexes...',
    ));

    await _ensureSchema();
    await _ensureFts(); // populate FTS5 after import

    onProgress?.call(ImportProgress(
      state: ImportState.done,
      parsedLines: total,
      importedLines: imported,
      totalLines: total,
      skippedLines: skipped,
      message: 'Done: $imported entries imported ($skipped duplicates).',
    ));

    logger.info(
        'DictionaryService: CSV import done — $imported entries, $skipped skipped');
    return imported;
  }

  // ─── Combine CSV ────────────────────────────────────────────

  /// Combine entries from an ECDICT CSV file into the current database.
  ///
  /// Unlike [importCsv] (INSERT OR IGNORE — skip duplicates entirely),
  /// this method **merges** new data into existing entries:
  ///
  /// | Field type   | Strategy                                      |
  /// |-------------|-----------------------------------------------|
  /// | Quality     | collins, oxford, frq → take the MAX           |
  /// |             | bnc → take the MIN (lower rank = more common) |
  /// | Text        | phonetic, definition, translation, pos,       |
  /// |             | exchange, detail, audio → fill blanks only     |
  /// | Tags        | merge &amp; dedup (e.g. "cet4 cet6" + "ielts" |
  /// |             | → "cet4 cet6 ielts")                          |
  /// | New words   | inserted as-is                                |
  ///
  /// Returns the total number of entries processed (new + merged).
  Future<int> combineCsv(
    String csvPath, {
    void Function(ImportProgress)? onProgress,
  }) async {
    if (_db == null || !_db!.isOpen) {
      throw StateError('No database open. Call openDatabase() first.');
    }

    final normPath = _normalizePath(csvPath);
    final file = File(normPath);
    if (!await file.exists()) {
      throw Exception('CSV file not found: $normPath');
    }

    onProgress?.call(ImportProgress(
      state: ImportState.parsing,
      totalLines: 0,
      message: 'Reading CSV file...',
    ));

    // Read entire file.
    final content = await file.readAsString();
    final rows = const CsvToListConverter(
      fieldDelimiter: ',',
      textDelimiter: '"',
    ).convert(content);

    if (rows.isEmpty) {
      throw Exception('CSV file is empty or could not be parsed');
    }

    // Skip header row.
    int start = 0;
    if (rows.first.length >= 3 &&
        rows.first[0].toString().trim().toLowerCase() == 'word') {
      start = 1;
    }

    final total = rows.length - start;

    onProgress?.call(ImportProgress(
      state: ImportState.importing,
      totalLines: total,
      message: 'Parsed $total rows. Combining...',
    ));

    // Drop indexes before bulk merge for speed.
    await _db!.execute('DROP INDEX IF EXISTS "stardict_2"');
    await _db!.execute('DROP INDEX IF EXISTS "stardict_3"');
    await _db!.execute('DROP INDEX IF EXISTS "stardict_4"');

    int imported = 0; // brand new rows
    int merged = 0; // existing rows updated
    const batchSize = 2000;

    await _db!.transaction((txn) async {
      for (int i = start; i < rows.length; i += batchSize) {
        final end = (i + batchSize).clamp(0, rows.length);

        // Parse batch rows into maps, keyed by lowercase word.
        final batchRows = <String, Map<String, dynamic>>{};

        for (int j = i; j < end; j++) {
          final fields = rows[j];
          if (fields.length < 4) continue;
          final word = _q(fields, 0);
          if (word.isEmpty) continue;

          final sw = word
              .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
              .toLowerCase();

          batchRows[word.toLowerCase()] = {
            'word': word,
            'sw': sw,
            'phonetic': _q(fields, 1),
            'definition': _q(fields, 2),
            'translation': _q(fields, 3),
            'pos': _q(fields, 4),
            'collins': int.tryParse(_q(fields, 5)) ?? 0,
            'oxford': int.tryParse(_q(fields, 6)) ?? 0,
            'tag': _q(fields, 7),
            'bnc': int.tryParse(_q(fields, 8)),
            'frq': int.tryParse(_q(fields, 9)),
            'exchange': _q(fields, 10),
            'detail': _q(fields, 11),
            'audio': _q(fields, 12),
          };
        }

        if (batchRows.isEmpty) continue;

        // Query existing words in this batch (case-insensitive via COLLATE NOCASE).
        final words = batchRows.keys.toList();
        final placeholders = List.filled(words.length, '?').join(',');
        final existingRows = await txn.rawQuery(
          'SELECT * FROM stardict WHERE word COLLATE NOCASE IN ($placeholders)',
          words,
        );

        // Build set of lowercased existing words for quick membership test.
        final existingWordsLower =
            existingRows.map((r) => (r['word'] as String).toLowerCase()).toSet();

        // ── New rows: batch INSERT ──
        final newRows = <Map<String, dynamic>>[];
        for (final entry in batchRows.entries) {
          if (!existingWordsLower.contains(entry.key)) {
            newRows.add(entry.value);
          }
        }

        if (newRows.isNotEmpty) {
          final buf = StringBuffer();
          buf.write('INSERT OR IGNORE INTO stardict '
              '(word, sw, phonetic, definition, translation, pos, '
              'collins, oxford, tag, bnc, frq, exchange, detail, audio) VALUES ');

          final values = newRows.map((r) {
            return "(${_qv(r['word'])},${_qv(r['sw'])},${_qv(r['phonetic'])},"
                "${_qv(r['definition'])},${_qv(r['translation'])},${_qv(r['pos'])},"
                "${r['collins']},${r['oxford']},${_qv(r['tag'])},"
                "${r['bnc'] ?? 'NULL'},"
                "${r['frq'] ?? 'NULL'},"
                "${_qv(r['exchange'])},${_qv(r['detail'])},${_qv(r['audio'])})";
          }).join(',');

          buf.write(values);
          buf.write(';');

          await txn.execute(buf.toString());
          imported += newRows.length;
        }

        // ── Existing rows: merge & batch UPDATE ──
        if (existingRows.isNotEmpty) {
          // Build UPDATE statements in sub-batches of 100 for speed.
          int mergedInBatch = 0;
          final updateBuf = StringBuffer();

          for (final existing in existingRows) {
            final existingWord = (existing['word'] as String).toLowerCase();
            final csvRow = batchRows[existingWord];
            if (csvRow == null) continue;

            final changed = _mergeEntry(existing, csvRow);

            // Build individual UPDATE (multi-statement SQL).
            updateBuf.write(
              "UPDATE stardict SET "
              "collins=${changed['collins'] ?? 0},"
              "oxford=${changed['oxford'] ?? 0},"
              "bnc=${changed['bnc'] ?? 'NULL'},"
              "frq=${changed['frq'] ?? 'NULL'},"
              "phonetic=${_qv(changed['phonetic'] as String? ?? '')},"
              "definition=${_qv(changed['definition'] as String? ?? '')},"
              "translation=${_qv(changed['translation'] as String? ?? '')},"
              "pos=${_qv(changed['pos'] as String? ?? '')},"
              "exchange=${_qv(changed['exchange'] as String? ?? '')},"
              "detail=${_qv(changed['detail'] as String? ?? '')},"
              "audio=${_qv(changed['audio'] as String? ?? '')},"
              "tag=${_qv(changed['tag'] as String? ?? '')} "
              "WHERE word=${_qv(existing['word'] as String)};",
            );

            mergedInBatch++;

            // Flush every 100 UPDATEs.
            if (mergedInBatch % 100 == 0) {
              await txn.execute(updateBuf.toString());
              updateBuf.clear();
              merged += mergedInBatch;
              mergedInBatch = 0;
            }
          }

          // Flush remaining UPDATEs.
          if (updateBuf.isNotEmpty) {
            await txn.execute(updateBuf.toString());
            merged += mergedInBatch;
          }
        }

        // Progress every 5 batches.
        if (i % (batchSize * 5) == 0 || end >= rows.length) {
          onProgress?.call(ImportProgress(
            state: ImportState.importing,
            parsedLines: end,
            importedLines: imported + merged,
            totalLines: total,
            message: 'New: $imported  Merged: $merged  / $total',
          ));
        }
      }
    });

    // Rebuild indexes + FTS after merge.
    onProgress?.call(ImportProgress(
      state: ImportState.indexing,
      totalLines: total,
      importedLines: imported + merged,
      message: 'Rebuilding indexes...',
    ));

    await _ensureSchema();
    await _ensureFts();

    onProgress?.call(ImportProgress(
      state: ImportState.done,
      totalLines: total,
      importedLines: imported + merged,
      message: 'Done: $imported new + $merged merged.',
    ));

    logger.info(
        'DictionaryService: CSV combine done — $imported new, $merged merged');
    return imported + merged;
  }

  /// Merge a CSV row into an existing stardict row.
  ///
  /// - Quality indicators (collins, oxford, frq): MAX
  /// - bnc: MIN (lower rank = more common)
  /// - Text fields: keep existing value if non-empty, otherwise use CSV
  /// - Tags: merge and dedup
  Map<String, dynamic> _mergeEntry(
    Map<String, dynamic> existing,
    Map<String, dynamic> csv,
  ) {
    final result = <String, dynamic>{};

    // Quality: take the better (MAX) value.
    final existingCollins = existing['collins'] as int? ?? 0;
    final csvCollins = csv['collins'] as int? ?? 0;
    result['collins'] =
        existingCollins > csvCollins ? existingCollins : csvCollins;

    final existingOxford = existing['oxford'] as int? ?? 0;
    final csvOxford = csv['oxford'] as int? ?? 0;
    result['oxford'] =
        existingOxford > csvOxford ? existingOxford : csvOxford;

    // bnc: lower rank = more common → take MIN of non-null values.
    final existingBnc = existing['bnc'] as int?;
    final csvBnc = csv['bnc'] as int?;
    if (existingBnc == null) {
      result['bnc'] = csvBnc;
    } else if (csvBnc == null) {
      result['bnc'] = existingBnc;
    } else {
      result['bnc'] = existingBnc < csvBnc ? existingBnc : csvBnc;
    }

    // frq: higher = more common → take MAX.
    final existingFrq = existing['frq'] as int?;
    final csvFrq = csv['frq'] as int?;
    if (existingFrq == null) {
      result['frq'] = csvFrq;
    } else if (csvFrq == null) {
      result['frq'] = existingFrq;
    } else {
      result['frq'] = existingFrq > csvFrq ? existingFrq : csvFrq;
    }

    // Text fields: keep existing if non-empty, otherwise fill from CSV.
    for (final field in [
      'phonetic',
      'definition',
      'translation',
      'pos',
      'exchange',
      'detail',
      'audio',
    ]) {
      final existingVal = (existing[field] as String? ?? '').trim();
      final csvVal = (csv[field] as String? ?? '').trim();
      result[field] = existingVal.isNotEmpty ? existingVal : csvVal;
    }

    // Tags: merge + dedup.
    final existingTags = (existing['tag'] as String? ?? '').trim();
    final csvTags = (csv['tag'] as String? ?? '').trim();
    if (existingTags.isEmpty) {
      result['tag'] = csvTags;
    } else if (csvTags.isEmpty) {
      result['tag'] = existingTags;
    } else {
      final merged = <String>{};
      merged.addAll(
          existingTags.split(RegExp(r'\s+')).where((t) => t.isNotEmpty));
      merged.addAll(
          csvTags.split(RegExp(r'\s+')).where((t) => t.isNotEmpty));
      result['tag'] = merged.join(' ');
    }

    return result;
  }

  // ─── Helpers ─────────────────────────────────────────────────

  String _normalizePath(String path) =>
      path.replaceAll('\\', '/').replaceAll('//', '/');

  /// Get string value from CSV row, trimmed.
  String _q(List<dynamic> row, int i) =>
      i < row.length ? row[i].toString().trim() : '';

  /// Quote and escape a string value for raw SQL.
  String _qv(String s) => "'${s.replaceAll("'", "''")}'";

  /// Get row value by index and quote it.
  String _qv2(List<dynamic> row, int i) => _qv(_q(row, i));

  /// Get int value from row, render as SQL literal.
  String _qint(List<dynamic> row, int i) {
    if (i >= row.length) return '0';
    final v = row[i];
    if (v == null || v == '') return '0';
    return int.tryParse(v.toString())?.toString() ?? '0';
  }

  /// Get int-or-null from row, render as SQL NULL or literal.
  String _qnull(List<dynamic> row, int i) {
    if (i >= row.length) return 'NULL';
    final v = row[i];
    if (v == null || v == '') return 'NULL';
    final parsed = int.tryParse(v.toString());
    return parsed != null ? parsed.toString() : 'NULL';
  }

  /// Check if a string contains any CJK character.
  bool _isChinese(String s) {
    for (int i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if ((c >= 0x4E00 && c <= 0x9FFF) || // CJK Unified
          (c >= 0x3400 && c <= 0x4DBF) || // CJK Extension A
          (c >= 0xF900 && c <= 0xFAFF)) {
        // CJK Compatibility
        return true;
      }
    }
    return false;
  }

  /// Build a safe FTS5 query string. Escapes characters that FTS5 treats
  /// as syntax, and quotes multi-word queries. Prefix each term with a
  /// wildcard so partial matches work too.
  String _ftsQuery(String q) {
    // Escape FTS5 syntax characters.
    final escaped = q
        .replaceAll('*', '')
        .replaceAll('"', '')
        .replaceAll("'", '')
        .replaceAll('(', '')
        .replaceAll(')', '')
        .replaceAll('-', '')
        .replaceAll(':', '');

    final terms = escaped.trim().split(RegExp(r'\s+'));
    if (terms.length == 1 && terms.first.isNotEmpty) {
      // Single term: prefix match.
      return '"${terms.first}"*';
    }
    // Multiple terms: AND them, each with prefix.
    return terms.where((t) => t.isNotEmpty).map((t) => '"$t"*').join(' ');
  }
}
