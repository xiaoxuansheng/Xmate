/// XMate -- File context submenu service (singleton).
library;

import 'dart:io';

import 'package:flutter/services.dart';

import '../search/file_search_service.dart';
import '../settings/settings_service.dart';
import 'file_submenu_item.dart';

class FileSubmenuService {
  static final FileSubmenuService _instance = FileSubmenuService._();
  factory FileSubmenuService() => _instance;
  FileSubmenuService._();

  final _settings = SettingsService();
  static const _kKey = 'app.fileSubmenu.actions';
  static const _fileOpsChannel = MethodChannel('com.xmate/fileops');

  // Load / Save (all items: builtins + customs mixed, sorted) ---------------

  /// Load items for the submenu (only enabled built-ins).
  List<FileSubMenuItem> loadItems() {
    final items = _loadAll();
    items.removeWhere((i) => i is BuiltinFileAction && !i.enabled);
    items.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return items;
  }

  /// Load ALL items for settings UI (disabled built-ins included).
  List<FileSubMenuItem> loadAllItems() {
    final items = _loadAll();
    items.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return items;
  }

  List<FileSubMenuItem> _loadAll() {
    final raw = _settings.get(_kKey);
    if (raw is List && raw.isNotEmpty) {
      final items = parseSubmenuItems(raw);
      // Ensure every built-in kind is present (forward-compat)
      final seen = items.whereType<BuiltinFileAction>().map((b) => b.kind).toSet();
      for (final k in FileActionKind.values) {
        if (!seen.contains(k)) {
          items.add(BuiltinFileAction(k, sortOrder: items.length));
        }
      }
      return items;
    }
    return defaultBuiltins();
  }

  Future<void> saveItems(List<FileSubMenuItem> items) async {
    final json = items.map((i) => switch (i) {
      BuiltinFileAction b => b.toJson(),
      CustomFileAction c => c.toJson(),
    }).toList();
    await _settings.set(_kKey, json);
  }

  // Execute -----------------------------------------------------------------

  Future<void> execute(FileSubMenuItem item, String filePath) async {
    FileSearchService().markOpened(filePath);
    switch (item) {
      case BuiltinFileAction(:final kind):
        await _execBuiltin(kind, filePath);
      case CustomFileAction a:
        await _execCustom(a, filePath);
    }
  }

  /// Supported file extensions for the Translate file action.
  static const supportedTranslateExts = '.txt .html .srt .pdf .docx .pptx .epub .odt .odp';

  /// Supported file extensions for the Convert file action.
  static const supportedConvertExts = '3gp 3gpp aac aiff ape arw avi avif bik bmp '
      'cda cr2 dds dng doc docx exr flac flv gif '
      'heic heif ico jfif jpg jpeg m4a m4b m4v mkv mov '
      'mp3 mp4 mpg mpeg nef odp ods odt oga ogg '
      'ogv opus pdf png ppt pptx psd raf rm svg '
      'tga tif tiff ts vob wav webm webp wma wmv '
      'xls xlsx xcf';

  Future<void> _execBuiltin(FileActionKind kind, String filePath) async {
    // C++ getPath also normalises / → \, kept here as belt-and-suspenders.
    final winPath = filePath.replaceAll('/', '\\');
    switch (kind) {
      case FileActionKind.openFolder:
        // explorer /select, requires the trailing comma and backslash path.
        await Process.run('explorer', ['/select,', winPath]);
      case FileActionKind.copyPath:
        await Clipboard.setData(ClipboardData(text: filePath));
      case FileActionKind.copy:
        await _fileOpsChannel.invokeMethod('copyToClipboard', {'path': winPath});
      case FileActionKind.cut:
        await _fileOpsChannel.invokeMethod('cutToClipboard', {'path': winPath});
      case FileActionKind.shortcut:
        await _fileOpsChannel.invokeMethod('createShortcut', {'path': winPath});
      case FileActionKind.delete:
        await _fileOpsChannel.invokeMethod('deleteToRecycleBin', {'path': winPath});
      case FileActionKind.properties:
        await _fileOpsChannel.invokeMethod('showProperties', {'path': winPath});
      case FileActionKind.pinToStart:
        await _fileOpsChannel.invokeMethod('pinToStart', {'path': winPath});
      case FileActionKind.openAsAdmin:
        await _fileOpsChannel.invokeMethod('openAsAdmin', {'path': winPath});
      case FileActionKind.translateFile:
        // Handled by appKey in command_palette; no-op here
        break;
      case FileActionKind.convertFile:
        await sendFileToConverter(filePath);
        // Spawn FC detached process
        try {
          await Process.start(
              Platform.resolvedExecutable, ['--fileconverter'],
              mode: ProcessStartMode.detached);
        } catch (_) {}
        break;
    }
  }

  /// Whether the translate file action should be visible for this file path.
  static bool isTranslateSupported(String filePath) {
    final dot = filePath.lastIndexOf('.');
    if (dot < 0) return false;
    final ext = filePath.substring(dot).toLowerCase();
    return supportedTranslateExts.contains(ext);
  }

  /// Whether the convert file action should be visible for this file path.
  static bool isConvertSupported(String filePath) {
    final dot = filePath.lastIndexOf('.');
    if (dot < 0) return false;
    final ext = filePath.substring(dot + 1).toLowerCase();
    return supportedConvertExts.contains(ext);
  }

  /// Pending-file path that FC polls to pick up new files from external contexts.
  static String get _fcPendingPath =>
      '${Platform.environment['APPDATA']}\\XMate\\fc_add_pending.json';

  /// Write a file for FC to add. If an FC process is already running it will
  /// pick up the file via polling; otherwise we spawn a new FC.
  static Future<void> sendFileToConverter(String filePath) async {
    try {
      final dir = Directory('${Platform.environment['APPDATA']}\\XMate');
      if (!await dir.exists()) await dir.create(recursive: true);
      await File(_fcPendingPath).writeAsString(
          '{"paths":["${filePath.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"],"ts":${DateTime.now().millisecondsSinceEpoch}}');
    } catch (_) {}
  }

  Future<void> _execCustom(CustomFileAction a, String filePath) async {
    final expandedArgs = a.expandArgs(filePath);

    // runAsAdmin: delegate to C++ runas helper (same pattern as OpenFileAsAdmin).
    // ShellExecuteExW(runas) cannot elevate the current process — the C++ side
    // launches a new elevated instance via --run-command, which executes the
    // command and exits.
    if (a.runAsAdmin) {
      final winPath = a.path.replaceAll('/', '\\');
      final winDir = a.workingDirectory.replaceAll('/', '\\');
      await _fileOpsChannel.invokeMethod('runCommandAsAdmin', {
        'cmdPath': winPath,
        'args': expandedArgs,
        'workDir': winDir,
      });
      return;
    }

    if (a.runSilently) {
      final finalArgs = _splitArgs(expandedArgs);
      final psArgs = StringBuffer();
      psArgs.write("-NoProfile -Command Start-Process '${a.path}'");
      psArgs.write(" -WindowStyle Hidden");
      if (finalArgs.isNotEmpty) {
        final quoted = finalArgs.map((x) => "'$x'").join(',');
        psArgs.write(" -ArgumentList $quoted");
      }
      await Process.start('powershell.exe', [psArgs.toString()],
        runInShell: true,
        workingDirectory: a.workingDirectory.isEmpty ? null : a.workingDirectory,
      );
      return;
    }

    final finalArgs = _splitArgs(expandedArgs);
    await Process.start(a.path, finalArgs,
      runInShell: true,
      workingDirectory: a.workingDirectory.isEmpty ? null : a.workingDirectory,
    );
  }

  static List<String> _splitArgs(String s) {
    final result = <String>[];
    final re = RegExp(r'''"([^"]*)"|(\S+)''');
    for (final m in re.allMatches(s)) {
      result.add(m.group(1) ?? m.group(2)!);
    }
    return result;
  }
}
