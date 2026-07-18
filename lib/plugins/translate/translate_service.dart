/// Translation service — LibreTranslate HTTP API client.
///
/// Supports any LibreTranslate-compatible server (local or remote).
/// Two-tier API:
/// - [translate]        → simple String? return (backward compatible)
/// - [translateWithDetail] → rich [TranslateResult] with typed errors (for debug UI)
library;

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Rich translation result with typed error information.
class TranslateResult {
  final bool ok;
  final String? text; // translated text when ok==true
  final String? errorType; // 'connection_refused' | 'timeout' | 'http_error' | 'parse_error' | 'unknown'
  final String? errorMessage; // human-readable description

  const TranslateResult._({
    required this.ok,
    this.text,
    this.errorType,
    this.errorMessage,
  });

  factory TranslateResult.success(String text) => TranslateResult._(
        ok: true,
        text: text,
      );

  factory TranslateResult.failure(String type, String message) =>
      TranslateResult._(
        ok: false,
        errorType: type,
        errorMessage: message,
      );

  @override
  String toString() => ok ? 'TranslateResult(ok, "$text")' : 'TranslateResult($errorType, "$errorMessage")';
}

class TranslateService {
  /// Normalized server base URL (no trailing slash).
  final String baseUrl;

  final String? apiKey;
  final Duration timeout;

  TranslateService({
    String? baseUrl,
    this.apiKey,
    this.timeout = const Duration(seconds: 10),
  }) : baseUrl = _normalizeUrl(baseUrl ?? 'http://localhost:5000');

  /// Strip trailing slashes so `$baseUrl/translate` never produces `//`.
  static String _normalizeUrl(String url) {
    String u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  // ── Simple API (backward compatible with TranslatePage) ──────────

  /// Translate [text] from [from] language to [to] language.
  /// Returns the translated text, or null on any error.
  Future<String?> translate(
    String text, {
    String from = 'auto',
    String to = 'zh',
  }) async {
    final result = await translateWithDetail(text, from: from, to: to);
    return result.ok ? result.text : null;
  }

  // ── Rich API (for debug UI) ──────────────────────────────────────

  /// Translate with detailed error information.
  Future<TranslateResult> translateWithDetail(
    String text, {
    String from = 'auto',
    String to = 'zh',
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/translate');
      final body = <String, dynamic>{
        'q': text,
        'source': from,
        'target': to,
        'format': 'text',
      };
      if (apiKey != null && apiKey!.isNotEmpty) {
        body['api_key'] = apiKey;
      }

      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);

      if (response.statusCode == 200) {
        try {
          final decoded = jsonDecode(response.body) as Map<String, dynamic>;
          final translatedText = decoded['translatedText'];
          if (translatedText is String && translatedText.isNotEmpty) {
            return TranslateResult.success(translatedText);
          }
          return TranslateResult.success(translatedText?.toString() ?? '');
        } catch (e) {
          return TranslateResult.failure(
            'parse_error',
            'Failed to parse server response: $e',
          );
        }
      } else {
        String bodyPreview = response.body;
        if (bodyPreview.length > 200) {
          bodyPreview = '${bodyPreview.substring(0, 200)}...';
        }
        return TranslateResult.failure(
          'http_error',
          'HTTP ${response.statusCode}: $bodyPreview',
        );
      }
    } on TimeoutException catch (_) {
      return TranslateResult.failure(
        'timeout',
        'Request timed out after ${timeout.inSeconds}s',
      );
    } on http.ClientException catch (e) {
      // SocketException, HandshakeException, etc.
      return TranslateResult.failure(
        'connection_refused',
        'Connection failed: ${e.message}',
      );
    } catch (e) {
      return TranslateResult.failure(
        'unknown',
        '$e',
      );
    }
  }

  // ── Languages ────────────────────────────────────────────────────

  /// Fetch supported languages from the LibreTranslate server.
  /// Returns list of `{code, name}` maps, or empty list on error.
  Future<List<Map<String, dynamic>>> fetchLanguages() async {
    try {
      final uri = Uri.parse('$baseUrl/languages');
      final response = await http.get(uri).timeout(timeout);

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is List) {
          return decoded.cast<Map<String, dynamic>>();
        }
      }
      return [];
    } catch (_) {
      return [];
    }
  }
}

// ── Hardcoded language fallback ────────────────────────────────────

/// Chinese name lookup for language codes.
/// Covers all Argos Translate supported codes + fallback list.
const kLangNamesZh = <String, String>{
  'auto': '自动检测',
  'ar': '阿拉伯语',
  'az': '阿塞拜疆语',
  'bg': '保加利亚语',
  'bn': '孟加拉语',
  'ca': '加泰罗尼亚语',
  'cs': '捷克语',
  'da': '丹麦语',
  'de': '德语',
  'el': '希腊语',
  'en': '英语',
  'eo': '世界语',
  'es': '西班牙语',
  'et': '爱沙尼亚语',
  'eu': '巴斯克语',
  'fa': '波斯语',
  'fi': '芬兰语',
  'fr': '法语',
  'ga': '爱尔兰语',
  'gl': '加利西亚语',
  'he': '希伯来语',
  'hi': '印地语',
  'hu': '匈牙利语',
  'id': '印尼语',
  'it': '意大利语',
  'ja': '日语',
  'ko': '韩语',
  'ky': '吉尔吉斯语',
  'lt': '立陶宛语',
  'lv': '拉脱维亚语',
  'ms': '马来语',
  'nb': '挪威语',
  'nl': '荷兰语',
  'pb': '葡萄牙语（巴西）',
  'pl': '波兰语',
  'pt': '葡萄牙语',
  'ro': '罗马尼亚语',
  'ru': '俄语',
  'sk': '斯洛伐克语',
  'sl': '斯洛文尼亚语',
  'sq': '阿尔巴尼亚语',
  'sv': '瑞典语',
  'sw': '斯瓦希里语',
  'th': '泰语',
  'tl': '他加禄语',
  'tr': '土耳其语',
  'uk': '乌克兰语',
  'ur': '乌尔都语',
  'vi': '越南语',
  'zh': '简体中文',
  'zh-Hans': '简体中文',
  'zt': '繁体中文',
};

/// Lookup the Chinese name for a language code, falling back to the code itself.
String langNameZh(String code) => kLangNamesZh[code] ?? code;

