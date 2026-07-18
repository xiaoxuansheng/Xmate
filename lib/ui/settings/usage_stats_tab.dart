/// Usage statistics tab — shows feature usage counts.
///
/// Appears in Settings → Debug tab. Read-only view with reset option.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/stats/usage_stats_service.dart';

class UsageStatsTab extends StatefulWidget {
  const UsageStatsTab({super.key});

  @override
  State<UsageStatsTab> createState() => _UsageStatsTabState();
}

class _UsageStatsTabState extends State<UsageStatsTab> {

  late Map<String, int> _stats;
  late int _total;
  bool _hasData = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    final all = UsageStatsService().getAll();
    final total = UsageStatsService().totalCount;
    setState(() {
      _stats = all;
      _total = total;
      _hasData = all.isNotEmpty;
    });
  }

  // ── Friendly labels for known feature IDs ──

  static const _labels = <String, String>{
    'palette.open': 'Open palette (hotkey)',
    'palette.open_with_selection': 'Open palette + grab selection',
    'settings.open': 'Open settings',
    'screenshot.activate': 'Screenshot',
    'screenshot.hotkey': 'Screenshot (hotkey)',
    'screenshot.tray': 'Screenshot (tray)',
    'screenrecording.hotkey': 'Screen recording (hotkey)',
    'quicklook.hotkey': 'QuickLook (hotkey)',
    'translate.quick_entry': 'Translate (palette entry)',
    'translate.open': 'Translate (command)',
    'file.open': 'Open file',
    'file.translate': 'Translate file',
    'file.delete': 'Delete file',
    'file.copy': 'Copy file',
    'file.copyPath': 'Copy file path',
    'file.properties': 'File properties',
    'file.openFolder': 'Open containing folder',
    'search.text': 'Web search',
    'calculator': 'Calculator',
    'exchange_rate.convert': 'Exchange rate convert',
    'timezone.convert': 'Timezone convert',
    'dictionary.quick_lookup': 'Dictionary quick lookup',
    'dictionary.activate': 'Dictionary (command)',
    'screenrecording.activate': 'Screen recording (command)',
    'quicklook.activate': 'QuickLook (command)',
    'file_converter.activate': 'File converter (command)',
    'file.cut': 'Cut file',
    'file.shortcut': 'Create desktop shortcut',
    'file.pinToStart': 'Pin to Start',
    'file.openAsAdmin': 'Open as admin',
    'file.convertFile': 'Convert file',
    'translate.from_quicklook': 'Translate (from QuickLook)',
  };

  String _label(String id) {
    if (_labels.containsKey(id)) return _labels[id]!;
    if (id.startsWith('user_command.')) {
      return 'User command: ${id.substring('user_command.'.length)}';
    }
    if (id.startsWith('search.')) {
      return 'Search: ${id.substring('search.'.length)}';
    }
    if (id.startsWith('file.')) {
      return 'File: ${id.substring('file.'.length)}';
    }
    return id;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _sectionCard(
      context: context,
      title: 'Usage Statistics',
      icon: Icons.bar_chart,
      children: [
        _summaryRow(context),
        if (!_hasData)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            child: Text(
              'No usage data yet. Use features to collect stats.',
              style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(97)),
            ),
          ),
        if (_hasData) ...[
          _tableHeader(context),
          ..._stats.entries.map((e) => _statRow(context, e.key, e.value)),
          _tableFooter(context),
        ],
      ],
    );
  }

  Widget _summaryRow(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Icon(
            _hasData ? Icons.check_circle : Icons.info_outline,
            size: 14,
            color: _hasData
                ? const Color(0xFF4CAF50)
                : cs.onSurface.withAlpha(100),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _hasData
                  ? '${_stats.length} features tracked  ·  $_total total uses'
                  : 'No data collected',
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withAlpha(179),
              ),
            ),
          ),
          if (_hasData)
            _miniButton(
              icon: Icons.refresh,
              tooltip: 'Refresh',
              onTap: _refresh,
              color: cs.primary,
            ),
          if (_hasData) ...[
            const SizedBox(width: 4),
            _miniButton(
              icon: Icons.delete_outline,
              tooltip: 'Reset all stats',
              onTap: () async {
                await UsageStatsService().resetAll();
                _refresh();
              },
              color: cs.primary,
            ),
          ],
        ],
      ),
    );
  }

  Widget _miniButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    required Color color,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: tooltip,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 14, color: color),
        ),
      ),
    );
  }

  Widget _tableHeader(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = cs.onSurface.withAlpha(97);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      color: cs.onSurface.withAlpha(6),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              'Feature',
              style: TextStyle(fontSize: 11, color: muted, fontWeight: FontWeight.w600),
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              'Count',
              style: TextStyle(fontSize: 11, color: muted, fontWeight: FontWeight.w600),
              textAlign: TextAlign.right,
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              '%',
              style: TextStyle(fontSize: 11, color: muted, fontWeight: FontWeight.w600),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statRow(BuildContext context, String id, int count) {
    final cs = Theme.of(context).colorScheme;
    final pct = _total > 0 ? (count * 100.0 / _total) : 0.0;
    final accent = cs.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    _label(id),
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withAlpha(179),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: id));
                  },
                  child: Tooltip(
                    message: 'Copy feature ID',
                    child: Icon(Icons.copy, size: 10,
                        color: cs.onSurface.withAlpha(61)),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              count.toString(),
              style: TextStyle(
                fontSize: 12,
                color: count > 10 ? accent : cs.onSurface.withAlpha(138),
                fontWeight: count > 10 ? FontWeight.w600 : FontWeight.normal,
              ),
              textAlign: TextAlign.right,
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              pct >= 1.0 ? '${pct.toStringAsFixed(0)}%' : '<1%',
              style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(97)),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tableFooter(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: cs.onSurface.withAlpha(10)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Total',
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withAlpha(138),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            _total.toString(),
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ── Section card (matches settings_page _SectionCard style) ──

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
}
