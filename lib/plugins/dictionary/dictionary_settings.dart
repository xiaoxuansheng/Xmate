/// Dictionary settings section — embedded in the Translate&Dict tab.
///
/// Displays DB status, selection, CSV import/combine, and Daily Word tag filters.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/picker/picker_service.dart';
import '../../core/settings/settings_service.dart';
import 'dictionary_service.dart';

/// Embedded settings widget for the dictionary plugin.
///
/// Lives inside the Translate&Dict tab, below the translation section.
class DictionarySettings extends StatefulWidget {
  const DictionarySettings({super.key});

  @override
  State<DictionarySettings> createState() => _DictionarySettingsState();
}

class _DictionarySettingsState extends State<DictionarySettings> {
  static const _kDbPathKey = 'dictionary.dbPath';
  static const _kDailyWordTagsKey = 'dictionary.dailyWordTags';
  static const _accent = Color(0xFF5AAAC2);

  final _service = DictionaryService();
  final _settings = SettingsService();

  String? _dbPath;
  String _status = 'No database loaded';
  int _entryCount = 0;
  int _fileSize = 0;
  bool _initializing = true;

  // Daily Word tag filter state
  List<String> _availableTags = [];
  Set<String> _selectedTags = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _service.init();

    // Auto-load lemma from bundled assets.
    await _service.loadLemmaFromAsset();

    // Open saved DB if not already open.
    if (!_service.isOpen) {
      final savedPath = _settings.get(_kDbPathKey) as String?;
      if (savedPath != null && savedPath.isNotEmpty) {
        try {
          await _service.openDatabase(savedPath);
        } catch (_) {
          _status = 'Failed to open saved DB: $savedPath';
        }
      }
    }

    // Read current DB path (already open by plugin or previous session).
    _dbPath = _service.activeDbPath ?? _settings.get(_kDbPathKey) as String?;

    await _refreshStats();
    await _refreshTags();
    final savedTagStr = _settings.get(_kDailyWordTagsKey) as String?;
    if (savedTagStr != null && savedTagStr.isNotEmpty) {
      _selectedTags = savedTagStr.split(',').toSet();
    }

    if (mounted) {
      setState(() => _initializing = false);
    }
  }

  Future<void> _refreshStats() async {
    if (!_service.isOpen) return;
    final stats = await _service.getStats();
    setState(() {
      _entryCount = stats.entryCount;
      _fileSize = stats.fileSize;
      _status =
          '${_fmtNum(_entryCount)} entries  ·  ${_fmtSize(_fileSize)}';
    });
  }

  Future<void> _refreshTags() async {
    if (!_service.isOpen) return;
    try {
      final tags = await _service.getTags();
      if (mounted) setState(() => _availableTags = tags);
    } catch (_) {}
  }

  // ── Actions ────────────────────────────────────────────────

  Future<void> _selectDb() async {
    final path =
        await PickerService().pickFile(title: 'Select dictionary database (.db)');
    if (path == null || path.isEmpty) return;

    try {
      await _service.openDatabase(path);
      await _settings.set(_kDbPathKey, path);
      setState(() => _dbPath = path);
      await _refreshStats();
      await _refreshTags();
    } catch (e) {
      setState(() => _status = 'Failed to open: $e');
    }
  }

  Future<void> _importCsv() async {
    final path =
        await PickerService().pickFile(title: 'Select ECDICT CSV file (.csv)');
    if (path == null || path.isEmpty) return;

    if (!_service.isOpen) {
      try {
        final dbPath = await _service.createDatabase();
        await _settings.set(_kDbPathKey, dbPath);
        setState(() => _dbPath = dbPath);
      } catch (e) {
        setState(() => _status = 'Failed to create DB: $e');
        return;
      }
    }

    setState(() => _status = 'Importing...');

    try {
      await _service.importCsv(
        path,
        onProgress: (p) {
          if (mounted) setState(() => _status = p.message ?? 'Importing...');
        },
      );
      await _refreshStats();
      await _refreshTags();
    } catch (e) {
      setState(() => _status = 'Import error: $e');
    }
  }

  Future<void> _combineCsv() async {
    final path =
        await PickerService().pickFile(title: 'Select ECDICT CSV file (.csv)');
    if (path == null || path.isEmpty) return;

    if (!_service.isOpen) {
      setState(() => _status = 'Open a database first');
      return;
    }

    setState(() => _status = 'Combining...');

    try {
      await _service.combineCsv(
        path,
        onProgress: (p) {
          if (mounted) setState(() => _status = p.message ?? 'Combining...');
        },
      );
      await _refreshStats();
      await _refreshTags();
    } catch (e) {
      setState(() => _status = 'Combine error: $e');
    }
  }

  void _toggleTag(String tag) {
    setState(() {
      if (_selectedTags.contains(tag)) {
        _selectedTags.remove(tag);
      } else {
        _selectedTags.add(tag);
      }
    });
    _settings.set(_kDailyWordTagsKey, _selectedTags.join(','));
  }

  // ── Build ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        _sectionHeader('Dictionary', Icons.menu_book),
        const SizedBox(height: 8),

        Container(
          decoration: BoxDecoration(
            color: cs.onSurface.withAlpha(8),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Row 1: Status (entries + file size)
              _statusRow(),
              const _Divider(),

              // Row 2: DB path selection
              _actionRow(
                label: 'Database',
                buttonText: 'Select...',
                subtitle: _dbPath ?? 'No database selected',
                onTap: _selectDb,
              ),
              const _Divider(),

              // Row 3: Import + Combine CSV buttons
              _importRow(),
              const _Divider(),

              // Row 4: Daily Word tag filter
              _dailyWordRow(),
              const _Divider(),

              // Row 5: Copyright attribution
              _copyrightRow('Dictionary data: ECDICT (skywind3000/ECDICT)'),

              if (_initializing)
                const Padding(
                  padding: EdgeInsets.fromLTRB(14, 8, 14, 8),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Sub-widgets ────────────────────────────────────────────

  Widget _sectionHeader(String title, IconData icon) {
    final cs = Theme.of(context).colorScheme;
    return Row(children: [
      Icon(icon, size: 16, color: cs.primary),
      const SizedBox(width: 6),
      Text(title,
          style: TextStyle(
              fontSize: 13,
              color: cs.primary,
              fontWeight: FontWeight.w500)),
    ]);
  }

  Widget _statusRow() {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Icon(
            _service.isOpen ? Icons.check_circle : Icons.info_outline,
            size: 14,
            color: _service.isOpen
                ? const Color(0xFF4CAF50)
                : cs.onSurface.withAlpha(100),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _status,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withAlpha(180),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionRow({
    required String label,
    required String buttonText,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withAlpha(180),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withAlpha(100),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              foregroundColor: _accent,
              textStyle: const TextStyle(fontSize: 12),
            ),
            child: Text(buttonText),
          ),
        ],
      ),
    );
  }

  Widget _importRow() {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              'Import',
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withAlpha(180),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Row(
              children: [
                _miniBtn('Import CSV', _importCsv),
                const SizedBox(width: 8),
                _miniBtn('Combine CSV', _combineCsv),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dailyWordRow() {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 72,
                child: Text(
                  'Daily Word',
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withAlpha(180),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Expanded(
                child: _availableTags.isEmpty
                    ? Text(
                        'No database loaded',
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withAlpha(80),
                        ),
                      )
                    : Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          ..._availableTags.map((tag) => _tagChip(tag)),
                          _tagChip('No Tag'),
                        ],
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tagChip(String tag) {
    final selected = _selectedTags.contains(tag);
    final color = _tagColor(tag);

    return GestureDetector(
      onTap: () => _toggleTag(tag),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: selected
              ? color.withAlpha(35)
              : const Color(0xFF888888).withAlpha(20),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: selected
                ? color.withAlpha(120)
                : const Color(0xFF888888).withAlpha(50),
            width: 0.8,
          ),
        ),
        child: Text(
          tag,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: selected ? color : const Color(0xFF888888),
          ),
        ),
      ),
    );
  }

  /// Maps common exam tags to distinct colors.
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
      case 'no tag':
        return const Color(0xFF5AAAC2);
      default:
        return const Color(0xFF5AAAC2);
    }
  }

  Widget _miniBtn(String label, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          color: cs.primary.withAlpha(20),
          border: Border.all(
            color: cs.primary.withAlpha(60),
            width: 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: cs.primary,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _copyrightRow(String text) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: cs.onSurface.withAlpha(70),
        ),
      ),
    );
  }

  // ── Formatting ─────────────────────────────────────────────

  String _fmtNum(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(0)}K';
    return n.toString();
  }

  String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }
}

/// Thin divider.
class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: 14,
      endIndent: 14,
      color: Theme.of(context).dividerColor,
    );
  }
}
