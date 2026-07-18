/// XMate Dictionary Plugin — data models
///
/// Based on ECDICT schema (skywind3000/ECDICT).
library;

import 'dart:convert';
import 'dart:io';

/// A single dictionary word entry (maps to stardict table row).
class WordEntry {
  final int id;
  final String word;
  final String? sw; // stripped word (for matching)
  final String? phonetic;
  final String? definition;
  final String? translation;
  final String? pos;
  final int collins;
  final bool oxford;
  final String? tag;
  final int? bnc;
  final int? frq;
  final String? exchange;
  final String? detail;
  final String? audio;

  const WordEntry({
    required this.id,
    required this.word,
    this.sw,
    this.phonetic,
    this.definition,
    this.translation,
    this.pos,
    this.collins = 0,
    this.oxford = false,
    this.tag,
    this.bnc,
    this.frq,
    this.exchange,
    this.detail,
    this.audio,
  });

  factory WordEntry.fromMap(Map<String, dynamic> map) {
    return WordEntry(
      id: map['id'] as int? ?? 0,
      word: map['word'] as String? ?? '',
      sw: map['sw'] as String?,
      phonetic: map['phonetic'] as String?,
      definition: map['definition'] as String?,
      translation: map['translation'] as String?,
      pos: map['pos'] as String?,
      collins: map['collins'] as int? ?? 0,
      oxford: (map['oxford'] as int? ?? 0) != 0,
      tag: map['tag'] as String?,
      bnc: map['bnc'] as int?,
      frq: map['frq'] as int?,
      exchange: map['exchange'] as String?,
      detail: map['detail'] as String?,
      audio: map['audio'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'word': word,
      'sw': sw ?? word,
      'phonetic': phonetic,
      'definition': definition,
      'translation': translation,
      'pos': pos,
      'collins': collins,
      'oxford': oxford ? 1 : 0,
      'tag': tag,
      'bnc': bnc,
      'frq': frq,
      'exchange': exchange,
      'detail': detail,
      'audio': audio,
    };
  }

  // ── Derived fields ────────────────────────────────────────────

  /// Parse exam tags into a list of individual tags (e.g. "cet4 cet6 ielts").
  List<String> get tagList {
    if (tag == null || tag!.isEmpty) return [];
    return tag!.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  }

  /// Collins star count as display string (e.g. "★★★").
  String get collinsStars => collins > 0 ? '★' * collins : '';

  /// Whether this is a known common word (Collins or Oxford flagged).
  bool get isCommon => collins > 0 || oxford;

  /// Parsed exchange entries as a list of (label, word) pairs.
  /// E.g. exchange JSON {"p":"took","d":"taken"} →
  ///   [("过去式", "took"), ("过去分词", "taken")]
  List<(String label, String word)> get exchangeDecoded {
    if (exchange == null || exchange!.isEmpty) return [];
    late Map<String, dynamic> map;
    try {
      map = json.decode(exchange!) as Map<String, dynamic>;
    } catch (_) {
      // Some entries use comma-separated format like "s:cats/p:catted"
      return _parseCompactExchange(exchange!);
    }

    final result = <(String, String)>[];
    for (final entry in map.entries) {
      final label = _kExchangeLabels[entry.key] ?? entry.key;
      final value = entry.value.toString();
      if (value.isNotEmpty) {
        result.add((label, value));
      }
    }
    return result;
  }

  @override
  String toString() => 'WordEntry($word, ${translation ?? ''})';
}

// ── Exchange code labels (from stardict.py DictHelper) ──────────

const _kExchangeLabels = <String, String>{
  'p': '过去式',
  'd': '过去分词',
  'i': '现在分词',
  '3': '三单',
  'r': '比较级',
  't': '最高级',
  's': '复数',
  '0': '原型',
  '1': '类别',
};

/// Parse compact exchange format: "s:cats/i:catting/p:catted/3:cats/d:catted"
List<(String, String)> _parseCompactExchange(String raw) {
  final result = <(String, String)>[];
  for (final part in raw.split('/')) {
    final colon = part.indexOf(':');
    if (colon < 1) continue;
    final code = part.substring(0, colon).trim();
    final word = part.substring(colon + 1).trim();
    if (code.isNotEmpty && word.isNotEmpty) {
      final label = _kExchangeLabels[code] ?? code;
      result.add((label, word));
    }
  }
  return result;
}

// ── POS single-letter code map (from stardict.py DictHelper) ───

const _kPosCodes = <String, String>{
  'a': '代词',
  'c': '连接词',
  'd': '限定词',
  'i': '介词',
  'j': '形容词',
  'm': '数词',
  'n': '名词',
  'p': '代词',
  'r': '副词',
  'u': '感叹词',
  't': '不定式标记',
  'v': '动词',
  'x': '否定标记',
};

/// Decode a single-letter POS code to Chinese name.
/// Returns null if the code is not recognized or input is already multi-char.
String? decodePosCode(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final trimmed = raw.trim();
  // Already human-readable (multi-char like "n.", "v./n.")
  if (trimmed.length > 1) return trimmed;
  return _kPosCodes[trimmed.toLowerCase()];
}

// ═══════════════════════════════════════════════════════════════
// Dictionary metadata & import models
// ═══════════════════════════════════════════════════════════════

/// Metadata about a dictionary database.
class DictionaryInfo {
  final int id;
  final String name;
  final String fileName;
  final int entryCount;
  final DateTime importedAt;
  final String? sourcePath;
  final bool isActive;

  const DictionaryInfo({
    required this.id,
    required this.name,
    required this.fileName,
    required this.entryCount,
    required this.importedAt,
    this.sourcePath,
    this.isActive = false,
  });

  factory DictionaryInfo.fromMap(Map<String, dynamic> map) {
    return DictionaryInfo(
      id: map['id'] as int? ?? 0,
      name: map['name'] as String? ?? '',
      fileName: map['file_name'] as String? ?? '',
      entryCount: map['entry_count'] as int? ?? 0,
      importedAt: DateTime.tryParse(map['imported_at'] as String? ?? '') ??
          DateTime(2000),
      sourcePath: map['source_path'] as String?,
      isActive: (map['is_active'] as int? ?? 0) != 0,
    );
  }
}

/// Import state machine.
enum ImportState { idle, parsing, importing, indexing, done, error }

/// Progress report during CSV import.
class ImportProgress {
  final ImportState state;
  final int parsedLines;
  final int importedLines;
  final int skippedLines;
  final int totalLines;
  final String? message;
  final String? error;

  const ImportProgress({
    this.state = ImportState.idle,
    this.parsedLines = 0,
    this.importedLines = 0,
    this.skippedLines = 0,
    this.totalLines = 0,
    this.message,
    this.error,
  });

  double? get percent {
    if (totalLines <= 0) return null;
    return importedLines / totalLines;
  }
}

// ═══════════════════════════════════════════════════════════════
// LemmaDB — word-form → base-form mapping
// ═══════════════════════════════════════════════════════════════

/// Word-form lemmatization database.
///
/// Loads the ECDICT `lemma.en.txt` file (~186K words → 84K lemmas).
/// Maps inflected forms to their base lemma, and vice versa.
///
/// Usage:
/// ```dart
/// final lemma = LemmaDB();
/// lemma.loadFromFile('/path/to/lemma.en.txt');
/// final base = lemma.wordStem('gave');   // → ['give']
/// final forms = lemma.expandStem('give'); // → ['gave', 'given', 'giving', 'gives']
/// ```
class LemmaDB {
  /// word → list of stems (usually 1)
  final Map<String, List<String>> _wordToStems = {};

  /// stem → list of inflected forms
  final Map<String, List<String>> _stemToWords = {};

  bool _loaded = false;
  bool get isLoaded => _loaded;

  /// Load from the ECDICT lemma.en.txt file.
  ///
  /// Format: `stem/frq -> word1,word2,word3,...`
  /// Lines starting with `;` are comments.
  void loadFromFile(String path) {
    final content = File(path).readAsStringSync();
    _loadContent(content);
  }

  /// Load from a string (e.g. from bundled assets).
  void loadFromString(String content) => _loadContent(content);

  void _loadContent(String content) {
    _loaded = false;
    _wordToStems.clear();
    _stemToWords.clear();

    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith(';')) continue;

      final arrow = line.indexOf('->');
      if (arrow < 0) continue;

      final left = line.substring(0, arrow).trim(); // stem/frq
      final right = line.substring(arrow + 2).trim(); // word1,word2,...

      // Extract stem (before /).
      final slash = left.indexOf('/');
      final stem = (slash >= 0 ? left.substring(0, slash) : left)
          .trim()
          .toLowerCase();
      if (stem.isEmpty) continue;

      // Extract inflected words.
      final words = right
          .split(',')
          .map((w) => w.trim().toLowerCase())
          .where((w) => w.isNotEmpty)
          .toList();

      // Map each inflected form → stem.
      for (final w in words) {
        _wordToStems.putIfAbsent(w, () => []).add(stem);
      }

      // Map stem → all inflected forms.
      _stemToWords[stem] = words;

      // Also map stem → itself (so "give" → ["give"] works).
      _wordToStems.putIfAbsent(stem, () => []).add(stem);
    }

    _loaded = true;
  }

  /// Find base lemmas for a given word form.
  /// `gave` → `['give']`,  `took` → `['take']`,  `cat` → `['cat']`
  List<String> wordStem(String word) {
    final w = word.trim().toLowerCase();
    return _wordToStems[w] ?? [w];
  }

  /// Find all inflected forms for a given stem.
  /// `give` → `['gave', 'given', 'giving', 'gives']`
  List<String> expandStem(String stem) {
    final s = stem.trim().toLowerCase();
    return _stemToWords[s] ?? [s];
  }

  /// Total number of word→stem mappings loaded.
  int get wordCount => _wordToStems.length;
}

