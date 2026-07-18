/// IPC protocol — data models for sr_status.json / sr_command.json.
library;

import '../recording_state.dart';

class SrStatusMessage {
  final String status;
  final int elapsedMs;
  final String? outputPath;
  final String? error;
  final List<String> logs;

  const SrStatusMessage({
    required this.status,
    this.elapsedMs = 0,
    this.outputPath,
    this.error,
    this.logs = const [],
  });

  Map<String, dynamic> toJson() => {
        'status': status,
        'elapsedMs': elapsedMs,
        'outputPath': outputPath,
        'error': error,
        'logs': logs,
      };

  factory SrStatusMessage.fromJson(Map<String, dynamic> json) {
    final rawLogs = json['logs'];
    return SrStatusMessage(
      status: json['status'] as String? ?? 'idle',
      elapsedMs: json['elapsedMs'] as int? ?? 0,
      outputPath: json['outputPath'] as String?,
      error: json['error'] as String?,
      logs: rawLogs is List
          ? rawLogs.cast<String>()
          : const [],
    );
  }

  RecordingStatus get recordingStatus {
    switch (status) {
      case 'recording': return RecordingStatus.recording;
      case 'stopping':  return RecordingStatus.stopping;
      case 'stopped':   return RecordingStatus.stopped;
      case 'error':     return RecordingStatus.error;
      case 'paused':    return RecordingStatus.paused;
      default:          return RecordingStatus.idle;
    }
  }
}

class SrCommandMessage {
  final String command;
  final int timestamp;

  const SrCommandMessage({
    required this.command,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'command': command,
        'timestamp': timestamp,
      };

  factory SrCommandMessage.fromJson(Map<String, dynamic> json) {
    return SrCommandMessage(
      command: json['command'] as String? ?? '',
      timestamp: json['timestamp'] as int? ?? 0,
    );
  }
}
