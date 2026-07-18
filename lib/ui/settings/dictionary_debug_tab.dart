/// Dictionary debug tab — DB and import management.
///
/// Appears in Settings → Debug tab. Dictionary search has moved to its own
/// standalone window (xmate.exe --dictionary), launched from the command palette.
library;

import 'package:flutter/material.dart';

import '../../core/picker/picker_service.dart';
import '../../core/settings/settings_service.dart';
import '../../plugins/dictionary/dictionary_service.dart';

/// Debug management widget for the dictionary plugin.
///
/// Handles database selection, CSV import, and lemma loading.
class DictionaryDebugTab extends StatefulWidget {
  const DictionaryDebugTab({super.key});

  @override
  State<DictionaryDebugTab> createState() => _DictionaryDebugTabState();
}

class _DictionaryDebugTabState extends State<DictionaryDebugTab> {
  static const _kDbPathKey = 'dictionary.dbPath';
  static const _accent = Color(0xFF5AAAC2);

  final _service = DictionaryService();
  final _settings = SettingsService();

  String? _dbPath;
  String _status = 'No database loaded';
  int _entryCount = 0;
  int _fileSize = 0;
  bool _initializing = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _service.init();

    final savedPath = _settings.get(_kDbPathKey) as String?;
    if (savedPath != null && savedPath.isNotEmpty) {
      try {
        await _service.openDatabase(savedPath);
        _dbPath = savedPath;
        await _refreshStats();
      } catch (_) {
        _status = 'Failed to open saved DB: $savedPath';
      }
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
      _status = '${_fmtNum(_entryCount)} entries  ·  ${_fmtSize(_fileSize)}';
    });
  }

  // ── Actions ────────────────────────────────────────────────

  Future<void> _selectDb() async {
    final path = await PickerService()
        .pickFile(title: 'Select dictionary database (.db)');
    if (path == null || path.isEmpty) return;

    try {
      await _service.openDatabase(path);
      await _settings.set(_kDbPathKey, path);
      setState(() => _dbPath = path);
      await _refreshStats();
    } catch (e) {
      setState(() => _status = 'Failed to open: $e');
    }
  }

  Future<void> _combineCsv() async {
    final path = await PickerService()
        .pickFile(title: 'Select ECDICT CSV file (.csv)');
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
          if (mounted) {
            setState(() {
              _status = p.message ?? 'Combining...';
            });
          }
        },
      );
      await _refreshStats();
    } catch (e) {
      setState(() => _status = 'Combine error: $e');
    }
  }

  Future<void> _importCsv() async {
    final path = await PickerService()
        .pickFile(title: 'Select ECDICT CSV file (.csv)');
    if (path == null || path.isEmpty) return;

    // If no DB is open yet, create one first.
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
          if (mounted) {
            setState(() {
              _status = p.message ?? 'Importing...';
            });
          }
        },
      );
      await _refreshStats();
    } catch (e) {
      setState(() => _status = 'Import error: $e');
    }
  }

  // ── Build ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return _sectionCard(
      context: context,
      title: 'Dictionary',
      icon: Icons.menu_book,
      children: [
        _statusRow(context),
        const _ThinDivider(),
        _actionRow(
          context,
          label: 'Database',
          buttonText: 'Select DB...',
          subtitle: _dbPath ?? 'No database selected',
          onTap: _selectDb,
        ),
        const _ThinDivider(),
        _actionRow(
          context,
          label: 'Import',
          buttonText: 'Import CSV...',
          subtitle: 'Import ECDICT CSV file',
          onTap: _importCsv,
        ),
        const _ThinDivider(),
        _actionRow(
          context,
          label: 'Combine',
          buttonText: 'Combine CSV...',
          subtitle: 'Merge new CSV into current DB (upsert)',
          onTap: _combineCsv,
        ),
        const _ThinDivider(),
        if (_initializing)
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 8, 14, 8),
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }

  // ── Sub-widgets ────────────────────────────────────────────

  Widget _statusRow(BuildContext context) {
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

  Widget _actionRow(
    BuildContext context, {
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
            width: 64,
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              foregroundColor: _accent,
              textStyle: const TextStyle(fontSize: 12),
            ),
            child: Text(buttonText),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({
    required BuildContext context,
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Icon(icon, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  color: cs.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: cs.onSurface.withAlpha(8),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ],
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

/// Thin divider matching settings_page _Divider style.
class _ThinDivider extends StatelessWidget {
  const _ThinDivider();

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
