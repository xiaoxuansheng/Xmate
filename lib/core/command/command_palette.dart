library;

import 'dart:async';
import 'dart:io';
import 'package:flutter/gestures.dart' show kPrimaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../app.dart';
import 'package:window_manager/window_manager.dart';
import '../plugin/plugin_base.dart';
import '../plugin/plugin_registry.dart';
import '../search/search_engine_service.dart';
import '../search/file_search_service.dart';
import '../search/file_search_filter.dart';
import '../command/user_command_service.dart';
import '../command/file_submenu_service.dart';
import '../command/file_submenu_item.dart';
import '../quicklook/quicklook_palette_state.dart';
import '../../plugins/dictionary/dictionary_service.dart';
import '../../plugins/dictionary/dictionary_models.dart';
import '../../plugins/notes/note_model.dart';
import '../../plugins/notes/note_store.dart';
import 'calculator_service.dart';
import 'exchange_rate_service.dart';
import 'timezone_service.dart';
import 'command_engine.dart';
import '../theme/theme_colors.dart';
import '../stats/usage_stats_service.dart';

class CommandPalette extends StatefulWidget {
  final PluginRegistry registry;
  final VoidCallback onClose;
  final GlobalKey contentKey;
  final GlobalKey dropdownMeasureKey;
  final String? initialText;
  const CommandPalette({
    super.key,
    required this.registry,
    required this.onClose,
    required this.contentKey,
    required this.dropdownMeasureKey,
    this.initialText,
  });
  @override State<CommandPalette> createState() => _S();
}

class _S extends State<CommandPalette> {
  final _e = CommandEngine();
  final _c = TextEditingController();
  final _f = FocusNode();
  final _searchService = SearchEngineService();
  final _fileSearchService = FileSearchService();
  final _userCommandService = UserCommandService();
  final _fileSubmenuService = FileSubmenuService();

  List<_PaletteEntry> _r = [];              // measurement tree data
  List<_PaletteEntry> _visibleResults = []; // visible tree data
  int _si = -1;                              // -1 = text mode, >=0 = list mode
  bool _altHeld = false;                       // Alt key held → show Alt+N badges

  /// Submenu — dual-buffer to avoid flicker (mirrors _r / _visibleResults).
  List<SearchEngine>? _submenuMeasure;  // measurement tree
  List<SearchEngine>? _submenuEngines;  // visible tree (non-null → submenu shown)

  /// File context submenu — dual-buffer.
  List<FileSubMenuItem>? _fileSubmenuMeasure;
  List<FileSubMenuItem>? _fileSubmenuItems;
  String? _selectedFilePath;            // file these actions operate on

  int _pendingSel = -1;  // list-mode Enter passes through TextField → -1 use first

  // ── Exchange rate mode ──
  final _rateService = ExchangeRateService();
  String? _ratePrefix;                     // '$' or '￥' (￥), null = not in rate mode
  String _rateSourceCurrency = 'USD';       // current source currency selection
  Map<String, double>? _rateData;           // cached rates from service
  DateTime? _rateTimestamp;                 // last fetch time
  bool _rateLoading = false;               // loading indicator

  // ── Timezone mode ──
  final _tzService = TimezoneService();
  String? _tzPrefix;                  // 'UTC', null = not in timezone mode
  String _tzSourceTimezone = '';      // system IANA timezone
  String _tzTargetTimezone = '';      // target IANA timezone (persisted)

  // ── Note mode ──
  bool _noteMode = false;               // "@ " prefix active
  List<NoteData> _noteModeNotes = [];   // cached note list (entered mode)
  Set<String> _noteOpenIds = {};        // notes with an open window

  /// Filter mode — when non-null the palette only shows file results
  /// filtered by this preset.  Activated by typing "keyword " at the
  /// start of the query.
  FileSearchFilter? _activeFilter;
  String _lastQ = ''; // previous query, used to detect typed-space
  bool _pasteDetected = false;  // set by Ctrl+V, consumed in _search()

  // Quick dictionary state
  WordEntry? _dictMatch;
  int _dictQueryVersion = 0;

  final _scrollCtrl = ScrollController();   // visible list scroll
  int _measureVersion = 0;   // guard against stale refitWindow callbacks

  // Cache the tear-off so add/remove use the IDENTICAL closure.
  // Dart creates a new closure for every `_handleEarlyKey` reference —
  // without this, removeEarlyKeyEventHandler cannot find the handler
  // added in initState and the old handler leaks forever (V2.2.13 fix).
  late final KeyEventResult Function(KeyEvent) _earlyKeyHandler = _handleEarlyKey;
  late final void Function() _searchListener = _onSearch;
  late final bool Function(KeyEvent) _hwKeyHandler = _onHardwareKey;

  static const _dragChannel = MethodChannel('com.xmate/dragdrop');
  static const _dragOutChannel = MethodChannel('com.xmate/dragout');
  static const double _dragOutThreshold = 8.0;

  // ── File drag-out state ──────────────────────────────────────
  int? _dragFilePtrId;
  Offset? _dragFileOrigin;
  bool _dragFileFired = false;

  void _onFileDragDown(PointerDownEvent e) {
    if (_dragFilePtrId != null && _dragFilePtrId != e.pointer) return;
    _dragFilePtrId = e.pointer;
    _dragFileOrigin = e.position;
    _dragFileFired = false;
  }

  void _onFileDragMove(PointerMoveEvent e, String fullPath) {
    if (e.pointer != _dragFilePtrId) return;
    if (_dragFileOrigin == null || _dragFileFired) return;
    if ((e.buttons & kPrimaryMouseButton) == 0) return;
    if ((e.position - _dragFileOrigin!).distance < _dragOutThreshold) return;

    _dragFileFired = true;
    final snapshotPath = fullPath; // String value type — assignment is a snapshot
    _dragOutChannel.invokeMethod('start', {
      'mode': 'file',
      'files': [snapshotPath],
    }).whenComplete(_resetFileDrag);
  }

  void _onFileDragEnd(PointerEvent e) {
    if (e.pointer == _dragFilePtrId) _resetFileDrag();
  }

  void _resetFileDrag() {
    _dragFilePtrId = null;
    _dragFileOrigin = null;
    _dragFileFired = false;
  }

  @override void initState() {
    super.initState();
    _c.addListener(_searchListener);
    FocusManager.instance.addEarlyKeyEventHandler(_earlyKeyHandler);
    HardwareKeyboard.instance.addHandler(_hwKeyHandler);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        // Populate initialText if provided (e.g. from text selection grab).
        final t = widget.initialText;
        if (t != null && t.isNotEmpty) {
          final sanitized = _sanitizeInput(t);
          _c.value = TextEditingValue(
            text: sanitized,
            selection: TextSelection.collapsed(offset: sanitized.length),
          );
        }
        _f.requestFocus();
      }
    });
    // Native Windows drag-drop → Dart
    _dragChannel.setMethodCallHandler((call) async {
      if (call.method != 'onDrop' || !mounted) return;
      final args = call.arguments as Map<dynamic, dynamic>?;
      if (args == null) return;
      final type = args['type'] as String?;
      if (type == 'text') {
        _handleTextDrop(args['text'] as String? ?? '');
      } else if (type == 'files') {
        final raw = args['files'] as List<dynamic>?;
        if (raw != null && raw.isNotEmpty) {
          _handleFileDrop(raw.cast<String>());
        }
      }
    });
  }

  @override void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_earlyKeyHandler);
    HardwareKeyboard.instance.removeHandler(_hwKeyHandler);
    _cancelArrowRepeat();
    _c.dispose();
    _f.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onSearch() {
    // While IME is composing (e.g. Chinese pinyin), skip search so the list
    // doesn't flicker on every intermediate keystroke.
    final composing = _c.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;

    // Enforce single-line + 200-char cap on every input change.
    // Runs after the TextField already accepted the character; if the text
    // exceeds limits, clamp it and move the cursor.
    final raw = _c.text;
    final sanitized = _sanitizeInput(raw);
    if (sanitized != raw) {
      // Detach listener while we fix the text to avoid a recursive call.
      _c.removeListener(_searchListener);
      final offset = sanitized.length;
      _c.value = TextEditingValue(
        text: sanitized,
        selection: TextSelection.collapsed(offset: offset),
      );
      _c.addListener(_searchListener);
    }

    _search(_c.text);
  }

  void _search(String q) {
    // Don't rebuild the list while user is in a submenu.
    if (_submenuEngines != null || _fileSubmenuItems != null || _fileSubmenuMeasure != null) return;
    final wasEmpty = _visibleResults.isEmpty;

    // ── Timezone mode (active) ──
    // When _tzPrefix is set, all results are timezone conversion entries.
    if (_tzPrefix != null) {
      _lastQ = q;
      final prefix = '$_tzPrefix ';
      if (!q.startsWith(prefix)) {
        _exitTzMode();
        _search(q);
        return;
      }
      final dtStr = q.substring(prefix.length);
      final dt = _parseDateTime(dtStr);
      _buildTzEntries(dt, wasEmpty);
      return;
    }

    // ── Exchange rate mode (active) ──
    // When _ratePrefix is set, all results are rate conversion entries.
    if (_ratePrefix != null) {
      _lastQ = q; // guard against re-entry after backspace exit
      final prefix = '$_ratePrefix ';
      if (!q.startsWith(prefix)) {
        // Prefix lost (e.g. select-all + delete) — exit rate mode
        _exitRateMode();
        _search(q);
        return;
      }
      final amountStr = q.substring(prefix.length);
      final amount = double.tryParse(amountStr);
      _buildRateEntries(amount, wasEmpty);
      return;
    }

    // ── Note mode (active) ──
    // When _noteMode is set, results are: [create new note, ...existing notes].
    if (_noteMode) {
      _lastQ = q;
      if (!(q.startsWith('@ ') || q.startsWith('＠ '))) {
        // Prefix lost (e.g. select-all + delete) — exit note mode
        _noteMode = false;
        _search(q);
        return;
      }
      _buildNoteEntries(q.substring(2), wasEmpty);
      return;
    }

    // ── Map search mode detection ──
    // "map " prefix → show map search engines (not file results).
    // Exit: backspace when text is exactly "map ".
    const kMapPrefix = 'map ';

    if (_activeFilter != null && _activeFilter!.keyword == 'map') {
      _lastQ = q;
      if (q == kMapPrefix) {
        final entries = <_PaletteEntry>[];
        entries.add(_PlaceholderEntry());
        _renderEntries(entries, wasEmpty);
        return;
      }
      if (q.startsWith(kMapPrefix)) {
        final searchText = q.substring(kMapPrefix.length);
        if (searchText.isNotEmpty) {
          final entries = <_PaletteEntry>[];
          final defaultEngine = _searchService.getDefaultEngine(SearchEngineCategory.map);
          if (defaultEngine != null) {
            entries.add(_SearchEntry(
              engineName: defaultEngine.name,
              query: searchText,
              onExecute: () => _searchService.execute(defaultEngine, searchText),
              onEnterSubmenu: _enterMapSubmenu,
            ));
          }
          _renderEntries(entries, wasEmpty);
        }
        return;
      }
      // Prefix lost — exit map mode, fall through.
      _activeFilter = null;
    }

    // ── Filter mode detection ──
    // Entry: text contains a space, first-word keyword matches a known
    // filter → enter filter mode.
    // Exit:  only via KeyEvent Backspace when text is exactly "keyword ".

    if (_activeFilter != null && _activeFilter!.keyword != 'map') {
      _lastQ = q;
      final prefix = '${_activeFilter!.keyword} ';
      if (q.startsWith(prefix)) {
        // Filter mode active — build filter entries, skip normal mode.
        final entries = <_PaletteEntry>[];
        final searchText = q.substring(prefix.length);
        if (searchText.isNotEmpty) {
          final fileResults = _fileSearchService.search(searchText, filter: _activeFilter);
          if (fileResults.isNotEmpty) {
            for (int i = 0; i < fileResults.length && i < 20; i++) {
              final fr = fileResults[i];
              entries.add(_FileResultEntry(fr,
      onSubmenu: () => _enterFileSubmenu(fr.fullPath),
      onHover: () => _onFileHover(fr.fullPath),
      onDragDown: _onFileDragDown,
      onDragMove: (e) => _onFileDragMove(e, fr.fullPath),
      onDragEnd: _onFileDragEnd,
    ));
            }
          }
        } else {
          entries.add(_PlaceholderEntry());
        }
        _renderEntries(entries, wasEmpty);
        return;
      }
      // Prefix lost (e.g. select-all delete) — exit filter, fall through.
      _activeFilter = null;
    }

    // Entry check — only when user just typed a space after the keyword
    // (_lastQ is the keyword without the trailing space).
    if (q.endsWith(' ') && q.indexOf(' ') == q.length - 1) {
      final keyword = q.substring(0, q.length - 1);
      if (_lastQ == keyword) {
        // map keyword → enter map search mode
        if (keyword == 'map') {
          _activeFilter = FileSearchFilter(keyword: 'map', name: 'Map Search', isBuiltin: true);
          _lastQ = q;
          _search(q);
          return;
        }
        final filters = _fileSearchService.getActiveFilters();
        for (final f in filters) {
          if (f.keyword == keyword) {
            _activeFilter = f;
            _lastQ = q; // prevent re-entry in recursive call
            _search(q);
            return;
          }
        }
      }
    }

    // ── Exchange rate mode entry: "$ " or "￥ " ──
    // Detect when user types the trigger symbol followed by a space.
    // Trigger symbols: '$' (half-width) or '￥' (full-width yen sign).
    // _lastQ != q guards against re-entry after Backspace exit (same
    // pattern as file filter mode — see filter entry check above).
    if (_ratePrefix == null && (q == '\$ ' || q == '￥ ') && _lastQ != q) {
      _ratePrefix = q.substring(0, 1);
      _rateSourceCurrency = _rateService.sourceCurrency;
      _lastQ = q;
      _enterRateMode();
      _search(q);
      return;
    }

    // ── Timezone mode entry: "UTC " ──
    // _lastQ != q guards against re-entry after Backspace exit.
    if (_tzPrefix == null && q == 'UTC ' && _lastQ != q) {
      _tzPrefix = 'UTC';
      _tzSourceTimezone = _tzService.sourceTimezone; // persisted, auto-detect on first run
      _tzTargetTimezone = _tzService.targetTimezone;
      _lastQ = q;
      _enterTzMode();
      return;
    }

    // ── Note mode entry: "@ " or "＠ " ──
    // Same pattern as rate/tz modes: symbol + space, _lastQ != q guards
    // against re-entry after Backspace exit.
    if (!_noteMode && (q == '@ ' || q == '＠ ') && _lastQ != q) {
      _noteMode = true;
      _lastQ = q;
      _enterNoteMode();
      _search(q);
      return;
    }

    final prevQ = _lastQ;
    _lastQ = q;

    // ── Build palette entries (normal mode only) ──
    final entries = <_PaletteEntry>[];

    // 1. Calculator — when query starts with "=" (topmost)
    if (q.startsWith('=')) {
      final expr = q.substring(1);
      final calc = CalculatorService();
      if (expr.isEmpty) {
        // "=" alone — show calculator hint entry
        entries.add(_CalcEntry(
          expression: '',
          result: null,
          onExecute: () {
            Process.run('calc', []);
          },
        ));
      } else {
        final result = calc.evaluate(expr);
        if (result != null) {
          entries.add(_CalcEntry(
            expression: expr,
            result: result,
            onExecute: () {
              Process.run('calc', []);
            },
          ));
        }
      }
    }

    // 2. Search entry (only when query is non-empty)
    if (q.isNotEmpty) {
      final engine = _searchService.getDefaultEngine(SearchEngineCategory.text);
      if (engine != null) {
        entries.add(_SearchEntry(
          engineName: engine.name,
          query: q,
          onExecute: () {
            _searchService.execute(engine, q);
          },
          onEnterSubmenu: _enterSubmenu,
        ));
      }
    }

    // 2.4. Quick Dictionary — exact English (3-20 chars) or Chinese (2-6 chars)
    if (q.isNotEmpty && _dictMatch != null) {
      entries.add(_DictEntry(
        entry: _dictMatch!,
        onExecute: () {
          final word = _dictMatch!.word;
          appKey.currentState?.showDictionary(initialText: word);
        },
      ));
    }

    // 2.5. Paste/Drop → Translate entry
    // Ctrl+V sets _pasteDetected.  Text drag (or paste without Ctrl key)
    // is detected by a >1 char jump vs the previous query — normal typing
    // changes length by exactly ±1.
    final textJumped = q.isNotEmpty &&
        ((prevQ.isNotEmpty && (q.length - prevQ.length).abs() > 1) ||
         (prevQ.isEmpty && q.length > 1));
    if (q.isNotEmpty && !q.startsWith('=') && (_pasteDetected || textJumped)) {
      _pasteDetected = false;
      final displayText = q.length > 40 ? '${q.substring(0, 40)}...' : q;
      entries.add(_TranslateEntry(
        text: displayText,
        fullText: q,
        onExecute: () {
          final text = q;
          appKey.currentState?.showTranslate(initialText: text);
        },
      ));
    }

    // Async quick-dictionary lookup (spawn after building entries).
    final isEnDictCandidate =
        q.isNotEmpty && RegExp(r'^[a-zA-Z]{3,20}$').hasMatch(q);
    final isCnDictCandidate =
        q.isNotEmpty && RegExp(r'^[一-鿿]{2,6}$').hasMatch(q);
    if ((isEnDictCandidate || isCnDictCandidate) && !q.startsWith('=')) {
      _tryDictLookup(q);
    } else {
      if (_dictMatch != null) {
        _dictMatch = null;
      }
    }

    // 3. Commands — only show when query has 2+ characters
    if (q.length >= 2) {
      final allItems = widget.registry.getAllCommands();
      final a = allItems.map((c) => _A(c)).toList();
      final newMatches = _e.search(q, a);

      // When query contains space (keyword + args), also search user commands
      // with just the first word.  The fuzzy engine only matches when the
      // query is a substring of the match term, so "cmd /k echo" would miss
      // keyword "cmd".  This ensures the command still appears in the list.
      final firstWord = q.split(' ').first;
      if (firstWord.length < q.length) {
        final userItems = allItems
            .where((c) => c.id.startsWith('user_command.'))
            .map((c) => _A(c))
            .toList();
        final extraMatches = _e.search(firstWord, userItems);
        // Merge, skip duplicates by underlying CommandItem id
        final seenIds = newMatches.map((m) => (m.item as _A).cmd.id).toSet();
        for (final m in extraMatches) {
          if (seenIds.add((m.item as _A).cmd.id)) {
            newMatches.add(m);
          }
        }
      }

      for (final m in newMatches) {
        final cmd = (m.item as _A).cmd;
        final isRecycleBin = cmd.id == 'user_command.default_bin';
        entries.add(_CommandEntry(m, onSecondaryTap: isRecycleBin ? () {
          _closePalette();
          Process.run('powershell', ['-Command', 'Clear-RecycleBin -Force']);
        } : null));
      }
    }

    // 4. File Search — show for any non-empty query (single char OK), max 20
    if (q.isNotEmpty) {
      final fileResults = _fileSearchService.search(q);
      if (fileResults.isNotEmpty) {
        for (int i = 0; i < fileResults.length && i < 20; i++) {
          final fr = fileResults[i];
          entries.add(_FileResultEntry(fr,
      onSubmenu: () => _enterFileSubmenu(fr.fullPath),
      onHover: () => _onFileHover(fr.fullPath),
      onDragDown: _onFileDragDown,
      onDragMove: (e) => _onFileDragMove(e, fr.fullPath),
      onDragEnd: _onFileDragEnd,
    ));
        }
      }
    }

    _renderEntries(entries, wasEmpty);
  }

  void _renderEntries(List<_PaletteEntry> entries, bool wasEmpty) {
    final nowEmpty = entries.isEmpty;

    if (nowEmpty) {
      _visibleResults = [];
      _r = [];
      _si = -1;
      _submenuEngines = null;
      _submenuMeasure = null;
      _measureVersion++;
      setState(() {});
      if (!wasEmpty) {
        appKey.currentState?.refitWindow(null);
      }
    } else if (wasEmpty) {
      _visibleResults = [];
      _r = entries;
      _si = -1;
      final v = ++_measureVersion;
      setState(() {});
      appKey.currentState?.refitWindow(() {
        if (mounted && _measureVersion == v) {
          _visibleResults = _r;
          setState(() {});
        }
      });
    } else {
      _r = entries;
      _si = -1;
      _submenuEngines = null;
      _submenuMeasure = null;
      final v = ++_measureVersion;
      setState(() {});
      appKey.currentState?.refitWindow(() {
        if (mounted && _measureVersion == v) {
          _visibleResults = _r;
          setState(() {});
        }
      });
    }
  }

  /// Enforce single-line input: replace newlines with spaces, cap at 200 chars,
  /// and trim leading/trailing whitespace.
  static String _sanitizeInput(String text) {
    var sanitized = text.replaceAll(RegExp(r'[\r\n]+'), ' ');
    if (sanitized.length > 200) {
      sanitized = sanitized.substring(0, 200);
    }
    return sanitized;
  }

  void _closePalette() {
    _c.removeListener(_searchListener);
    // Defer close by one frame.  No _f.unfocus() here — EditableText's
    // dispose will cleanly detach the IME connection when the widget is
    // torn down in the next build.  By then the IME is fully idle.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onClose();
    });
  }

  // ── Exchange rate mode helpers ──

  /// Enter exchange rate mode: load rates asynchronously, then rebuild.
  void _enterRateMode() {
    _rateLoading = true;
    _rateService.loadRates().then((data) {
      if (!mounted || _ratePrefix == null) return;
      _rateData = data?.rates;
      _rateTimestamp = data?.timestamp;
      _rateLoading = false;
      _search(_c.text);
    });
  }

  /// Exit exchange rate mode: clear all rate state.
  void _exitRateMode() {
    _ratePrefix = null;
    _rateData = null;
    _rateTimestamp = null;
    _rateLoading = false;
  }

  // ── Note mode helpers ──

  /// Enter note mode: snapshot note list, then fetch open-window ids async.
  void _enterNoteMode() {
    _noteModeNotes = NoteStore.list();
    _noteOpenIds = {};
    NoteLauncher.openNoteIds().then((ids) {
      if (!mounted || !_noteMode) return;
      _noteOpenIds = ids;
      _search(_c.text);
    });
  }

  /// Build note-mode entries: [create new] + existing notes (custom order).
  void _buildNoteEntries(String content, bool wasEmpty) {
    final entries = <_PaletteEntry>[];
    entries.add(_NoteCreateEntry(content: content));
    for (final n in _noteModeNotes) {
      entries.add(_NoteAppendEntry(
        note: n,
        content: content,
        isOpen: _noteOpenIds.contains(n.id),
        onDelete: () => _deleteNoteEntry(n),
      ));
    }
    // Optimization: skip refitWindow when entry count unchanged (typing
    // content only changes entry text, not the list height).
    if (!wasEmpty && entries.length == _visibleResults.length) {
      _r = entries;
      _visibleResults = entries;
      _si = -1;
      setState(() {});
      return;
    }
    _renderEntries(entries, wasEmpty);
  }

  /// Delete a note from the palette list (locked notes must unlock first).
  Future<void> _deleteNoteEntry(NoteData n) async {
    if (n.locked) return; // 锁定（折叠）便签需先解锁才能删除
    if (_noteOpenIds.contains(n.id)) {
      await NoteLauncher.closeWindow(n.id);
      await Future.delayed(const Duration(milliseconds: 200));
    }
    NoteStore.delete(n.id);
    if (!mounted || !_noteMode) return;
    _noteModeNotes = NoteStore.list();
    _noteOpenIds.remove(n.id);
    final q = _c.text;
    _buildNoteEntries(q.length >= 2 ? q.substring(2) : '', false);
  }

  // ── Timezone mode helpers ──

  /// Enter timezone mode: prefill input with current date+time, then rebuild.
  void _enterTzMode() {
    final now = DateTime.now();
    final timeStr =
        '${now.year}-${_padDateTime2(now.month)}-${_padDateTime2(now.day)} '
        '${_padDateTime2(now.hour)}:${_padDateTime2(now.minute)}';
    // Detach listener while setting text to avoid recursive _search() call.
    _c.removeListener(_searchListener);
    _c.value = TextEditingValue(
      text: 'UTC $timeStr',
      selection: TextSelection.collapsed(offset: 'UTC $timeStr'.length),
    );
    _c.addListener(_searchListener);
    _search(_c.text);
  }

  /// Exit timezone mode: clear all timezone state.
  void _exitTzMode() {
    _tzPrefix = null;
    _tzSourceTimezone = '';
    _tzTargetTimezone = '';
  }

  /// Parse user input after "UTC " prefix into a [DateTime].
  ///
  /// Supports: "2026-07-09 14:30", "2026-07-09", "14:30",
  /// "2026-7-9 14:30" (no leading zeros), "09-07 14:30" (no year),
  /// "2026/07/09 14:30" (slash separator).
  /// Returns null if parsing fails.
  DateTime? _parseDateTime(String s) {
    if (s.isEmpty) return null;
    final trimmed = s.trim();
    if (trimmed.isEmpty) return null;

    // Try standard formats with DateTime.tryParse
    DateTime? dt = DateTime.tryParse(trimmed);
    if (dt != null) return dt;

    // Try with "T" separator (ISO format)
    final withT = trimmed.replaceAll(' ', 'T');
    dt = DateTime.tryParse(withT);
    if (dt != null) return dt;

    // Try slash separator: "2026/07/09 14:30"
    final slash = trimmed.replaceAll('/', '-');
    dt = DateTime.tryParse(slash);
    if (dt != null) return dt;

    // Try "HH:mm" only — use today's date
    final timeMatch = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(trimmed);
    if (timeMatch != null) {
      final h = int.tryParse(timeMatch.group(1)!);
      final m = int.tryParse(timeMatch.group(2)!);
      if (h != null && m != null && h >= 0 && h <= 23 && m >= 0 && m <= 59) {
        final now = DateTime.now();
        return DateTime(now.year, now.month, now.day, h, m);
      }
    }

    return null;
  }

  /// Build timezone conversion entries.
  void _buildTzEntries(DateTime? sourceDt, bool wasEmpty) {
    final entries = <_PaletteEntry>[];

    // Header: source & target timezone dropdowns (centered)
    entries.add(_TzHeaderEntry(
      sourceTimezone: _tzSourceTimezone,
      targetTimezone: _tzTargetTimezone,
      onSourceChanged: (newSrc) {
        _tzSourceTimezone = newSrc;
        _tzService.sourceTimezone = newSrc;
        _search(_c.text);
      },
      onTargetChanged: (newTarget) {
        _tzTargetTimezone = newTarget;
        _tzService.targetTimezone = newTarget;
        _search(_c.text);
      },
    ));

    if (sourceDt != null) {
      final result = _tzService.convert(sourceDt, _tzSourceTimezone, _tzTargetTimezone);
      if (result != null) {
        entries.add(_TzResultEntry(
          result: result,
          sourceTz: _tzSourceTimezone,
          targetTz: _tzTargetTimezone,
          onExecute: () {
            // Copy target time with timezone label to clipboard
            final t = result.time;
            final dateStr =
                '${t.year}-${_padDateTime2(t.month)}-${_padDateTime2(t.day)} '
                '${_padDateTime2(t.hour)}:${_padDateTime2(t.minute)}';
            final tzLabel = result.abbreviation.isNotEmpty
                ? ' ${result.abbreviation}'
                : '';
            final offLabel = TimezoneService.formatUtcOffset(result.utcOffset);
            final dstLabel = result.isDst ? ' DST' : '';
            Clipboard.setData(ClipboardData(text: '$dateStr$tzLabel ($offLabel$dstLabel)'));
          },
        ));
      }
    } else {
      entries.add(_TzPlaceholderEntry(
        text: 'Enter a date/time (e.g., 2026-07-09 14:30)',
      ));
    }

    // Optimization: skip refitWindow when entry count unchanged.
    if (!wasEmpty && entries.length == _visibleResults.length) {
      _r = entries;
      _visibleResults = entries;
      _si = -1;
      setState(() {});
      return;
    }

    _renderEntries(entries, wasEmpty);
  }

  static String _padDateTime2(int n) => n.toString().padLeft(2, '0');

  /// Build rate conversion entries when [amount] is parsed.
  /// [amount] is null when the user hasn't typed a valid number yet.
  void _buildRateEntries(double? amount, bool wasEmpty) {
    final entries = <_PaletteEntry>[];

    // Add the header entry (currency selector + timestamp)
    entries.add(_RateHeaderEntry(
      ratePrefix: _ratePrefix!,
      sourceCurrency: _rateSourceCurrency,
      timestamp: _rateTimestamp,
      loading: _rateLoading,
      sourceCurrencies: ExchangeRateService.sourceCurrencies,
      currencyName: ExchangeRateService.currencyName,
      onCurrencyChanged: (newCurrency) {
        _rateSourceCurrency = newCurrency;
        _rateService.sourceCurrency = newCurrency;
        _search(_c.text);
      },
    ));

    // If we have rates and a valid amount, build conversion entries
    if (amount != null && _rateData != null && _rateData!.isNotEmpty) {
      final conversions = _rateService.convert(amount, _rateSourceCurrency, _rateData!);
      for (final target in ExchangeRateService.targetCurrencies) {
        final value = conversions[target];
        if (value != null) {
          entries.add(_RateEntry(
            sourceAmount: amount,
            sourceCurrency: _rateSourceCurrency,
            targetCurrency: target,
            targetAmount: value,
            onExecute: () {
              _closePalette();
              Process.run('calc', []);
            },
          ));
        }
      }
    } else if (_rateLoading) {
      entries.add(_RatePlaceholderEntry(text: 'Loading rates...'));
    } else if (_rateData == null || _rateData!.isEmpty) {
      entries.add(_RatePlaceholderEntry(text: 'Unable to load exchange rate data'));
    }
    // If amount is null and we have rates: just show header (empty result list)

    // Optimization: when the entry count hasn't changed (e.g. switching source
    // currency), skip the full refitWindow dual-buffer cycle — just swap the
    // visible list directly.  Same window height → no resize needed.
    if (!wasEmpty && entries.length == _visibleResults.length) {
      _r = entries;
      _visibleResults = entries;
      _si = -1;
      setState(() {});
      return;
    }

    _renderEntries(entries, wasEmpty);
  }
  void _exec(int i) {
    // ── File submenu mode: execute the selected action ──
    if (_fileSubmenuItems != null) {
      if (i < 0 || i >= _fileSubmenuItems!.length) return;
      if (_selectedFilePath == null) return;
      final item = _fileSubmenuItems![i];
      // Translate file → close palette first, then open translate on next frame
      if (item is BuiltinFileAction && item.kind == FileActionKind.translateFile) {
        final path = _selectedFilePath!;
        UsageStatsService().record('file.translate');
        _closePalette();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          appKey.currentState?.showTranslate(initialFiles: [path]);
        });
        return;
      }
      if (item is BuiltinFileAction) {
        UsageStatsService().record('file.${item.kind.name}');
      }
      _closePalette();
      _fileSubmenuService.execute(item, _selectedFilePath!);
      return;
    }
    // ── Engine submenu mode: execute search with the selected engine ──
    if (_submenuEngines != null) {
      if (i < 0 || i >= _submenuEngines!.length) return;
      final engine = _submenuEngines![i];
      UsageStatsService().record('search.${engine.name}');
      _searchService.execute(engine, _c.text);
      _closePalette();
      return;
    }

    // ── Normal mode ──
    // _r always holds the latest data; _visibleResults is a delayed copy
    // (refitWindow → postFrameCallback → await _afterNextFrame).
    // When Enter fires between the two frames, _visibleResults is stale
    // but non-empty — so we prefer _r whenever available.
    final list = _r.isNotEmpty ? _r : _visibleResults;
    if (i < 0 || i >= list.length) return;
    final entry = list[i];
    switch (entry) {
      case _PlaceholderEntry():
      case _RateHeaderEntry():
      case _RatePlaceholderEntry():
      case _TzHeaderEntry():
      case _TzPlaceholderEntry():
        break;
      case _RateEntry(:final onExecute):
        UsageStatsService().record('exchange_rate.convert');
        onExecute(); _closePalette();
        break;
      case _TzResultEntry(:final onExecute):
        UsageStatsService().record('timezone.convert');
        onExecute(); // copy to clipboard, don't close palette
        break;
      case _CalcEntry(:final onExecute):
        UsageStatsService().record('calculator');
        onExecute(); _closePalette();
      case _DictEntry(:final onExecute):
        UsageStatsService().record('dictionary.quick_lookup');
        onExecute(); // showDictionary replaces overlay → don't closePalette
      case _TranslateEntry(:final onExecute):
        UsageStatsService().record('translate.quick_entry');
        onExecute(); // showTranslate replaces overlay → don't closePalette
      case _NoteCreateEntry(:final content):
        UsageStatsService().record('notes.create');
        _closePalette();
        NoteLauncher.createAndOpen(content.trim());
      case _NoteAppendEntry(:final note, :final content):
        final text = content.trim();
        _closePalette();
        if (text.isEmpty || note.locked) {
          // 无内容 / 锁定便签（不可追加）→ 打开/前置该便签
          UsageStatsService().record('notes.open');
          NoteLauncher.spawn(note.id);
        } else {
          UsageStatsService().record('notes.append');
          NoteLauncher.appendText(note.id, text);
        }
      case _SearchEntry(:final onExecute):
        UsageStatsService().record('search.text');
        onExecute(); _closePalette();
      case _FileResultEntry(:final fileResult):
        UsageStatsService().record('file.open');
        _openFile(fileResult.fullPath);
        _closePalette();
      case _CommandEntry(:final match):
        final cmd = (match.item as _A).cmd;
        final queryText = _c.text;
        UsageStatsService().record(cmd.id);
        _closePalette();
        if (cmd.id.startsWith('user_command.')) {
          final userCmdId = cmd.id.substring('user_command.'.length);
          final userCommands = _userCommandService.loadCommands();
          final userCmd = userCommands.cast<UserCommand?>().firstWhere(
            (c) => c!.id == userCmdId,
            orElse: () => null,
          );
          if (userCmd != null && userCmd.type != 'script') {
            final extraArgs = _extractExtraArgs(cmd, queryText);
            _userCommandService.execute(userCmd, extraArgs: extraArgs);
            return;
          }
        }
        cmd.onExecute();
    }
  }

  /// Extract extra arguments typed after the command keyword.
  ///
  /// When user types "cmd /k dir", the query matches keyword "cmd"
  /// and "/k dir" is returned as extra args.
  String _extractExtraArgs(CommandItem cmd, String query) {
    if (query.isEmpty) return '';

    // Collect all possible match terms (keyword aliases + display text)
    final terms = <String>[];
    terms.addAll(cmd.aliases); // keyword first — preferred match
    terms.add(cmd.text);       // name as fallback (usually longer)

    for (final term in terms) {
      if (term.isEmpty) continue;
      final lower = query.toLowerCase();
      final tLower = term.toLowerCase();
      // Query must start with the term followed by a space (or be exactly the term)
      if (lower == tLower) return '';
      if (lower.startsWith('$tLower ') || lower.startsWith('$tLower\t')) {
        return query.substring(term.length).trim();
      }
    }
    return '';
  }

  /// Write the currently selected file path (if any) to the palette state
  /// file so a running QuickLook process can preview it.
  void _notifyPaletteState() {
    if (_si < 0) return;
    final list = _r.isNotEmpty ? _r : _visibleResults;
    if (_si >= list.length) return;
    final entry = list[_si];
    if (entry is _FileResultEntry) {
      QuickLookPaletteState.update(
          path: entry.fileResult.fullPath, active: true);
    }
  }

  /// Notify QuickLook palette state when mouse hovers over a file entry.
  void _onFileHover(String fullPath) {
    QuickLookPaletteState.update(path: fullPath, active: true);
  }

  /// Auto-scroll the list so the selected item is visible.
  /// Uses [jumpTo] so holding an arrow key repeats smoothly without
  /// animation stacking.
  void _scrollToSelection() {
    if (_si < 0 || !_scrollCtrl.hasClients) return;
    // Each ListTile (dense) is ~48px. Scroll so the selection stays within
    // the visible area: scroll up once the item is past the top, scroll
    // down once it's near the bottom.
    const itemH = 53.0;
    final viewH = _scrollCtrl.position.viewportDimension;
    final scrollPx = _scrollCtrl.position.pixels;
    final itemTop = _si * itemH;
    final itemBottom = itemTop + itemH;
    if (itemTop < scrollPx) {
      _scrollCtrl.jumpTo(itemTop);
    } else if (itemBottom > scrollPx + viewH) {
      _scrollCtrl.jumpTo(itemBottom - viewH);
    }
  }

  /// Enter the file context submenu (Right-arrow on a _FileResultEntry, or file drag).
  void _enterFileSubmenu(String filePath) {
    var items = _fileSubmenuService.loadItems();
    // Filter: translate file only shown for supported extensions
    if (!FileSubmenuService.isTranslateSupported(filePath)) {
      items = items.where((it) => it is! BuiltinFileAction || it.kind != FileActionKind.translateFile).toList();
    }
    // Filter: convert file only shown for supported extensions
    if (!FileSubmenuService.isConvertSupported(filePath)) {
      items = items.where((it) => it is! BuiltinFileAction || it.kind != FileActionKind.convertFile).toList();
    }
    _selectedFilePath = filePath;
    _fileSubmenuMeasure = items;
    _fileSubmenuItems = null;
    _si = items.isNotEmpty ? 0 : -1;
    final v = ++_measureVersion;
    setState(() {});
    appKey.currentState?.refitWindow(() {
      if (mounted && _measureVersion == v) {
        _fileSubmenuItems = _fileSubmenuMeasure;
        _fileSubmenuMeasure = null;
        setState(() {});
      }
    });
  }

  /// Exit file submenu back to the main list — instant, no refitWindow.
  void _exitFileSubmenu() {
    _fileSubmenuMeasure = null;
    _fileSubmenuItems = null;
    _selectedFilePath = null;
    _si = 0;
    setState(() {});
  }

  /// Map logical key → 0-based digit index (0-9).
  /// Returns -1 if the key is not a digit.
  int _digitKeyIndex(LogicalKeyboardKey k) {
    if (k == LogicalKeyboardKey.digit1) return 1;
    if (k == LogicalKeyboardKey.digit2) return 2;
    if (k == LogicalKeyboardKey.digit3) return 3;
    if (k == LogicalKeyboardKey.digit4) return 4;
    if (k == LogicalKeyboardKey.digit5) return 5;
    if (k == LogicalKeyboardKey.digit6) return 6;
    if (k == LogicalKeyboardKey.digit7) return 7;
    if (k == LogicalKeyboardKey.digit8) return 8;
    if (k == LogicalKeyboardKey.digit9) return 9;
    if (k == LogicalKeyboardKey.digit0) return 0;
    return -1;
  }

  /// Enter the engine submenu (called when pressing Right on a _SearchEntry).
  /// Uses dual-buffer pattern: measure → resize → reveal (no flicker).
  void _enterSubmenu() => _enterEngineSubmenu(SearchEngineCategory.text);
  void _enterMapSubmenu() => _enterEngineSubmenu(SearchEngineCategory.map);

  void _enterEngineSubmenu(SearchEngineCategory category) {
    final engines = _searchService.loadEnginesByCategory(category);
    _submenuMeasure = engines;       // measurement tree renders this
    _submenuEngines = null;          // visible tree still shows main list
    _si = engines.isNotEmpty ? 0 : -1;
    final v = ++_measureVersion;
    setState(() {});
    appKey.currentState?.refitWindow(() {
      if (mounted && _measureVersion == v) {
        _submenuEngines = _submenuMeasure;
        _submenuMeasure = null;
        setState(() {});
      }
    });
  }

  /// Exit submenu back to the main list — instant, no refitWindow.
  void _exitSubmenu() {
    _submenuMeasure = null;
    _submenuEngines = null;
    _si = 0;
    setState(() {});
  }

  // ── Arrow repeat (custom timer, not OS key repeat) ──

Timer? _arrowDelayTimer;
  Timer? _arrowPeriodicTimer;

  void _cancelArrowRepeat() {
    _arrowDelayTimer?.cancel();
    _arrowPeriodicTimer?.cancel();
    _arrowDelayTimer = null;
    _arrowPeriodicTimer = null;
  }

  void _startArrowRepeat(LogicalKeyboardKey key, VoidCallback action) {
    _arrowDelayTimer?.cancel();
    _arrowPeriodicTimer?.cancel();
    _arrowDelayTimer = Timer(const Duration(milliseconds: 500), () {
      _arrowPeriodicTimer = Timer.periodic(const Duration(milliseconds: 60), (_) => action());
    });
  }

  void _arrowDownAction() {
    final inSub = _fileSubmenuItems != null || _submenuEngines != null;
    final listLen = _fileSubmenuItems != null
        ? _fileSubmenuItems!.length
        : _submenuEngines != null
            ? _submenuEngines!.length
            : (_r.isNotEmpty ? _r : _visibleResults).length;
    if (listLen > 0) {
      if (_si == -1) {
        setState(() => _si = 0);
      } else if (_si == listLen - 1) {
        setState(() => _si = -1);
      } else {
        setState(() => _si = _si + 1);
      }
      _scrollToSelection();
      if (!inSub) _notifyPaletteState();
    }
  }

  void _arrowUpAction() {
    final inSub = _fileSubmenuItems != null || _submenuEngines != null;
    final listLen = _fileSubmenuItems != null
        ? _fileSubmenuItems!.length
        : _submenuEngines != null
            ? _submenuEngines!.length
            : (_r.isNotEmpty ? _r : _visibleResults).length;
    if (listLen > 0) {
      if (_si == -1) {
        setState(() => _si = listLen - 1);
      } else if (_si == 0) {
        setState(() => _si = -1);
      } else {
        setState(() => _si = _si - 1);
      }
      _scrollToSelection();
      if (!inSub) _notifyPaletteState();
    }
  }

  // ── Early key event handler ──
  // Registered via FocusManager.instance.addEarlyKeyEventHandler.
  // Fires BEFORE the Focus tree walk.  Returning KeyEventResult.handled
  // skips the entire tree — the TextField's Shortcuts/Actions never fire
  // and its cursor will not move.
  //
  // Text mode   (_si == -1): left/right → ignored → TextField cursor moves
  // List mode   (_si >= 0):  ALL arrows → handled → TextField unresponsive
  // Submenu mode:            left      → handled (exit submenu)
  //                          right     → handled (no-op)
  //
  // Arrow keys use a custom repeat timer (500 ms delay, 60 ms interval).
  // OS key repeat is unreliable in a WS_POPUP Flutter window on Windows,
  // so we drive it ourselves from KeyDown / KeyUp events.

  /// HardwareKeyboard handler — fires AFTER the Focus tree.
  /// Acts as a backup for Alt+digit when the early handler can't see
  /// the digit key (e.g. when platform Shortcuts/Actions consume it).
  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!mounted) return false;
    final inSubmenu = _submenuEngines != null;
    final inFileSubmenu = _fileSubmenuItems != null;
    if (inSubmenu || inFileSubmenu) return false;
    if (!mounted) return false;
    final visible = _r.isNotEmpty ? _r : _visibleResults;
    final listLen = visible.length;
    if (listLen == 0) return false;
    if (!_altHeld) return false;
    final n = _digitKeyIndex(event.logicalKey);
    if (n >= 0 && n < listLen) {
      setState(() => _altHeld = false);
      _exec(n);
      return true;
    }
    // Non-digit while Alt badges are visible → cancel
    setState(() => _altHeld = false);
    return false;
  }

  KeyEventResult _handleEarlyKey(KeyEvent event) {
    final isDown = event is KeyDownEvent;
    final isUp = event is KeyUpEvent;
    if (!isDown && !isUp) return KeyEventResult.ignored;

    final k = event.logicalKey;
    final inSubmenu = _submenuEngines != null;
    final inFileSubmenu = _fileSubmenuItems != null;
    final visible = _r.isNotEmpty ? _r : _visibleResults;
    final listLen = inFileSubmenu
        ? _fileSubmenuItems!.length
        : inSubmenu
            ? _submenuEngines!.length
            : visible.length;

    // ── Arrow keys ─────────────────────────────────────────────────────
    if (k == LogicalKeyboardKey.arrowUp) {
      if (isDown) {
        _arrowUpAction();
        _startArrowRepeat(LogicalKeyboardKey.arrowUp, _arrowUpAction);
      } else if (isUp) {
        _cancelArrowRepeat();
      }
      return KeyEventResult.handled;
    }

    // ── ArrowDown ─────────────────────────────────────────────────────
    if (k == LogicalKeyboardKey.arrowDown) {
      if (isDown) {
        _arrowDownAction();
        _startArrowRepeat(LogicalKeyboardKey.arrowDown, _arrowDownAction);
      } else if (isUp) {
        _cancelArrowRepeat();
      }
      return KeyEventResult.handled;
    }

    // ── Rate-mode backspace: exit rate mode, preserve space ──
    // Same pattern as filter-mode backspace (see below).
    if (isDown && k == LogicalKeyboardKey.backspace && _ratePrefix != null) {
      if (_c.text == '${_ratePrefix} ') {
        _exitRateMode();
        _search(_c.text);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // ── Tz-mode backspace: exit timezone mode, preserve space ──
    if (isDown && k == LogicalKeyboardKey.backspace && _tzPrefix != null) {
      if (_c.text == '${_tzPrefix} ') {
        _exitTzMode();
        _search(_c.text);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // ── Note-mode backspace: exit note mode, preserve space ──
    if (isDown && k == LogicalKeyboardKey.backspace && _noteMode) {
      if (_c.text == '@ ' || _c.text == '＠ ') {
        _noteMode = false;
        _search(_c.text);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // ── Filter-mode backspace: exit filter, preserve space ──
    // Must be above the text-mode early-return so Backspace is intercepted
    // even when the cursor is in the TextField (_si == -1).
    // Only on KeyDown — KeyUp would see stale _c.text after TextField already
    // deleted a character (e.g. backspacing from "doc f" to "doc ").
    if (isDown && k == LogicalKeyboardKey.backspace && _activeFilter != null) {
      if (_c.text == '${_activeFilter!.keyword} ') {
        _activeFilter = null;
        _search(_c.text);
        return KeyEventResult.handled;
      }
      // Text has more content after the space — let TextField handle normally.
      return KeyEventResult.ignored;
    }

    // ── Enter ──
    // ALWAYS let Enter reach the TextField so EditableText runs its
    // full commit chain (performAction → onEditingComplete → onSubmitted).
    // List mode: stash the selected index first, then pass through.
    // This is critical for IME correctness — when the IME is selecting
    // candidates (e.g. Chinese pinyin), _c.value.composing may already
    // be empty even though the IME still needs Enter to confirm.  If we
    // consume Enter here the IME never gets it, composition is corrupted,
    // and subsequent Enter presses stop working.
    if (k == LogicalKeyboardKey.enter) {
      if (_si == -1) {
        return KeyEventResult.ignored; // → TextField → onSubmitted
      }
      if (_si >= 0 && _si < listLen) {
        // Stash selection, reset to text mode.  Do NOT call setState —
        // we're inside _handleEarlyKey and the widget rebuild would race
        // with EditableText's per-frame input processing.
        _pendingSel = _si;
        _si = -1;
      }
      return KeyEventResult.ignored; // → TextField → onSubmitted or IME
    }

    // ── Alt key: show / hide number badges ──────────────────────
    if (k == LogicalKeyboardKey.altLeft || k == LogicalKeyboardKey.altRight) {
      if (isDown && !_altHeld && listLen > 0) {
        setState(() => _altHeld = true);
        return KeyEventResult.handled; // stop Alt reaching Focus tree/IME
      }
      if (isUp && _altHeld) {
        setState(() => _altHeld = false);
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // ── Alt+digit: execute nth item ──────────────────────────────
    // Only for the main list (not submenus — submenus have their own
    // custom shortcut system).
    if (isDown && _altHeld &&
        !inSubmenu && !inFileSubmenu && listLen > 0) {
      final n = _digitKeyIndex(k);
      if (n >= 0 && n < listLen) {
        setState(() => _altHeld = false);
        _exec(n);
        return KeyEventResult.handled;
      }
      // Non-digit while Alt is active → cancel badges
      setState(() => _altHeld = false);
      return KeyEventResult.ignored;
    }

    // ── Paste detection (Ctrl+V) ──
    // Detect paste in text mode so _search() can offer a Translate entry.
    if (isDown && k == LogicalKeyboardKey.keyV &&
        HardwareKeyboard.instance.isControlPressed &&
        !inSubmenu && !inFileSubmenu && _si == -1) {
      _pasteDetected = true;
      return KeyEventResult.ignored; // let TextField handle paste
    }

    // ── In text mode, let everything else fall through to the IME ──────
    // Arrow keys and Escape are handled above (they enter list mode /
    // close the palette).  All other keys must reach the TextField for
    // IME composition and normal typing to work.
    if (!inSubmenu && !inFileSubmenu && _si == -1) {
      return KeyEventResult.ignored;
    }

    // ── All other keys only respond to KeyDown ────────────────────────
    if (!isDown) return KeyEventResult.ignored;

    // ── Shortcut keys — shared helper ──────────────────────────────────
    String? buildCombo(LogicalKeyboardKey key) {
      if (key == LogicalKeyboardKey.controlLeft || key == LogicalKeyboardKey.controlRight ||
          key == LogicalKeyboardKey.shiftLeft || key == LogicalKeyboardKey.shiftRight ||
          key == LogicalKeyboardKey.altLeft || key == LogicalKeyboardKey.altRight ||
          key == LogicalKeyboardKey.metaLeft || key == LogicalKeyboardKey.metaRight) {
        return null;
      }
      final parts = <String>[];
      if (HardwareKeyboard.instance.isControlPressed) parts.add('Ctrl');
      if (HardwareKeyboard.instance.isShiftPressed) parts.add('Shift');
      if (HardwareKeyboard.instance.isAltPressed) parts.add('Alt');
      if (HardwareKeyboard.instance.isMetaPressed) parts.add('Win');
      parts.add(key.keyLabel);
      return parts.join('+');
    }

    // ── File submenu shortcut keys ─────────────────────────────────────
    if (inFileSubmenu && isDown) {
      final combo = buildCombo(k);
      if (combo != null) {
        for (int i = 0; i < _fileSubmenuItems!.length; i++) {
          if (_fileSubmenuItems![i].shortcut == combo) { _exec(i); return KeyEventResult.handled; }
        }
      }
    }

    // ── Global command shortcut keys ───────────────────────────────────
    {
      final combo = buildCombo(k);
      if (combo != null) {
        final commands = _userCommandService.loadCommands();
        for (final cmd in commands.where((c) => c.enabled)) {
          if (cmd.shortcut == combo) {
            _closePalette();
            _userCommandService.execute(cmd);
            return KeyEventResult.handled;
          }
        }
      }
    }

    // ── Escape ──
    if (k == LogicalKeyboardKey.escape) {
      if (inFileSubmenu) {
        _exitFileSubmenu();
        return KeyEventResult.handled;
      }
      if (inSubmenu) {
        _exitSubmenu();
        return KeyEventResult.handled;
      }
      _closePalette();
      return KeyEventResult.handled;
    }

    // ── ArrowLeft ──
    if (k == LogicalKeyboardKey.arrowLeft) {
      // File submenu: go back to main list
      if (inFileSubmenu) {
        _exitFileSubmenu();
        return KeyEventResult.handled;
      }
      // Search engine submenu: go back to main list
      if (inSubmenu) {
        _exitSubmenu();
        return KeyEventResult.handled;
      }
      // List mode: deselect -> text mode, TextField does NOT get this key
      if (_si >= 0) {
        setState(() => _si = -1);
        return KeyEventResult.handled;
      }
      // Text mode: let TextField move cursor left
      return KeyEventResult.ignored;
    }

    // ── ArrowRight ──
    if (k == LogicalKeyboardKey.arrowRight) {
      // Any submenu: no deeper levels, swallow the key
      if (inFileSubmenu || inSubmenu) {
        return KeyEventResult.handled;
      }
      // List mode: on SearchEntry -> engine submenu (respects callback set in _search);
      // on FileResultEntry -> file submenu
      if (_si >= 0) {
        final entry = _visibleResults[_si];
        if (entry is _SearchEntry) {
          entry.onEnterSubmenu(); // uses _enterSubmenu (text) or _enterMapSubmenu (map)
        } else if (entry is _FileResultEntry) {
          _enterFileSubmenu(entry.fileResult.fullPath);
        }
        return KeyEventResult.handled;
      }
      // Text mode: let TextField move cursor right
      return KeyEventResult.ignored;
    }

    return KeyEventResult.ignored;
  }

  /// Open a file or directory in its default handler.
  void _openFile(String path) {
    _fileSearchService.markOpened(path);
    Process.run('cmd', ['/c', 'start', '', path]);
  }

  // ── Quick dictionary lookup ──────────────────────────────────

  void _tryDictLookup(String q) async {
    final ds = DictionaryService();
    if (!ds.isOpen) return;
    final version = ++_dictQueryVersion;
    try {
      WordEntry? result;
      if (RegExp(r'^[a-zA-Z]{3,20}$').hasMatch(q)) {
        result = await ds.query(q);
      } else if (RegExp(r'^[一-鿿]{2,6}$').hasMatch(q)) {
        // Chinese → FTS search, take best match.
        final results = await ds.searchFts(q, limit: 1);
        if (results.isNotEmpty) result = results.first;
      }
      if (!mounted || version != _dictQueryVersion) return;
      if (result != null) {
        // Avoid infinite loop: only trigger re-search if the match changed.
        final changed =
            _dictMatch == null || _dictMatch!.word.toLowerCase() != result.word.toLowerCase();
        _dictMatch = result;
        if (changed) _search(q); // re-search to surface the dict entry
      }
    } catch (_) {}
  }

  // ── Drag-drop handlers ────────────────────────────────────────

  void _handleTextDrop(String text) {
    final t = _sanitizeInput(text);
    if (t.isEmpty) return;
    final entry = _TranslateEntry(
      text: t.length > 40 ? '${t.substring(0, 40)}...' : t,
      fullText: t,
      onExecute: () {
        appKey.currentState?.showTranslate(initialText: t);
      },
    );
    // Set text silently (detach listener → set → reattach to avoid
    // _search() clobbering our entry)
    _c.removeListener(_searchListener);
    _c.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
    _c.addListener(_searchListener);
    _f.requestFocus();
    // Standard dual-buffer: _r for measurement, _visibleResults stays
    // empty until refitWindow callback fires.
    _r = [entry];
    _visibleResults = [];
    _si = -1;
    _submenuEngines = null;
    _submenuMeasure = null;
    _fileSubmenuItems = null;
    _fileSubmenuMeasure = null;
    final v = ++_measureVersion;
    setState(() {});
    appKey.currentState?.refitWindow(() {
      if (mounted && _measureVersion == v) {
        _visibleResults = _r;
        setState(() {});
      }
    });
  }

  void _handleFileDrop(List<String> paths) {
    if (paths.isEmpty) return;
    // Only single-file drops — multi-file drops are ambiguous for submenu.
    if (paths.length != 1) return;
    // Normalize any forward slashes to backslashes for Windows APIs.
    final filePath = paths.first.replaceAll('/', '\\');
    if (filePath.isEmpty) return;
    // Guard: both WM_DROPFILES and OLE IDropTarget may fire for the same
    // drop — ignore re-entry when already in or about to show file submenu.
    if (_fileSubmenuItems != null || _fileSubmenuMeasure != null) return;
    // Clear palette state before entering submenu so the dual-buffer
    // refitWindow path works from a clean starting point.
    _activeFilter = null;
    _visibleResults = [];
    _r = [];
    _si = -1;
    _submenuEngines = null;
    _submenuMeasure = null;
    _enterFileSubmenu(filePath);
  }

  @override Widget build(BuildContext c) {
    // Measurement tree: render submenu engines / file submenu if measuring, else _r
    final subForMeasure = _submenuMeasure ?? _submenuEngines;
    final hasMeasure = _r.isNotEmpty || subForMeasure != null || _fileSubmenuMeasure != null;
    // Visible tree: show submenu engines, file submenu, or _visibleResults
    final hasVisible = _visibleResults.isNotEmpty || _submenuEngines != null || _fileSubmenuItems != null;
    final measureLayer = hasMeasure
        ? _buildMeasureLayer(subForMeasure)
        : const SizedBox.shrink();
    final visibleDropdown = hasVisible
        ? _buildVisibleDropdown()
        : const SizedBox.shrink();

    return SizedBox(
      width: 540,
      height: 500,
      child: Stack(
        children: <Widget>[
          Column(
            key: widget.contentKey,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _buildTextField(hasVisible),
              visibleDropdown,
            ],
          ),
          measureLayer,
        ],
      ),
    );
  }

  Widget _buildTextField(bool showDropdown) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(width: 540, child: TextField(
      controller: _c, focusNode: _f, autofocus: true,
      textInputAction: TextInputAction.send,
      // Override default onEditingComplete: only clear composing, do NOT
      // unfocus yet.  The default calls _f.unfocus() which sends
      // TextInput.clearClient to the platform while the IME is still in
      // its completion transition (IME English commit via Enter).
      // That corrupts the IME's internal state, and the next TextField
      // inherits a broken connection where performAction is never sent
      // for Enter → onSubmitted never fires → Enter appears "swallowed".
      // We defer unfocus to _closePalette which runs in a postFrameCallback.
      onEditingComplete: _c.clearComposing,
      // onSubmitted fires when Enter reaches the TextField naturally —
      // i.e. when no IME consumed it.  In text mode (_si == -1) the early
      // key handler lets Enter pass through (returns ignored).  If the IME
      // doesn't need Enter for composition/candidate confirmation, the
      // TextField receives it and we execute the first result.
      //
      // CRITICAL: _exec(0) eventually disposes this CommandPalette.
      // If we call it synchronously inside onSubmitted we tear down
      // the TextEditingController while Flutter's EditableText is still
      // processing the Enter key — corrupting internal state.
      // Defer to the next frame so the TextField finishes its event
      // handling before we tear down the widget.
      onSubmitted: (_) {
        final sel = _pendingSel;
        _pendingSel = -1;
        final visible = _r.isNotEmpty ? _r : _visibleResults;
        final target = (sel >= 0 && sel < visible.length) ? sel : 0;
        if (visible.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _exec(target);
          });
        }
      },
      style: TextStyle(fontSize: 16, color: cs.onSurface),
      decoration: InputDecoration(
        hintText: _tzPrefix != null
            ? 'Edit date/time (yyyy-mm-dd HH:mm)...'
            : _ratePrefix != null
            ? 'Enter amount in $_rateSourceCurrency...'
            : _noteMode
            ? 'Write your thoughts now...'
            : _activeFilter != null
                ? 'Filter: ${_activeFilter!.name} — type to search...'
                : 'Type a command...',
        hintStyle: TextStyle(color: cs.onSurface.withAlpha(120)),
        prefixIcon: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => windowManager.startDragging(),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(Icons.search, size: 20, color: cs.onSurface.withAlpha(179)),
          ),
        ),
        filled: true,
        fillColor: XMateColors.panelBg(context),
        border: OutlineInputBorder(
            borderRadius: showDropdown
                ? const BorderRadius.vertical(top: Radius.circular(12))
                : BorderRadius.circular(12),
            borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: showDropdown
                ? const BorderRadius.vertical(top: Radius.circular(12))
                : BorderRadius.circular(12),
            borderSide: BorderSide(color: cs.primary.withAlpha(180))),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    ));
  }

  // ── Dropdown builders ──

  Widget _buildVisibleDropdown() {
    if (_fileSubmenuItems != null) {
      return _buildFileSubmenuList(_fileSubmenuItems!, selected: true);
    }
    if (_submenuEngines != null) {
      return _buildEngineList(_submenuEngines!, selected: true);
    }
    return _buildEntryList(_visibleResults, selected: true);
  }

  Widget _buildMeasureLayer(List<SearchEngine>? subForMeasure) {
    if (_fileSubmenuMeasure != null) {
      return _buildHiddenFileSubmenuList(_fileSubmenuMeasure!);
    }
    if (subForMeasure != null) {
      return _buildHiddenEngineList(subForMeasure);
    }
    return _buildHiddenEntryList(_r);
  }

  // ── Entry list (normal mode) ──

  Widget _buildEntryList(List<_PaletteEntry> items, {bool selected = false}) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(width: 540, child: Material(
      color: XMateColors.panelBg(context),
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
        side: BorderSide(color: cs.primary.withAlpha(60), width: 1.5),
      ),
      child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 320),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_activeFilter != null) _FilterHeader(_activeFilter!),
          Flexible(
            child: ListView.builder(controller: _scrollCtrl, padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: items.length,
              itemBuilder: (ctx, i) {
                final s = selected && i == _si;
                final tier = items[i].bgTier;
                final bgColor = tier == 0
                    ? cs.primary.withAlpha(46)    // 18%
                    : tier == 1
                        ? cs.primary.withAlpha(31) // 12%
                        : tier == 2
                            ? cs.primary.withAlpha(15) // 6%
                            : null;
                final child = items[i].buildRow(ctx, s, () => _exec(i), index: i, altHeld: _altHeld);
                if (bgColor == null) return child;
                return Container(color: bgColor, child: child);
              }),
          ),
        ]),
      ),
    ));
  }

  Widget _buildHiddenEntryList(List<_PaletteEntry> items) {
    final cs = Theme.of(context).colorScheme;
    return OverflowBox(
      alignment: Alignment.topCenter,
      minWidth: 540, maxWidth: 540,
      minHeight: 0, maxHeight: 400,
      child: IgnorePointer(
        ignoring: true,
        child: Opacity(
          opacity: 0,
          child: SizedBox(width: 540, child: Material(
            key: widget.dropdownMeasureKey,
            color: XMateColors.panelBg(context),
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
            child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 320),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (_activeFilter != null) _FilterHeader(_activeFilter!),
                Flexible(
                  child: ListView.builder(padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: items.length,
                    itemBuilder: (ctx, i) {
                      final tier = items[i].bgTier;
                      final bgColor = tier == 0
                          ? cs.primary.withAlpha(46)
                          : tier == 1
                              ? cs.primary.withAlpha(31)
                              : tier == 2
                                  ? cs.primary.withAlpha(15)
                                  : null;
                      final child = items[i].buildRow(ctx, false, () {});
                      if (bgColor == null) return child;
                      return Container(color: bgColor, child: child);
                    },
                  ),
                ),
              ]),
            ),
          )),
        ),
      ),
    );
  }

  // ── Engine list (submenu mode — matches main entry list styling) ──

  Widget _buildEngineList(List<SearchEngine> engines, {bool selected = false}) {
    final cs = Theme.of(context).colorScheme;
    final pBg = XMateColors.panelBg(context);
    final list = Column(mainAxisSize: MainAxisSize.min, children: [
      _SubmenuHeaderRow(onBack: _exitSubmenu),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Divider(height: 1, thickness: 1, color: XMateColors.divider(context)),
      ),
      Flexible(
        child: ListView.builder(padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: engines.length,
          itemBuilder: (ctx, i) {
            final e = engines[i];
            final s = selected && i == _si;
            return ListTile(
              dense: true,
              selected: s,
              selectedTileColor: XMateColors.highlightStrong(context),
              leading: Icon(
                e.copyMode ? Icons.content_copy : Icons.open_in_browser,
                size: 18, color: cs.onSurface.withAlpha(179),
              ),
              title: Text(
                e.name,
                style: TextStyle(
                  fontSize: 14, color: cs.onSurface,
                  fontWeight: s ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              onTap: () => _exec(i),
            );
          }),
      ),
    ]);

    return SizedBox(
      width: 540,
      child: Material(
        color: pBg,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: list,
        ),
      ),
    );
  }

  Widget _buildHiddenEngineList(List<SearchEngine> engines) {
    final pBg = XMateColors.panelBg(context);
    final list = Column(mainAxisSize: MainAxisSize.min, children: [
      _SubmenuHeaderRow(onBack: _exitSubmenu),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Divider(height: 1, thickness: 1, color: XMateColors.divider(context)),
      ),
      Flexible(
        child: ListView.builder(padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: engines.length,
          itemBuilder: (ctx, i) => ListTile(
            dense: true,
            leading: Icon(
              engines[i].copyMode ? Icons.content_copy : Icons.open_in_browser,
              size: 18,
            ),
            title: Text(engines[i].name, style: const TextStyle(fontSize: 14)),
          ),
        ),
      ),
    ]);

    return OverflowBox(
      alignment: Alignment.topCenter,
      minWidth: 540, maxWidth: 540,
      minHeight: 0, maxHeight: 400,
      child: IgnorePointer(
        ignoring: true,
        child: Opacity(
          opacity: 0,
          child: SizedBox(
            width: 540,
            child: Material(
              key: widget.dropdownMeasureKey,
              color: pBg,
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
              child: list,
            ),
          ),
        ),
      ),
    );
  }

  // ── File submenu builders ──

  Widget _buildFileSubmenuList(List<FileSubMenuItem> items, {bool selected = false}) {
    final cs = Theme.of(context).colorScheme;
    final pBg = XMateColors.panelBg(context);
    return SizedBox(
      width: 540,
      child: Material(
        color: pBg,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 320),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _SubmenuHeaderRow(onBack: _exitFileSubmenu),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Divider(height: 1, thickness: 1, color: XMateColors.divider(context)),
            ),
            Flexible(
              child: ListView.builder(controller: _scrollCtrl,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: items.length,
                itemBuilder: (ctx, i) {
                  final item = items[i];
                  final s = selected && i == _si;
                  return ListTile(
                    dense: true,
                    selected: s,
                    selectedTileColor: XMateColors.highlightStrong(context),
                    leading: Icon(item.icon, size: 18, color: cs.onSurface.withAlpha(179)),
                    title: Text(item.title, style: TextStyle(
                        fontSize: 14, color: cs.onSurface,
                        fontWeight: s ? FontWeight.w600 : FontWeight.normal)),
                    trailing: item.shortcut.isNotEmpty
                        ? Text(item.shortcut, style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(97)))
                        : null,
                    onTap: () => _exec(i),
                  );
                }),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildHiddenFileSubmenuList(List<FileSubMenuItem> items) {
    final pBg = XMateColors.panelBg(context);
    final list = Column(mainAxisSize: MainAxisSize.min, children: [
      _SubmenuHeaderRow(onBack: _exitFileSubmenu),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Divider(height: 1, thickness: 1, color: XMateColors.divider(context)),
      ),
      Flexible(
        child: ListView.builder(padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: items.length,
          itemBuilder: (ctx, i) => ListTile(
            dense: true,
            leading: Icon(items[i].icon, size: 18),
            title: Text(items[i].title, style: const TextStyle(fontSize: 14)),
          ),
        ),
      ),
    ]);
    return OverflowBox(
      alignment: Alignment.topCenter,
      minWidth: 540, maxWidth: 540,
      minHeight: 0, maxHeight: 400,
      child: IgnorePointer(
        ignoring: true,
        child: Opacity(
          opacity: 0,
          child: SizedBox(width: 540, child: Material(
            key: widget.dropdownMeasureKey,
            color: pBg,
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
            child: list,
          )),
        ),
      ),
    );
  }
}

// ── Submenu header row ──

class _SubmenuHeaderRow extends StatelessWidget {
  final VoidCallback? onBack;
  const _SubmenuHeaderRow({this.onBack});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onBack,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 16, 6),
        child: Row(children: [
          Icon(Icons.arrow_back, size: 14, color: cs.primary),
          const SizedBox(width: 6),
          Text('Search engines', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(138))),
        ]),
      ),
    );
  }
}

// ── Filter header row ──

class _FilterHeader extends StatelessWidget {
  final FileSearchFilter filter;
  const _FilterHeader(this.filter);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 16, 6),
      child: Row(children: [
        Icon(Icons.filter_alt, size: 14, color: cs.primary),
        const SizedBox(width: 6),
        Text('Filter: ${filter.name}',
            style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(138))),
        const Spacer(),
        Text(filter.keyword,
            style: TextStyle(fontSize: 11, color: cs.primary)),
      ]),
    );
  }
}

// ── Adapter: wraps CommandItem for the fuzzy engine ──

class _A implements CommandMatchable {
  final CommandItem cmd;
  _A(this.cmd);
  @override List<String> get matchTerms => [cmd.text, ...cmd.aliases];
  @override String get displayText => cmd.text;
  @override String? get description => cmd.description;
}

// ── Sealed palette entry types ──

sealed class _PaletteEntry {
  Widget buildRow(BuildContext context, bool selected, VoidCallback onTap,
      {int index = -1, bool altHeld = false});

  /// Background tier for visual grouping:
  ///   0 = search bar (top, 18% alpha primary)
  ///   1 = calculator / quick-dict / quick-translate (12% alpha primary)
  ///   2 = plugin commands (6% alpha primary)
  ///   3 = file results (no extra bg)
  int get bgTier => 3;

  /// Shared Alt+N badge shown at the right of list items when Alt is held.
  /// Matches the style of file submenu shortcut labels.
  static Widget altBadge(BuildContext context, int index, bool visible) {
    if (!visible || index < 0 || index > 9) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final label = index < 9 ? 'Alt+${index}' : 'Alt+0';
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Text(label,
          style: TextStyle(fontSize: 10, color: cs.primary)),
    );
  }
}

/// Format a double result for display — integers without decimal point,
/// floats with up to 10 significant digits, trailing zeros stripped.
String _formatResult(double v) {
  if (!v.isFinite) return v.toString();
  if (v == v.truncateToDouble()) {
    return v.toStringAsFixed(0);
  }
  final s = v.toStringAsPrecision(10);
  if (s.contains('.')) {
    return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
  return s;
}

class _CalcEntry extends _PaletteEntry {
  final String expression;
  final double? result;     // null = placeholder mode (only "=")
  final VoidCallback onExecute;

  _CalcEntry({required this.expression, required this.result, required this.onExecute});

  @override int get bgTier => 1;

  static const _resultColor = Color(0xFFFFA726); // orange-yellow

  @override
  Widget buildRow(BuildContext context, bool selected, VoidCallback onTap,
      {int index = -1, bool altHeld = false}) {
    final cs = Theme.of(context).colorScheme;
    final isPlaceholder = result == null;
    return GestureDetector(
      onSecondaryTap: isPlaceholder ? null : () {
        Clipboard.setData(ClipboardData(text: _formatResult(result!)));
      },
      child: ListTile(
        dense: true,
        selected: selected,
        selectedTileColor: XMateColors.highlightStrong(context),
        leading: Icon(
          Icons.calculate,
          size: 18,
          color: isPlaceholder ? cs.onSurface.withAlpha(97) : cs.onSurface.withAlpha(179),
        ),
        title: isPlaceholder
            ? Text(
                'Calculator',
                style: TextStyle(fontSize: 14, color: cs.onSurface.withAlpha(138)),
              )
            : RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: '$expression = ',
                      style: TextStyle(
                        fontSize: 14,
                        color: cs.onSurface,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    TextSpan(
                      text: _formatResult(result!),
                      style: TextStyle(
                        fontSize: 14,
                        color: _resultColor,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
        trailing: _PaletteEntry.altBadge(context, index, altHeld),
        subtitle: Text(
          isPlaceholder
              ? 'Type expression: +, -, *, /, %, ^, ()'
              : 'Open Calculator  |  Right-click to copy result',
          style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(120)),
        ),
        onTap: onTap,
      ),
    );
  }
}

class _DictEntry extends _PaletteEntry {
  final WordEntry entry;
  final VoidCallback onExecute;

  _DictEntry({required this.entry, required this.onExecute});

  @override int get bgTier => 1;

  @override
  Widget buildRow(BuildContext context, bool selected, VoidCallback onTap,
      {int index = -1, bool altHeld = false}) {
    final cs = Theme.of(context).colorScheme;
    final firstMeaning = _firstCnParagraph(entry.translation ?? '');
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: XMateColors.highlightStrong(context),
      leading: Icon(Icons.menu_book, size: 18, color: cs.primary),
      title: Text(
        entry.word,
        style: TextStyle(
          fontSize: 14,
          color: cs.onSurface,
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      trailing: _PaletteEntry.altBadge(context, index, altHeld),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              firstMeaning,
              style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(120)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            'Open dictionary',
            style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(77)),
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  static String _firstCnParagraph(String translation) {
    final para = translation.split('\\n').first.trim();
    if (para.length > 40) return '${para.substring(0, 40)}…';
    return para;
  }
}

class _TranslateEntry extends _PaletteEntry {
  final String text;       // display text (may be truncated)
  final String fullText;   // full pasted text
  final VoidCallback onExecute;

  _TranslateEntry({required this.text, required this.fullText, required this.onExecute});

  @override int get bgTier => 1;

  @override
  Widget buildRow(BuildContext context, bool selected, VoidCallback onTap,
      {int index = -1, bool altHeld = false}) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: XMateColors.highlightStrong(context),
      leading: Icon(Icons.translate, size: 18, color: cs.primary),
      title: Text(
        "Translate '$text'",
        style: TextStyle(
          fontSize: 14,
          color: cs.onSurface,
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      trailing: _PaletteEntry.altBadge(context, index, altHeld),
      subtitle: Text(
        'Open translation window',
        style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(120)),
      ),
      onTap: onTap,
    );
  }
}

class _PlaceholderEntry extends _PaletteEntry {
  @override
  Widget buildRow(BuildContext context, bool selected, VoidCallback onTap,
      {int index = -1, bool altHeld = false}) => const SizedBox.shrink();
}

// ── Note mode entries ─────────────────────────────────────────

class _NoteCreateEntry extends _PaletteEntry {
  final String content;
  _NoteCreateEntry({required this.content});

  @override int get bgTier => 0;

  @override
  Widget buildRow(BuildContext context, bool selected, VoidCallback onTap,
      {int index = -1, bool altHeld = false}) {
    final cs = Theme.of(context).colorScheme;
    final t = content.trim();
    final display = t.length > 30 ? '${t.substring(0, 30)}…' : t;
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: XMateColors.highlightStrong(context),
      leading: Icon(Icons.note_add_outlined, size: 18, color: cs.primary),
      title: Text(
        t.isEmpty ? 'New empty note' : 'New note: "$display"',
        style: TextStyle(
          fontSize: 14,
          color: cs.onSurface,
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      trailing: _PaletteEntry.altBadge(context, index, altHeld),
      subtitle: Text(
        'Create a new sticky note',
        style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(120)),
      ),
      onTap: onTap,
    );
  }
}

class _NoteAppendEntry extends _PaletteEntry {
  final NoteData note;
  final String content;
  final bool isOpen;
  final VoidCallback onDelete;
  _NoteAppendEntry(
      {required this.note,
      required this.content,
      required this.isOpen,
      required this.onDelete});

  @override
  Widget buildRow(BuildContext context, bool selected, VoidCallback onTap,
      {int index = -1, bool altHeld = false}) {
    final cs = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    // 锁定便签：不泄露内容预览
    final preview = note.locked ? 'Locked note' : note.preview;
    final display =
        preview.length > 26 ? '${preview.substring(0, 26)}…' : preview;
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: XMateColors.highlightStrong(context),
      leading: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: note.color.body(brightness),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: note.color.title(brightness), width: 1.8),
        ),
        child: note.locked
            ? Icon(Icons.lock, size: 10, color: note.color.title(brightness))
            : null,
      ),
      title: Row(children: [
        Flexible(
          child: Text(
            display,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              color: cs.onSurface,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
        if (isOpen)
          Container(
            margin: const EdgeInsets.only(left: 6),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: cs.primary.withAlpha(36),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('Active',
                style: TextStyle(fontSize: 9.5, color: cs.primary)),
          ),
      ]),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        _PaletteEntry.altBadge(context, index, altHeld),
        const SizedBox(width: 2),
        if (note.locked)
          Tooltip(
            message: 'Locked — unlock in the note first',
            waitDuration: const Duration(milliseconds: 500),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.lock_outline,
                  size: 15, color: cs.onSurface.withAlpha(110)),
            ),
          )
        else
          Tooltip(
            message: 'Delete note',
            waitDuration: const Duration(milliseconds: 500),
            child: InkWell(
              onTap: onDelete,
              borderRadius: BorderRadius.circular(5),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.delete_outline,
                    size: 15, color: cs.error.withAlpha(190)),
              ),
            ),
          ),
      ]),
      subtitle: Text(
        note.locked
            ? 'Open this note (locked)'
            : content.trim().isEmpty
                ? 'Open this note'
                : 'Append to this note',
        style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(120)),
      ),
      onTap: onTap,
    );
  }
}

class _SearchEntry extends _PaletteEntry {
  final String engineName;
  final String query;
  final VoidCallback onExecute;
  final VoidCallback onEnterSubmenu;

  _SearchEntry({required this.engineName, required this.query, required this.onExecute, required this.onEnterSubmenu});

  @override int get bgTier => 0;

  @override
  Widget buildRow(BuildContext context, bool selected, VoidCallback onTap,
      {int index = -1, bool altHeld = false}) {
    final cs = Theme.of(context).colorScheme;
    final displayQuery = query.length > 35 ? '${query.substring(0, 35)}...' : query;
    return GestureDetector(
      onSecondaryTap: onEnterSubmenu,
      child: ListTile(
        dense: true,
        selected: selected,
        selectedTileColor: XMateColors.highlightStrong(context),
        leading: Icon(Icons.search, size: 18, color: cs.onSurface.withAlpha(179)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          _PaletteEntry.altBadge(context, index, altHeld),
          Icon(Icons.chevron_right, size: 16, color: cs.onSurface.withAlpha(97)),
        ]),
        title: Text(
          'Search "$displayQuery" with $engineName',
          style: TextStyle(
            fontSize: 14,
            color: cs.onSurface,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        onTap: onTap,
      ),
    );
  }
}

class _CommandEntry extends _PaletteEntry {
  final CommandMatch match;
  final VoidCallback? onSecondaryTap;

  _CommandEntry(this.match, {this.onSecondaryTap});

  @override int get bgTier => 2;

  @override
  Widget buildRow(BuildContext context, bool selected, VoidCallback onTap,
      {int index = -1, bool altHeld = false}) {
    final cs = Theme.of(context).colorScheme;
    final cmd = (match.item as _A).cmd;
    return GestureDetector(
      onSecondaryTap: onSecondaryTap,
      child: ListTile(
    dense: true,
    selected: selected,
    selectedTileColor: XMateColors.highlightStrong(context),
    leading: Icon(cmd.icon, size: 18, color: cs.onSurface.withAlpha(179)),
    title: Text(
      cmd.text,
      style: TextStyle(
        fontSize: 14,
        color: cs.onSurface,
        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
      ),
    ),
    trailing: _PaletteEntry.altBadge(context, index, altHeld),
    subtitle: () {
      final desc = cmd.description.isNotEmpty
          ? Text(cmd.description, style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(150)))
          : null;
      if (onSecondaryTap == null) return desc;
      final hint = Text('Right-click to empty Recycle Bin',
          style: TextStyle(fontSize: 11, color: cs.primary.withAlpha(180)));
      if (desc == null) return hint;
      return Row(children: [desc, const SizedBox(width: 8), hint]);
    }(),
    onTap: onTap,
  ),
);
  }
}

class _FileResultEntry extends _PaletteEntry {
  final FileSearchResult fileResult;
  final VoidCallback onSubmenu; // right-click or right-arrow
  final VoidCallback? onHover;
  final void Function(PointerDownEvent e)? onDragDown;
  final void Function(PointerMoveEvent e)? onDragMove;
  final void Function(PointerEvent e)? onDragEnd;

  _FileResultEntry(this.fileResult, {
    required this.onSubmenu,
    this.onHover,
    this.onDragDown,
    this.onDragMove,
    this.onDragEnd,
  });

  static final _iconCache = <String, Uint8List?>{};

  @override
  Widget buildRow(BuildContext context, bool selected, VoidCallback onTap,
      {int index = -1, bool altHeld = false}) {
    final cs = Theme.of(context).colorScheme;
    final inner = MouseRegion(
      onEnter: (_) => onHover?.call(),
      child: GestureDetector(
        onSecondaryTap: onSubmenu,
        child: ListTile(
          dense: true,
          selected: selected,
          selectedTileColor: XMateColors.highlightStrong(context),
          leading: _FileIcon(ext: fileResult.ext, isDir: fileResult.isDir, filePath: fileResult.fullPath),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            _PaletteEntry.altBadge(context, index, altHeld),
            Icon(Icons.chevron_right, size: 16, color: cs.onSurface.withAlpha(97)),
          ]),
          title: Text(
            fileResult.name + (fileResult.ext.isNotEmpty ? '.${fileResult.ext}' : ''),
            style: TextStyle(
              fontSize: 14,
              color: cs.onSurface,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          subtitle: Text(
            fileResult.fullPath,
            style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(120)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: onTap,
        ),
      ),
    );

    // Wrap with Listener for OLE drag-out to Explorer / other apps.
    // Listener is used (not GestureDetector) to avoid competing in
    // the gesture arena with the inner GestureDetector / ListTile.
    if (onDragDown == null || onDragMove == null || onDragEnd == null) {
      return inner;
    }
    return Listener(
      onPointerDown: onDragDown,
      onPointerMove: onDragMove,
      onPointerUp: onDragEnd,
      onPointerCancel: onDragEnd,
      child: inner,
    );
  }
}

/// A small (18×18) file icon widget that shows the system icon for a file
/// extension, falling back to a generic Material icon.
class _FileIcon extends StatefulWidget {
  final String ext;
  final bool isDir;
  final String filePath;
  const _FileIcon({required this.ext, required this.isDir, required this.filePath});
  @override State<_FileIcon> createState() => _FileIconState();
}

class _FileIconState extends State<_FileIcon> {
  Uint8List? _png;
  String? _loadingKey;
  static final _channel = MethodChannel('com.xmate/filesearch');

  @override void initState() {
    super.initState();
    _load();
  }

  @override void didUpdateWidget(_FileIcon old) {
    super.didUpdateWidget(old);
    if (old.ext != widget.ext || old.isDir != widget.isDir || old.filePath != widget.filePath) _load();
  }

  void _load() {
    final cacheKey = widget.isDir ? widget.filePath : widget.filePath;
    _png = _FileResultEntry._iconCache[cacheKey];
    if (_png == null && _loadingKey != cacheKey) {
      _loadingKey = cacheKey;
      _channel.invokeMethod('getFileIcon', {'path': widget.filePath}).then((v) {
        if (_loadingKey != cacheKey) return;
        _loadingKey = null;
        if (!mounted) return;
        if (v is Uint8List && v.isNotEmpty) {
          _FileResultEntry._iconCache[cacheKey] = v;
          setState(() => _png = v);
        } else {
          _FileResultEntry._iconCache[cacheKey] = null;
          setState(() => _png = null);
        }
      }).catchError((_) {
        if (_loadingKey != cacheKey) return;
        _loadingKey = null;
        _FileResultEntry._iconCache[cacheKey] = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_png != null) {
      return Image.memory(_png!, width: 18, height: 18, gaplessPlayback: true);
    }
    final cs = Theme.of(context).colorScheme;
    final icon = widget.isDir ? Icons.folder : Icons.insert_drive_file;
    return Icon(icon, size: 18, color: cs.onSurface.withAlpha(179));
  }
}

// ── Exchange rate entry types ──

/// Format a monetary amount for display — 2 decimal places for small amounts,
/// 0 decimals for large integer amounts, stripping trailing zeros.
String _formatRateAmount(double v) {
  if (!v.isFinite) return v.toString();
  if (v.abs() >= 1000 && v == v.truncateToDouble()) {
    return v.toStringAsFixed(0);
  }
  // 2 decimal places, strip trailing zeros
  final s = v.toStringAsFixed(2);
  return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
}

/// Header row shown at the top of rate results: currency selector pills + timestamp.
class _RateHeaderEntry extends _PaletteEntry {
  final String ratePrefix;
  final String sourceCurrency;
  final DateTime? timestamp;
  final bool loading;
  final List<String> sourceCurrencies;
  final String Function(String) currencyName;
  final ValueChanged<String> onCurrencyChanged;

  _RateHeaderEntry({
    required this.ratePrefix,
    required this.sourceCurrency,
    required this.timestamp,
    required this.loading,
    required this.sourceCurrencies,
    required this.currencyName,
    required this.onCurrencyChanged,
  });

  @override int get bgTier => 2;

  @override
  Widget buildRow(BuildContext context, bool selected, VoidCallback onTap,
      {int index = -1, bool altHeld = false}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Source currency pills
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: sourceCurrencies.map((code) {
                final isActive = code == sourceCurrency;
                return Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: GestureDetector(
                    onTap: () => onCurrencyChanged(code),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: isActive ? cs.primary : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isActive ? cs.primary : cs.onSurface.withAlpha(60),
                          width: 1,
                        ),
                      ),
                      child: Text(
                        code,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: isActive ? cs.onPrimary : cs.onSurface.withAlpha(179),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 4),
          // Timestamp
          Row(
            children: [
              if (loading)
                SizedBox(
                  width: 10, height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: cs.onSurface.withAlpha(120),
                  ),
                ),
              if (loading) const SizedBox(width: 6),
              Text(
                loading
                    ? 'Updating...'
                    : timestamp != null
                        ? 'Updated: ${timestamp!.year}-${_pad2(timestamp!.month)}-${_pad2(timestamp!.day)} ${_pad2(timestamp!.hour)}:${_pad2(timestamp!.minute)}'
                        : 'No data',
                style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(100)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _pad2(int n) => n.toString().padLeft(2, '0');
}

/// A single currency conversion result row.
class _RateEntry extends _PaletteEntry {
  final double sourceAmount;
  final String sourceCurrency;
  final String targetCurrency;
  final double targetAmount;
  final VoidCallback onExecute;

  _RateEntry({
    required this.sourceAmount,
    required this.sourceCurrency,
    required this.targetCurrency,
    required this.targetAmount,
    required this.onExecute,
  });

  @override int get bgTier => 3;

  @override
  Widget buildRow(BuildContext context, bool selected, VoidCallback onTap,
      {int index = -1, bool altHeld = false}) {
    final cs = Theme.of(context).colorScheme;
    final symbol = ExchangeRateService.currencySymbol(targetCurrency);
    final name = ExchangeRateService.currencyName(targetCurrency);
    final formatted = _formatRateAmount(targetAmount);
    final isOnshoreOffshore = targetCurrency == 'CNY' || targetCurrency == 'CNH';
    final label = isOnshoreOffshore
        ? (targetCurrency == 'CNY' ? 'Onshore' : 'Offshore')
        : name;

    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: XMateColors.highlightStrong(context),
      leading: SizedBox(
        width: 48,
        child: Text(
          targetCurrency,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: cs.primary,
          ),
        ),
      ),
      title: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '$symbol ',
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurface,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            TextSpan(
              text: formatted,
              style: TextStyle(
                fontSize: 14,
                color: const Color(0xFFFFA726), // same as calculator result
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      trailing: _PaletteEntry.altBadge(context, index, altHeld),
      subtitle: Text(
        '${_formatRateAmount(sourceAmount)} $sourceCurrency → $label',
        style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(120)),
      ),
      onTap: onTap,
    );
  }
}

/// Placeholder entry for loading / error states in rate mode.
class _RatePlaceholderEntry extends _PaletteEntry {
  final String text;
  _RatePlaceholderEntry({required this.text});

  @override int get bgTier => 3;

  @override
  Widget buildRow(BuildContext context, bool selected, VoidCallback onTap,
      {int index = -1, bool altHeld = false}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(
        text,
        style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(120)),
      ),
    );
  }
}

// ── Timezone entry types ──

/// Header row for timezone mode: two dropdown menus (source → target), centered.
/// The arrow between them can be clicked to swap source and target.
class _TzHeaderEntry extends _PaletteEntry {
  final String sourceTimezone;
  final String targetTimezone;
  final ValueChanged<String> onSourceChanged;
  final ValueChanged<String> onTargetChanged;

  _TzHeaderEntry({
    required this.sourceTimezone,
    required this.targetTimezone,
    required this.onSourceChanged,
    required this.onTargetChanged,
  });

  @override int get bgTier => 2;

  static const _tzOptions = TimezoneService.allTimezones;

  @override
  Widget buildRow(BuildContext context, bool selected, VoidCallback onTap,
      {int index = -1, bool altHeld = false}) {
    final cs = Theme.of(context).colorScheme;

    Widget buildDropdown({
      required String value,
      required ValueChanged<String?> onChanged,
    }) {
      return Container(
        width: 155,
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.primary.withAlpha(100), width: 1),
          color: cs.surfaceContainerHighest.withAlpha(80),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _tzOptions.contains(value) ? value : null,
            isExpanded: true,
            isDense: true,
            icon: Icon(Icons.expand_more, size: 16, color: cs.onSurface.withAlpha(140)),
            dropdownColor: cs.surfaceContainerHigh,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.primary),
            selectedItemBuilder: (ctx) => _tzOptions.map<Widget>((tz) {
              return Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  TimezoneService.cityLabel(tz),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.primary),
                  overflow: TextOverflow.ellipsis,
                ),
              );
            }).toList(),
            items: _tzOptions.map<DropdownMenuItem<String>>((tz) {
              return DropdownMenuItem<String>(
                value: tz,
                child: SizedBox(
                  width: 220,
                  child: Text(
                    TimezoneService.displayName(tz),
                    style: TextStyle(fontSize: 13, color: cs.onSurface),
                  ),
                ),
              );
            }).toList(),
            onChanged: onChanged,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          buildDropdown(value: sourceTimezone, onChanged: (v) { if (v != null) onSourceChanged(v); }),
          GestureDetector(
            onTap: () {
              // Swap source and target
              final tmp = sourceTimezone;
              onSourceChanged(targetTimezone);
              onTargetChanged(tmp);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Icon(Icons.swap_horiz, size: 20, color: cs.primary),
            ),
          ),
          buildDropdown(value: targetTimezone, onChanged: (v) { if (v != null) onTargetChanged(v); }),
        ],
      ),
    );
  }
}

/// A single timezone conversion result row — click to copy the time.
class _TzResultEntry extends _PaletteEntry {
  final TzResult result;
  final String sourceTz;
  final String targetTz;
  final VoidCallback onExecute;

  _TzResultEntry({
    required this.result,
    required this.sourceTz,
    required this.targetTz,
    required this.onExecute,
  });

  @override int get bgTier => 3;

  @override
  Widget buildRow(BuildContext context, bool selected, VoidCallback onTap,
      {int index = -1, bool altHeld = false}) {
    final cs = Theme.of(context).colorScheme;
    final t = result.time;
    final timeStr =
        '${t.year}-${_pad2(t.month)}-${_pad2(t.day)} '
        '${_pad2(t.hour)}:${_pad2(t.minute)}';
    final offSign = result.utcOffset.isNegative ? '-' : '+';
    final offAbs = result.utcOffset.abs();
    final offH = offAbs.inHours;
    final offM = offAbs.inMinutes.remainder(60);
    final utcStr = offM == 0
        ? 'UTC$offSign$offH'
        : 'UTC$offSign$offH:${offM.toString().padLeft(2, '0')}';
    final dstStr = result.isDst ? ', DST' : '';
    final abbrStr = result.abbreviation.isNotEmpty ? ' ${result.abbreviation}' : '';
    final offsetDetail = '($utcStr$dstStr)';
    final diffStr = TimezoneService.formatOffsetDiff(result.offsetDiff);

    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: XMateColors.highlightStrong(context),
      title: Center(
        child: RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: timeStr,
                style: TextStyle(
                  fontSize: 15,
                  color: const Color(0xFFFFA726),
                  fontWeight: FontWeight.w600,
                ),
              ),
              TextSpan(
                text: '$abbrStr $offsetDetail  |  $diffStr',
                style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(140)),
              ),
            ],
          ),
        ),
      ),
      subtitle: Center(
        child: Text(
          'Click to copy time',
          style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(100)),
        ),
      ),
      onTap: onTap,
    );
  }

  static String _pad2(int n) => n.toString().padLeft(2, '0');
}

/// Placeholder / hint entry for timezone mode when input is invalid.
class _TzPlaceholderEntry extends _PaletteEntry {
  final String text;
  _TzPlaceholderEntry({required this.text});

  @override int get bgTier => 3;

  @override
  Widget buildRow(BuildContext context, bool selected, VoidCallback onTap,
      {int index = -1, bool altHeld = false}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(
        text,
        style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(120)),
      ),
    );
  }
}
