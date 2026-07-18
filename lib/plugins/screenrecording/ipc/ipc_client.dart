/// IPC client — runs in the main XMate process.
/// Watches sr_status.json for recording progress; writes sr_command.json for stop.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'ipc_protocol.dart';
import '../recording_state.dart';

class IpcClient {
  StreamSubscription<FileSystemEvent>? _watchSub;
  RecordingStatus _lastStatus = RecordingStatus.idle;
  final String _dir;

  final void Function(SrStatusMessage status)? onStatusChanged;
  final void Function(RecordingStatus previous, RecordingStatus current)?
      onTransition;
  final Future<void> Function()? onDisconnected;
  final void Function()? onCloseRequested;

  bool _fileWasPresent = false;

  IpcClient({
    this.onStatusChanged, this.onTransition, this.onDisconnected,
    this.onCloseRequested,
  }) : _dir = _appDataDir();

  static String _appDataDir() {
    final appData = Platform.environment['APPDATA'] ??
        '${Platform.environment['USERPROFILE']}\\AppData\\Roaming';
    return '$appData\\XMate';
  }

  String get _commandPath => '$_dir\\sr_command.json';
  String get _statusPath => '$_dir\\sr_status.json';

  bool get isRecording =>
      _lastStatus == RecordingStatus.recording ||
      _lastStatus == RecordingStatus.stopping;

  void startPolling() {
    Directory(_dir).createSync(recursive: true);
    _poll();
    _watchSub = Directory(_dir).watch().listen((event) {
      if (!event.path.endsWith('sr_status.json')) return;
      if (event is FileSystemDeleteEvent) {
        if (_fileWasPresent) {
          _fileWasPresent = false;
          onDisconnected?.call();
        }
      } else {
        _poll();
      }
    });
  }

  Future<void> _poll() async {
    final f = File(_statusPath);
    final exists = await f.exists();
    if (exists) {
      _fileWasPresent = true;
      try {
        final content = await f.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        // Check for explicit close signal from subprocess.
        final rawStatus = json['status'] as String? ?? '';
        if (rawStatus == 'closed') {
          onCloseRequested?.call();
          return;
        }
        final msg = SrStatusMessage.fromJson(json);
        if (msg.recordingStatus != _lastStatus) {
          final prev = _lastStatus;
          _lastStatus = msg.recordingStatus;
          onTransition?.call(prev, msg.recordingStatus);
          onStatusChanged?.call(msg);
        }
      } catch (_) {}
    }
  }

  /// Send a command to the recording subprocess.
  Future<void> sendCommand(String command) async {
    try {
      final msg = SrCommandMessage(
        command: command,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
      Directory(_dir).createSync(recursive: true);
      await File(_commandPath).writeAsString(jsonEncode(msg.toJson()));
    } catch (_) {}
  }

  Future<void> stopRecording() => sendCommand('stop');

  void stopPolling() {
    _watchSub?.cancel();
    _watchSub = null;
  }

  void dispose() {
    stopPolling();
  }
}
