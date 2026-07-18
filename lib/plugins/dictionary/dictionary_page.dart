/// Standalone dictionary window page.
///
/// Dynamic-sizing in mini mode uses the same pattern as the command palette:
/// 1. Expand to generous height first (Flutter lays out without overflow)
/// 2. Wait one frame for layout to settle
/// 3. Measure actual content height via a key on the content column
/// 4. Shrink window to measured size
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'dictionary_models.dart';
import 'dictionary_service.dart';
import '../../core/search/search_engine_service.dart';
import '../../core/settings/settings_service.dart';
import '../../core/theme/theme_colors.dart';
import '../../core/drag/drag_out_helper.dart';

class DictionaryPage extends StatefulWidget {
  final VoidCallback onClose;
  final bool initialTopmost;
  final bool initialMiniMode;
  final String? initialText;

  const DictionaryPage({
    super.key,
    required this.onClose,
    this.initialTopmost = false,
    this.initialMiniMode = false,
    this.initialText,
  });

  @override
  State<DictionaryPage> createState() => DictionaryPageState();
}

class DictionaryPageState extends State<DictionaryPage> {
  static const _accent = Color(0xFF5AAAC2);
  static const _kTopmostKey = 'dictionary.topmost';
  static const _kMiniModeKey = 'dictionary.miniMode';
  static const _kBookmarksKey = 'dictionary.bookmarks';
  static const _kDbPathKey = 'dictionary.dbPath';
  static const _kLemmaPathKey = 'dictionary.lemmaPath';

  static const _windowW = 580.0;
  static const _normalH = 600.0;
  static const _generousH = 800.0; // generous height for measurement frame
  static const _emptyMiniH = 90.0; // fallback: titleBar + searchBar only

  final _service = DictionaryService();
  final _settings = SettingsService();
  final _searchService = SearchEngineService();
  final _searchCtrl = TextEditingController();
  final _contentKey = GlobalKey();
  static const _dragChannel = MethodChannel('com.xmate/dragdrop');
  int _windowGeneration = 0;

  bool _topmost = false;
  bool _miniMode = false;
  bool _initializing = true;
  bool _searchRunning = false;
  bool _showBookmarks = false;
  List<WordEntry> _results = [];

  Set<String> _bookmarks = {};
  List<WordEntry> _bookmarkResults = [];
  String _hintEn = ''; // English-only hint (shown initially)
  String _hintFull = ''; // Full hint (revealed on click)
  bool _hintRevealed = false;

  @override
  void initState() {
    super.initState();
    _topmost = widget.initialTopmost;
    _miniMode = widget.initialMiniMode;
    // Set initial text synchronously (same pattern as TranslatePage)
    // so the search bar shows the word before the first build.
    if (widget.initialText != null && widget.initialText!.isNotEmpty) {
      _searchCtrl.text = widget.initialText!;
    }
    _loadBookmarks();
    _initDragDrop();
    _init();
  }

  /// Called externally when the dictionary window receives new search text
  /// from a second --dictionary invocation (via C++ WM_COPYDATA forwarding).
  void searchText(String text) {
    _searchCtrl.text = text;
    _searchCtrl.selection = TextSelection.fromPosition(
      TextPosition(offset: text.length),
    );
    if (_showBookmarks) {
      setState(() => _showBookmarks = false);
    }
    _search();
  }

  /// Reset to initial state — clear search, restore hints.
  /// Called when the dictionary window is hidden (user clicked close).
  void resetState() {
    _searchCtrl.clear();
    _hintRevealed = false;
    _results = [];
    _showBookmarks = false;
    _bookmarkResults = [];
    setState(() {});
    _refreshHint();
  }

  @override
  void dispose() {
    _dragChannel.setMethodCallHandler(null);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _initDragDrop() {
    _dragChannel.setMethodCallHandler((call) async {
      if (call.method != 'onDrop' || !mounted) return;
      final args = call.arguments as Map<dynamic, dynamic>?;
      if (args == null) return;
      final type = args['type'] as String?;
      if (type == 'text') {
        final text = args['text'] as String? ?? '';
        if (text.isNotEmpty && mounted) {
          _searchCtrl.text = text;
          _searchCtrl.selection = TextSelection.fromPosition(
            TextPosition(offset: text.length),
          );
          if (_showBookmarks) {
            setState(() => _showBookmarks = false);
          }
          _search();
        }
      }
    });
  }

  void _loadBookmarks() {
    final raw = _settings.get(_kBookmarksKey) as String?;
    if (raw != null && raw.isNotEmpty) {
      _bookmarks = raw.split(',').toSet();
    }
  }

  Future<void> _saveBookmarks() async {
    await _settings.set(_kBookmarksKey, _bookmarks.join(','));
  }

  bool _isBookmarked(String word) =>
      _bookmarks.contains(word.toLowerCase());

  void _toggleBookmark(String word) {
    final key = word.toLowerCase();
    setState(() {
      if (_bookmarks.contains(key)) {
        _bookmarks.remove(key);
      } else {
        _bookmarks.add(key);
      }
    });
    _saveBookmarks();
  }

  // ── Init ────────────────────────────────────────────────────────

  Future<void> _init() async {
    await _service.init();

    // Auto-load lemma from bundled assets (non-blocking).
    _service.loadLemmaFromAsset();

    final savedPath = _settings.get(_kDbPathKey) as String?;
    if (savedPath != null && savedPath.isNotEmpty) {
      try {
        await _service.openDatabase(savedPath);
      } catch (_) {}
    }

    // Fallback: try loading lemma from saved file if asset-based didn't work.
    final savedLemma = _settings.get(_kLemmaPathKey) as String?;
    if (savedLemma != null && savedLemma.isNotEmpty) {
      try {
        _service.loadLemmaFromFile(savedLemma);
      } catch (_) {}
    }

    await _refreshHint();

    if (mounted) {
      setState(() => _initializing = false);
      // Trigger search if initial text was set (e.g. from quick dictionary).
      if (_searchCtrl.text.trim().isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _search());
      }
      // If starting in mini mode, do initial refit.
      if (_miniMode) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _refitWindow());
      }
    }
  }

  Future<void> _refreshHint() async {
    if (!_service.isOpen) return;
    try {
      // Apply Daily Word tag filter from settings.
      final savedTagStr =
          _settings.get('dictionary.dailyWordTags') as String?;
      final tags = (savedTagStr != null && savedTagStr.isNotEmpty)
          ? savedTagStr.split(',')
          : null;
      final entry = await _service.randomWord(tags: tags);
      if (entry != null) {
        final firstMeaning = _firstCnParagraph(entry.translation ?? '');
        _hintEn = entry.word;
        _hintFull = firstMeaning.isNotEmpty
            ? '${entry.word} — $firstMeaning'
            : entry.word;
        _hintRevealed = false;
      } else {
        _hintEn = 'Search EN↔ZH...';
        _hintFull = 'Search EN↔ZH...';
      }
    } catch (_) {
      _hintEn = 'Search EN↔ZH...';
      _hintFull = 'Search EN↔ZH...';
    }
  }

  void _toggleHint() {
    if (_hintEn == 'Search EN↔ZH...') return;
    setState(() => _hintRevealed = !_hintRevealed);
  }

  String _firstCnParagraph(String translation) {
    final para = translation.split('\\n').first.trim();
    if (para.length > 24) return '${para.substring(0, 24)}…';
    return para;
  }

  // ── Dynamic window sizing ───────────────────────────────────────

  static Future<void> _afterNextFrame() {
    final c = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) => c.complete());
    return c.future;
  }

  /// Measure content height and refit the window.
  ///
  /// Pattern (same as command palette refitWindow):
  /// 1. Expand to generous height → Flutter lays out content without overflow
  /// 2. Wait one frame → content renders at natural size
  /// 3. Measure `_contentKey` render box height
  /// 4. Shrink window to match measured content height
  Future<void> _refitWindow() async {
    if (!_miniMode) {
      await windowManager.setSize(const Size(_windowW, _normalH));
      return;
    }

    final gen = ++_windowGeneration;

    // Step 1: expand so Flutter can measure content without back-pressure.
    // The previous frame's content is still visible — this resize happens
    // behind the current paint.
    if (gen != _windowGeneration) return;
    await windowManager.setSize(const Size(_windowW, _generousH));

    // Step 2: wait for layout + paint of the expanded frame.
    await _afterNextFrame();
    if (gen != _windowGeneration) return;

    // Step 3: measure actual content height.
    double measuredH = _emptyMiniH;
    final ctx = _contentKey.currentContext;
    if (ctx != null) {
      final rb = ctx.findRenderObject() as RenderBox?;
      if (rb != null && rb.hasSize && rb.size.height > 2) {
        measuredH = rb.size.height;
      }
    }

    // +5: safety margin — render box measurement can be off by 1–2 px
    // due to sub-pixel layout rounding across device pixel ratio.
    final targetH = (measuredH + 5).clamp(_emptyMiniH, 800.0);

    // Step 4: shrink to measured height — content snaps into place.
    if (gen != _windowGeneration) return;
    await windowManager.setSize(Size(_windowW, targetH));
  }

  // ── Search ──────────────────────────────────────────────────────

  Future<void> _search() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) {
      setState(() => _results = []);
      if (_miniMode) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _refitWindow());
      }
      return;
    }
    if (!_service.isOpen) return;

    setState(() => _searchRunning = true);

    // Mini mode: expand window BEFORE rendering results so the
    // shrinkWrap content doesn't overflow the current tight bounds.
    if (_miniMode) {
      await windowManager.setSize(const Size(_windowW, _generousH));
    }

    try {
      final results = await _service.smartSearch(q, limit: 30);
      if (mounted) {
        setState(() {
          _results = results;
          _searchRunning = false;
        });
        if (_miniMode) {
          // Content is laid out at generous height — now measure and shrink.
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _refitWindow());
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _results = [];
          _searchRunning = false;
        });
      }
    }
  }

  Future<void> _navigateTo(String word) async {
    _searchCtrl.text = word;
    await _search();
  }

  // ── Search in web ────────────────────────────────────────────────

  void _searchInWeb(SearchEngine? engine) {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) return;
    final e = engine ?? _searchService.getDefaultEngine(SearchEngineCategory.dictionary);
    if (e == null) return;
    _searchService.execute(e, q);
  }

  void _showDictEngineMenu(Offset position) {
    final engines =
        _searchService.loadEnginesByCategory(SearchEngineCategory.dictionary);
    if (engines.isEmpty) return;
    final screen = MediaQuery.of(context).size;
    const menuW = 200.0;
    const rowH = 42.0;
    final menuH = engines.length * rowH;
    final left = (position.dx + menuW > screen.width)
        ? position.dx - menuW
        : position.dx;
    final top = (position.dy + menuH > screen.height)
        ? position.dy - menuH
        : position.dy;
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(builder: (ctx) {
      final cs = Theme.of(context).colorScheme;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => entry.remove(),
        child: Stack(children: [
          Positioned(
            left: left,
            top: top,
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 220),
                decoration: BoxDecoration(
                  color: XMateColors.dialogBg(context),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: cs.primary.withAlpha(60), width: 1),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: engines
                      .map((engine) => InkWell(
                            onTap: () {
                              entry.remove();
                              _searchInWeb(engine);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              child: Row(children: [
                                Icon(Icons.language,
                                    size: 14,
                                    color: cs.onSurface.withAlpha(138)),
                                const SizedBox(width: 8),
                                Text(engine.name,
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: cs.onSurface)),
                              ]),
                            ),
                          ))
                      .toList(),
                ),
              ),
            ),
          ),
        ]),
      );
    });
    overlay.insert(entry);
  }

  // ── Title bar ───────────────────────────────────────────────────

  Widget _titleBar() {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: XMateColors.panelBg(context),
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Row(
          children: [
            const SizedBox(width: 14),
            Icon(Icons.menu_book, size: 16, color: cs.primary),
            const SizedBox(width: 8),
            Text('Dictionary',
                style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface,
                    fontWeight: FontWeight.w500)),
            const Spacer(),
            _titleBtn(Icons.bookmarks, _toggleBookmarkList,
                active: _showBookmarks, tooltip: '单词本'),
            _titleBtn(Icons.vertical_align_top, _toggleTopmost,
                active: _topmost, tooltip: '置顶'),
            _titleBtn(
                _miniMode ? Icons.unfold_more : Icons.unfold_less,
                _toggleMiniMode,
                active: _miniMode,
                tooltip: _miniMode ? '完整模式' : '极简模式'),
            _titleBtn(Icons.minimize, () => windowManager.minimize(),
                tooltip: '最小化'),
            _titleBtn(Icons.close, widget.onClose, tooltip: '关闭'),
          ],
        ),
      ),
    );
  }

  Widget _titleBtn(IconData icon, VoidCallback onTap,
      {bool active = false, String? tooltip}) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: tooltip ?? '',
        child: Container(
          width: 42,
          height: 36,
          alignment: Alignment.center,
          child: Icon(icon,
              size: 16,
              color: active ? cs.primary : cs.onSurface.withAlpha(138)),
        ),
      ),
    );
  }

  Future<void> _toggleTopmost() async {
    _topmost = !_topmost;
    await windowManager.setAlwaysOnTop(_topmost);
    await _settings.set(_kTopmostKey, _topmost);
    setState(() {});
  }

  Future<void> _toggleMiniMode() async {
    _miniMode = !_miniMode;
    await _settings.set(_kMiniModeKey, _miniMode);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _refitWindow());
  }

  // ── Bookmark list ────────────────────────────────────────────────

  void _toggleBookmarkList() {
    if (_showBookmarks) {
      // Exit bookmark list, go back to search.
      setState(() {
        _showBookmarks = false;
        _searchCtrl.clear();
        _results = [];
        _bookmarkResults = [];
      });
    } else {
      // Enter bookmark list — look up all bookmarked words.
      _loadBookmarkResults();
    }
  }

  Future<void> _loadBookmarkResults() async {
    // Force full mode for bookmark list.
    if (_miniMode) {
      _miniMode = false;
      await _settings.set(_kMiniModeKey, false);
      await windowManager.setSize(const Size(_windowW, _normalH));
    }
    setState(() => _showBookmarks = true);
    if (_bookmarks.isEmpty) {
      setState(() {
        _searchCtrl.clear();
        _results = [];
        _bookmarkResults = [];
      });
      return;
    }
    final results = <WordEntry>[];
    for (final word in _bookmarks) {
      try {
        final entry = await _service.query(word);
        if (entry != null) results.add(entry);
      } catch (_) {}
    }
    // Sort by word.
    results.sort((a, b) => a.word.toLowerCase().compareTo(b.word.toLowerCase()));
    if (mounted) {
      setState(() {
        _searchCtrl.clear();
        _results = [];
        _bookmarkResults = results;
      });
      if (_miniMode) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _refitWindow());
      }
    }
  }

  // ── Search bar ──────────────────────────────────────────────────

  Widget _searchBar() {
    final cs = Theme.of(context).colorScheme;
    final showHint = _hintFull.isNotEmpty &&
        _hintFull != 'Search EN↔ZH...';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              autofocus: true,
              style: TextStyle(fontSize: 14, color: cs.onSurface),
              decoration: InputDecoration(
                hintText: showHint
                    ? (_hintRevealed ? _hintFull : _hintEn)
                    : 'Search EN↔ZH...',
                hintStyle: TextStyle(
                  color: cs.onSurface.withAlpha(60),
                  fontSize: 13,
                ),
                filled: true,
                fillColor: XMateColors.cardFill(context),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: cs.onSurface.withAlpha(30),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: cs.onSurface.withAlpha(30),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      BorderSide(color: _accent, width: 1.2),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                isDense: true,
                prefixIcon: Icon(Icons.search,
                    size: 18,
                    color: cs.onSurface.withAlpha(100)),
                suffixIcon: showHint
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GestureDetector(
                            onTap: () async {
                              await _refreshHint();
                              setState(() {});
                            },
                            child: Icon(
                              Icons.casino,
                              size: 16,
                              color: cs.onSurface.withAlpha(80),
                            ),
                          ),
                          const SizedBox(width: 6),
                          GestureDetector(
                            onTap: _toggleHint,
                            child: Icon(
                              _hintRevealed
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              size: 16,
                              color: cs.onSurface.withAlpha(80),
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                      )
                    : null,
              ),
              onSubmitted: (_) => _search(),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => _searchInWeb(null),
            onSecondaryTapUp: (d) => _showDictEngineMenu(d.globalPosition),
            child: Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _accent.withAlpha(120), width: 1),
              ),
              child: const Icon(Icons.open_in_browser,
                  color: _accent, size: 18),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _searchRunning ? null : _search,
            child: Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: _accent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: _searchRunning
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.arrow_forward,
                      color: Colors.white, size: 18),
            ),
          ),
        ],
      ),
    );
  }

  // ── Results ─────────────────────────────────────────────────────

  Widget _resultsArea() {
    // Bookmark list mode.
    if (_showBookmarks) {
      if (_bookmarkResults.isEmpty) {
        final cs = Theme.of(context).colorScheme;
        return _miniMode
            ? Padding(
                padding: const EdgeInsets.all(40),
                child: Center(
                  child: Text(
                    _bookmarks.isEmpty
                        ? 'No bookmarks. Tap ★ to add.'
                        : 'Loading...',
                    style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withAlpha(100)),
                  ),
                ),
              )
            : Expanded(
                child: Center(
                  child: Text(
                    _bookmarks.isEmpty
                        ? 'No bookmarks. Tap ★ to add.'
                        : 'Loading...',
                    style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withAlpha(100)),
                  ),
                ),
              );
      }
      if (_miniMode) {
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _bookmarkResults.length,
          itemBuilder: (_, i) =>
              _resultCard(context, _bookmarkResults[i], forceBookmarked: true),
        );
      }
      return Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          itemCount: _bookmarkResults.length,
          itemBuilder: (_, i) =>
              _resultCard(context, _bookmarkResults[i], forceBookmarked: true),
        ),
      );
    }
    if (_searchCtrl.text.trim().isEmpty && _results.isEmpty) {
      // Empty search: nothing below the search bar.
      // In normal mode, fill remaining space so the full window is covered.
      return _miniMode
          ? const SizedBox.shrink()
          : const Expanded(child: SizedBox.shrink());
    }
    if (_searchRunning && _results.isEmpty) {
      return _miniMode
          ? const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2)),
            )
          : const Expanded(
              child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2)),
            );
    }
    if (!_searchRunning &&
        _searchCtrl.text.trim().isNotEmpty &&
        _results.isEmpty) {
      return _miniMode
          ? const SizedBox.shrink()
          : const Expanded(child: SizedBox.shrink());
    }
    if (_results.isEmpty) {
      return _miniMode
          ? const SizedBox.shrink()
          : const Expanded(child: SizedBox.shrink());
    }

    final display = _miniMode ? _results.take(1).toList() : _results;

    if (_miniMode) {
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: display.length,
        itemBuilder: (_, i) => _resultCard(context, display[i]),
      );
    }

    // Normal mode: Expanded + scrollable.
    return Expanded(
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        itemCount: display.length,
        itemBuilder: (_, i) => _resultCard(context, display[i]),
      ),
    );
  }

  // ── Result card ─────────────────────────────────────────────────

  Widget _resultCard(BuildContext context, WordEntry entry,
      {bool forceBookmarked = false}) {
    final cs = Theme.of(context).colorScheme;
    final tags = entry.tagList;
    final exchanges = entry.exchangeDecoded;
    final isExact = _searchCtrl.text.trim().toLowerCase() ==
        entry.word.toLowerCase();
    final bookmarked = forceBookmarked || _isBookmarked(entry.word);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Container(
        decoration: BoxDecoration(
          color: isExact
              ? _accent.withAlpha(25)
              : cs.onSurface.withAlpha(8),
          borderRadius: BorderRadius.circular(8),
          border: isExact
              ? Border.all(color: _accent.withAlpha(80), width: 1)
              : null,
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _wordRow(context, entry, tags, bookmarked),
            if (entry.translation != null &&
                entry.translation!.isNotEmpty) ...[
              const SizedBox(height: 4),
              ..._splitParagraphs(entry.translation!).map(
                    (para) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: DragOutSelectableText(para,
                          style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurface.withAlpha(210))),
                    ),
                  ),
            ],
            if (!_miniMode &&
                entry.definition != null &&
                entry.definition!.isNotEmpty) ...[
              const SizedBox(height: 4),
              ..._splitParagraphs(entry.definition!).map(
                    (para) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: DragOutSelectableText(para,
                          style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurface.withAlpha(140),
                              fontStyle: FontStyle.italic)),
                    ),
                  ),
            ],
            if (exchanges.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 3,
                children: exchanges.map((e) {
                  final (label, w) = e;
                  return GestureDetector(
                    onTap: () => _navigateTo(w),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: cs.primary.withAlpha(20),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text.rich(TextSpan(children: [
                        TextSpan(
                            text: '$label ',
                            style: TextStyle(
                                fontSize: 10,
                                color: cs.onSurface
                                    .withAlpha(120))),
                        TextSpan(
                            text: w,
                            style: TextStyle(
                                fontSize: 11,
                                color: cs.primary,
                                fontWeight: FontWeight.w500)),
                      ])),
                    ),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _wordRow(BuildContext context, WordEntry entry,
      List<String> tags, bool bookmarked) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(entry.word,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface),
                    overflow: TextOverflow.ellipsis),
              ),
              if (entry.phonetic != null &&
                  entry.phonetic!.isNotEmpty) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(entry.phonetic!,
                      style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withAlpha(140)),
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ],
          ),
        ),
        ...tags.map((t) => Padding(
              padding: const EdgeInsets.only(left: 4),
              child: _tagChip(context, t),
            )),
        if (entry.oxford)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFF2196F3).withAlpha(30),
                borderRadius: BorderRadius.circular(3),
              ),
              child: const Text('OXFORD',
                  style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF2196F3))),
            ),
          ),
        if (entry.collinsStars.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(entry.collinsStars,
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFFFFC107))),
          ),
        GestureDetector(
          onTap: () => _toggleBookmark(entry.word),
          child: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Icon(
              bookmarked ? Icons.bookmark : Icons.bookmark_border,
              size: 16,
              color: bookmarked
                  ? const Color(0xFFFFC107)
                  : cs.onSurface.withAlpha(60),
            ),
          ),
        ),
      ],
    );
  }

  Widget _tagChip(BuildContext context, String tag) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: _tagColor(tag).withAlpha(30),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
            color: _tagColor(tag).withAlpha(80), width: 0.5),
      ),
      child: Text(tag.toUpperCase(),
          style: TextStyle(
            fontSize: 8,
            fontWeight: FontWeight.w600,
            color: _tagColor(tag),
          )),
    );
  }

  Color _tagColor(String tag) {
    switch (tag.toLowerCase()) {
      case 'cet4':
      case 'cet6':
        return const Color(0xFF4CAF50);
      case 'ielts':
        return const Color(0xFF2196F3);
      case 'toefl':
        return const Color(0xFFFF9800);
      case 'gre':
        return const Color(0xFF9C27B0);
      case '考研':
        return const Color(0xFFE91E63);
      default:
        return const Color(0xFF5AAAC2);
    }
  }

  List<String> _splitParagraphs(String text) {
    return text
        .split('\\n')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
  }

  // ── Build ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Container(
            width: _windowW,
            height: _normalH,
            decoration: BoxDecoration(
              color: XMateColors.panelBg(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withAlpha(60),
                  width: 1.5),
            ),
            child: const Center(
                child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        ),
      );
    }

    // By default (normal mode), the content Column has an Expanded child
    // and fills (up to) window height.
    // In mini mode, _resultsArea returns shrinkWrap widgets without
    // Expanded, so the Column sizes to its natural content height.
    // _refitWindow then measures that height and resizes the window.
    final content = Container(
      decoration: BoxDecoration(
        color: XMateColors.panelBg(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color:
                Theme.of(context).colorScheme.primary.withAlpha(60),
            width: 1.5),
      ),
      child: Column(
        key: _miniMode ? _contentKey : null,
        mainAxisSize: MainAxisSize.min,
        children: [
          _titleBar(),
          _searchBar(),
          if (!_miniMode || _hasContentToShow()) _resultsArea(),
        ],
      ),
    );

    if (_miniMode) {
      // Mini mode: content takes natural height, aligned to top.
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Align(
          alignment: Alignment.topCenter,
          child: content,
        ),
      );
    }

    // Normal mode: Scaffold fills the full window — content always
    // stretches to full height so there are no transparent dead zones.
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: content,
    );
  }

  /// Whether to render the content area below the search bar.
  bool _hasContentToShow() {
    return _searchRunning ||
        _searchCtrl.text.trim().isNotEmpty;
  }
}
