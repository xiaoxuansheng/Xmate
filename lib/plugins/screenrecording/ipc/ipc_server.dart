/// IPC server — runs in the recording subprocess.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'ipc_protocol.dart';
import '../recording_service.dart';

class IpcServer {
  final void Function(String command) onCommand;
  final RecordingService service;

  Timer? _pollTimer;
  String? _lastCommandTimestamp;
  int _lastLogCount = 0;

  IpcServer({
    required this.onCommand,
    required this.service,
  });

  String get _dir {
    final appData = Platform.environment['APPDATA'] ??
        '${Platform.environment['USERPROFILE']}\\AppData\\Roaming';
    return '$appData\\XMate';
  }

  String get _commandPath => '$_dir\\sr_command.json';
  String get _statusPath => '$_dir\\sr_status.json';

  void startPolling() {
    Directory(_dir).createSync(recursive: true);
    // Kill any stale stop command left over from a previous crash.
    try { File(_commandPath).deleteSync(); } catch (_) {}
    _lastLogCount = 0;
    writeStatus();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
  }

  Future<void> _poll() async {
    final f = File(_commandPath);
    if (!await f.exists()) return;
    try {
      final content = await f.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final msg = SrCommandMessage.fromJson(json);
      final tsKey = '${msg.command}_${msg.timestamp}';
      if (tsKey != _lastCommandTimestamp) {
        _lastCommandTimestamp = tsKey;
        onCommand(msg.command);
      }
    } catch (_) {}
  }

  void writeStatus() {
    final allLogs = service.logLines;
    // Only send new logs since last write to keep status file small.
    final newLogs = allLogs.length > _lastLogCount
        ? allLogs.sublist(_lastLogCount)
        : <String>[];
    _lastLogCount = allLogs.length;

    final msg = SrStatusMessage(
      status: service.status.name,
      elapsedMs: service.elapsedMs,
      outputPath: service.outputPath,
      error: service.lastError.isNotEmpty ? service.lastError : null,
      logs: newLogs, // incremental
    );
    try {
      File(_statusPath).writeAsStringSync(jsonEncode(msg.toJson()));
    } catch (_) {}
  }

  /// Write a close signal so the main process can destroy the overlay
  /// immediately, without waiting for the subprocess to fully exit.
  void notifyClose() {
    try {
      File(_statusPath).writeAsStringSync('{"status":"closed","elapsedMs":0}');
    } catch (_) {}
  }

  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    try { File(_statusPath).deleteSync(); } catch (_) {}
    try { File(_commandPath).deleteSync(); } catch (_) {}
  }
}
