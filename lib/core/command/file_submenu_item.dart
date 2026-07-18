/// XMate -- File context submenu item models.
library;

import 'package:flutter/material.dart';

// Built-in action kinds ----------------------------------------------------

enum FileActionKind {
  openFolder,    // open containing folder (explorer /select,)
  copyPath,      // copy full path to clipboard
  copy,          // copy file to clipboard (CF_HDROP)
  cut,           // cut file to clipboard (CF_HDROP + DROPEFFECT_MOVE)
  shortcut,      // create desktop shortcut
  delete,        // delete to Recycle Bin
  properties,    // file properties dialog
  pinToStart,    // pin to Start menu
  openAsAdmin,   // open file as administrator
  translateFile, // translate file in Translate window
  convertFile,   // open file in File Converter
}

// Sealed item base ----------------------------------------------------------

sealed class FileSubMenuItem {
  String get title;
  String get shortcut;
  IconData get icon;
  int get sortOrder;
}

// Built-in action (shortcut is now persistent / editable) ------------------

class BuiltinFileAction extends FileSubMenuItem {
  final FileActionKind kind;
  @override int sortOrder;
  @override String shortcut;
  bool enabled;

  BuiltinFileAction(this.kind, {int? sortOrder, this.shortcut = '', this.enabled = true})
      : sortOrder = sortOrder ?? kind.index;

  @override String get title => switch (kind) {
    FileActionKind.openFolder   => 'Open containing folder',
    FileActionKind.copyPath     => 'Copy path',
    FileActionKind.copy         => 'Copy',
    FileActionKind.cut          => 'Cut',
    FileActionKind.shortcut     => 'Create desktop shortcut',
    FileActionKind.delete       => 'Delete',
    FileActionKind.properties   => 'Properties',
    FileActionKind.pinToStart   => 'Pin to Start',
    FileActionKind.openAsAdmin  => 'Open as admin',
    FileActionKind.translateFile => 'Translate file',
    FileActionKind.convertFile => 'Convert file',
  };

  @override IconData get icon => switch (kind) {
    FileActionKind.openFolder   => Icons.folder_open,
    FileActionKind.copyPath     => Icons.content_copy,
    FileActionKind.copy         => Icons.copy,
    FileActionKind.cut          => Icons.content_cut,
    FileActionKind.shortcut     => Icons.shortcut,
    FileActionKind.delete       => Icons.delete,
    FileActionKind.properties   => Icons.info,
    FileActionKind.pinToStart   => Icons.push_pin,
    FileActionKind.openAsAdmin  => Icons.admin_panel_settings,
    FileActionKind.translateFile => Icons.translate,
    FileActionKind.convertFile => Icons.swap_horiz,
  };

  // JSON: { builtin: "openFolder", sortOrder: N, shortcut: "...", enabled: true/false }
  Map<String, dynamic> toJson() => {
    'builtin': kind.name,
    'sortOrder': sortOrder,
    if (shortcut.isNotEmpty) 'shortcut': shortcut,
    'enabled': enabled,
  };

  factory BuiltinFileAction.fromJson(Map<String, dynamic> json) {
    final kind = _parseKind(json['builtin'] as String?);
    return BuiltinFileAction(kind,
      sortOrder: (json['sortOrder'] as num?)?.toInt(),
      shortcut: json['shortcut'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  static FileActionKind _parseKind(String? s) {
    for (final k in FileActionKind.values) {
      if (k.name == s) return k;
    }
    return FileActionKind.openFolder;
  }

  BuiltinFileAction copyWith({int? sortOrder, String? shortcut, bool? enabled}) =>
      BuiltinFileAction(kind, sortOrder: sortOrder ?? this.sortOrder,
          shortcut: shortcut ?? this.shortcut,
          enabled: enabled ?? this.enabled);

  @override bool operator ==(Object other) =>
      other is BuiltinFileAction && other.kind == kind;
  @override int get hashCode => kind.hashCode;
}

// Custom user-defined action ------------------------------------------------

class CustomFileAction extends FileSubMenuItem {
  final String id;
  @override final String title;
  @override final String shortcut;
  final String path;           // executable path
  final String args;           // {file} -> selected file path
  final String workingDirectory;
  final bool runAsAdmin;
  final bool runSilently;
  @override int sortOrder;

  CustomFileAction({
    required this.id,
    required this.title,
    this.shortcut = '',
    required this.path,
    this.args = '',
    this.workingDirectory = '',
    this.runAsAdmin = false,
    this.runSilently = false,
    this.sortOrder = 100,
  });

  @override IconData get icon => Icons.play_arrow;

  String expandArgs(String filePath) => args.replaceAll('{file}', filePath);

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (shortcut.isNotEmpty) 'shortcut': shortcut,
    'path': path,
    if (args.isNotEmpty) 'args': args,
    if (workingDirectory.isNotEmpty) 'workingDirectory': workingDirectory,
    if (runAsAdmin) 'runAsAdmin': true,
    if (runSilently) 'runSilently': true,
    'sortOrder': sortOrder,
  };

  factory CustomFileAction.fromJson(Map<String, dynamic> json) =>
      CustomFileAction(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        shortcut: json['shortcut'] as String? ?? '',
        path: json['path'] as String? ?? '',
        args: json['args'] as String? ?? '',
        workingDirectory: json['workingDirectory'] as String? ?? '',
        runAsAdmin: json['runAsAdmin'] as bool? ?? false,
        runSilently: json['runSilently'] as bool? ?? false,
        sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 100,
      );

  @override bool operator ==(Object other) =>
      other is CustomFileAction && other.id == id;
  @override int get hashCode => id.hashCode;
}

// Parse helpers -------------------------------------------------------------

/// Parse a mixed JSON list into [FileSubMenuItem] objects.
List<FileSubMenuItem> parseSubmenuItems(List<dynamic> raw) {
  final items = <FileSubMenuItem>[];
  for (final e in raw) {
    if (e is! Map) continue;
    final map = Map<String, dynamic>.from(e);
    try {
      if (map.containsKey('builtin')) {
        items.add(BuiltinFileAction.fromJson(map));
      } else if (map.containsKey('id')) {
        items.add(CustomFileAction.fromJson(map));
      }
    } catch (_) {}
  }
  return items;
}

/// The default sorted list of all built-in actions with sensible shortcuts.
List<BuiltinFileAction> defaultBuiltins() {
  return [
    BuiltinFileAction(FileActionKind.openFolder, shortcut: 'O'),
    BuiltinFileAction(FileActionKind.copyPath, shortcut: 'Shift+C'),
    BuiltinFileAction(FileActionKind.copy, shortcut: 'C'),
    BuiltinFileAction(FileActionKind.cut, shortcut: 'X'),
    BuiltinFileAction(FileActionKind.shortcut),
    BuiltinFileAction(FileActionKind.delete, shortcut: 'Delete'),
    BuiltinFileAction(FileActionKind.properties, shortcut: 'P'),
    BuiltinFileAction(FileActionKind.pinToStart),
    BuiltinFileAction(FileActionKind.openAsAdmin),
    BuiltinFileAction(FileActionKind.translateFile, shortcut: 'T'),
    BuiltinFileAction(FileActionKind.convertFile, shortcut: 'V'),
  ];
}
