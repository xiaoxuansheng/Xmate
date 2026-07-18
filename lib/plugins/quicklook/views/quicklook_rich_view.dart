import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../../core/theme/theme_service.dart';

/// Preview mode for [QuickLookRichView].
enum RichViewMode { text, code, markdown }

/// Rich content preview using WebView2.
///
/// Supports three modes:
/// - [RichViewMode.text]: line numbers + selection + auto-detect highlight.js
/// - [RichViewMode.code]: line numbers + selection + language-specific highlight.js
/// - [RichViewMode.markdown]: TOC sidebar + marked.js + dark scrollbar
///
/// Falls back to plain-text if WebView2 is unavailable.
class QuickLookRichView extends StatefulWidget {
  final String filePath;
  final RichViewMode mode;

  const QuickLookRichView({
    super.key,
    required this.filePath,
    required this.mode,
  });

  @override
  State<QuickLookRichView> createState() => _QuickLookRichViewState();
}

class _QuickLookRichViewState extends State<QuickLookRichView> {
  bool _fallback = false;
  bool _truncated = false;
  String? _html;
  String? _errorMsg;

  static const _maxBytes = 2 * 1024 * 1024; // 2 MB

  // Map file extension → highlight.js language name.
  static const _langMap = {
    'dart': 'dart',
    'py': 'python',
    'js': 'javascript',
    'ts': 'typescript',
    'jsx': 'javascript',
    'tsx': 'typescript',
    'html': 'xml',
    'css': 'css',
    'scss': 'scss',
    'less': 'less',
    'cpp': 'cpp',
    'c': 'c',
    'h': 'c',
    'hpp': 'cpp',
    'java': 'java',
    'kt': 'kotlin',
    'swift': 'swift',
    'rs': 'rust',
    'go': 'go',
    'cs': 'csharp',
    'php': 'php',
    'rb': 'ruby',
    'lua': 'lua',
    'r': 'r',
    'm': 'objectivec',
    'mm': 'objectivec',
    'pl': 'perl',
    'sh': 'bash',
    'bat': 'dos',
    'ps1': 'powershell',
    'sql': 'sql',
    'json': 'json',
    'xml': 'xml',
    'yaml': 'yaml',
    'yml': 'yaml',
    'toml': 'ini',
    'groovy': 'groovy',
    'scala': 'scala',
    'elm': 'elm',
    'ex': 'elixir',
    'exs': 'elixir',
    'eex': 'elixir',
    'heex': 'elixir',
    'hs': 'haskell',
    'nim': 'nim',
    'zig': 'zig',
    'v': 'v',
    'fs': 'fsharp',
    'fsx': 'fsharp',
  };

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(covariant QuickLookRichView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filePath != oldWidget.filePath ||
        widget.mode != oldWidget.mode) {
      _fallback = false;
      _truncated = false;
      _html = null;
      _errorMsg = null;
      _prepare();
    }
  }

  Future<void> _prepare() async {
    try {
      final file = File(widget.filePath);
      if (!await file.exists()) {
        if (!mounted) return;
        setState(() => _errorMsg = 'File not found');
        return;
      }
      final length = await file.length();
      final readLen = length > _maxBytes ? _maxBytes : length;
      final bytes = await file.readAsBytes().then((b) => b.sublist(0, readLen));
      String content;
      try {
        content = utf8.decode(bytes);
      } catch (_) {
        content = String.fromCharCodes(bytes);
      }

      if (widget.mode == RichViewMode.markdown) {
        _html = await _buildMarkdownHtml(content);
      } else {
        final isText = widget.mode == RichViewMode.text;
        final lang = widget.mode == RichViewMode.code ? _langMap[_fileExt] ?? '' : '';
        _html = await _buildCodeHtml(content, lang: lang, isText: isText);
      }
      _truncated = length > _maxBytes;
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMsg = 'Failed to read file');
    }
  }

  // ─── Shared: code + text with line numbers ───

  Future<String> _buildCodeHtml(String code, {String lang = '', bool isText = false}) async {
    final highlightJs = await rootBundle
        .loadString('assets/quicklook/highlight.min.js');
    final isLight = ThemeService().effectiveBrightness == Brightness.light;
    final themeCss = await rootBundle.loadString(
      isLight ? 'assets/quicklook/github.min.css' : 'assets/quicklook/github-dark.min.css',
    );

    // HTML-escape code.
    final escaped = code
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');

    // Text mode: MS YaHei Light for both English and Chinese.
    // Code mode: monospace stack with YaHei Light as CJK fallback.
    final bodyFont = isText
        ? "'Microsoft YaHei Light','Microsoft YaHei',sans-serif"
        : "'Consolas','Cascadia Code','Courier New','Microsoft YaHei Light',monospace";

    return '''
<!DOCTYPE html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  $themeCss
  ::-webkit-scrollbar { width: 6px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: #30363D; border-radius: 3px; }
  ::-webkit-scrollbar-thumb:hover { background: #484F58; }
${isLight ? '''
  html, body {
    margin: 0; padding: 0;
    background: #FFFFFF; color: #24292E;
    font-family: $bodyFont;
    font-size: 13px; line-height: 1.5;
    overflow-y: auto; overflow-x: hidden; height: 100%;
  }
  .line-num {
    color: rgba(0,0,0,0.22); border-right: 1px solid rgba(0,0,0,0.06);
  }
  .line-num:hover { color: rgba(0,0,0,0.55); }
  .line.selected { background: rgba(3,102,214,0.08); }
  .line.selected .line-num { color: #0366D6; }
  body { caret-color: #0366D6; }
''' : r'''
  html, body {
    margin: 0; padding: 0;
    background: #1A1A2E; color: #E6EDF3;
    font-family: $bodyFont;
    font-size: 13px; line-height: 1.5;
    overflow-y: auto; overflow-x: hidden; height: 100%;
  }
  .line-num {
    color: rgba(255,255,255,0.22); border-right: 1px solid rgba(255,255,255,0.06);
  }
  .line-num:hover { color: rgba(255,255,255,0.55); }
  .line.selected { background: rgba(128,216,255,0.12); }
  .line.selected .line-num { color: #80D8FF; }
  body { caret-color: #80D8FF; }
'''}
  .line {
    display: flex; min-height: 19.5px;
    white-space: pre-wrap; overflow-wrap: break-word;
  }
  .line-num {
    width: 52px; min-width: 52px;
    text-align: right; padding-right: 8px;
    font-size: 12px; line-height: 1.625;
    user-select: none; cursor: pointer;
    margin-right: 12px;
  }
  .line-code { flex: 1; padding-right: 16px; user-select: text; cursor: text; }
  #hidden-code { display: none; }

  /* ── Read-only contenteditable cursor ── */
  #lines { outline: none; }
  #lines:focus { outline: none; }

  /* ── Search bar ── */
  #srch-bar {
    display: none; position: fixed; top: 0; right: 0;
    background: ${isLight ? '#F6F8FA' : '#252540'};
    border-bottom: 1px solid ${isLight ? '#D1D5DA' : '#30363D'};
    border-left: 1px solid ${isLight ? '#D1D5DA' : '#30363D'};
    border-radius: 0 0 0 8px;
    padding: 6px 10px; z-index: 1000;
    align-items: center; gap: 6px; font-size: 12px;
  }
  #srch-bar.show { display: flex; }
  #srch-inp {
    background: ${isLight ? '#FFFFFF' : '#1A1A2E'};
    border: 1px solid ${isLight ? '#D1D5DA' : '#30363D'}; border-radius: 4px;
    color: ${isLight ? '#24292E' : '#E6EDF3'};
    font-size: 12px; font-family: inherit;
    padding: 3px 8px; width: 180px; outline: none;
  }
  #srch-inp:focus { border-color: ${isLight ? '#0366D6' : '#58A6FF'}; }
  #srch-cnt { color: ${isLight ? '#586069' : '#8B949E'}; min-width: 36px; text-align: center; }
  .srch-btn {
    background: none; border: none; color: ${isLight ? '#586069' : '#8B949E'}; cursor: pointer;
    font-size: 13px; padding: 2px 5px; border-radius: 3px; line-height: 1;
  }
  .srch-btn:hover { color: ${isLight ? '#24292E' : '#E6EDF3'}; background: ${isLight ? 'rgba(3,102,214,0.08)' : '#30363D'}; }
  #srch-close { font-size: 15px; font-weight: bold; }

  /* ── Context menu ── */
  #ctx-menu {
    display: none; position: fixed; z-index: 2000;
    background: ${isLight ? '#FFFFFF' : '#252540'};
    border: 1px solid ${isLight ? '#D1D5DA' : '#30363D'}; border-radius: 6px;
    padding: 4px 0; min-width: 160px;
    box-shadow: ${isLight ? '0 4px 12px rgba(0,0,0,0.15)' : '0 4px 12px rgba(0,0,0,0.5)'};
  }
  #ctx-menu.show { display: block; }
  .ctx-item {
    padding: 7px 14px; font-size: 12px; color: ${isLight ? '#24292E' : '#E6EDF3'};
    cursor: pointer; display: flex; align-items: center;
  }
  .ctx-item:hover { background: ${isLight ? 'rgba(3,102,214,0.08)' : 'rgba(128,216,255,0.12)'}; }
  .ctx-kbd { color: ${isLight ? '#586069' : '#8B949E'}; font-size: 11px; margin-left: auto; padding-left: 16px; }

  /* ── Find highlights ── */
  mark.fh { background: rgba(255,213,79,0.45); color: ${isLight ? '#24292E' : '#fff'}; border-radius: 2px; }
  mark.fh-on { background: #FF8F00; color: ${isLight ? '#FFFFFF' : '#1A1A2E'}; }
</style>
</head><body>
<div id="srch-bar">
  <input id="srch-inp" type="text" placeholder="Find...">
  <span id="srch-cnt"></span>
  <button class="srch-btn" id="srch-prev" title="Previous (Shift+F3)">▲</button>
  <button class="srch-btn" id="srch-next" title="Next (F3)">▼</button>
  <button class="srch-btn" id="srch-close" title="Close (Esc)">&times;</button>
</div>
<div id="ctx-menu">
  <div class="ctx-item" data-act="selall"><span>Select All</span><span class="ctx-kbd">Ctrl+A</span></div>
  <div class="ctx-item" data-act="copy"><span>Copy</span><span class="ctx-kbd">Ctrl+C</span></div>
</div>
<div id="lines" contenteditable="true" spellcheck="false">${_buildLinesHtml(escaped)}</div>
<pre id="hidden-code"><code class="language-$lang">$escaped</code></pre>
<script>$highlightJs
(function() {
  // Highlight the hidden block.
  var pre = document.getElementById('hidden-code');
  if (pre) {
    ${lang.isNotEmpty ? "hljs.highlightElement(pre.querySelector('code'));"
                       : "/* text mode — skip syntax highlighting */"}
  }
  var codeEl = pre ? pre.querySelector('code') : null;

  // Distribute highlighted spans back to line elements.
  if (codeEl && codeEl.childNodes.length > 0) {
    var allHtml = codeEl.innerHTML;
    var htmlLines = allHtml.split('\\n');
    var plainLines = document.querySelectorAll('.line-code');
    for (var i = 0; i < Math.min(htmlLines.length, plainLines.length); i++) {
      plainLines[i].innerHTML = htmlLines[i] || '';
    }
  }

  // ── Selection logic ──
  var selLines = new Set();
  var lastLine = -1;

  document.querySelectorAll('.line-num').forEach(function(el) {
    el.addEventListener('click', function(e) {
      var n = parseInt(el.parentElement.getAttribute('data-line'));
      if (e.shiftKey && lastLine >= 0) {
        var lo = Math.min(lastLine, n), hi = Math.max(lastLine, n);
        for (var i = lo; i <= hi; i++) selLines.add(i);
      } else {
        if (selLines.has(n)) selLines.delete(n);
        else selLines.add(n);
      }
      lastLine = n;
      document.querySelectorAll('.line').forEach(function(l) {
        var ln = parseInt(l.getAttribute('data-line'));
        l.classList.toggle('selected', selLines.has(ln));
      });
    });
  });

  // Click on line text area (not line number) to deselect.
  document.querySelectorAll('.line-code').forEach(function(el) {
    el.addEventListener('click', function(e) {
      if (e.target === el) {
        selLines.clear(); lastLine = -1;
        document.querySelectorAll('.line').forEach(function(l) {
          l.classList.remove('selected');
        });
      }
    });
  });

  // Ctrl+C copies selected lines (line-number selection) or native text selection.
  document.addEventListener('copy', function(e) {
    if (selLines.size === 0) return; // let native copy handle free-form selection
    var lines = [];
    document.querySelectorAll('.line.selected .line-code').forEach(function(el) {
      lines.push(el.textContent);
    });
    e.clipboardData.setData('text/plain', lines.join('\\n'));
    e.preventDefault();
  });

  // ── Search ──
  var srchBar = document.getElementById('srch-bar');
  var srchInp = document.getElementById('srch-inp');
  var srchCnt = document.getElementById('srch-cnt');
  var srchMatches = [];
  var srchIdx = -1;
  var srchRawHtml = []; // cached original innerHTML per line-code for restore

  function srchClear() {
    var codes = document.querySelectorAll('.line-code');
    for (var i = 0; i < codes.length; i++) {
      if (srchRawHtml[i] !== undefined) codes[i].innerHTML = srchRawHtml[i];
    }
    srchMatches = []; srchIdx = -1; srchRawHtml = [];
  }

  function srchDo(text) {
    srchClear();
    if (!text) { srchCnt.textContent = ''; return; }

    var codes = document.querySelectorAll('.line-code');
    var re;
    try { re = new RegExp(text.replace(/[.*+?^\${}()|[\\]\\\\]/g, '\\\\\$&'), 'gi'); }
    catch(_) { srchCnt.textContent = 'err'; return; }

    for (var i = 0; i < codes.length; i++) {
      srchRawHtml[i] = codes[i].innerHTML;
      if (!re.test(codes[i].textContent)) continue;
      re.lastIndex = 0;
      codes[i].innerHTML = srchRawHtml[i].replace(re, function(m) {
        return '<mark class="fh">' + m + '</mark>';
      });
    }
    srchMatches = document.querySelectorAll('mark.fh');
    if (srchMatches.length > 0) {
      srchIdx = 0;
      srchMatches[0].classList.add('fh-on');
      srchMatches[0].scrollIntoView({block: 'center', behavior: 'smooth'});
    }
    srchUpdateCnt();
  }

  function srchUpdateCnt() {
    srchCnt.textContent = srchMatches.length > 0 ? (srchIdx + 1) + '/' + srchMatches.length : (srchInp.value ? '0/0' : '');
  }

  function srchNav(dir) {
    if (srchMatches.length === 0) return;
    srchMatches[srchIdx].classList.remove('fh-on');
    srchIdx = (srchIdx + dir + srchMatches.length) % srchMatches.length;
    srchMatches[srchIdx].classList.add('fh-on');
    srchMatches[srchIdx].scrollIntoView({block: 'center', behavior: 'smooth'});
    srchUpdateCnt();
  }

  function srchShow() {
    srchBar.classList.add('show');
    srchInp.value = '';
    srchCnt.textContent = '';
    srchClear();
    setTimeout(function() { srchInp.focus(); }, 50);
  }

  function srchHide() {
    srchBar.classList.remove('show');
    srchClear();
    srchCnt.textContent = '';
  }

  srchInp.addEventListener('input', function() { srchDo(srchInp.value); });
  document.getElementById('srch-next').addEventListener('click', function() { srchNav(1); });
  document.getElementById('srch-prev').addEventListener('click', function() { srchNav(-1); });
  document.getElementById('srch-close').addEventListener('click', srchHide);

  // ── Right-click context menu ──
  var ctxMenu = document.getElementById('ctx-menu');

  function ctxHide() { ctxMenu.classList.remove('show'); }

  document.addEventListener('contextmenu', function(e) {
    e.preventDefault();
    ctxMenu.style.left = e.pageX + 'px';
    ctxMenu.style.top = e.pageY + 'px';
    ctxMenu.classList.add('show');
  });

  document.addEventListener('click', function(e) {
    if (!ctxMenu.contains(e.target)) ctxHide();
  });

  ctxMenu.querySelector('[data-act="selall"]').addEventListener('click', function() {
    ctxHide();
    var total = document.querySelectorAll('.line').length;
    selLines.clear();
    for (var i = 1; i <= total; i++) selLines.add(i);
    lastLine = total;
    document.querySelectorAll('.line').forEach(function(l) {
      var ln = parseInt(l.getAttribute('data-line'));
      l.classList.toggle('selected', selLines.has(ln));
    });
  });

  ctxMenu.querySelector('[data-act="copy"]').addEventListener('click', function() {
    ctxHide();
    // Prefer native selection (free-form text drag-select).
    var nativeSel = window.getSelection();
    if (nativeSel && nativeSel.toString().length > 0) {
      document.execCommand('copy');
      return;
    }
    // Fallback: copy line-number-selected lines.
    if (selLines.size === 0) return;
    var lines = [];
    document.querySelectorAll('.line.selected .line-code').forEach(function(el) {
      lines.push(el.textContent);
    });
    navigator.clipboard.writeText(lines.join('\\n')).catch(function(){});
  });

  // ── Read-only contenteditable: cursor + keyboard nav, no typing ──
  var linesDiv = document.getElementById('lines');

  linesDiv.addEventListener('beforeinput', function(e) {
    e.preventDefault(); // block all text insertion/deletion
  });

  linesDiv.addEventListener('paste', function(e) {
    e.preventDefault();
  });

  linesDiv.addEventListener('cut', function(e) {
    e.preventDefault();
  });

  linesDiv.addEventListener('keydown', function(e) {
    // Allow Ctrl/Cmd shortcuts to bubble up
    if (e.ctrlKey || e.metaKey) return;
    // Allow function keys (F3, Escape, etc.) to bubble up
    if (e.key.startsWith('F') && e.key.length <= 3) return;
    if (e.key === 'Escape') return;
    // Allow navigation keys
    if (e.key === 'ArrowLeft' || e.key === 'ArrowRight' ||
        e.key === 'ArrowUp' || e.key === 'ArrowDown' ||
        e.key === 'Home' || e.key === 'End' ||
        e.key === 'PageUp' || e.key === 'PageDown' ||
        e.key === 'Tab' || e.key === 'Shift' ||
        e.key === 'Control' || e.key === 'Alt' || e.key === 'Meta') {
      return;
    }
    // Block everything else (letters, Enter, Backspace, Delete, etc.)
    e.preventDefault();
  });

  // ── Keyboard shortcuts ──
  document.addEventListener('keydown', function(e) {
    // Ctrl+F — show search bar
    if (e.ctrlKey && e.key === 'f') {
      e.preventDefault();
      srchShow();
      return;
    }
    // F3 — find next; Shift+F3 — find previous
    if (e.key === 'F3') {
      if (srchBar.classList.contains('show')) {
        e.preventDefault();
        srchNav(e.shiftKey ? -1 : 1);
        return;
      }
    }
    // Esc — close search bar if open
    if (e.key === 'Escape') {
      if (srchBar.classList.contains('show')) {
        e.preventDefault();
        srchHide();
        return;
      }
    }
    // Enter in search input — find next
    if (e.key === 'Enter' && document.activeElement === srchInp) {
      e.preventDefault();
      srchNav(e.shiftKey ? -1 : 1);
      return;
    }
    // Ctrl+A — select all lines
    if (e.ctrlKey && e.key === 'a') {
      if (srchBar.classList.contains('show') && document.activeElement === srchInp) return;
      e.preventDefault();
      var total = document.querySelectorAll('.line').length;
      selLines.clear();
      for (var i = 1; i <= total; i++) selLines.add(i);
      lastLine = total;
      document.querySelectorAll('.line').forEach(function(l) {
        var ln = parseInt(l.getAttribute('data-line'));
        l.classList.toggle('selected', selLines.has(ln));
      });
    }
  });
})();
</script>
</body></html>''';
  }

  /// Build the line-number HTML structure from escaped text lines.
  String _buildLinesHtml(String escaped) {
    final lines = escaped.split('\n');
    final buf = StringBuffer();
    for (int i = 0; i < lines.length; i++) {
      buf.write('<div class="line" data-line="${i + 1}">');
      buf.write('<span class="line-num">${i + 1}</span>');
      buf.write('<span class="line-code">${lines[i]}</span>');
      buf.writeln('</div>');
    }
    return buf.toString();
  }

  // ─── Markdown with TOC sidebar ───

  Future<String> _buildMarkdownHtml(String md) async {
    final highlightJs =
        await rootBundle.loadString('assets/quicklook/highlight.min.js');
    final isLight = ThemeService().effectiveBrightness == Brightness.light;
    final themeCss = await rootBundle.loadString(
      isLight ? 'assets/quicklook/github.min.css' : 'assets/quicklook/github-dark.min.css',
    );
    final markedJs =
        await rootBundle.loadString('assets/quicklook/marked.min.js');

    final mdJson = jsonEncode(md);

    return '''
<!DOCTYPE html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  $themeCss
  ::-webkit-scrollbar { width: 6px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: #30363D; border-radius: 3px; }
  ::-webkit-scrollbar-thumb:hover { background: #484F58; }

  html, body {
    margin: 0; padding: 0; height: 100%;
    background: ${isLight ? '#FFFFFF' : '#1A1A2E'}; color: ${isLight ? '#24292E' : '#E6EDF3'};
    font-family: -apple-system,BlinkMacSystemFont,'Segoe UI','Microsoft YaHei Light',sans-serif;
    overflow: hidden;
  }
  #app { display: flex; height: 100%; }

  /* ── TOC sidebar ── */
  #toc {
    width: 190px; min-width: 190px; height: 100%;
    overflow-y: auto; overflow-x: hidden;
    border-right: 1px solid ${isLight ? '#D1D5DA' : '#21262D'};
    padding: 16px 12px; box-sizing: border-box;
  }
  .toc-title {
    font-size: 12px; font-weight: 600; color: ${isLight ? '#586069' : '#8B949E'};
    text-transform: uppercase; letter-spacing: 0.5px;
    margin-bottom: 12px;
  }
  #toc a {
    display: block; font-size: 12px; line-height: 1.6;
    color: ${isLight ? '#586069' : '#8B949E'}; text-decoration: none;
    padding: 2px 0; border-radius: 3px;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }
  #toc a:hover { color: ${isLight ? '#24292E' : '#E6EDF3'}; }
  #toc a.toc-h2 { padding-left: 12px; }
  #toc a.toc-h3 { padding-left: 24px; font-size: 11px; }

  /* ── Content area ── */
  #content-wrap {
    flex: 1; height: 100%; overflow-y: auto;
  }
  #content {
    max-width: 860px; margin: 0 auto; padding: 24px 32px;
    font-size: 14px; line-height: 1.7;
  }
  #content h1, #content h2, #content h3,
  #content h4, #content h5, #content h6 {
    margin-top: 24px; margin-bottom: 16px;
    font-weight: 600; line-height: 1.25;
  }
  #content h1 { font-size: 1.8em; border-bottom: 1px solid ${isLight ? '#D1D5DA' : '#30363D'}; padding-bottom: 8px; }
  #content h2 { font-size: 1.4em; border-bottom: 1px solid ${isLight ? '#D1D5DA' : '#30363D'}; padding-bottom: 6px; }
  #content h3 { font-size: 1.15em; }
  #content p { margin: 0 0 16px 0; }
  #content a { color: ${isLight ? '#0366D6' : '#58A6FF'}; text-decoration: none; }
  #content ul, #content ol { padding-left: 24px; margin-bottom: 16px; }
  #content li { margin-bottom: 4px; }
  #content blockquote {
    border-left: 4px solid ${isLight ? '#D1D5DA' : '#30363D'}; margin: 0 0 16px 0;
    padding: 0 16px; color: ${isLight ? '#586069' : '#8B949E'};
  }
  #content code {
    background: ${isLight ? '#F6F8FA' : '#161B22'}; padding: 2px 6px;
    border-radius: 4px; font-size: 0.9em;
    font-family: 'Consolas','Courier New','Microsoft YaHei Light',monospace;
  }
  #content pre {
    background: ${isLight ? '#F6F8FA' : '#161B22'}; border-radius: 6px;
    padding: 16px; overflow-x: auto;
  }
  #content pre code {
    background: none; padding: 0; font-size: 13px; line-height: 1.5;
  }
  #content table {
    border-collapse: collapse; width: 100%; margin-bottom: 16px;
  }
  #content th, #content td {
    border: 1px solid ${isLight ? '#D1D5DA' : '#30363D'}; padding: 8px 12px; text-align: left;
  }
  #content img { max-width: 100%; }
  #content hr { border: none; border-top: 1px solid ${isLight ? '#D1D5DA' : '#30363D'}; margin: 24px 0; }
</style>
</head><body>
<div id="app">
  <div id="toc">
    <div class="toc-title">Contents</div>
    <div id="toc-list"></div>
  </div>
  <div id="content-wrap">
    <div id="content"></div>
  </div>
</div>
<script>$markedJs
document.getElementById('content').innerHTML = marked.parse(${mdJson});
</script>
<script>$highlightJs
hljs.highlightAll();
</script>
<script>
(function() {
  // Build TOC from headings.
  var toc = document.getElementById('toc-list');
  var headings = document.querySelectorAll('#content h1, #content h2, #content h3');
  headings.forEach(function(h, i) {
    var id = 'md-h-' + i;
    h.id = id;
    var a = document.createElement('a');
    a.textContent = h.textContent;
    a.href = '#' + id;
    a.className = 'toc-' + h.tagName.toLowerCase();
    a.addEventListener('click', function(e) {
      e.preventDefault();
      document.getElementById(id).scrollIntoView({behavior: 'smooth'});
    });
    toc.appendChild(a);
  });
})();
</script>
</body></html>''';
  }

  String get _fileExt {
    final name = widget.filePath.split(RegExp(r'[/\\]')).last;
    final dotIdx = name.lastIndexOf('.');
    if (dotIdx <= 0) return '';
    return name.substring(dotIdx + 1).toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMsg != null) {
      return Center(
        child: Text(_errorMsg!,
            style: const TextStyle(fontSize: 15, color: Colors.redAccent)),
      );
    }

    if (_fallback) {
      // Fallback imported from quicklook_text_view.dart.
      // We import it directly to avoid circular deps.
      return _PlainTextFallback(filePath: widget.filePath);
    }

    if (_html == null) {
      return const Center(
        child:
            CircularProgressIndicator(strokeWidth: 2, color: Colors.white38),
      );
    }

    return Column(
      children: [
        if (_truncated)
          Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: Colors.orange.withAlpha(40),
            child: const Text('File too large, showing first 2 MB',
                style:
                    TextStyle(fontSize: 11, color: Colors.orangeAccent)),
          ),
        Expanded(
          child: InAppWebView(
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              transparentBackground: true,
              supportZoom: false,
              disableDefaultErrorPage: true,
              disableContextMenu: false, // custom JS context menu
              disableHorizontalScroll: true,
              disableVerticalScroll: false,
            ),
            initialData: InAppWebViewInitialData(
              data: _html!,
              mimeType: 'text/html',
              encoding: 'utf-8',
            ),
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              final url = navigationAction.request.url;
              if (url != null && url.toString() != 'about:blank') {
                await Process.run('cmd', ['/c', 'start', '', url.toString()]);
                return NavigationActionPolicy.CANCEL;
              }
              return NavigationActionPolicy.ALLOW;
            },
            onReceivedError: (controller, request, error) {
              if (!mounted) return;
              setState(() => _fallback = true);
            },
          ),
        ),
      ],
    );
  }
}

/// Minimal plain-text fallback when WebView2 is unavailable.
/// Mirrors [QuickLookTextView]'s line-number view.
class _PlainTextFallback extends StatefulWidget {
  final String filePath;
  const _PlainTextFallback({required this.filePath});

  @override
  State<_PlainTextFallback> createState() => _PlainTextFallbackState();
}

class _PlainTextFallbackState extends State<_PlainTextFallback> {
  String? _content;
  String? _errorMsg;
  static const _maxBytes = 1 * 1024 * 1024;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _PlainTextFallback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filePath != oldWidget.filePath) {
      _content = null;
      _errorMsg = null;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final file = File(widget.filePath);
      if (!await file.exists()) {
        if (!mounted) return;
        setState(() => _errorMsg = 'Failed to read text');
        return;
      }
      final length = await file.length();
      final readLen = length > _maxBytes ? _maxBytes : length;
      final bytes =
          await file.readAsBytes().then((b) => b.sublist(0, readLen));
      String content;
      try {
        content = String.fromCharCodes(bytes);
      } catch (_) {
        content = String.fromCharCodes(bytes.cast<int>());
      }
      if (!mounted) return;
      setState(() => _content = content);
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMsg = 'Failed to read text');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMsg != null) {
      return Center(
          child: Text(_errorMsg!,
              style:
                  const TextStyle(fontSize: 15, color: Colors.redAccent)));
    }
    if (_content == null) {
      return const Center(
          child: CircularProgressIndicator(
              strokeWidth: 2, color: Colors.white38));
    }
    final lines = _content!.split('\n');
    return ListView.builder(
      itemCount: lines.length,
      itemExtent: 19.5,
      itemBuilder: (context, i) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 52,
              child: Text(
                '${i + 1}',
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white38,
                    fontFamily: 'Consolas'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                lines[i],
                style: const TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: Colors.white,
                    fontFamily: 'Consolas'),
              ),
            ),
          ],
        );
      },
    );
  }
}
