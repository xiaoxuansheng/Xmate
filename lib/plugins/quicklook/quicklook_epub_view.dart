import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'parsers/epub_zip_reader.dart';
import '../../core/theme/theme_service.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Models
// ══════════════════════════════════════════════════════════════════════════════

class _ChapterData { final String label, bodyHtml; const _ChapterData(this.label, this.bodyHtml); }
class _EpubData {
  final String? title, author;
  final List<_ChapterData> chapters;
  final String coverHtml, cssStyles;
  _EpubData({this.title, this.author, this.chapters = const [], this.coverHtml = '', this.cssStyles = ''});
}
class _OpfItem { final String href, mediaType; const _OpfItem(this.href, this.mediaType); }

// ══════════════════════════════════════════════════════════════════════════════
// XML helpers
// ══════════════════════════════════════════════════════════════════════════════

String? _attr(String tag, String name) =>
    (RegExp('$name\\s*=\\s*"([^"]*)"', caseSensitive: false).firstMatch(tag)
    ?? RegExp("$name\\s*=\\s*'([^']*)'", caseSensitive: false).firstMatch(tag))?.group(1);

String? _tagContent(String xml, String tag) =>
    RegExp('<$tag\\b[^>]*>\\s*(.+?)\\s*</$tag>', dotAll: true, caseSensitive: false).firstMatch(xml)?.group(1)?.trim();

String _stripHtml(String s) =>
    s.replaceAll(RegExp(r'<[^>]*>', dotAll: true), '').replaceAll('&amp;', '&')
     .replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"')
     .replaceAll('&#39;', "'").replaceAll(RegExp(r'&[a-z]+;'), '')
     .replaceAll(RegExp(r'&#\d+;'), '').trim();

String _chapterLabel(String xhtml, int index, bool isFirst) {
  for (final tag in ['title', 'h1', 'h2', 'h3']) {
    final m = RegExp('<$tag[^>]*>(.+?)</$tag>', dotAll: true, caseSensitive: false).firstMatch(xhtml);
    if (m != null) { final t = _stripHtml(m.group(1)!); if (t.isNotEmpty && t.length < 80) return t; }
  }
  return isFirst ? 'Cover' : 'Chapter ${index + 1}';
}

String _resolve(String base, String target) {
  if (target.startsWith('/')) return target.substring(1);
  final bd = base.contains('/') ? base.substring(0, base.lastIndexOf('/') + 1) : '';
  final out = <String>[];
  for (final p in '$bd$target'.split('/')) {
    if (p == '.' || p.isEmpty) continue;
    if (p == '..') { if (out.isNotEmpty) out.removeLast(); continue; }
    out.add(p);
  }
  return out.join('/');
}

String _wrapChapterHtml(String bodyContent, String css, String maybeCover, {bool isLight = false}) => '''
<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
html{background:${isLight ? '#FFFFFF' : '#1a1a2e'}}
body{background:${isLight ? '#FFFFFF' : '#1a1a2e'};color:${isLight ? '#24292E' : '#ddd'};margin:0;padding:0;
font-family:system-ui,Georgia,serif;font-size:15px;line-height:1.7;
word-wrap:break-word;overflow-wrap:break-word}
::-webkit-scrollbar{width:6px}::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:${isLight ? '#D1D5DA' : '#30363D'};border-radius:3px}
.epub-cover{text-align:center;padding:24px}
.epub-cover img{max-width:60%!important;height:auto!important;box-shadow:0 4px 24px #00000040;border-radius:4px}
.epub-chapter{padding:24px 32px}
a{color:${isLight ? '#0366D6' : '#80d8ff'}}
img,svg{max-width:100%!important;height:auto!important}
h1,h2,h3,h4{color:${isLight ? '#24292E' : '#eee'};margin-top:1.2em;margin-bottom:.6em}
h1{font-size:1.6em}h2{font-size:1.35em}h3{font-size:1.15em}
p{margin:.5em 0}
pre,code{background:${isLight ? 'rgba(0,0,0,0.04)' : '#ffffff10'};border-radius:4px;padding:2px 6px}
pre{padding:12px;overflow-x:auto;white-space:pre-wrap}
blockquote{border-left:3px solid ${isLight ? 'rgba(0,0,0,0.12)' : '#ffffff30'};margin:1em 0;padding:.5em 1em;color:${isLight ? 'rgba(0,0,0,0.56)' : '#ffffff90'}}
table{border-collapse:collapse;width:100%}
td,th{border:1px solid ${isLight ? 'rgba(0,0,0,0.12)' : '#ffffff20'};padding:6px 10px}
.search-highlight{background:#ffff0044!important;border-radius:2px}
.search-highlight-active{background:#ff8800aa!important;border-radius:2px}
$css
</style></head><body>$maybeCover<section class="epub-chapter">$bodyContent</section></body></html>''';

// ══════════════════════════════════════════════════════════════════════════════
// EPUB parser
// ══════════════════════════════════════════════════════════════════════════════

Future<_EpubData> _parseEpub(File file) async {
  final size = await file.length(), raf = await file.open(mode: FileMode.read);
  try {
    final dirMap = await readEpubZipDir(raf, size);
    final ce = dirMap['meta-inf/container.xml'] ?? (throw FormatException('Missing container.xml'));
    final opfPath = _attr(
      RegExp(r'<rootfile\b[^>]*>', caseSensitive: false).firstMatch(utf8.decode(await extractEpubEntry(raf, ce)))!.group(0)!, 'full-path')
        ?? (throw FormatException('No rootfile'));
    final oe = dirMap[opfPath.toLowerCase()] ?? (throw FormatException('OPF not found: $opfPath'));
    final opfXml = utf8.decode(await extractEpubEntry(raf, oe));
    final opfDir = opfPath.contains('/') ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1) : '';

    final title = _tagContent(opfXml, 'dc:title') ?? _tagContent(opfXml, 'title');
    final author = _tagContent(opfXml, 'dc:creator') ?? _tagContent(opfXml, 'creator');

    final manifest = <String, _OpfItem>{};
    for (final m in RegExp(r'<item\b[^>]*>', caseSensitive: false).allMatches(opfXml)) {
      final s = m.group(0)!, id = _attr(s, 'id'), href = _attr(s, 'href'), mt = _attr(s, 'media-type');
      if (id != null && href != null) manifest[id] = _OpfItem(href, mt ?? '');
    }
    final spine = <String>[];
    for (final m in RegExp(r'<itemref\b[^>]*>', caseSensitive: false).allMatches(opfXml)) {
      final ir = _attr(m.group(0)!, 'idref'); if (ir != null) spine.add(ir);
    }
    if (spine.isEmpty) throw FormatException('Empty spine');

    // Pre-load images & CSS
    final dataUris = <String, String>{};
    final allCss = StringBuffer();
    String? coverId;
    for (final e in manifest.entries) {
      if (e.key.toLowerCase().contains('cover') && e.value.mediaType.startsWith('image/')) coverId = e.key;
    }
    for (final e in manifest.entries) {
      final k = _resolve(opfDir, e.value.href).toLowerCase(), ent = dirMap[k];
      if (ent == null) continue;
      if (e.value.mediaType.startsWith('image/')) {
        try { final b = await extractEpubEntry(raf, ent); dataUris[k] = 'data:${e.value.mediaType};base64,${base64.encode(b)}'; } catch (_) {}
      } else if (e.value.mediaType == 'text/css') {
        try { allCss.writeln(utf8.decode(await extractEpubEntry(raf, ent))); } catch (_) {}
      }
    }

    String coverHtml = '';
    if (coverId != null) {
      final ci = manifest[coverId]; if (ci != null) {
        final uri = dataUris[_resolve(opfDir, ci.href).toLowerCase()];
        if (uri != null) coverHtml = '<div class="epub-cover"><img src="$uri"></div>';
      }
    }

    final chapters = <_ChapterData>[];
    for (final idref in spine) {
      final item = manifest[idref]; if (item == null) continue;
      if (!item.mediaType.contains('xml') && !item.mediaType.contains('html') && !item.mediaType.contains('xhtml')) continue;
      final chKey = _resolve(opfDir, item.href).toLowerCase(), chEnt = dirMap[chKey];
      if (chEnt == null) continue;
      String xhtml;
      try { xhtml = utf8.decode(await extractEpubEntry(raf, chEnt)); } catch (_) { continue; }
      final label = _chapterLabel(xhtml, chapters.length, chapters.isEmpty);
      xhtml = xhtml.replaceFirst(RegExp(r'<\?xml[^?]*\?>', caseSensitive: false), '')
                   .replaceFirst(RegExp(r'<!DOCTYPE[^>]*>', caseSensitive: false), '');
      final bm = RegExp(r'<body[^>]*>(.*)</body>', dotAll: true, caseSensitive: false).firstMatch(xhtml);
      String content = bm != null ? bm.group(1)! : xhtml;
      final chBase = _resolve(opfDir, item.href);
      content = content.replaceAllMapped(
        RegExp(r'((?:img|image)\b[^>]*\b(?:src|href|xlink:href)\s*=\s*")([^"]*)(")', caseSensitive: false), (m) {
          final src = m.group(2)!;
          if (src.startsWith('http') || src.startsWith('data:')) return m.group(0)!;
          final uri = dataUris[_resolve(chBase, src).toLowerCase()];
          return uri != null ? '${m.group(1)}$uri${m.group(3)}' : m.group(0)!;
        });
      final chCover = chapters.isEmpty ? coverHtml : '';
      final epubIsLight = ThemeService().effectiveBrightness == Brightness.light;
      chapters.add(_ChapterData(label, _wrapChapterHtml(content, allCss.toString(), chCover, isLight: epubIsLight)));
    }
    return _EpubData(title: title, author: author, chapters: chapters, coverHtml: coverHtml, cssStyles: allCss.toString());
  } finally { raf.closeSync(); }
}

// ══════════════════════════════════════════════════════════════════════════════
// Widget
// ══════════════════════════════════════════════════════════════════════════════

class QuickLookEpubView extends StatefulWidget {
  final String filePath;
  const QuickLookEpubView({super.key, required this.filePath});
  @override State<QuickLookEpubView> createState() => _QuickLookEpubViewState();
}

class _QuickLookEpubViewState extends State<QuickLookEpubView> {
  _EpubData? _data;
  String? _error;
  bool _loading = true;
  int _selToc = 0;
  InAppWebViewController? _webCtrl;
  bool _tocVisible = true;

  // Search
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  int _matchCount = 0, _activeMatch = 0;

  static const _tocW = 170.0;

  @override void initState() { super.initState(); _load(); }
  @override void dispose() { _searchCtrl.dispose(); _searchFocus.dispose(); super.dispose(); }

  @override void didUpdateWidget(covariant QuickLookEpubView old) {
    super.didUpdateWidget(old);
    if (widget.filePath != old.filePath) {
      _data = null; _error = null; _loading = true; _selToc = 0; _webCtrl = null;
      _searchCtrl.clear(); _matchCount = 0; _activeMatch = 0;
      _load();
    }
  }

  Future<void> _load() async {
    try { final d = await _parseEpub(File(widget.filePath));
      if (mounted) setState(() { _data = d; _loading = false; }); }
    catch (e) { if (mounted) setState(() { _error = 'Failed: $e'; _loading = false; }); }
  }

  void _switchChapter(int i) {
    if (_data == null || i == _selToc) return;
    _selToc = i; setState(() {});
    _webCtrl?.loadData(data: _data!.chapters[i].bodyHtml, mimeType: 'text/html', encoding: 'utf-8');
    _clearSearch();
  }

  // ── Search ─────────────────────────────────────────────────────────

  void _clearSearch() {
    _webCtrl?.evaluateJavascript(source: jsClearHighlights);
    _matchCount = 0; _activeMatch = 0;
  }

  void _doSearch(String q) {
    if (q.isEmpty) { _clearSearch(); return; }
    final escaped = q
        .replaceAll('\\', '\\\\').replaceAll("'", "\\'")
        .replaceAll('\n', '\\n').replaceAll('\r', '');
    _webCtrl?.evaluateJavascript(source: _jsSearch(escaped)).then((result) {
      if (result == null || !mounted) return;
      final count = int.tryParse(result.toString()) ?? 0;
      setState(() { _matchCount = count; _activeMatch = count > 0 ? 1 : 0; });
    });
  }

  void _nextMatch() {
    if (_matchCount == 0) return;
    final n = _activeMatch >= _matchCount ? 1 : _activeMatch + 1;
    setState(() => _activeMatch = n);
    _webCtrl?.evaluateJavascript(source: jsScrollToMatch(n - 1));
  }

  void _prevMatch() {
    if (_matchCount == 0) return;
    final n = _activeMatch <= 1 ? _matchCount : _activeMatch - 1;
    setState(() => _activeMatch = n);
    _webCtrl?.evaluateJavascript(source: jsScrollToMatch(n - 1));
  }

  // ── TOC ────────────────────────────────────────────────────────────

  Widget _buildToc() {
    final cs = Theme.of(context).colorScheme;
    final chapters = _data!.chapters;
    return Container(width: _tocW,
      decoration: BoxDecoration(color: cs.onSurface.withAlpha(6), border: Border(right: BorderSide(color: cs.onSurface.withAlpha(21)))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(height: 30, padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(color: cs.onSurface.withAlpha(8), border: Border(bottom: BorderSide(color: cs.onSurface.withAlpha(21)))),
          child: Row(children: [
            Text('Contents', style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(138), fontWeight: FontWeight.w600)),
            const Spacer(),
            GestureDetector(onTap: () => setState(() => _tocVisible = !_tocVisible),
              child: Icon(Icons.menu_open, size: 14, color: cs.onSurface.withAlpha(97))),
          ])),
        Expanded(child: ListView.builder(padding: const EdgeInsets.symmetric(vertical: 4), itemCount: chapters.length,
          itemBuilder: (_, i) => _tocItem(i, cs))),
      ]));
  }

  Widget _tocItem(int i, ColorScheme cs) {
    final sel = i == _selToc;
    return GestureDetector(onTap: () => _switchChapter(i),
      child: Container(height: 30, padding: const EdgeInsets.only(left: 12, right: 6),
        color: sel ? cs.primary.withAlpha(37) : Colors.transparent,
        child: Row(children: [
          Container(width: 3, height: 18, margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(color: sel ? cs.primary : Colors.transparent, borderRadius: BorderRadius.circular(2))),
          Expanded(child: Text(_data!.chapters[i].label,
            style: TextStyle(fontSize: 12, color: sel ? cs.onSurface : cs.onSurface.withAlpha(153), fontWeight: sel ? FontWeight.w600 : FontWeight.normal),
            maxLines: 1, overflow: TextOverflow.ellipsis)),
        ])));
  }

  // ── Header + Search bar ────────────────────────────────────────────

  Widget _buildHeader() {
    final cs = Theme.of(context).colorScheme;
    final d = _data!;
    return Container(
      color: cs.onSurface.withAlpha(8),
      child: Column(children: [
        // Title row
        Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            GestureDetector(onTap: () => setState(() => _tocVisible = !_tocVisible),
              child: Icon(Icons.menu_book, size: 16, color: cs.primary)),
            const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(d.title ?? 'EPUB E-book', style: TextStyle(fontSize: 13, color: cs.onSurface, fontWeight: FontWeight.w600),
                maxLines: 1, overflow: TextOverflow.ellipsis),
              if (d.author != null) Text(d.author!, style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(138)), maxLines: 1, overflow: TextOverflow.ellipsis),
            ])),
            if (_selToc > 0)
              GestureDetector(onTap: () => _switchChapter(_selToc - 1),
                child: Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Icon(Icons.chevron_left, size: 18, color: cs.onSurface.withAlpha(138)))),
            Text('${_selToc + 1}/${d.chapters.length}', style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(97))),
            if (_selToc < d.chapters.length - 1)
              GestureDetector(onTap: () => _switchChapter(_selToc + 1),
                child: Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Icon(Icons.chevron_right, size: 18, color: cs.onSurface.withAlpha(138)))),
          ])),
        // Search bar
        _buildSearchBar(cs),
      ]),
    );
  }

  Widget _buildSearchBar(ColorScheme cs) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 150),
      child: _searchFocus.hasFocus || _searchCtrl.text.isNotEmpty
          ? Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: cs.onSurface.withAlpha(5),
                border: Border(top: BorderSide(color: cs.onSurface.withAlpha(21))),
              ),
              child: Row(children: [
                Icon(Icons.search, size: 14, color: cs.onSurface.withAlpha(97)),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    focusNode: _searchFocus,
                    onChanged: _doSearch,
                    style: TextStyle(fontSize: 12, color: cs.onSurface),
                    decoration: InputDecoration(
                      hintText: 'Search in chapter...',
                      hintStyle: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(61)),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                if (_matchCount > 0) ...[
                  Text('$_activeMatch/$_matchCount', style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(97))),
                  const SizedBox(width: 4),
                  _searchNavBtn(Icons.keyboard_arrow_up, _prevMatch, cs),
                  _searchNavBtn(Icons.keyboard_arrow_down, _nextMatch, cs),
                ],
                _searchNavBtn(Icons.close, () { _searchCtrl.clear(); _clearSearch(); _searchFocus.unfocus(); }, cs),
              ]),
            )
          : const SizedBox(width: double.infinity),
    );
  }

  Widget _searchNavBtn(IconData icon, VoidCallback onTap, ColorScheme cs) {
    return GestureDetector(
      onTap: onTap,
      child: Container(width: 22, height: 22, alignment: Alignment.center,
        child: Icon(icon, size: 14, color: cs.onSurface.withAlpha(97))),
    );
  }

  // ── Body ───────────────────────────────────────────────────────────

  Widget _buildBody() {
    final ch = _data!.chapters[_selToc];
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.escape && _searchFocus.hasFocus) {
          _searchCtrl.clear(); _clearSearch(); _searchFocus.unfocus(); setState(() {});
          return KeyEventResult.handled;
        }
        if (HardwareKeyboard.instance.isControlPressed && event.logicalKey == LogicalKeyboardKey.keyF) {
          _searchFocus.requestFocus(); setState(() {});
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: InAppWebView(
        initialData: InAppWebViewInitialData(data: ch.bodyHtml, mimeType: 'text/html', encoding: 'utf-8'),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true, transparentBackground: true,
          disableHorizontalScroll: false, disableVerticalScroll: false,
        ),
        onWebViewCreated: (ctrl) => _webCtrl = ctrl,
        onReceivedError: (_, __, e) { debugPrint('[EPUB] WebView error: ${e.description}'); },
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) return Center(child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary));
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(fontSize: 14, color: Colors.redAccent)));
    return Column(children: [
      _buildHeader(),
      Divider(height: 1, color: cs.onSurface.withAlpha(31)),
      Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_tocVisible) _buildToc(),
        if (!_tocVisible) GestureDetector(onTap: () => setState(() => _tocVisible = !_tocVisible),
          child: Container(width: 20, color: cs.onSurface.withAlpha(5),
            alignment: Alignment.center, child: Icon(Icons.menu, size: 12, color: cs.onSurface.withAlpha(97)))),
        Expanded(child: _buildBody()),
      ])),
    ]);
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// JS helpers — search & highlight in WebView2
// ══════════════════════════════════════════════════════════════════════════════

String get jsClearHighlights => '''
(function(){
  document.querySelectorAll('.search-highlight,.search-highlight-active').forEach(function(el){
    var p=el.parentNode;
    p.replaceChild(document.createTextNode(el.textContent),el);
    p.normalize();
  });
})();
''';

String _jsEscape(String s) =>
    s.replaceAll('\\', '\\\\').replaceAll("'", "\\'");

String _jsSearch(String query) {
  final escaped = _jsEscape(query);
  return r'''
(function(){
  document.querySelectorAll('.search-highlight,.search-highlight-active').forEach(function(el){
    var p=el.parentNode;
    p.replaceChild(document.createTextNode(el.textContent),el);
    p.normalize();
  });
  var q=''' + "'" + escaped + "'" + r''';
  if (!q) return 0;
  var re = new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'),'gi');
  var count = 0;
  function walk(node){
    if (node.nodeType===3){
      var m, txt=node.textContent, last=0, frag=document.createDocumentFragment();
      re.lastIndex=0;
      while ((m=re.exec(txt))!==null){
        count++;
        if (m.index>last) frag.appendChild(document.createTextNode(txt.slice(last,m.index)));
        var span=document.createElement('span');
        span.className='search-highlight';
        span.setAttribute('data-match',count);
        span.textContent=m[0];
        frag.appendChild(span);
        last=m.index+m[0].length;
        if (!re.global) break;
      }
      if (last<txt.length) frag.appendChild(document.createTextNode(txt.slice(last)));
      if (last>0){ node.parentNode.replaceChild(frag,node); }
    } else if (node.nodeType===1){
      if (node.classList.contains('search-highlight') || node.classList.contains('search-highlight-active')) return;
      for (var c=node.firstChild;c;){ var n=c.nextSibling; walk(c); c=n; }
    }
  }
  walk(document.body);
  return count;
})();
''';
}

String jsScrollToMatch(int idx) => r'''
(function(){
  var all=document.querySelectorAll('.search-highlight,.search-highlight-active');
  all.forEach(function(el){ el.classList.remove('search-highlight-active'); });
  if (all.length<=''' + idx.toString() + r''') return;
  var el=all[''' + idx.toString() + r'''];
  el.classList.add('search-highlight-active');
  el.scrollIntoView({behavior:'smooth',block:'center'});
})();
''';
