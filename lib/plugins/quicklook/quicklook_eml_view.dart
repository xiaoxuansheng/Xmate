import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../core/drag/drag_out_helper.dart';
import 'parsers/eml_parser.dart';
import '../../core/theme/theme_service.dart';

// ══════════════════════════════════════════════════════════════════════════════
// EML Preview Widget
// ══════════════════════════════════════════════════════════════════════════════

class QuickLookEmlView extends StatefulWidget {
  final String filePath;
  const QuickLookEmlView({super.key, required this.filePath});

  @override
  State<QuickLookEmlView> createState() => _QuickLookEmlViewState();
}

class _QuickLookEmlViewState extends State<QuickLookEmlView> {
  EmlMessage? _msg;
  String? _error;
  bool _loading = true;
  bool _attsExpanded = false;

  static const _maxFileSize = 5 * 1024 * 1024;
  static const _maxVisibleAtts = 3;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(covariant QuickLookEmlView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filePath != oldWidget.filePath) {
      _msg = null; _error = null; _loading = true; _attsExpanded = false;
      _parse();
    }
  }

  Future<void> _parse() async {
    try {
      final file = File(widget.filePath);
      final size = await file.length();
      Uint8List bytes;
      if (size > _maxFileSize) {
        final raf = await file.open(mode: FileMode.read);
        bytes = await raf.read(_maxFileSize);
        await raf.close();
      } else {
        bytes = await file.readAsBytes();
      }
      final msg = parseEml(bytes);
      if (!mounted) return;
      setState(() { _msg = msg; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'Failed to parse email: $e'; _loading = false; });
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────

  String? _extractEmail(String? value) {
    if (value == null) return null;
    final m = RegExp(r'<([^>]+@[^>]+)>').firstMatch(value);
    if (m != null) return m.group(1);
    final m2 = RegExp(r'([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})').firstMatch(value);
    return m2?.group(1);
  }

  Future<void> _openMailto(String? address) async {
    if (address == null) return;
    try {
      await Process.run('cmd', ['/c', 'start', '', 'mailto:$address']);
    } catch (_) {}
  }

  /// Extract an attachment's decoded data to a temp file and open it.
  Future<void> _openAttachment(EmlAttachment att) async {
    final name = att.filename ?? 'attachment';
    try {
      final up = Platform.environment['USERPROFILE'];
      final rawDir = up != null ? '$up\\AppData\\Local\\Temp'
          : Platform.environment['TEMP'] ?? Platform.environment['TMP'];
      if (rawDir == null) return;
      // Force backslashes — Dart File may preserve forward slashes.
      final dir = rawDir.replaceAll('/', '\\');
      final safeName = name.replaceAll('/', '\\');
      final fullPath = '$dir\\$safeName';
      await File(fullPath).writeAsBytes(att.data);
      await Process.run('cmd', ['/c', 'start', '', fullPath]);
    } catch (_) {}
  }

  // EML keeps its own 3-tier size formatter — do NOT replace with fileSizeStr.
  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // ── HTML template ──────────────────────────────────────────────────

  String _buildHtml(String bodyHtml, {bool isLight = false}) {
    return '''
<!DOCTYPE html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  html { background: ${isLight ? '#FFFFFF' : '#1a1a2e'}; }
  body {
    background: ${isLight ? '#FFFFFF' : '#1a1a2e'}; color: ${isLight ? '#24292E' : '#ddd'};
    margin: 0; padding: 16px;
    font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
    font-size: 14px; line-height: 1.6;
    word-wrap: break-word; overflow-wrap: break-word;
  }
  a { color: ${isLight ? '#0366D6' : '#80d8ff'}; }
  img { max-width: 100% !important; width: auto !important; height: auto !important; }
  table { max-width: 100% !important; table-layout: auto; }
  pre, code { background: ${isLight ? 'rgba(0,0,0,0.04)' : '#ffffff10'}; border-radius: 4px; padding: 2px 6px; }
  pre { padding: 12px; overflow-x: auto; }
  blockquote {
    border-left: 3px solid ${isLight ? 'rgba(0,0,0,0.12)' : '#ffffff30'}; margin-left: 0;
    padding-left: 12px; color: ${isLight ? 'rgba(0,0,0,0.56)' : '#ffffff90'};
  }
  table { border-collapse: collapse; }
  td, th { border: 1px solid ${isLight ? 'rgba(0,0,0,0.12)' : '#ffffff20'}; padding: 6px 10px; }
</style>
</head><body>$bodyHtml</body></html>''';
  }

  // ── Header row ─────────────────────────────────────────────────────

  Widget _hdrRow(String label, String? value) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 56, child: Text('$label:', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(97), fontFamily: 'monospace'))),
        Expanded(child: Text(value, style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(179)), maxLines: 3, overflow: TextOverflow.ellipsis)),
      ]),
    );
  }

  Widget _hdrLinkRow(String label, String? value) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final email = _extractEmail(value);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 56, child: Text('$label:', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(97), fontFamily: 'monospace'))),
        Expanded(
          child: GestureDetector(
            onTap: email != null ? () => _openMailto(email) : null,
            child: Text(value,
              style: TextStyle(fontSize: 12, color: email != null ? cs.primary : cs.onSurface.withAlpha(179)),
              maxLines: 3, overflow: TextOverflow.ellipsis),
          ),
        ),
      ]),
    );
  }

  // ── Header block ───────────────────────────────────────────────────

  Widget _buildHeader(EmlMessage msg) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      color: cs.onSurface.withAlpha(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _hdrLinkRow('From', msg.from),
          _hdrLinkRow('To', msg.to),
          if (msg.cc != null && msg.cc!.isNotEmpty) _hdrLinkRow('Cc', msg.cc),
          _hdrRow('Date', msg.date),
          _hdrRow('Subject', msg.subject),
          _buildAttachments(msg.attachments),
        ],
      ),
    );
  }

  // ── Attachments (inside header, under Subject) ─────────────────────

  Widget _buildAttachments(List<EmlAttachment> atts) {
    if (atts.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final showAll = _attsExpanded || atts.length <= _maxVisibleAtts;
    final visibleAtts = showAll ? atts : atts.sublist(0, _maxVisibleAtts);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: cs.onSurface.withAlpha(8),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Icon(Icons.attach_file, size: 12, color: cs.onSurface.withAlpha(97)),
              const SizedBox(width: 4),
              Text('${atts.length} attachment${atts.length > 1 ? 's' : ''}',
                style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(97))),
              if (atts.length > _maxVisibleAtts) ...[
                const Spacer(),
                GestureDetector(
                  onTap: () => setState(() => _attsExpanded = !_attsExpanded),
                  child: Text(
                    _attsExpanded ? 'Collapse ▲' : 'Show all ▼',
                    style: TextStyle(fontSize: 10, color: cs.primary),
                  ),
                ),
              ],
            ]),
            const SizedBox(height: 6),
            ...visibleAtts.map((a) => _buildAttRow(a, cs)),
          ],
        ),
      ),
    );
  }

  Widget _buildAttRow(EmlAttachment a, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: GestureDetector(
        onTap: () => _openAttachment(a),
        child: Row(children: [
          Icon(Icons.insert_drive_file_outlined, size: 11, color: cs.onSurface.withAlpha(97)),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '${a.filename ?? 'attachment'}  (${_fmtSize(a.size)})',
              style: TextStyle(fontSize: 11, color: cs.primary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
      ),
    );
  }

  // ── Body UI ────────────────────────────────────────────────────────

  Widget _buildBody(EmlMessage msg) {
    final cs = Theme.of(context).colorScheme;
    if (msg.bodyText.isEmpty) {
      return Center(
        child: Text('No message body', style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(97))),
      );
    }
    if (msg.bodyIsHtml) {
      return InAppWebView(
        initialData: InAppWebViewInitialData(
          data: _buildHtml(msg.bodyText, isLight: ThemeService().effectiveBrightness == Brightness.light),
          mimeType: 'text/html', encoding: 'utf-8',
        ),
        initialSettings: InAppWebViewSettings(
          disableHorizontalScroll: false,
          disableVerticalScroll: false,
          transparentBackground: true,
        ),
        shouldOverrideUrlLoading: (controller, navigationAction) async {
          final url = navigationAction.request.url;
          if (url != null && url.toString() != 'about:blank') {
            await Process.run('cmd', ['/c', 'start', '', url.toString()]);
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
      );
    }
    return Container(
      padding: const EdgeInsets.all(14),
      child: SingleChildScrollView(
        child: DragOutSelectableText(
          msg.bodyText,
          style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(179), height: 1.5, fontFamily: 'monospace'),
        ),
      ),
    );
  }

  // ── Main build ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
      );
    }
    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(fontSize: 14, color: Colors.redAccent)),
      );
    }
    final msg = _msg!;
    return Column(children: [
      _buildHeader(msg),
      Divider(height: 1, color: cs.onSurface.withAlpha(31)),
      Expanded(child: _buildBody(msg)),
    ]);
  }
}
