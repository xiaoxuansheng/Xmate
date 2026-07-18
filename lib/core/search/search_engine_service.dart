/// XMate search engine service
///
/// Manages configurable search engines across multiple categories and
/// executes web searches.  Supports two modes:
///   - copyMode=false: substitute {query} into URL template, open browser
///   - copyMode=true:  copy query to clipboard, then open URL (for AI chat)
library;

import 'dart:io';

import 'package:flutter/services.dart';

import '../settings/settings_service.dart';

// ── Category enum ────────────────────────────────────────────────

/// Category of search engine, determining which UI surfaces it appears in
/// and what execution behavior it follows.
enum SearchEngineCategory {
  text,       // web text search with {query} substitution
  image,      // image search (copy image to clipboard, then open engine URL)
  map,        // map / geolocation search
  translate,  // translation service search
  dictionary, // dictionary / word lookup
}

// ── Data model ───────────────────────────────────────────────────

class SearchEngine {
  String name;
  String url;
  bool copyMode;
  SearchEngineCategory category;

  SearchEngine({
    required this.name,
    required this.url,
    this.copyMode = false,
    this.category = SearchEngineCategory.text,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'copyMode': category == SearchEngineCategory.image ? true : copyMode,
        'category': category.name,
      };

  factory SearchEngine.fromJson(Map<String, dynamic> json) {
    final cat = _parseCategory(json['category'] as String?);
    return SearchEngine(
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
      copyMode:
          (json['copyMode'] as bool? ?? false) || cat == SearchEngineCategory.image,
      category: cat,
    );
  }

  static SearchEngineCategory _parseCategory(String? raw) {
    if (raw == null) return SearchEngineCategory.text;
    return SearchEngineCategory.values.firstWhere(
      (c) => c.name == raw,
      orElse: () => SearchEngineCategory.text,
    );
  }

  /// Shallow copy for UI state updates.
  SearchEngine copyWith({
    String? name,
    String? url,
    bool? copyMode,
    SearchEngineCategory? category,
  }) =>
      SearchEngine(
        name: name ?? this.name,
        url: url ?? this.url,
        copyMode: copyMode ?? this.copyMode,
        category: category ?? this.category,
      );
}

// ── Service ──────────────────────────────────────────────────────

class SearchEngineService {
  static const _kEngines = 'app.search.engines';

  final _settings = SettingsService();

  // ── Built-in defaults ──────────────────────────────────────────

  /// Built-in search engine defaults shipped on first run.
  static List<SearchEngine> _buildDefaults() => [
        // ── Text ──
        SearchEngine(
            name: 'Bing',
            url: 'https://www.bing.com/search?q={query}',
            category: SearchEngineCategory.text),
        SearchEngine(
            name: 'Google',
            url: 'https://www.google.com/search?q={query}',
            category: SearchEngineCategory.text),
        SearchEngine(
            name: 'Baidu',
            url: 'https://www.baidu.com/s?wd={query}',
            category: SearchEngineCategory.text),
        SearchEngine(
            name: 'Doubao',
            url: 'https://www.doubao.com/chat/',
            copyMode: true,
            category: SearchEngineCategory.text),
        SearchEngine(
            name: 'Qianwen',
            url: 'https://tongyi.aliyun.com/qianwen/',
            copyMode: true,
            category: SearchEngineCategory.text),
        // ── Image ──
        SearchEngine(
            name: 'Baidu Shitu',
            url: 'https://graph.baidu.com/pcpage/index',
            copyMode: true,
            category: SearchEngineCategory.image),
        SearchEngine(
            name: 'Google Images',
            url: 'https://www.google.com/imghp',
            copyMode: true,
            category: SearchEngineCategory.image),
        // ── Map ──
        SearchEngine(
            name: '百度地图',
            url: 'https://map.baidu.com/search/{query}',
            category: SearchEngineCategory.map),
        SearchEngine(
            name: '高德地图',
            url: 'https://ditu.amap.com/search?query={query}',
            category: SearchEngineCategory.map),
        SearchEngine(
            name: 'Google Maps',
            url: 'https://www.google.com/maps/search/{query}',
            category: SearchEngineCategory.map),
        // ── Translate ──
        SearchEngine(
            name: '百度翻译',
            url: 'https://fanyi.baidu.com/#auto/zh/{query}',
            category: SearchEngineCategory.translate),
        SearchEngine(
            name: 'Google Translate',
            url: 'https://translate.google.com/?text={query}',
            category: SearchEngineCategory.translate),
        SearchEngine(
            name: '有道翻译',
            url: 'https://fanyi.youdao.com/',
            copyMode: true,
            category: SearchEngineCategory.translate),
        // ── Dictionary ──
        SearchEngine(
            name: 'Cambridge',
            url: 'https://dictionary.cambridge.org/dictionary/english/{query}',
            category: SearchEngineCategory.dictionary),
        SearchEngine(
            name: 'Collins',
            url: 'https://www.collinsdictionary.com/dictionary/english/{query}',
            category: SearchEngineCategory.dictionary),
        SearchEngine(
            name: 'Merriam-Webster',
            url: 'https://www.merriam-webster.com/dictionary/{query}',
            category: SearchEngineCategory.dictionary),
      ];

  // ── Load / Save ────────────────────────────────────────────────

  /// Load all engines across all categories.
  List<SearchEngine> loadEngines() {
    final raw = _settings.get(_kEngines);
    if (raw is List && raw.isNotEmpty) {
      return raw
          .map((e) => SearchEngine.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    // First run: seed built-in defaults
    final defaults = _buildDefaults();
    _settings.set(_kEngines, defaults.map((e) => e.toJson()).toList());
    return defaults;
  }

  /// Load engines filtered by [category].
  List<SearchEngine> loadEnginesByCategory(SearchEngineCategory category) {
    return loadEngines().where((e) => e.category == category).toList();
  }

  /// Persist the full engine list.
  Future<void> saveEngines(List<SearchEngine> engines) async {
    await _settings.set(
        _kEngines, engines.map((e) => e.toJson()).toList());
  }

  /// Save engines for a single category, preserving other categories' engines.
  Future<void> saveEnginesByCategory(
      SearchEngineCategory category, List<SearchEngine> catEngines) async {
    final all = loadEngines();
    final others = all.where((e) => e.category != category).toList();
    final merged = [...catEngines, ...others];
    await saveEngines(merged);
  }

  // ── Default engine ─────────────────────────────────────────────

  /// Get the default engine for [category] — the first engine in that
  /// category's list.
  SearchEngine? getDefaultEngine(SearchEngineCategory category) {
    final engines = loadEnginesByCategory(category);
    return engines.isNotEmpty ? engines.first : null;
  }

  /// Get the name of the default engine for [category].
  String getDefaultEngineName(
      [SearchEngineCategory category = SearchEngineCategory.text]) {
    return getDefaultEngine(category)?.name ?? '';
  }

  /// Set the default engine for [category] by moving [name] to position 0
  /// within its category group.
  Future<void> setDefaultEngineName(String name,
      {SearchEngineCategory category = SearchEngineCategory.text}) async {
    final all = loadEngines();
    final catEngines = all.where((e) => e.category == category).toList();
    final idx = catEngines.indexWhere((e) => e.name == name);
    if (idx <= 0) return; // already first or not found
    final target = catEngines.removeAt(idx);
    catEngines.insert(0, target);
    final others = all.where((e) => e.category != category).toList();
    await saveEngines([...catEngines, ...others]);
  }

  // ── URL building ───────────────────────────────────────────────

  /// Substitute {query} into the URL template with URL-encoded query.
  String buildUrl(SearchEngine engine, String query) {
    final encoded = Uri.encodeQueryComponent(query);
    return engine.url.replaceAll('{query}', encoded);
  }

  // ── Execution ──────────────────────────────────────────────────

  /// Execute a text / map / translate / dictionary search:
  /// copy query to clipboard (if copyMode), then open URL.
  Future<void> execute(SearchEngine engine, String query) async {
    if (engine.copyMode) {
      await Clipboard.setData(ClipboardData(text: query));
    }
    final url = buildUrl(engine, query);
    await Process.run('cmd', ['/c', 'start', '', url]);
  }

  /// Execute an image search: open the engine URL.
  /// The caller is responsible for copying the image to clipboard first.
  Future<void> executeImageSearch(SearchEngine engine) async {
    await Process.run('cmd', ['/c', 'start', '', engine.url]);
  }

}
