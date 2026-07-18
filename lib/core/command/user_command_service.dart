library;

import 'dart:io';
import 'package:flutter/material.dart';
import '../settings/settings_service.dart';

/// A user-customizable command that runs an executable or opens a URL.
/// [type] 'command' = executable/URL (default), 'script' = built-in XMate script.
class UserCommand {
  final String id;
  String keyword;
  String name;
  String shortcut;
  String path;
  String args;
  String workingDirectory;
  bool enabled;
  bool runAsAdmin;
  bool runSilently;
  String type;    // 'command' or 'script'
  bool builtin;   // true = cannot be deleted

  UserCommand({
    required this.id,
    required this.keyword,
    required this.name,
    this.shortcut = '',
    required this.path,
    this.args = '',
    this.workingDirectory = '',
    this.enabled = true,
    this.runAsAdmin = false,
    this.runSilently = false,
    this.type = 'command',
    this.builtin = false,
  });

  factory UserCommand.fromJson(Map<String, dynamic> json) => UserCommand(
    id: json['id'] as String? ?? '',
    keyword: json['keyword'] as String? ?? '',
    name: json['name'] as String? ?? '',
    shortcut: json['shortcut'] as String? ?? '',
    path: json['path'] as String? ?? '',
    args: json['args'] as String? ?? '',
    workingDirectory: json['workingDirectory'] as String? ?? '',
    enabled: json['enabled'] as bool? ?? true,
    runAsAdmin: json['runAsAdmin'] as bool? ?? false,
    runSilently: json['runSilently'] as bool? ?? false,
    type: json['type'] as String? ?? 'command',
    builtin: json['builtin'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'keyword': keyword,
    'name': name,
    'shortcut': shortcut,
    'path': path,
    'args': args,
    'workingDirectory': workingDirectory,
    'enabled': enabled,
    'runAsAdmin': runAsAdmin,
    'runSilently': runSilently,
    'type': type,
    'builtin': builtin,
  };

  UserCommand copy() => UserCommand(
    id: id,
    keyword: keyword,
    name: name,
    shortcut: shortcut,
    path: path,
    args: args,
    workingDirectory: workingDirectory,
    enabled: enabled,
    runAsAdmin: runAsAdmin,
    runSilently: runSilently,
    type: type,
    builtin: builtin,
  );
}

/// Service for managing user-defined commands.
///
/// Commands are persisted to [SettingsService] under `app.commands`.
/// On first run, 8 built-in defaults + script commands are seeded.
class UserCommandService {
  static const _kCommands = 'app.commands';

  final _settings = SettingsService();

  // ── Script handler registry ──
  // Register built-in script handlers here so both main.dart and app.dart
  // can use the same dispatch logic when registering user commands.

  static final Map<String, VoidCallback> _scriptHandlers = {};

  /// Register a script command handler. Call once at startup (e.g. in main.dart).
  static void registerScriptHandler(String id, VoidCallback handler) {
    _scriptHandlers[id] = handler;
  }

  /// Get the handler for a script command, or null if not registered.
  static VoidCallback? getScriptCallback(String id) {
    return _scriptHandlers[id];
  }

  /// Load user commands from settings.  Seeds built-in defaults on first run.
  /// Also migrates missing built-in script commands into existing user lists.
  List<UserCommand> loadCommands() {
    final raw = _settings.get(_kCommands);
    if (raw is List) {
      final list = <UserCommand>[];
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          final cmd = UserCommand.fromJson(item);
          if (cmd.id.isNotEmpty && cmd.keyword.isNotEmpty && cmd.path.isNotEmpty) {
            list.add(cmd);
          }
        }
      }
      if (list.isNotEmpty) {
        // Migrate: ensure all built-in scripts are present
        final defaults = _buildDefaults();
        var changed = false;
        for (final d in defaults.where((d) => d.builtin)) {
          if (!list.any((c) => c.id == d.id)) {
            list.insert(0, d.copy()); // prepend new built-in scripts
            changed = true;
          }
        }
        if (changed) saveCommands(list);
        return list;
      }
    }
    // First run — seed defaults
    final defaults = _buildDefaults();
    saveCommands(defaults);
    return defaults;
  }

  /// Persist commands to settings.
  Future<void> saveCommands(List<UserCommand> commands) async {
    await _settings.set(_kCommands, commands.map((c) => c.toJson()).toList());
  }

  /// Return only enabled commands.
  List<UserCommand> getEnabledCommands(List<UserCommand> all) =>
      all.where((c) => c.enabled).toList();

  /// Execute a user command — launch the executable or open the URL.
  ///
  /// If [cmd.runAsAdmin] or [cmd.runSilently] is set, the command is wrapped
  /// with PowerShell `Start-Process` to achieve elevation / hidden window.
  ///
  /// If [extraArgs] is provided (from user typing "keyword extra args"),
  /// it is appended to the command's built-in [UserCommand.args].
  Future<void> execute(UserCommand cmd, {String extraArgs = ''}) async {
    // URLs — open in default browser
    if (cmd.path.startsWith('http://') || cmd.path.startsWith('https://')) {
      await Process.run('cmd', ['/c', 'start', '', cmd.path]);
      return;
    }

    final builtin = cmd.args.trim();
    final combined = [if (builtin.isNotEmpty) builtin, if (extraArgs.isNotEmpty) extraArgs].join(' ');
    final argList = combined.isNotEmpty ? _splitArgs(combined) : <String>[];

    // Determine executable and final arguments.
    String exe;
    List<String> finalArgs;

    if (cmd.runAsAdmin || cmd.runSilently) {
      // Wrap with PowerShell Start-Process for admin elevation / silent mode.
      final psCmd = StringBuffer("Start-Process '${cmd.path}'");
      if (cmd.runAsAdmin) psCmd.write(' -Verb RunAs');
      if (cmd.runSilently) psCmd.write(' -WindowStyle Hidden');
      if (argList.isNotEmpty) {
        final quoted = argList.map((a) => "'$a'").join(',');
        psCmd.write(' -ArgumentList $quoted');
      }
      exe = 'powershell.exe';
      finalArgs = ['-Command', psCmd.toString()];
    } else {
      exe = cmd.path;
      finalArgs = argList;
    }

    await Process.start(
      exe,
      finalArgs,
      workingDirectory: cmd.workingDirectory.trim().isNotEmpty
          ? cmd.workingDirectory.trim()
          : null,
      runInShell: true,
    );
  }

  /// Built-in default commands, seeded on first run.
  static List<UserCommand> _buildDefaults() => [
    // ── Scripts (built-in XMate features) ──
    UserCommand(
      id: 'script_swap_monitors',
      keyword: 'swap',
      name: 'Swap Monitor Apps',
      shortcut: '',
      path: 'Swap all apps between monitor 1 and monitor 2',
      type: 'script',
      builtin: true,
      enabled: true,
    ),
    // ── System commands ──
    UserCommand(
      id: 'default_cmd',
      keyword: 'cmd',
      name: 'Command Prompt',
      path: 'cmd.exe',
      runAsAdmin: true,
    ),
    UserCommand(
      id: 'default_psh',
      keyword: 'psh',
      name: 'PowerShell',
      path: 'powershell.exe',
      runAsAdmin: true,
    ),
    UserCommand(
      id: 'default_run',
      keyword: 'run',
      name: 'Run Dialog',
      path: 'explorer.exe',
      args: 'shell:::{2559a1f3-21d7-11d4-bdaf-00c04f60b9f0}',
    ),
    UserCommand(
      id: 'default_file',
      keyword: 'file',
      name: 'File Explorer',
      path: 'explorer.exe',
    ),
    UserCommand(
      id: 'default_device',
      keyword: 'device',
      name: 'Device Manager',
      path: 'devmgmt.msc',
    ),
    UserCommand(
      id: 'default_shutdown',
      keyword: 'shutdown',
      name: 'Shutdown',
      path: 'shutdown.exe',
      args: '/s /t 0',
    ),
    UserCommand(
      id: 'default_reboot',
      keyword: 'reboot',
      name: 'Reboot',
      path: 'shutdown.exe',
      args: '/r /t 0',
    ),
    UserCommand(
      id: 'default_bin',
      keyword: 'bin',
      name: 'Recycle Bin',
      path: 'explorer.exe',
      args: 'shell:RecycleBinFolder',
      builtin: true,
    ),
  ];

  /// Split an argument string into a list, respecting double quotes.
  static List<String> _splitArgs(String args) {
    final result = <String>[];
    final regex = RegExp(r'"[^"]*"|\S+');
    for (final match in regex.allMatches(args)) {
      var arg = match.group(0)!;
      if (arg.startsWith('"') && arg.endsWith('"')) {
        arg = arg.substring(1, arg.length - 1);
      }
      result.add(arg);
    }
    return result;
  }
}
