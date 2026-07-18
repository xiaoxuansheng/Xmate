/// Recording engine — runs in the main XMate process.
library;

import 'dart:io';
import 'recording_state.dart';
import 'ipc/ipc_client.dart';

class RecordingEngine {
  final SrData srData;
  final void Function(RecordingStatus status)? onStatusChanged;
  final Future<void> Function()? onDisconnected;
  final void Function()? onCloseRequested;
  late final IpcClient _ipc;
  IpcClient get ipc => _ipc;

  RecordingEngine({
    required this.srData, this.onStatusChanged, this.onDisconnected,
    this.onCloseRequested,
  }) {
    _ipc = IpcClient(
      onTransition: (prev, curr) { onStatusChanged?.call(curr); },
      onDisconnected: onDisconnected,
      onCloseRequested: onCloseRequested,
    );
  }

  Future<void> spawn() async {
    final exe = Platform.resolvedExecutable;
    final args = <String>[
      '--screenrecording',
      '--sr-offset-x', '${srData.offsetX}',
      '--sr-offset-y', '${srData.offsetY}',
      '--sr-width', '${srData.width}',
      '--sr-height', '${srData.height}',
      '--sr-output', srData.outputPath,
      '--sr-framerate', '${srData.framerate}',
      '--sr-mode', srData.mode == RecordingMode.fullscreen ? '1' : '0',
      '--sr-encoder', srData.encoder,
      '--sr-crf', '${srData.crf}',
      '--sr-audio', srData.audioSource,
      if (srData.audioDeviceName.isNotEmpty) ...['--sr-audio-device', srData.audioDeviceName],
      '--sr-auto', srData.autoStart ? '1' : '0',
    ];
    if (srData.ffmpegPath.isNotEmpty && srData.ffmpegPath != 'ffmpeg.exe') {
      args.add('--sr-ffmpeg-path'); args.add(srData.ffmpegPath);
    }
    await Process.start(exe, args, mode: ProcessStartMode.detached);
    _ipc.startPolling();
  }

  Future<void> dispose() async { _ipc.dispose(); }
}
