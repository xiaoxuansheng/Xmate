import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../../core/search/file_search_channel.dart';
import '../../../core/quicklook/quicklook_utils.dart';

/// Fallback preview: shows file icon + name + size + modification time.
class QuickLookFallbackView extends StatefulWidget {
  final String filePath;
  const QuickLookFallbackView({super.key, required this.filePath});

  @override
  State<QuickLookFallbackView> createState() => _QuickLookFallbackViewState();
}

class _QuickLookFallbackViewState extends State<QuickLookFallbackView> {
  Uint8List? _iconPng;
  String? _iconErrorMsg;

  @override
  void initState() {
    super.initState();
    _loadIcon();
  }

  @override
  void didUpdateWidget(covariant QuickLookFallbackView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filePath != oldWidget.filePath) {
      _iconPng = null;
      _iconErrorMsg = null;
      _loadIcon();
    }
  }

  Future<void> _loadIcon() async {
    try {
      final png = await FileSearchChannel().getFileIcon(widget.filePath);
      if (!mounted) return;
      setState(() => _iconPng = png);
    } catch (e) {
      if (!mounted) return;
      setState(() => _iconErrorMsg = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final file = File(widget.filePath);
    final name = file.uri.pathSegments.last;
    FileStat? stat;
    try {
      stat = file.statSync();
    } catch (_) {}

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icon
            if (_iconPng != null)
              Image.memory(_iconPng!, width: 64, height: 64, gaplessPlayback: true)
            else if (_iconErrorMsg != null)
              Icon(Icons.insert_drive_file, size: 64, color: cs.onSurface.withAlpha(97))
            else
              SizedBox(
                width: 64,
                height: 64,
                child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
              ),
            const SizedBox(height: 16),
            // File name
            Text(
              name,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: cs.onSurface),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Divider(color: cs.onSurface.withAlpha(61), height: 1),
            const SizedBox(height: 12),
            // Properties
            if (stat != null) ...[
              _propRow('Size', fileSizeStr(stat.size), cs),
              const SizedBox(height: 6),
              _propRow('Modified', fileTimeStr(stat.modified), cs),
            ] else ...[
              Text('Unable to read file properties',
                  style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(138))),
            ],
            const SizedBox(height: 16),
            Text('Press Enter to open',
                style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(97))),
          ],
        ),
      ),
    );
  }

  Widget _propRow(String label, String value, ColorScheme cs) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label: ', style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(138))),
        Text(value, style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(179))),
      ],
    );
  }
}
