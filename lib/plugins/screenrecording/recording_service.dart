/// FFmpeg process management for the recording subprocess.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'recording_state.dart';
import '../../core/utils/filename_template.dart';

/// FFmpeg stderr decoder: GBK first, UTF-8 fallback, system encoding last resort.
final _ffStderrDecoder = StreamTransformer<List<int>, String>.fromHandlers(
  handleData: (data, sink) => sink.add(decodeWinConsole(data)),
);

class RecordingService {
  Process? _ffmpeg;
  RecordingStatus _status = RecordingStatus.idle;
  int _displayMs = 0;
  Timer? _elapsedTimer;
  String _lastError = '';
  final List<String> _logLines = [];
  String? _outputPath;

  // Pause / resume support
  final List<RecordingSegment> _segments = [];
  SrData? _lastData;

  // Stop + finalize coordination
  Completer<void>? _stopCompleter;
  bool _isFinalizing = false;

  RecordingStatus get status => _status;
  int get elapsedMs => _displayMs;
  String get lastError => _lastError;
  String? get outputPath => _outputPath;
  List<String> get logLines => List.unmodifiable(_logLines);
  List<RecordingSegment> get segments => List.unmodifiable(_segments);

  void Function(String line)? onProgress;
  void Function(RecordingStatus status)? onStatusChanged;

  RecordingService({this.onProgress, this.onStatusChanged});

  void _log(String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    _logLines.add('[$ts] $msg');
    if (_logLines.length > 1000) _logLines.removeAt(0);
    onProgress?.call(msg);
  }

  /// Generate a segment path: {base}_part{N}.mp4
  String _segmentPath(int n) {
    final base = _lastData!.outputPath;
    final dot = base.lastIndexOf('.');
    if (dot < 0) return '${base}_part$n';
    return '${base.substring(0, dot)}_part$n${base.substring(dot)}';
  }

  Future<bool> start(SrData data) async {
    if (_status == RecordingStatus.recording || _status == RecordingStatus.paused) {
      return false;
    }
    if (_ffmpeg != null) { _ffmpeg?.kill(); _ffmpeg = null; }
    _stopCompleter = null;
    _isFinalizing = false;
    _lastData = data;
    _outputPath = data.outputPath;
    _lastError = '';
    _logLines.clear();
    _segments.clear();
    _displayMs = 0;

    _log('── start ${data.mode.name} ──');
    _log('capture: +${data.offsetX},${data.offsetY} ${data.width}x${data.height}');
    _log('encoder: ${data.encoder} fps=${data.framerate} crf=${data.crf}');
    _log('output: ${data.outputPath}');

    try {
      final dir = Directory(File(data.outputPath).parent.path);
      if (!await dir.exists()) await dir.create(recursive: true);
    } catch (e) { _log('WARN mkdir: $e'); }

    final ffFile = File(data.ffmpegPath);
    if (!ffFile.existsSync()) {
      _lastError = 'ffmpeg not found: ${data.ffmpegPath}';
      _log('ERROR $_lastError');
      _setStatus(RecordingStatus.error);
      return false;
    }

    // Always write to segment path; renamed/concat'd on final stop.
    final segPath = _segmentPath(1);
    _segments.add(RecordingSegment(path: segPath, startMs: 0));

    return _launchFfmpeg(data, segPath);
  }

  Future<bool> _launchFfmpeg(SrData data, String outPath) async {
    // IMPORTANT: all -i inputs come FIRST, then any filter/map, then output options.
    final args = <String>[
      ...data.ffmpegInputArgs,
      ...data.audioInputArgs,
      ...data.audioFilterArgs,
      ...data.videoOutputArgs,
      ...data.audioOutputArgs,
      '-y', outPath,
    ];

    _log('ffmpeg: ${data.ffmpegPath}');
    _log('inputArgs:  ${data.ffmpegInputArgs}');
    _log('audioIn:    ${data.audioInputArgs}');
    _log('audioFilt:  ${data.audioFilterArgs}');
    _log('videoOut:   ${data.videoOutputArgs}');
    _log('audioOut:   ${data.audioOutputArgs}');
    _log('outPath:    $outPath');
    // Full command-line equivalent (for copy-paste debugging in cmd):
    _log('── FULL CMD ──');
    _log(_shellCmdString(data.ffmpegPath, args));
    _log('──────────────');

    try {
      _ffmpeg = await Process.start(data.ffmpegPath, args);
      _log('pid=${_ffmpeg!.pid} → $outPath');
      _setStatus(RecordingStatus.recording);
      _startElapsedTimer();

      final stderrLines = <String>[];
      _ffmpeg!.stderr
          .transform(_ffStderrDecoder).transform(const LineSplitter())
          .listen(stderrLines.add, onError: (e) => _log('stderrErr: $e'),
              onDone: () => _log('stderr closed: ${stderrLines.length} lines'));

      _ffmpeg!.stdout
          .transform(utf8.decoder).transform(const LineSplitter())
          .listen((l) { if (l.isNotEmpty) _log('stdout: $l'); });

      _ffmpeg!.exitCode.then((code) => _onFfmpegExit(code, stderrLines));
      return true;
    } catch (e) {
      _lastError = 'Process.start: $e';
      _log('ERROR $_lastError');
      _setStatus(RecordingStatus.error);
      return false;
    }
  }

  void _onFfmpegExit(int code, List<String> stderrLines) {
    _log('exit=$code, stderr=${stderrLines.length}');
    final n = stderrLines.length;
    if (n > 0) {
      _log('── stderr first 5 ──');
      stderrLines.take(5).forEach((l) => _log('  $l'));
      if (n > 15) _log('  ... (${n - 10} lines) ...');
      _log('── stderr last 5 ──');
      stderrLines.skip((n - 5).clamp(0, n)).forEach((l) => _log('  $l'));
    }
    _ffmpeg = null;

    if (code == 0 || code == 255) {
      // Finalise the current segment
      if (_segments.isNotEmpty) {
        _segments.last.endMs = _displayMs;
      }

      if (_status == RecordingStatus.stopping) {
        // User requested final stop — merge segments if needed
        _finalizeSegments(); // will complete _stopCompleter
      } else if (_status == RecordingStatus.recording) {
        // Unexpected exit — treat as error
        _lastError = 'FFmpeg exited unexpectedly (code=$code)';
        _setStatus(RecordingStatus.error);
        _completeStopCompleter();
      }
      // If paused, the _setStatus was already set by pause()
    } else {
      _lastError = 'FFmpeg exit=$code';
      _setStatus(RecordingStatus.error);
      _completeStopCompleter();
    }
  }

  /// Resolve [_stopCompleter] if it exists and is not yet completed.
  /// Safe to call from any path — no-op if already completed or no completer.
  void _completeStopCompleter() {
    _isFinalizing = false;
    if (_stopCompleter != null && !_stopCompleter!.isCompleted) {
      _stopCompleter!.complete();
    }
  }

  Future<void> _finalizeSegments() async {
    _stopElapsedTimer();
    final out = _lastData!.outputPath;
    if (_segments.length == 1) {
      // Single segment — just rename to output path
      try {
        final segFile = File(_segments.first.path);
        final dest = File(out);
        if (dest.existsSync()) await dest.delete();
        await segFile.rename(dest.path);
        _log('renamed single segment → $out');
        _setStatus(RecordingStatus.stopped);
      } catch (e) {
        _lastError = 'Rename segment: $e';
        _log('ERROR $_lastError');
        _setStatus(RecordingStatus.error);
      }
    } else {
      // Multiple segments — concat via ffmpeg
      _log('concat ${_segments.length} segments → $out');
      try {
        final listPath = '${out}.concat.txt';
        final lines = _segments.map((s) => "file '${s.path.replaceAll('\\', '/')}'").toList();
        await File(listPath).writeAsString('${lines.join('\n')}\n');
        final ff = _lastData!.ffmpegPath;
        final result = await Process.run(ff, [
          '-f', 'concat', '-safe', '0', '-i', listPath,
          '-c', 'copy', '-y', out,
        ]);
        _log('concat stdout: ${result.stdout}');
        if (result.stderr.isNotEmpty) _log('concat stderr: ${result.stderr}');
        try { await File(listPath).delete(); } catch (_) {}
        // Clean up temp segment files
        for (final seg in _segments) {
          try { await File(seg.path).delete(); } catch (_) {}
        }
        if (result.exitCode == 0) {
          _log('concat OK');
          _setStatus(RecordingStatus.stopped);
        } else {
          _lastError = 'Concat exit=${result.exitCode}';
          _log('ERROR $_lastError');
          _setStatus(RecordingStatus.error);
        }
      } catch (e) {
        _lastError = 'Concat: $e';
        _log('ERROR $_lastError');
        _setStatus(RecordingStatus.error);
      }
    }
    _completeStopCompleter();
  }

  /// Pause: send 'q' to ffmpeg to gracefully stop the current segment.
  Future<void> pause() async {
    if (_status != RecordingStatus.recording) {
      _log('pause ignored (status=${_status.name})');
      return;
    }
    _log('── Pause ──');
    _setStatus(RecordingStatus.paused);
    _stopElapsedTimer();
    if (_segments.isNotEmpty) _segments.last.endMs = _displayMs;
    try { _ffmpeg?.stdin.write('q'); await _ffmpeg?.stdin.close(); } catch (e) { _log('stdinErr: $e'); }
  }

  /// Resume: start a new segment.
  Future<bool> resume() async {
    if (_status != RecordingStatus.paused) return false;
    if (_lastData == null) return false;
    _log('── Resume ──');
    final n = _segments.length + 1;
    final segPath = _segmentPath(n);
    _segments.add(RecordingSegment(path: segPath, startMs: _displayMs));
    return _launchFfmpeg(_lastData!, segPath);
  }

  /// Final stop (square button).  Returns a Future that resolves once
  /// the ffmpeg process has exited and segments have been finalised
  /// (renamed or concat'd to the output path).  Callers can await this
  /// Future to guarantee the output file is ready before closing the window.
  Future<void> stop() async {
    if (_status == RecordingStatus.paused) {
      // Already paused — finalize directly
      _log('── Stop (from paused) ──');
      _setStatus(RecordingStatus.stopping);
      _isFinalizing = true;
      _stopCompleter = Completer<void>();
      try {
        await _finalizeSegments();
      } finally {
        _isFinalizing = false;
        if (!_stopCompleter!.isCompleted) _stopCompleter!.complete();
      }
      return;
    }
    if (_status != RecordingStatus.recording) {
      _log('stop ignored (status=${_status.name})');
      return;
    }
    _log('── Stop ──');
    _setStatus(RecordingStatus.stopping);
    _isFinalizing = true;
    _stopCompleter = Completer<void>();

    try { _ffmpeg?.stdin.write('q'); await _ffmpeg?.stdin.close(); } catch (e) { _log('stdinErr: $e'); }

    // Force-kill timeout.  If ffmpeg doesn't exit within 8 s we kill it
    // and finalise what we have — this is the same logic as before but
    // now resolves the _stopCompleter.
    Future.delayed(const Duration(seconds: 8), () {
      if (_status == RecordingStatus.stopping && _ffmpeg != null) {
        _log('force kill');
        _ffmpeg?.kill();
        if (_segments.isNotEmpty) _segments.last.endMs = _displayMs;
        _ffmpeg = null;
        _finalizeSegments();
      }
    });
    // Awaitable: resolves when _finalizeSegments completes (or timeout force-kill).
    return _stopCompleter!.future;
  }

  void _setStatus(RecordingStatus s) {
    _status = s;
    onStatusChanged?.call(s);
  }

  void _startElapsedTimer() {
    _elapsedTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _displayMs += 200,
    );
  }

  void _stopElapsedTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
  }

  int get fileSize {
    if (_status == RecordingStatus.stopped && _outputPath != null) {
      try { return File(_outputPath!).lengthSync(); } catch (_) { return 0; }
    }
    return 0;
  }

  /// Build a shell-quoted command string for copy-paste debugging.
  /// Each arg that contains spaces or special chars is double-quoted.
  static String _shellCmdString(String exe, List<String> args) {
    final buf = StringBuffer();
    buf.write(_shellQuote(exe));
    for (final a in args) {
      buf.write(' ');
      buf.write(_shellQuote(a));
    }
    return buf.toString();
  }

  static String _shellQuote(String s) {
    // If the string contains characters that need quoting, wrap in double quotes.
    if (s.contains(' ') || s.contains('"') || s.contains('&') ||
        s.contains('|') || s.contains('<') || s.contains('>') ||
        s.contains('^') || s.contains('%')) {
      return '"${s.replaceAll('"', '\\"')}"';
    }
    return s;
  }

  void dispose() {
    _stopElapsedTimer();

    // Case 1: stop() already in progress (paths ① / ② / ③).
    // The completer was set, 'q' was sent, ffmpeg is exiting or
    // _finalizeSegments is running.  Do NOT kill ffmpeg — let it
    // finish gracefully.  Safety net: if it somehow hangs, kill
    // after 15 s (the subprocess isolate is still alive for Timers
    // until the message loop exits).
    if (_isFinalizing && _stopCompleter != null) {
      Timer(const Duration(seconds: 15), () {
        _ffmpeg?.kill();
        _ffmpeg = null;
      });
      return;
    }

    // Case 2: still recording/paused but stop was never called.
    // This is path ④ — WM_CLOSE arrived before the IPC 'stop'
    // command, or the user closed via OS-level window management.
    // Fire a stop, give ffmpeg a grace window, then kill as last
    // resort.  We cannot await here (dispose is synchronous), so
    // we rely on a Timer-based safety kill.
    if (_status == RecordingStatus.recording ||
        _status == RecordingStatus.paused) {
      stop(); // fire-and-forget: sends 'q', sets _isFinalizing
      Timer(const Duration(seconds: 12), () {
        _ffmpeg?.kill();
        _ffmpeg = null;
      });
      return;
    }

    // Case 3: idle / stopped / error.
    // No ffmpeg process to protect — safe to kill.
    _ffmpeg?.kill();
    _ffmpeg = null;
  }
}
