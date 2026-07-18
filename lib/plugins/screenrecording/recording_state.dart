/// Data models for screen recording plugin.
library;

/// Recording mode.
/// - [fullscreen]: entire monitor (Alt+R hotkey).
/// - [region]: screenshot-plugin selection → window recording overlay.
enum RecordingMode { region, fullscreen }

enum RecordingStatus { idle, recording, stopping, stopped, error, paused }

class SrData {
  final int offsetX, offsetY, width, height;
  final String outputPath;
  final int framerate;
  final String ffmpegPath;
  final RecordingMode mode;
  final String encoder;  // libx264, libx265, etc.
  final int crf;          // 1-50, lower = higher quality. 23 default.
  final String audioSource; // 'none' | derived from audioDeviceNames
  final String audioDeviceName; // legacy, derived: first device or ''
  final List<String> audioDeviceNames; // primary multi-device list
  final int audioBitrate; // AAC bitrate in kbps, 48-320, default 128
  final bool showMouse; // capture mouse cursor (toolbar toggle), default true
  final bool allMonitors; // capture all monitors in one video, default false
  final bool autoStart; // true → begin recording immediately; false → show toolbar idle

  const SrData({
    required this.offsetX,
    required this.offsetY,
    required this.width,
    required this.height,
    required this.outputPath,
    this.framerate = 15,
    required this.ffmpegPath,
    this.mode = RecordingMode.fullscreen,
    this.encoder = 'libx264',
    this.crf = 25,
    this.audioSource = 'none',
    this.audioDeviceName = '',
    this.audioDeviceNames = const [],
    this.audioBitrate = 128,
    this.showMouse = true,
    this.allMonitors = false,
    this.autoStart = false,
  });

  factory SrData.fromJson(Map<String, dynamic> json) {
    final namesRaw = json['audioDeviceNames'];
    final List<String> names;
    if (namesRaw is List) {
      names = namesRaw.map((e) => e.toString()).toList();
    } else {
      names = const [];
    }
    return SrData(
      offsetX: json['offsetX'] as int? ?? 0,
      offsetY: json['offsetY'] as int? ?? 0,
      width: json['width'] as int? ?? 0,
      height: json['height'] as int? ?? 0,
      outputPath: json['outputPath'] as String? ?? '',
      framerate: json['framerate'] as int? ?? 15,
      ffmpegPath: json['ffmpegPath'] as String? ?? 'ffmpeg.exe',
      mode: (json['mode'] as int? ?? 1) == 0
          ? RecordingMode.region
          : RecordingMode.fullscreen,
      encoder: json['encoder'] as String? ?? 'libx264',
      crf: json['crf'] as int? ?? 25,
      audioSource: names.isEmpty ? 'none' : json['audioSource'] as String? ?? '',
      audioDeviceName: names.isNotEmpty ? names.first : '',
      audioDeviceNames: names,
      audioBitrate: json['audioBitrate'] as int? ?? 128,
      showMouse: json['showMouse'] is bool ? json['showMouse'] as bool : true,
      allMonitors: json['allMonitors'] is bool ? json['allMonitors'] as bool : false,
      autoStart: json['autoStart'] as bool? ?? false,
    );
  }

  /// Video input args — gdigrab desktop capture.
  /// Does NOT include output codec/preset/crf/pix_fmt (those go after all -i).
  /// When [allMonitors] is true, skips offset/size so gdigrab captures
  /// the full virtual desktop spanning all displays.
  List<String> get ffmpegInputArgs => [
        '-f', 'gdigrab',
        '-framerate', '$framerate',
        if (!allMonitors) ...['-offset_x', '$offsetX', '-offset_y', '$offsetY',
                              '-video_size', '${width}x$height'],
        if (!showMouse) '-draw_mouse', if (!showMouse) '0',
        '-i', 'desktop',
      ];

  /// Audio input args (dshow) — one input per device.
  /// Special handling for `__system_audio__`: uses Stereo Mix / WASAPI loopback.
  List<String> get audioInputArgs {
    if (audioDeviceNames.isEmpty) return const [];
    final args = <String>[];
    for (final name in audioDeviceNames) {
      if (name == '__system_audio__') {
        // System audio loopback — try Stereo Mix first, then
        // fall back to common loopback device names.
        args.addAll(['-f', 'dshow', '-i', 'audio=Stereo Mix']);
      } else {
        args.addAll(['-f', 'dshow', '-i', 'audio=$name']);
      }
    }
    return args;
  }

  /// Audio filter + map args — only needed when ≥2 audio devices.
  /// Uses amix to combine all audio inputs into a single stereo track.
  List<String> get audioFilterArgs {
    if (audioDeviceNames.length < 2) return const [];
    final n = audioDeviceNames.length;
    // Build labels: [1:a][2:a][3:a]...
    final labels = StringBuffer();
    for (int i = 1; i <= n; i++) {
      labels.write('[$i:a]');
    }
    return [
      '-filter_complex', '${labels}amix=inputs=$n:duration=first[aout]',
      '-map', '0:v',
      '-map', '[aout]',
    ];
  }

  /// Video output args — placed after ALL -i inputs.
  List<String> get videoOutputArgs => [
        '-c:v', encoder,
        '-preset', 'ultrafast',
        '-crf', '$crf',
        '-pix_fmt', 'yuv420p',
      ];

  /// Audio output args — empty when no audio is configured.
  List<String> get audioOutputArgs {
    if (audioDeviceNames.isEmpty) return const [];
    return [
      '-c:a', 'aac',
      '-b:a', '${audioBitrate}k',
    ];
  }

  ({int x, int y, int w, int h}) get captureRect => (
        x: offsetX, y: offsetY, w: width, h: height,
      );
}

/// Tracks a single recording segment for pause/resume support.
class RecordingSegment {
  final String path;
  final int startMs;
  int endMs;

  RecordingSegment({
    required this.path,
    required this.startMs,
    this.endMs = 0,
  });

  int get durationMs => endMs > 0 ? endMs - startMs : 0;
}
