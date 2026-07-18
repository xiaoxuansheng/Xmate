/// Shared formatting utilities used across QuickLook viewers and settings.
///
/// These functions replace duplicated `_formatSize`, `_fmtSize`, `_formatTime`,
/// `_fmtTime`, `_formatHotkey`, and `hotkeyLabel` implementations scattered
/// across the plugin.
library;

import 'dart:convert';
import 'package:flutter/services.dart' show LogicalKeyboardKey, MethodChannel;
import 'quicklook_palette_state.dart';

/// Format [bytes] into a human-readable size string (B / KB / MB / GB).
///
/// Examples: `"512 B"`, `"1.5 KB"`, `"23.7 MB"`, `"1.25 GB"`.
String fileSizeStr(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Format [dt] as `YYYY-MM-DD HH:MM:SS` (default) or `YYYY-MM-DD HH:MM`
/// when [showSeconds] is false.
///
/// Examples: `"2025-12-31 14:03:27"`, `"2025-12-31 14:03"`.
String fileTimeStr(DateTime dt, {bool showSeconds = true}) {
  final ymd = '${dt.year}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';
  final hm = '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';
  if (showSeconds) {
    return '$ymd $hm:${dt.second.toString().padLeft(2, '0')}';
  }
  return '$ymd $hm';
}

/// Format a hardware hotkey from modifier bitmask and USB HID [keyId].
///
/// [mods] bits: 1=Alt, 2=Ctrl, 4=Shift, 8=Win.
/// Returns a human-readable string like `"Alt+S"` or `"Ctrl+Shift+Space"`.
/// When no key is found returns [emptyLabel] (default `"Unset"`).
String formatHotkey(int mods, int keyId, {String emptyLabel = 'Unset'}) {
  final parts = <String>[];
  if (mods & 1 != 0) parts.add('Alt');
  if (mods & 2 != 0) parts.add('Ctrl');
  if (mods & 4 != 0) parts.add('Shift');
  if (mods & 8 != 0) parts.add('Win');
  final k = LogicalKeyboardKey.findKeyByKeyId(keyId);
  if (k != null) {
    final n = k.keyLabel;
    if (n.length == 1 && n.codeUnitAt(0) >= 0x41 && n.codeUnitAt(0) <= 0x5A) {
      parts.add(n);
    } else if (n == ' ') {
      parts.add('Space');
    } else {
      parts.add(n);
    }
  }
  return parts.isEmpty ? emptyLabel : parts.join('+');
}

/// Query the currently selected file path using three sources:
/// 1. Palette state file (command palette file navigation) — highest priority
/// 2. File Converter selected file — when converter is open and has a selection
/// 3. Explorer COM selection (CabinetWClass / ExploreWClass) — lowest priority
///
/// Returns null when no single file is selected or when the palette is
/// not active (releases the file pin).  This consolidates the identical
/// priority-fallback logic previously duplicated in [_showQuickLook]
/// (main.dart) and [_pollSelection] (quicklook_page.dart).
Future<String?> getSelectedFilePath() async {
  // 1-2. Check palette state first (both palette and converter sources).
  try {
    final ps = await QuickLookPaletteState.read();
    if (ps.active && ps.path != null && ps.path!.isNotEmpty) {
      return ps.path;
    }
  } catch (_) {}
  // 3. Fall back to Explorer COM selection.
  try {
    const channel = MethodChannel('com.xmate/quicklook');
    final json = await channel.invokeMethod<String>('getExplorerSelection');
    if (json != null && json.isNotEmpty) {
      final map = jsonDecode(json) as Map<String, dynamic>;
      final count = map['count'] as int? ?? 0;
      if (count == 1) {
        return map['path'] as String?;
      }
    }
  } catch (_) {}
  return null;
}
