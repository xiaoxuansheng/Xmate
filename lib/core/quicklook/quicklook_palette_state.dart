import 'dart:convert';
import 'dart:io';

/// Shared state file used to communicate the current file selection to
/// the QuickLook process.  Written by the main process, read (polled) by
/// the QuickLook subprocess.
///
/// File: %APPDATA%/XMate/ql_palette.json
/// Format: {"path": "C:/...", "active": true, "source": "palette"}
///
/// Priority order (polled by QL):
///   1. source = "palette" (command palette file navigation)
///   2. source = "converter" (File Converter selected file)
///   3. Explorer COM selection (fallback)
class QuickLookPaletteState {
  final String? path;
  final bool active;
  final String source;

  const QuickLookPaletteState({this.path, this.active = false, this.source = ''});

  static Future<String> get _path async {
    final dir = '${Platform.environment['APPDATA']}\\XMate';
    await Directory(dir).create(recursive: true);
    return '$dir\\ql_palette.json';
  }

  /// Write the current palette selection.  [active] should be true while
  /// the palette is open; set it to false (or call [clear]) when the
  /// palette closes so QuickLook falls back to Explorer polling.
  static Future<void> update({String? path, bool active = true, String source = ''}) async {
    try {
      await File(await _path)
          .writeAsString(jsonEncode({'path': path, 'active': active, 'source': source}));
    } catch (_) {}
  }

  /// Delete the state file so QuickLook treats it as "palette closed".
  static Future<void> clear() async {
    try {
      final f = File(await _path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Synchronous version for use in [dispose] / [State.deactivate].
  static void clearSync() {
    try {
      final dir = '${Platform.environment['APPDATA']}\\XMate';
      final f = File('$dir\\ql_palette.json');
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Read the current palette state.  Returns an inactive state if the
  /// file doesn't exist or is malformed.
  static Future<QuickLookPaletteState> read() async {
    try {
      final f = File(await _path);
      if (!await f.exists()) return const QuickLookPaletteState();
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return QuickLookPaletteState(
        path: m['path'] as String?,
        active: m['active'] == true,
        source: (m['source'] as String?) ?? '',
      );
    } catch (_) {
      return const QuickLookPaletteState();
    }
  }
}
