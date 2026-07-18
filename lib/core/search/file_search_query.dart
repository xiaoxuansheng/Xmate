/// XMate File Search — Query parser.
///
/// Normalizes input, extracts trigrams from both text and pinyin initials,
/// parses filter keywords (ext:pdf).
library;

import 'file_pinyin_data.dart';
import 'file_trigram_index.dart';

/// Result of parsing a user search query.
class FileSearchQuery {
  final String originalInput;
  final String normalizedText; // lowercased original (Chinese preserved)
  final String pinyinText; // Chinese chars → pinyin initials
  final List<int> textTrigrams; // packed uint32 trigrams from normalizedText
  final List<int> pinyinTrigrams; // packed uint32 trigrams from pinyinText
  final List<String> extFilters; // ext:pdf → "pdf"
  final List<String> pathFilters; // path:src → "src"

  const FileSearchQuery._({
    required this.originalInput,
    required this.normalizedText,
    required this.pinyinText,
    required this.textTrigrams,
    required this.pinyinTrigrams,
    required this.extFilters,
    required this.pathFilters,
  });

  /// Whether this query has enough structure to produce trigrams.
  bool get hasTextTrigrams => textTrigrams.isNotEmpty;
  bool get hasPinyinTrigrams => pinyinTrigrams.isNotEmpty;
  bool get isValid => hasTextTrigrams || hasPinyinTrigrams;

  @override
  String toString() =>
      'FileSearchQuery("$originalInput" text=${textTrigrams.length}trigrams pinyin=${pinyinTrigrams.length}trigrams'
      ' ext=$extFilters path=$pathFilters)';
}

/// Parse a user search query string.
///
/// Steps:
/// 1. Extract filter keywords (ext:xxx, path:xxx) — these are removed from the
///    search text.
/// 2. Normalize remaining text: lowercase.
/// 3. Build pinyin_initials version (Chinese chars → initials).
/// 4. Extract UTF-8 bytes trigrams from both normalized text and pinyin.
///
/// Examples:
/// - "山东" → textTrigrams from "山东", pinyinTrigrams from "sd"
/// - "sd" → textTrigrams from "sd", pinyinTrigrams from "sd" (same)
/// - "readme ext:md" → textTrigrams from "readme", extFilters=["md"]
FileSearchQuery parseQuery(String input) {
  // 1. Extract filter keywords from the input
  String remaining = input;
  final extFilters = <String>[];
  final pathFilters = <String>[];

  // Match ext:xxx and path:xxx patterns (case-insensitive)
  final filterRe = RegExp(r'\b(ext|path):(\S+)', caseSensitive: false);
  remaining = remaining.replaceAllMapped(filterRe, (m) {
    final key = m.group(1)!.toLowerCase();
    final value = m.group(2)!.toLowerCase();
    if (key == 'ext') extFilters.add(value);
    if (key == 'path') pathFilters.add(value);
    return ''; // remove from search text
  });

  // Clean up multiple spaces
  remaining = remaining.replaceAll(RegExp(r'\s+'), ' ').trim();

  // 2. Normalize
  final normalizedText = remaining.toLowerCase();

  // 3. Build pinyin initials
  final pinyinText = toPinyinInitials(remaining);

  // 4. Extract UTF-8 bytes trigrams
  final textTrigrams = normalizedText.isNotEmpty
      ? extractTrigrams(normalizedText).toSet().toList()
      : <int>[];
  final pinyinTrigrams = pinyinText.isNotEmpty
      ? extractTrigrams(pinyinText).toSet().toList()
      : <int>[];

  return FileSearchQuery._(
    originalInput: input,
    normalizedText: normalizedText,
    pinyinText: pinyinText,
    textTrigrams: textTrigrams,
    pinyinTrigrams: pinyinTrigrams,
    extFilters: extFilters,
    pathFilters: pathFilters,
  );
}
