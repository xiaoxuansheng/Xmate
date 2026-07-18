/// Environment setup checker widget — placed in Settings → Debug tab.
///
/// Encapsulates the SetupChecker logic that was previously in HelpPage.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/setup/setup_checker.dart';

class SetupCheckerTab extends StatefulWidget {
  const SetupCheckerTab({super.key});

  @override
  State<SetupCheckerTab> createState() => _SetupCheckerTabState();
}

class _SetupCheckerTabState extends State<SetupCheckerTab> {
  final SetupChecker _checker = SetupChecker();
  StreamSubscription<SetupState>? _sub;
  SetupState? _state;

  @override
  void initState() {
    super.initState();
    _state = _checker.current;
    _sub = _checker.onStateChanged.listen((s) {
      if (mounted) setState(() => _state = s);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _checker.dispose();
    super.dispose();
  }

  void _run() {
    if (_state?.running == true) return;
    _checker.runAll();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final running = _state?.running ?? false;
    final done = _state?.done ?? false;
    final items = _state?.items ?? _checker.current.items;
    final total = items.length;
    final completed = items.where((i) => i.status != SetupItemStatus.pending && i.status != SetupItemStatus.running).length;
    final errors = items.where((i) => i.status == SetupItemStatus.error).length;
    final logPath = _state?.logPath;

    return Container(
      decoration: BoxDecoration(
        color: cs.onSurface.withAlpha(8),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.build, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                'Environment Setup Check',
                style: TextStyle(fontSize: 13, color: cs.primary, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              SizedBox(
                height: 30,
                child: ElevatedButton.icon(
                  onPressed: running ? null : _run,
                  icon: Icon(running ? Icons.hourglass_empty : Icons.play_arrow, size: 16),
                  label: Text(
                    running ? 'Running...' : (done ? 'Re-run' : 'Run Check'),
                    style: const TextStyle(fontSize: 12),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: cs.primary,
                    foregroundColor: cs.onPrimary,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                ),
              ),
            ],
          ),
          if (running || done) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: total > 0 ? completed / total : 0,
                minHeight: 6,
                backgroundColor: cs.onSurface.withAlpha(20),
                valueColor: AlwaysStoppedAnimation<Color>(errors > 0 ? Colors.redAccent : cs.primary),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              running
                  ? '$completed / $total checks completed'
                  : 'Done — OK: ${items.where((i) => i.status == SetupItemStatus.ok).length}, '
                      'Warnings: ${items.where((i) => i.status == SetupItemStatus.warning).length}, '
                      'Errors: $errors',
              style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(138)),
            ),
            const SizedBox(height: 6),
            const Divider(height: 1),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (_, i) => _buildItemRow(context, items[i]),
              ),
            ),
          ],
          if (logPath != null) ...[
            const SizedBox(height: 6),
            Text('Log saved: $logPath',
                style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(120))),
          ],
        ],
      ),
    );
  }

  Widget _buildItemRow(BuildContext context, SetupCheckItem item) {
    final cs = Theme.of(context).colorScheme;
    IconData icon;
    Color color;
    switch (item.status) {
      case SetupItemStatus.ok:
        icon = Icons.check_circle; color = Colors.greenAccent; break;
      case SetupItemStatus.warning:
        icon = Icons.warning_amber; color = Colors.orangeAccent; break;
      case SetupItemStatus.error:
        icon = Icons.error; color = Colors.redAccent; break;
      case SetupItemStatus.running:
        icon = Icons.sync; color = cs.primary; break;
      case SetupItemStatus.pending:
        icon = Icons.radio_button_unchecked; color = cs.onSurface.withAlpha(77); break;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            child: item.status == SetupItemStatus.running
                ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5, color: color))
                : Icon(icon, size: 14, color: color),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.label, style: TextStyle(fontSize: 12, color: item.status == SetupItemStatus.pending ? cs.onSurface.withAlpha(120) : cs.onSurface, fontWeight: item.status == SetupItemStatus.running ? FontWeight.w600 : FontWeight.normal)),
                if (item.detail != null && item.detail!.isNotEmpty)
                  Text(item.detail!, style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(120)), maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
