/// Conversion job — state machine for a single file conversion.
library;

import 'dart:io';
import 'output_type.dart';

/// A single conversion job, mirroring C# `ConversionJob`.
class ConversionJob {
  final String inputPath;
  final OutputType outputType;
  final Map<String, String> settings;
  final String outputDir;
  final String? outputFileName;

  /// When set, this is a combined job: multiple inputs → single output.
  final List<String>? inputPaths;

  /// Per-file settings for combine mode (one per inputPath).
  /// Each map is the full settings from that file's buildSettings().
  final List<Map<String, String>>? perFileSettings;

  String _outputPath = '';
  ConversionState _state = ConversionState.unknown;
  double _progress = 0.0;
  String? _errorMessage;
  String _userState = 'Preparing…';
  Process? _ffmpegProcess;
  bool _cancelRequested = false;
  DateTime? _startTime;

  ConversionJob({
    required this.inputPath,
    required this.outputType,
    required this.settings,
    this.outputDir = '',
    this.outputFileName,
    this.inputPaths,
    this.perFileSettings,
  });

  // ── Getters ──

  String get outputPath => _outputPath;
  ConversionState get state => _state;
  double get progress => _progress;
  String? get errorMessage => _errorMessage;
  String get userState => _userState;
  bool get cancelRequested => _cancelRequested;
  DateTime? get startTime => _startTime;

  bool get isDone => _state == ConversionState.done;
  bool get isFailed => _state == ConversionState.failed;
  bool get isInProgress => _state == ConversionState.inProgress;
  bool get isCancelable => _state == ConversionState.inProgress;

  String get inputFileName => inputPath.split(RegExp(r'[/\\]')).last;

  String get inputExtension {
    final dot = inputPath.lastIndexOf('.');
    return dot < 0 ? '' : inputPath.substring(dot + 1).toLowerCase();
  }

  // ── State transitions ──

  /// Generate output path and mark job ready.
  void prepare() {
    final ext = outputType.extension;
    final dir = outputDir.isNotEmpty ? outputDir : _defaultOutputDir();

    // Combined mode: use first input's basename + "combined"
    String baseName;
    if (inputPaths != null && inputPaths!.isNotEmpty) {
      final first = inputPaths!.first.split(RegExp(r'[/\\]')).last;
      baseName = outputFileName ??
          '${first.replaceAll(RegExp(r'\.[^.]+$'), '')}_combined';
    } else {
      baseName = outputFileName ??
          inputFileName.replaceAll(RegExp(r'\.[^.]+$'), '');
    }

    _outputPath = _uniquePath('$dir\\$baseName.$ext');
    _state = ConversionState.ready;
    _userState = 'Queued';
  }

  /// Mark as in-progress (called by service when conversion starts).
  /// [process] is optional — Office COM conversion has no FFmpeg process.
  void markStarted([Process? process]) {
    _ffmpegProcess = process;
    _startTime = DateTime.now();
    _state = ConversionState.inProgress;
    _userState = 'Converting…';
  }

  /// Update progress from parsed FFmpeg output.
  void updateProgress(double p, {String? userState}) {
    _progress = p.clamp(0.0, 1.0);
    if (userState != null) _userState = userState;
  }

  /// Mark as done.
  void markDone() {
    _progress = 1.0;
    _state = ConversionState.done;
    _userState = 'Done';
    _ffmpegProcess = null;
  }

  /// Mark as failed.
  void markFailed(String message) {
    if (_state == ConversionState.failed) return; // don't override
    _state = ConversionState.failed;
    _userState = 'Failed';
    _errorMessage = message;
    _ffmpegProcess = null;
  }

  /// Request cancellation (sends 'q' to FFmpeg stdin).
  void cancel() {
    if (!isCancelable) return;
    _cancelRequested = true;
    try {
      _ffmpegProcess?.stdin.write('q');
    } catch (_) {}
  }

  /// Force-kill the FFmpeg process.
  void forceKill() {
    try {
      _ffmpegProcess?.kill();
    } catch (_) {}
    _ffmpegProcess = null;
  }

  // ── Post-conversion cleanup ──

  /// Delete output file if conversion failed and file exists.
  void cleanupFailedOutput() {
    try {
      final f = File(_outputPath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  // ── Helpers ──

  String _defaultOutputDir() {
    final home = Platform.environment['USERPROFILE'] ?? '.';
    return '$home\\Documents';
  }

  /// Generate a unique path: if "out.mp3" exists → "out (1).mp3", etc.
  static String _uniquePath(String path) {
    if (!File(path).existsSync()) return path;

    final dot = path.lastIndexOf('.');
    final base = dot < 0 ? path : path.substring(0, dot);
    final ext = dot < 0 ? '' : path.substring(dot);

    for (int i = 1; i < 10000; i++) {
      final candidate = '$base ($i)$ext';
      if (!File(candidate).existsSync()) return candidate;
    }
    return path; // fallback
  }
}
