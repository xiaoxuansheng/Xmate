/// RFC 2822 / 2045-2047 MIME email parser.
///
/// Extracted from quicklook_eml_view.dart to separate parsing logic from UI.
/// All semantics preserved exactly as in the original embedded implementation.
library;

import 'dart:convert';
import 'dart:typed_data';

// ══════════════════════════════════════════════════════════════════════════════
// Data models
// ══════════════════════════════════════════════════════════════════════════════

class EmlAttachment {
  final String? filename;
  final int size;
  final String? mimeType;
  final Uint8List data; // decoded body bytes — for open-on-click

  const EmlAttachment({
    this.filename, this.mimeType, required this.size, required this.data,
  });
}

class EmlMessage {
  final String? from;
  final String? to;
  final String? subject;
  final String? date;
  final String? cc;
  final String bodyText;
  final bool bodyIsHtml;
  final List<EmlAttachment> attachments;
  final Map<String, String> inlineParts; // cid → data: URI

  const EmlMessage({
    this.from, this.to, this.subject, this.date, this.cc,
    required this.bodyText, required this.bodyIsHtml,
    this.attachments = const [],
    this.inlineParts = const {},
  });
}

// ══════════════════════════════════════════════════════════════════════════════
// RFC 2047 / Quoted-Printable / Base64 decoders
// ══════════════════════════════════════════════════════════════════════════════

final _reEncWord = RegExp(r'=\?([^?]+)\?([BbQq])\?([^?]*)\?=');

String _decodeRfc2047(String text) {
  return text.replaceAllMapped(_reEncWord, (m) {
    final charset = m.group(1)!;
    final encoding = m.group(2)!.toUpperCase();
    final encoded = m.group(3)!;
    try {
      Uint8List bytes;
      if (encoding == 'B') {
        String b64 = encoded.replaceAll('_', '/');
        while (b64.length % 4 != 0) { b64 += '='; }
        bytes = base64.decode(b64);
      } else {
        bytes = _decodeQuotedPrintableBytes(encoded.replaceAll('_', ' '));
      }
      final cs = charset.toLowerCase();
      if (cs == 'utf-8') return utf8.decode(bytes, allowMalformed: true);
      if (cs == 'iso-8859-1' || cs == 'latin1') return latin1.decode(bytes);
      try { return utf8.decode(bytes, allowMalformed: true); } catch (_) {}
      return latin1.decode(bytes);
    } catch (_) {
      return encoded;
    }
  });
}

Uint8List _decodeQuotedPrintableBytes(String text) {
  final out = <int>[];
  int i = 0;
  while (i < text.length) {
    if (text[i] == '=' && i + 2 < text.length) {
      final h = text[i + 1];
      final l = text[i + 2];
      if (_isHex(h) && _isHex(l)) {
        out.add(int.parse('$h$l', radix: 16));
        i += 3;
        continue;
      }
    }
    if (text[i] == '=' && (i + 1 >= text.length || text[i + 1] == '\r' || text[i + 1] == '\n')) {
      i++;
      if (i < text.length && text[i] == '\r') i++;
      if (i < text.length && text[i] == '\n') i++;
      continue;
    }
    out.add(text.codeUnitAt(i));
    i++;
  }
  return Uint8List.fromList(out);
}

bool _isHex(String c) {
  final code = c.codeUnitAt(0);
  return (code >= 0x30 && code <= 0x39) ||
         (code >= 0x41 && code <= 0x46) ||
         (code >= 0x61 && code <= 0x66);
}

Uint8List _decodeB64(String text) {
  final clean = text.replaceAll(RegExp(r'\s+'), '');
  return base64.decode(clean);
}

String _decodeCharset(Uint8List bytes, String? charset) {
  if (charset == null || charset.isEmpty) {
    try { return utf8.decode(bytes, allowMalformed: true); } catch (_) {}
    return latin1.decode(bytes);
  }
  final cs = charset.toLowerCase().trim();
  if (cs == 'utf-8' || cs == 'utf8') {
    try { return utf8.decode(bytes, allowMalformed: true); } catch (_) {}
  }
  if (cs == 'iso-8859-1' || cs == 'latin1' || cs == 'windows-1252') {
    return latin1.decode(bytes);
  }
  try { return utf8.decode(bytes, allowMalformed: true); } catch (_) {}
  return latin1.decode(bytes);
}

Uint8List _decodeTransfer(Uint8List body, String? cte) {
  if (cte == null) return body;
  switch (cte.toLowerCase().trim()) {
    case 'base64':
      try { return _decodeB64(latin1.decode(body)); } catch (_) { return body; }
    case 'quoted-printable':
      return _decodeQuotedPrintableBytes(latin1.decode(body));
    case '7bit':
    case '8bit':
    case 'binary':
    default:
      return body;
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// MIME part parser
// ══════════════════════════════════════════════════════════════════════════════

class _MimePart {
  final Map<String, String> headers;
  final Uint8List body;
  const _MimePart(this.headers, this.body);

  String? get contentType => _header('content-type');
  String? get cte => _header('content-transfer-encoding');
  String? get contentDisposition => _header('content-disposition');
  String? get contentId => _header('content-id');

  String? _header(String name) {
    final v = headers[name];
    if (v != null) return v;
    return headers.entries
        .firstWhere((e) => e.key.toLowerCase() == name, orElse: () => const MapEntry('', ''))
        .value;
  }
}

(int, int)? _findHeaderBodySplit(Uint8List data) {
  for (int i = 0; i < data.length - 1; i++) {
    if (data[i] == 0x0D && data[i + 1] == 0x0A && i + 3 < data.length &&
        data[i + 2] == 0x0D && data[i + 3] == 0x0A) {
      return (i + 4, i);
    }
    if (data[i] == 0x0A && i + 1 < data.length && data[i + 1] == 0x0A) {
      return (i + 2, i);
    }
  }
  return null;
}

Map<String, String> _parseHeaders(String block) {
  final map = <String, List<String>>{};
  String? currentKey;
  for (final rawLine in block.split(RegExp(r'\r?\n'))) {
    if (rawLine.isEmpty) continue;
    if ((rawLine.startsWith(' ') || rawLine.startsWith('\t')) && currentKey != null) {
      map[currentKey]!.last += ' ${rawLine.trimLeft()}';
      continue;
    }
    final colon = rawLine.indexOf(':');
    if (colon < 1) continue;
    final key = rawLine.substring(0, colon).toLowerCase().trim();
    final value = rawLine.substring(colon + 1).trim();
    if (map.containsKey(key)) {
      map[key]!.add(value);
    } else {
      map[key] = [value];
    }
    currentKey = key;
  }
  final result = <String, String>{};
  for (final e in map.entries) {
    result[e.key] = _decodeRfc2047(e.value.join(', '));
  }
  return result;
}

String? _extractBoundary(String contentType) {
  final m = RegExp(r'boundary\s*=\s*"?([^";\s]+)"?', caseSensitive: false)
      .firstMatch(contentType);
  return m?.group(1);
}

String? _extractCharset(String contentType) {
  final m = RegExp(r'charset\s*=\s*"?([^";\s]+)"?', caseSensitive: false)
      .firstMatch(contentType);
  return m?.group(1);
}

String _extractMimeType(String contentType) {
  final semi = contentType.indexOf(';');
  return (semi >= 0 ? contentType.substring(0, semi) : contentType).trim().toLowerCase();
}

String? _extractFilename(Map<String, String> headers) {
  final disp = headers['content-disposition'];
  if (disp != null) {
    final star = RegExp("filename\\*\\s*=\\s*[^;'\"]*''([^;\"]*)", caseSensitive: false)
        .firstMatch(disp);
    if (star != null) {
      try { return Uri.decodeComponent(star.group(1)!); } catch (_) {}
    }
    final m = RegExp(r'filename\s*=\s*"?([^";\n]+)"?', caseSensitive: false)
        .firstMatch(disp);
    if (m != null) return _trimQuotes(m.group(1)!);
  }
  final ct = headers['content-type'];
  if (ct != null) {
    final m = RegExp(r'name\s*=\s*"?([^";\n]+)"?', caseSensitive: false)
        .firstMatch(ct);
    if (m != null) return _trimQuotes(m.group(1)!);
  }
  return null;
}

String _trimQuotes(String s) {
  s = s.trim();
  if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
    return s.substring(1, s.length - 1);
  }
  return s;
}

String _cleanCid(String cid) {
  var s = cid.trim();
  if (s.startsWith('<') && s.endsWith('>')) s = s.substring(1, s.length - 1);
  return s;
}

List<Uint8List> _splitByBoundary(Uint8List body, String boundary) {
  final parts = <Uint8List>[];
  final marker = ascii.encode('--$boundary');
  final endMarker = ascii.encode('--$boundary--');

  int start = 0;
  while (start < body.length) {
    int idx = _indexOfBytes(body, marker, start);
    if (idx < 0) break;
    if (_matchAt(body, endMarker, idx)) break;

    int contentStart = idx + marker.length;
    if (contentStart < body.length && body[contentStart] == 0x0D) contentStart++;
    if (contentStart < body.length && body[contentStart] == 0x0A) contentStart++;

    start = contentStart;

    int nextIdx = _indexOfBytes(body, marker, start);
    if (nextIdx < 0) {
      parts.add(body.sublist(start));
      break;
    }

    int contentEnd = nextIdx;
    if (contentEnd > start && body[contentEnd - 1] == 0x0A) contentEnd--;
    if (contentEnd > start && body[contentEnd - 1] == 0x0D) contentEnd--;

    if (contentEnd > start) {
      parts.add(body.sublist(start, contentEnd));
    }
    start = nextIdx;
  }
  return parts;
}

int _indexOfBytes(Uint8List data, List<int> pattern, int start) {
  outer:
  for (int i = start; i <= data.length - pattern.length; i++) {
    for (int j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) continue outer;
    }
    return i;
  }
  return -1;
}

bool _matchAt(Uint8List data, List<int> pattern, int offset) {
  if (offset + pattern.length > data.length) return false;
  for (int i = 0; i < pattern.length; i++) {
    if (data[offset + i] != pattern[i]) return false;
  }
  return true;
}

_MimePart _parsePart(Uint8List data) {
  final split = _findHeaderBodySplit(data);
  if (split == null) return _MimePart({}, data);
  final (bodyStart, headerEnd) = split;
  final headerBlock = latin1.decode(data.sublist(0, headerEnd));
  final headers = _parseHeaders(headerBlock);
  final body = data.sublist(bodyStart);
  return _MimePart(headers, body);
}

// ══════════════════════════════════════════════════════════════════════════════
// Main EML parser — public entry point
// ══════════════════════════════════════════════════════════════════════════════

EmlMessage parseEml(Uint8List raw) {
  final root = _parsePart(raw);

  String? from = root.headers['from'];
  String? to = root.headers['to'];
  String? subject = root.headers['subject'];
  String? date = root.headers['date'];
  String? cc = root.headers['cc'];

  date = _formatDate(date);

  String? htmlText;
  String? plainText;
  final attachments = <EmlAttachment>[];
  final inlineParts = <String, String>{};

  _doWalk(root, (String? html, String? plain, List<EmlAttachment> atts, Map<String, String> inlines) {
    if (html != null) htmlText = html;
    if (plain != null) plainText = plain;
    attachments.addAll(atts);
    inlineParts.addAll(inlines);
  });

  final bool bodyIsHtml;
  final String bodyText;
  if (htmlText != null) {
    bodyText = htmlText!;
    bodyIsHtml = true;
  } else if (plainText != null) {
    bodyText = plainText!;
    bodyIsHtml = false;
  } else {
    bodyText = '';
    bodyIsHtml = false;
  }

  final resolvedBody = (bodyIsHtml && inlineParts.isNotEmpty)
      ? _resolveCidRefs(bodyText, inlineParts)
      : bodyText;

  return EmlMessage(
    from: from, to: to, subject: subject, date: date, cc: cc,
    bodyText: resolvedBody, bodyIsHtml: bodyIsHtml,
    attachments: attachments, inlineParts: inlineParts,
  );
}

String? _formatDate(String? date) {
  if (date == null) return null;
  final m = RegExp(r'^(.*?)\s+([+-])(\d{2})(\d{2})(\s*\([^)]*\))?\s*$').firstMatch(date);
  if (m == null) return date;
  final body = m.group(1)!;
  final sign = m.group(2)!;
  final h = int.parse(m.group(3)!);
  final min = int.parse(m.group(4)!);
  if (min == 0) return '$body UTC$sign$h:00';
  return '$body UTC$sign$h:${min.toString().padLeft(2, '0')}';
}

typedef _WalkCb = void Function(
  String? html, String? plain, List<EmlAttachment> atts, Map<String, String> inlines,
);

void _doWalk(_MimePart part, _WalkCb cb) {
  final ct = part.contentType;
  final mimeType = ct != null ? _extractMimeType(ct) : 'text/plain';
  final boundary = ct != null ? _extractBoundary(ct) : null;

  if (mimeType.startsWith('multipart/') && boundary != null) {
    for (final chunk in _splitByBoundary(part.body, boundary)) {
      if (chunk.isEmpty) continue;
      _doWalk(_parsePart(chunk), cb);
    }
    return;
  }

  final charset = ct != null ? _extractCharset(ct) : null;
  final decoded = _decodeTransfer(part.body, part.cte);
  final text = _decodeCharset(decoded, charset);

  final disp = part.contentDisposition;
  final filename = _extractFilename(part.headers);
  final cid = part.contentId != null ? _cleanCid(part.contentId!) : null;
  final isInline = disp != null && disp.toLowerCase().contains('inline');
  final isAttachment = disp != null && disp.toLowerCase().contains('attachment');

  if (mimeType.startsWith('image/') && cid != null && cid.isNotEmpty) {
    final b64 = base64.encode(decoded);
    cb(null, null, [], {cid: 'data:$mimeType;base64,$b64'});
    return;
  }

  if (mimeType.startsWith('image/') && isInline && filename != null) {
    final b64 = base64.encode(decoded);
    cb(null, null, [], {filename: 'data:$mimeType;base64,$b64'});
    return;
  }

  if (filename != null && (isAttachment || (!isInline))) {
    cb(null, null, [
      EmlAttachment(filename: filename, mimeType: mimeType, size: decoded.length, data: decoded),
    ], {});
    return;
  }

  if (mimeType == 'text/html') {
    cb(text, null, [], {});
  } else if (mimeType == 'text/plain') {
    cb(null, text, [], {});
  } else if (mimeType.startsWith('text/')) {
    cb(null, text, [], {});
  } else if (filename != null || disp != null) {
    cb(null, null, [
      EmlAttachment(filename: filename ?? 'attachment', mimeType: mimeType, size: decoded.length, data: decoded),
    ], {});
  }
}

String _resolveCidRefs(String html, Map<String, String> inlineParts) {
  return html.replaceAllMapped(
    RegExp(r"""(["'(]?\s*)cid:([^\s"'<>)]+)(\s*["')]?)""", caseSensitive: false),
    (m) {
      var rawCid = m.group(2)!.trim();
      while (rawCid.endsWith('.') || rawCid.endsWith(',')) {
        rawCid = rawCid.substring(0, rawCid.length - 1);
      }
      final dataUri = inlineParts[rawCid] ?? inlineParts['<$rawCid>'];
      if (dataUri != null) return '${m.group(1)}$dataUri${m.group(3)}';
      return m.group(0)!;
    },
  );
}
