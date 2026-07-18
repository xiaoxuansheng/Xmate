/// Offline translation service for OCR translate — LibreTranslate HTTP API bridge.
///
/// Connects to the local LibreTranslate server (managed by `ServerManager`).
/// No Marian / ONNX dependency — fully HTTP.
library;

import 'package:http/http.dart' as http;
import 'dart:convert';

import '../../translate/server_manager.dart';

class TranslateService {
  final ServerManager _srv = ServerManager();

  /// Batch-translate [texts] from [from] language to [to] language.
  ///
  /// Returns a list of translated strings in the same order as input.
  /// On any error, returns the raw error text for each entry.
  Future<List<String>> translateBatch(
    List<String> texts, {
    String from = 'auto',
    String to = 'zh',
  }) async {
    final results = <String>[];
    for (final text in texts) {
      if (text.trim().isEmpty) {
        results.add('');
        continue;
      }
      try {
        final uri = Uri.parse('${_srv.baseUrl}/translate');
        final body = <String, dynamic>{
          'q': text,
          'source': from,
          'target': to,
          'format': 'text',
        };
        final response = await http
            .post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
            .timeout(const Duration(seconds: 15));
        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body) as Map<String, dynamic>;
          results.add((decoded['translatedText'] as String?) ?? '');
        } else {
          results.add('HTTP ${response.statusCode}');
        }
      } catch (e) {
        results.add('$e');
      }
    }
    return results;
  }
}
