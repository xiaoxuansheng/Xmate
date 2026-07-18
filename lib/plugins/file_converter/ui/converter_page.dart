/// File converter main page — file list + per-file settings + conversion.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:window_manager/window_manager.dart';
import '../../../../core/theme/theme_colors.dart';
import '../../../../core/quicklook/quicklook_palette_state.dart' as qls;
import '../models/output_type.dart';
import '../models/input_category.dart';
import '../models/conversion_job.dart';
import '../models/conversion_preset.dart';
import '../converter_service.dart';
import '../engines/office_utils.dart';

/// Per-file state tracked in the UI.
class _FileItem {
  final String path;
  final String name;
  OutputType outputType;
  String outputDir;
  String outputFileName;

  // ── Audio ──
  int audioBitrate;
  int audioChannels;
  String audioEncMode;

  // ── Video ──
  String videoEncoder;  // e.g. libx264, libx265, libvpx-vp9, mpeg4, libtheora
  int videoQuality;
  String videoSpeed;
  int videoFps;         // 0 = auto, >0 = fixed
  bool videoFpsOrig;    // true = lock FPS to source (read-only)
  bool videoPFR;        // true = peak frame rate
  bool enableAudio;

  // ── Image / Transform ──
  double scale;
  int rotation;       // 0, 90, 180, 270
  bool flipH, flipV;
  bool clampPo2;
  int imageMaxSize;   // 0 = no limit, otherwise max pixels on longest side
  int cropLeft, cropTop, cropRight, cropBottom;
  int padLeft, padTop, padRight, padBottom;
  String padColor;

  // ── Custom command ──
  bool customCmdEnabled;
  String customCmd;

  // ── PDF / Document ──
  int pdfDpi;            // 72–300, default 200
  String pdfPageSize;    // A4 / Letter / Legal
  String pdfPageRange;   // "all" | "1-9" | "1,3-5" etc.

  // ── qpdf / PDF structured modifications ──
  String pdfPageMode;          // 'all','delete','custom' — for pages row
  String pdfRotate;            // '0','+90','-90','180'
  String pdfRotatePages;       // '' = all pages, '1,3,5' = specific pages
  int pdfSplitPages;           // 0 = disabled, -1 = custom, >0 = preset
  int pdfSplitCustom;          // used when pdfSplitPages == -1
  String pdfPageOrder;         // '' = no reorder, '1,3,5,2,4' etc

  // ── qpdf / PDF post-processing (advanced) ──
  bool pdfAdvanced;
  bool pdfOptimize;
  bool pdfLinearize;
  bool pdfOptimizeImages;
  bool pdfDeterministicId;
  bool pdfNormalizeContent;
  String pdfWatermarkPath;
  String pdfUnderlayPath;
  bool pdfEncrypt;
  String pdfEncryptUserPassword;
  String pdfEncryptOwnerPassword;
  String pdfEncryptKeyLength;   // '128' or '256'
  bool pdfAllowPrint;
  bool pdfAllowModify;
  bool pdfAllowCopy;
  bool pdfAllowAnnotate;

  // ── Source PDF decryption ──
  String pdfSourcePassword;     // for decrypting encrypted source PDFs

  // ── Trim ──
  String trimStart;
  String trimEnd;
  double speedMultiplier; // 1.0 = normal, 0.5 = half speed, 2.0 = double speed

  ConversionJob? job;

  _FileItem({
    required this.path,
    required this.name,
    required this.outputType,
    required this.outputDir,
    required this.outputFileName,
    this.audioBitrate = 128,
    this.audioChannels = 0,
    this.audioEncMode = '',
    this.videoEncoder = 'libx264',
    this.videoQuality = 28,
    this.videoSpeed = 'medium',
    this.videoFps = 0,
    this.videoFpsOrig = false,
    this.videoPFR = false,
    this.enableAudio = true,
    this.scale = 1.0,
    this.rotation = 0,
    this.flipH = false,
    this.flipV = false,
    this.clampPo2 = false,
    this.imageMaxSize = 0,
    this.cropLeft = 0,
    this.cropTop = 0,
    this.cropRight = 0,
    this.cropBottom = 0,
    this.padLeft = 0,
    this.padTop = 0,
    this.padRight = 0,
    this.padBottom = 0,
    this.padColor = 'black',
    this.customCmdEnabled = false,
    this.customCmd = '',
    this.pdfDpi = 200,
    this.pdfPageSize = 'A4',
    this.pdfPageRange = 'all',
    this.pdfPageMode = 'all',
    this.pdfRotate = '0',
    this.pdfRotatePages = '',
    this.pdfSplitPages = 0,
    this.pdfSplitCustom = 0,
    this.pdfPageOrder = '',
    this.pdfAdvanced = false,
    this.pdfOptimize = false,
    this.pdfLinearize = false,
    this.pdfOptimizeImages = false,
    this.pdfDeterministicId = false,
    this.pdfNormalizeContent = false,
    this.pdfWatermarkPath = '',
    this.pdfUnderlayPath = '',
    this.pdfEncrypt = false,
    this.pdfEncryptUserPassword = '',
    this.pdfEncryptOwnerPassword = '',
    this.pdfEncryptKeyLength = '256',
    this.pdfAllowPrint = true,
    this.pdfAllowModify = true,
    this.pdfAllowCopy = true,
    this.pdfAllowAnnotate = true,
    this.pdfSourcePassword = '',
    this.trimStart = '',
    this.trimEnd = '',
    this.speedMultiplier = 1.0,
  });

  String get inputExt {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  bool get isAudio => outputType.category == OutputCategory.audio;
  bool get isVideo => outputType.category == OutputCategory.video;
  bool get isImage => outputType.category == OutputCategory.image || outputType == OutputType.gif;
  bool get isDoc  => outputType.category == OutputCategory.document;

  void _initTrimEndFromDuration(int dur) => trimEnd = _FileItem._secToHms(dur);
  void _setTrimEndFromDuration(int dur) => trimEnd = _FileItem._secToHms(dur);

  static String _secToHms(int total) {
    final h = total ~/ 3600, m = (total % 3600) ~/ 60, s = total % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Map<String, String> buildSettings() {
    final defaults = ConversionPreset.withDefaults(outputType).settings;
    final merged = Map<String, String>.from(defaults);

    // Audio
    if (isAudio || (isVideo && enableAudio)) {
      if (audioBitrate > 0) merged['AudioBitrate'] = '$audioBitrate';
      if (audioChannels >= 0) merged['AudioChannelCount'] = '$audioChannels';
      if (audioEncMode.isNotEmpty) merged['AudioEncodingMode'] = audioEncMode;
    }
    if (isVideo) merged['EnableAudio'] = enableAudio ? 'True' : 'False';

    // Video
    if (isVideo) {
      if (videoEncoder.isNotEmpty) merged['VideoEncoder'] = videoEncoder;
      if (videoQuality > 0) merged['VideoQuality'] = '$videoQuality';
      if (videoSpeed.isNotEmpty) merged['VideoEncodingSpeed'] = videoSpeed;
      if (videoFps > 0) merged['VideoFramesPerSecond'] = '$videoFps';
      if (videoPFR) merged['VideoPeakFrameRate'] = 'True';
    }

    // Scale + Rotation (video + image)
    if (isVideo || isImage) {
      merged[isVideo ? 'VideoScale' : 'ImageScale'] = scale.toStringAsFixed(2);
      final rk = isVideo ? 'VideoRotation' : 'ImageRotation';
      merged[rk] = '$rotation';
    }

    // Crop
    if (cropLeft > 0 || cropTop > 0 || cropRight > 0 || cropBottom > 0) {
      merged['CropLeft'] = '$cropLeft'; merged['CropTop'] = '$cropTop';
      merged['CropRight'] = '$cropRight'; merged['CropBottom'] = '$cropBottom';
    }

    // Flip
    if (flipH) merged['FlipH'] = 'True';
    if (flipV) merged['FlipV'] = 'True';

    // Clamp to Po2
    if (clampPo2) merged['ClampPo2'] = 'True';

    // Max image size
    if (imageMaxSize > 0) merged['ImageMaximumSize'] = '$imageMaxSize';

    // Pad
    if (padLeft > 0 || padTop > 0 || padRight > 0 || padBottom > 0) {
      merged['PadLeft'] = '$padLeft'; merged['PadTop'] = '$padTop';
      merged['PadRight'] = '$padRight'; merged['PadBottom'] = '$padBottom';
      merged['PadColor'] = padColor;
    }

    // Custom
    merged['EnableFFMPEGCustomCommand'] = customCmdEnabled ? 'True' : 'False';
    if (customCmdEnabled && customCmd.isNotEmpty) merged['FFMPEGCustomCommand'] = customCmd;

    // PDF / Document
    if (isDoc || outputType == OutputType.pdf) {
      merged['PdfDpi'] = '$pdfDpi';
      if (pdfPageSize.isNotEmpty) merged['PdfPageSize'] = pdfPageSize;
      if (pdfPageRange.isNotEmpty) merged['PdfPageRange'] = pdfPageRange;
      if (pdfPageMode != 'all') merged['PdfPageMode'] = pdfPageMode;
      merged['PdfRotate'] = pdfRotate;
      if (pdfRotatePages.isNotEmpty) merged['PdfRotatePages'] = pdfRotatePages;
      if (pdfSplitPages > 0) merged['PdfSplitPages'] = '$pdfSplitPages';
      if (pdfPageOrder.isNotEmpty) merged['PdfPageOrder'] = pdfPageOrder;
      merged['PdfOptimize'] = pdfOptimize ? 'True' : 'False';
      merged['PdfLinearize'] = pdfLinearize ? 'True' : 'False';
      merged['PdfOptimizeImages'] = pdfOptimizeImages ? 'True' : 'False';
      merged['PdfDeterministicId'] = pdfDeterministicId ? 'True' : 'False';
      merged['PdfNormalizeContent'] = pdfNormalizeContent ? 'True' : 'False';
      if (pdfWatermarkPath.isNotEmpty) merged['PdfWatermarkPath'] = pdfWatermarkPath;
      if (pdfUnderlayPath.isNotEmpty) merged['PdfUnderlayPath'] = pdfUnderlayPath;
      merged['PdfEncrypt'] = pdfEncrypt ? 'True' : 'False';
      if (pdfEncrypt) {
        merged['PdfEncryptUserPassword'] = pdfEncryptUserPassword;
        merged['PdfEncryptOwnerPassword'] = pdfEncryptOwnerPassword;
        merged['PdfEncryptKeyLength'] = pdfEncryptKeyLength;
        merged['PdfEncryptAllowPrint'] = pdfAllowPrint ? 'True' : 'False';
        merged['PdfEncryptAllowModify'] = pdfAllowModify ? 'True' : 'False';
        merged['PdfEncryptAllowCopy'] = pdfAllowCopy ? 'True' : 'False';
        merged['PdfEncryptAllowAnnotate'] = pdfAllowAnnotate ? 'True' : 'False';
      }
    }

    // Trim + Speed
    if (trimStart.isNotEmpty) merged['TrimStart'] = trimStart;
    if (trimEnd.isNotEmpty) merged['TrimEnd'] = trimEnd;
    if ((speedMultiplier - 1.0).abs() > 0.01) merged['SpeedMultiplier'] = speedMultiplier.toStringAsFixed(2);

    return merged;
  }

  void initDefaults() {
    switch (outputType) {
      case OutputType.aac:  audioBitrate = 128; audioEncMode = ''; break;
      case OutputType.flac: audioBitrate = 0;   audioEncMode = ''; break;
      case OutputType.mp3:  audioBitrate = 190; audioEncMode = 'mp3VBR'; break;
      case OutputType.ogg:  audioBitrate = 160; audioEncMode = ''; break;
      case OutputType.wav:  audioBitrate = 0;   audioEncMode = 'wav16'; break;
      case OutputType.avi:  videoEncoder = 'mpeg4'; videoQuality = 20; videoSpeed = 'medium'; enableAudio = true; audioBitrate = 190; break;
      case OutputType.mkv:  videoEncoder = 'libx264'; videoQuality = 28; videoSpeed = 'medium'; enableAudio = true; audioBitrate = 128; break;
      case OutputType.mp4:  videoEncoder = 'libx264'; videoQuality = 28; videoSpeed = 'medium'; enableAudio = true; audioBitrate = 128; break;
      case OutputType.ogv:  videoEncoder = 'libtheora'; videoQuality = 7;  videoSpeed = 'medium'; enableAudio = true; audioBitrate = 160; break;
      case OutputType.webm: videoEncoder = 'libvpx-vp9'; videoQuality = 40; videoSpeed = 'medium'; enableAudio = true; audioBitrate = 160; break;
      default: break;
    }
    scale = 1.0; rotation = 0; flipH = false; flipV = false; clampPo2 = false;
    cropLeft = 0; cropTop = 0; cropRight = 0; cropBottom = 0;
    padLeft = 0; padTop = 0; padRight = 0; padBottom = 0; padColor = 'black';
    videoFps = 0; videoFpsOrig = false; videoPFR = false;
    imageMaxSize = 0;
    pdfDpi = 200; pdfPageSize = 'A4'; pdfPageRange = 'all';
    pdfPageMode = 'all'; pdfRotate = '0'; pdfRotatePages = '';
    pdfSplitPages = 0; pdfSplitCustom = 0; pdfPageOrder = '';
    pdfOptimize = false; pdfLinearize = false; pdfEncrypt = false;
    pdfOptimizeImages = false; pdfDeterministicId = false;
    pdfNormalizeContent = false; pdfWatermarkPath = ''; pdfUnderlayPath = '';
    pdfAdvanced = false;
    pdfEncryptUserPassword = ''; pdfEncryptOwnerPassword = '';
    pdfEncryptKeyLength = '256';
    pdfAllowPrint = true; pdfAllowModify = true;
    pdfAllowCopy = true; pdfAllowAnnotate = true;
    pdfSourcePassword = '';
    speedMultiplier = 1.0;
  }
}

// ── Grouped format dropdown (top-level helper types) ──

abstract class _FormatEntry {
  OutputType? get value => null;
}
class _FormatGroupHeader extends _FormatEntry {
  final IconData icon;
  final String label;
  _FormatGroupHeader(this.icon, this.label);
}
class _FormatItem extends _FormatEntry {
  @override final OutputType value;
  _FormatItem(this.value);
}

class ConverterPage extends StatefulWidget {
  final String ffmpegPath;
  final String qpdfPath;
  final String defaultOutputDir;
  final int maxParallel;
  final HardwareAcceleration hwAccel;
  final VoidCallback onClose;

  const ConverterPage({
    super.key,
    required this.ffmpegPath,
    this.qpdfPath = '',
    this.defaultOutputDir = '',
    this.maxParallel = 1,
    this.hwAccel = HardwareAcceleration.off,
    required this.onClose,
  });

  @override
  State<ConverterPage> createState() => _ConverterPageState();
}

class _ConverterPageState extends State<ConverterPage> {
  ConverterService? _svc;

  final List<_FileItem> _fileItems = [];
  int? _selectedIndex;
  bool _combineEnabled = false;
  bool _topmost = false;

  static const _dragChannel = MethodChannel('com.xmate/dragdrop');

  Timer? _pendingTimer;
  bool _qlSpawned = false;  // set when Preview button opens a QL window

  @override
  void initState() {
    super.initState();
    _svc = ConverterService(ffmpegPath: widget.ffmpegPath, qpdfPath: widget.qpdfPath, maxParallel: widget.maxParallel, hwAccel: widget.hwAccel);
    _svc!.onJobUpdated.listen((_) {
      if (mounted) setState(() {});
    });
    _svc!.jobListStream.listen((_) {
      if (mounted) setState(() {});
    });
    _initDragDrop();
    _loadWindowState();
    _startPendingPoll();
  }

  void _startPendingPoll() {
    _pendingTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _checkPendingFiles());
    // Also check immediately on startup
    _checkPendingFiles();
  }

  void _checkPendingFiles() {
    try {
      final pending = File('${Platform.environment['APPDATA']}\\XMate\\fc_add_pending.json');
      if (!pending.existsSync()) return;
      final content = pending.readAsStringSync();
      pending.deleteSync();
      final m = jsonDecode(content) as Map<String, dynamic>;
      final paths = (m['paths'] as List?)?.cast<String>() ?? [];
      if (paths.isNotEmpty && mounted) {
        _addFiles(paths);
      }
    } catch (_) {}
  }

  Future<void> _loadWindowState() async {
    try {
      final f = File(_fcStatePath);
      if (!await f.exists()) return;
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _topmost = m['topmost'] == true;
      if (_topmost) {
        await windowManager.setAlwaysOnTop(true);
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  static String get _fcStatePath =>
      '${Platform.environment['APPDATA']}\\XMate\\fc_state.json';

  Future<void> _saveWindowState() async {
    try {
      final dir = Directory('${Platform.environment['APPDATA']}\\XMate');
      if (!await dir.exists()) await dir.create(recursive: true);
      await File(_fcStatePath)
          .writeAsString(jsonEncode({'topmost': _topmost}));
    } catch (_) {}
  }

  /// Office status hint text — informational, shown for Office documents.
  String? _officeHint(String filePath) {
    final app = officeAppFor(filePath);
    if (app == null) return null;
    return 'via ${officeAppLabel(app)}';
  }

  void _initDragDrop() {
    _dragChannel.setMethodCallHandler((call) async {
      if (call.method != 'onDrop' || !mounted) return;
      final args = call.arguments as Map<dynamic, dynamic>?;
      if (args == null) return;
      final type = args['type'] as String?;
      if (type == 'files') {
        final raw = args['files'] as List<dynamic>?;
        if (raw == null || raw.isEmpty) return;
        _addFiles(raw.cast<String>());
      }
    });
  }

  void _addFiles(List<String> paths) {
    final supported = compatibleInputExtensions;
    final unsupported = <String>[];
    for (final path in paths) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final name = file.uri.pathSegments.last;
      final ext = name.contains('.')
          ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
          : '';
      if (!supported.contains(ext)) {
        unsupported.add(name);
        continue;
      }
      if (_fileItems.any((f) => f.path == path)) continue;
      final cat = getInputCategory(ext);
      final compat = OutputType.values
          .where((ot) =>
              ot.isPhase1Supported && isOutputCompatibleWithCategory(ot, cat))
          .toList();
      // Default to first compatible format in the SAME category as the input
      final outCat = _outputCategoryFor(cat);
      final sameCat = compat.where((ot) => ot.category == outCat).toList();
      final defaultType = sameCat.isNotEmpty
          ? sameCat.first
          : (compat.isNotEmpty ? compat.first : OutputType.mp4);
      final dir = _resolveOutputDir(path);
      final baseName =
          name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
      setState(() {
        _fileItems.add(_FileItem(
          path: path,
          name: name,
          outputType: defaultType,
          outputDir: dir,
          outputFileName: baseName,
        ));
        if (_selectedIndex == null) _selectedIndex = 0;
        if (_selectedIndex == 0) _onFileSelected(0);
      });
      _triggerProbe(path); // probe async — won't block UI
    }
    if (unsupported.isNotEmpty) {
      final names = unsupported.length <= 3
          ? unsupported.join(', ')
          : '${unsupported.take(3).join(', ')} and ${unsupported.length - 3} more';
      _showSnack('Unsupported: $names');
    }
  }

  /// Resolve default output directory for a file: user-configured global
  /// default → source file's parent directory → Documents fallback.
  String _resolveOutputDir(String inputPath) {
    final d = widget.defaultOutputDir;
    if (d.isNotEmpty && Directory(d).existsSync()) return d;
    final parent = File(inputPath).parent.path;
    return parent.isNotEmpty
        ? parent
        : '${Platform.environment['USERPROFILE'] ?? '.'}\\Documents';
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: TextStyle(fontSize: 12, color: cs.onSurface)),
        duration: const Duration(seconds: 2),
        backgroundColor: XMateColors.pageBg(context),
      ),
    );
  }

  @override
  void dispose() {
    _dragChannel.setMethodCallHandler(null);
    _svc?.dispose();
    _pendingTimer?.cancel();
    // Close QL windows spawned from FC Preview + clear shared state
    if (_qlSpawned) {
      try {
        const MethodChannel('com.xmate/quicklook')
            .invokeMethod('closeQuickLookWindows', {'includePinned': false});
      } catch (_) {}
      _qlSpawned = false;
    }
    qls.QuickLookPaletteState.clearSync();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: compatibleInputExtensions.toList(),
    );
    if (result != null && result.files.isNotEmpty) {
      final paths = result.files
          .where((f) => f.path != null)
          .map((f) => f.path!)
          .toList();
      _addFiles(paths);
    }
  }

  List<OutputType> _compatibleOutputs(_FileItem item) {
    final cat = getInputCategory(item.inputExt);
    var formatList = OutputType.values
        .where((ot) {
          if (!ot.isPhase1Supported) return false;
          if (_combineEnabled) {
            return isOutputCompatibleWithCategory(ot, cat) && ot.supportsCombine;
          }
          return isOutputCompatibleWithCategory(ot, cat);
        })
        .toList();

    formatList.sort((a, b) => a.label.compareTo(b.label));
    return formatList;
  }

  void _removeFile(int index) {
    setState(() {
      if (_selectedIndex == index) _selectedIndex = null;
      _fileItems.removeAt(index);
      if (_selectedIndex != null && _selectedIndex! >= _fileItems.length) {
        _selectedIndex =
            _fileItems.isEmpty ? null : _fileItems.length - 1;
      }
      _updateCombineState();
    });
  }

  /// Whether combine mode is currently valid.
  bool get _canCombine {
    if (_fileItems.length < 2) return false;
    final firstType = _fileItems.first.outputType;
    if (!firstType.supportsCombine) return false;
    return _fileItems.every((f) => f.outputType == firstType);
  }

  void _updateCombineState() {
    if (!_canCombine) _combineEnabled = false;
  }

  /// Sync settings across all files when combine mode is toggled on.
  /// - All files share format, output dir, filename (from first file)
  /// - Image: unify output dimensions to the max from probed sizes
  /// - Video: sync encoder, CRF, FPS (use max)
  /// - Audio: sync bitrate, channels (use max)
  void _syncCombineSettings() {
    if (_fileItems.length < 2) return;
    final first = _fileItems.first;

    // ── Format + filename + outputDir: all files same as first ──
    final firstType = first.outputType;
    final firstName = first.outputFileName;
    final firstDir = first.outputDir;
    for (final item in _fileItems.skip(1)) {
      item.outputType = firstType;
      item.outputFileName = firstName;
      item.outputDir = firstDir;
      item.initDefaults();
    }

    // ── Image: unify target dimensions ──
    if (firstType.category == OutputCategory.image || firstType == OutputType.gif) {
      _syncImageDimensions();
    }

    // ── Video: sync encoder/CRF/FPS ──
    if (firstType.category == OutputCategory.video) {
      _syncVideoParams();
    }

    // ── Audio: sync bitrate/channels ──
    if (firstType.category == OutputCategory.audio) {
      _syncAudioParams();
    }
  }

  /// Unify image output dimensions: find max probed w×h, compute scale+pad for each.
  void _syncImageDimensions() {
    // Find max width and max height from probed files
    int maxW = 0, maxH = 0;
    for (final item in _fileItems) {
      final p = _getProbe(item.path);
      if (p != null && p.w > 0) {
        if (p.w > maxW) maxW = p.w;
        if (p.h > maxH) maxH = p.h;
      }
    }
    if (maxW == 0 || maxH == 0) return;

    // Apply to all files: scale to match the largest, then pad to fill
    for (final item in _fileItems) {
      final p = _getProbe(item.path);
      if (p == null || p.w == 0) continue;

      // Target AR = maxW/maxH
      // First scale so both dimensions fit within maxW×maxH
      final srcAR = p.w / p.h;
      final dstAR = maxW / maxH;

      double scaleVal;
      if (srcAR > dstAR) {
        // Source wider: scale by width
        scaleVal = maxW / p.w;
      } else {
        // Source taller: scale by height
        scaleVal = maxH / p.h;
      }

      final scaledW = (p.w * scaleVal).round();
      final scaledH = (p.h * scaleVal).round();

      item.scale = double.parse(scaleVal.toStringAsFixed(3));
      item.padLeft = (maxW - scaledW) ~/ 2;
      item.padRight = maxW - scaledW - item.padLeft;
      item.padTop = (maxH - scaledH) ~/ 2;
      item.padBottom = maxH - scaledH - item.padTop;

      // Don't apply pad if no padding needed
      if (item.padLeft + item.padRight + item.padTop + item.padBottom == 0) {
        item.padLeft = 0; item.padTop = 0; item.padRight = 0; item.padBottom = 0;
      }
    }
  }

  /// Sync video encoder, CRF quality, and FPS to max across all files.
  void _syncVideoParams() {
    // Find max values
    int maxQuality = 0, maxFps = 0;
    String bestEncoder = _fileItems.first.videoEncoder;
    for (final item in _fileItems) {
      if (item.videoQuality > maxQuality) maxQuality = item.videoQuality;
      if (item.videoFps > maxFps) maxFps = item.videoFps;
      // Prefer libx264 if mixed
      if (item.videoEncoder == 'libx264') bestEncoder = 'libx264';
    }
    for (final item in _fileItems) {
      item.videoEncoder = bestEncoder;
      item.videoQuality = maxQuality;
      if (maxFps > 0) item.videoFps = maxFps;
    }
  }

  /// Sync audio bitrate and channels to max.
  void _syncAudioParams() {
    int maxBr = 0, maxCh = 0;
    for (final item in _fileItems) {
      if (item.audioBitrate > maxBr) maxBr = item.audioBitrate;
      if (item.audioChannels > maxCh) maxCh = item.audioChannels;
    }
    for (final item in _fileItems) {
      item.audioBitrate = maxBr;
      item.audioChannels = maxCh;
    }
  }

  /// Generic combine sync: call [action] on every file except [source].
  void _syncToAllExcept(_FileItem source, void Function(_FileItem) action) {
    for (final other in _fileItems) {
      if (other != source) action(other);
    }
  }

  bool get _isConverting {
    final svc = _svc;
    if (svc == null) return false;
    return svc.jobs.any((j) =>
        j.state == ConversionState.inProgress ||
        j.state == ConversionState.ready);
  }

  void _startConversion() {
    if (_fileItems.isEmpty) return;
    final svc = _svc!;

    if (_combineEnabled && _canCombine) {
      // Combined mode: single job with multiple inputPaths + perFileSettings
      final first = _fileItems.first;
      final settings = first.buildSettings();
      final job = ConversionJob(
        inputPath: first.path,
        outputType: first.outputType,
        settings: settings,
        outputDir: first.outputDir,
        outputFileName: first.outputFileName,
        inputPaths: _fileItems.map((f) => f.path).toList(),
        perFileSettings: _fileItems.map((f) => f.buildSettings()).toList(),
      );
      for (final item in _fileItems) {
        item.job = job;
      }
      svc.enqueue(job);
    } else {
      // Individual mode: one job per file
      final jobs = <ConversionJob>[];
      for (final item in _fileItems) {
        final settings = item.buildSettings();
        final job = ConversionJob(
          inputPath: item.path,
          outputType: item.outputType,
          settings: settings,
          outputDir: item.outputDir,
          outputFileName: item.outputFileName,
        );
        item.job = job;
        jobs.add(job);
      }
      svc.enqueueAll(jobs);
    }
  }

  void _cancelAll() => _svc?.cancelAll();

  Future<void> _toggleTopmost() async {
    _topmost = !_topmost;
    setState(() {});
    await windowManager.setAlwaysOnTop(_topmost);
    _saveWindowState();
  }

  Future<void> _previewFile(_FileItem item) async {
    // Close existing non-pinned QL windows first (same pattern as _showQuickLook)
    try {
      await const MethodChannel('com.xmate/quicklook')
          .invokeMethod('closeQuickLookWindows', {'includePinned': false});
    } catch (_) {}
    // Write FC selection to palette state so QL polling picks it up
    await qls.QuickLookPaletteState.update(path: item.path, active: true, source: 'converter');
    _qlSpawned = true;
    // Launch QuickLook in detached process
    try {
      final exe = Platform.resolvedExecutable;
      await Process.start(exe, ['--quicklook', item.path.replaceAll('/', '\\')], mode: ProcessStartMode.detached);
    } catch (_) {}
  }

  /// When QL was spawned from Preview, the palette state follows FC selection.
  void _onFileSelected(int index) {
    if (!_qlSpawned || index < 0 || index >= _fileItems.length) return;
    final item = _fileItems[index];
    qls.QuickLookPaletteState.update(path: item.path, active: true, source: 'converter');
  }

  String _fileStatus(_FileItem item) {
    final job = item.job;
    if (job == null) return '';
    if (job.isInProgress) {
      if (job.progress > 0) return '${(job.progress * 100).round()}%';
      return 'Converting…';
    }
    if (job.isDone) return 'Done';
    if (job.isFailed) return 'Failed';
    return 'Queued';
  }

  Color _fileStatusColor(_FileItem item, ColorScheme cs) {
    final job = item.job;
    if (job == null) return cs.onSurface.withAlpha(120);
    if (job.isDone) return Colors.green;
    if (job.isFailed) return cs.error;
    if (job.isInProgress) return cs.primary;
    return cs.onSurface.withAlpha(120);
  }

  IconData? _fileStatusIcon(_FileItem item) {
    final job = item.job;
    if (job == null) return null;
    if (job.isDone) return Icons.check_circle;
    if (job.isFailed) return Icons.error;
    if (job.isInProgress) return Icons.sync;
    return null;
  }

  // ────────────────────────────────────────────────────────────
  //  Build
  // ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isConverting = _isConverting;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        margin: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: XMateColors.panelBg(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cs.primary.withAlpha(60), width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _titleBar(cs),
            _dropZone(cs),
            Expanded(child: _bodyScroll(cs)),
            _bottomBar(cs, isConverting),
          ],
        ),
      ),
    );
  }

  /// Scrollable area: file list + settings panel.
  Widget _bodyScroll(ColorScheme cs) {
    if (_fileItems.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Text(
              'No files added yet.\nDrag & drop or click Browse to add files.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, color: cs.onSurface.withAlpha(100))),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _fileListSection(cs),
          if (_selectedIndex != null) _settingsPanel(cs),
        ],
      ),
    );
  }

  // ── Title bar ──────────────────────────────────────────────

  Widget _titleBar(ColorScheme cs) {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: 38,
        decoration: const BoxDecoration(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Row(children: [
          const SizedBox(width: 14),
          Icon(Icons.swap_horiz, size: 16, color: cs.primary),
          const SizedBox(width: 8),
          Text('File Converter',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface)),
          const Spacer(),
          _titleBtn(Icons.vertical_align_top, _toggleTopmost, tooltip: '置顶', active: _topmost),
          _titleBtn(Icons.minimize, () => windowManager.minimize()),
          _titleBtn(Icons.close, widget.onClose),
        ]),
      ),
    );
  }

  Widget _titleBtn(IconData icon, VoidCallback onTap, {String? tooltip, bool active = false}) {
    final cs = Theme.of(context).colorScheme;
    final child = GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 38,
        alignment: Alignment.center,
        child: Icon(icon, size: 16, color: active ? cs.primary : cs.onSurface.withAlpha(138)),
      ),
    );
    if (tooltip != null) {
      return Tooltip(
        message: tooltip,
        child: child,
      );
    }
    return child;
  }

  // ── Part 1: Drop zone ─────────────────────────────────────

  Widget _dropZone(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Row(children: [
        Expanded(
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              border:
                  Border.all(color: cs.outline.withAlpha(80), style: BorderStyle.solid),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                  'Drag & drop files here, or click Browse to add',
                  style: TextStyle(
                      fontSize: 12, color: cs.onSurface.withAlpha(120))),
            ),
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          onPressed: _isConverting ? null : _pickFiles,
          icon: const Icon(Icons.folder_open, size: 16),
          label: const Text('Browse', style: TextStyle(fontSize: 12)),
          style: ElevatedButton.styleFrom(
            backgroundColor: cs.primary,
            foregroundColor: cs.onPrimary,
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
      ]),
    );
  }

  // ── Part 2: File list ─────────────────────────────────────

  Widget _fileListSection(ColorScheme cs) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outline.withAlpha(40)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header row
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withAlpha(80),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: Row(children: [
              const SizedBox(width: 22),
              const SizedBox(width: 4),
              Expanded(
                  child: Text('File',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface.withAlpha(150)))),
              SizedBox(
                  width: 72,
                  child: Text('Status',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface.withAlpha(150)))),
              const SizedBox(width: 28),
            ]),
          ),
          // Reorderable rows
          Flexible(
            child: ReorderableListView.builder(
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              itemCount: _fileItems.length,
              proxyDecorator: (child, index, animation) {
                return AnimatedBuilder(
                  animation: animation,
                  builder: (_, child) => Material(
                    color: Colors.transparent,
                    child: child,
                  ),
                  child: child,
                );
              },
              onReorderItem: (oldIndex, newIndex) {
                if (_isConverting) return;
                setState(() {
                  final item = _fileItems.removeAt(oldIndex);
                  _fileItems.insert(newIndex, item);
                  // Update selection index to follow the moved item
                  if (_selectedIndex == oldIndex) {
                    _selectedIndex = newIndex;
                  } else if (_selectedIndex != null &&
                      _selectedIndex! >= newIndex &&
                      _selectedIndex! < oldIndex) {
                    _selectedIndex = _selectedIndex! + 1;
                  } else if (_selectedIndex != null &&
                      _selectedIndex! <= newIndex &&
                      _selectedIndex! > oldIndex) {
                    _selectedIndex = _selectedIndex! - 1;
                  }
                });
              },
              itemBuilder: (_, i) => _fileRow(i, cs),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fileRow(int index, ColorScheme cs) {
    final item = _fileItems[index];
    final selected = index == _selectedIndex;
    final converting = _isConverting;
    final status = _fileStatus(item);
    final statusIcon = _fileStatusIcon(item);

    return Container(
      key: ValueKey(item.path),
      child: GestureDetector(
      onTap: converting ? null : () => setState(() { _selectedIndex = index; _triggerProbe(_fileItems[index].path); _onFileSelected(index); }),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? cs.primary.withAlpha(15) : Colors.transparent,
          border:
              Border(top: BorderSide(color: cs.outline.withAlpha(20))),
        ),
        child: Row(children: [
          // Drag handle
          if (!converting)
            ReorderableDragStartListener(
              index: index,
              child: Icon(Icons.drag_indicator, size: 16,
                  color: cs.onSurface.withAlpha(80)),
            ),
          // File icon + name + path
          Icon(_fileIconFor(item), size: 14, color: cs.onSurface.withAlpha(150)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name,
                    style: TextStyle(fontSize: 12, color: cs.onSurface),
                    overflow: TextOverflow.ellipsis),
                Text(item.path,
                    style: TextStyle(
                        fontSize: 10,
                        color: cs.onSurface.withAlpha(100)),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1),
                // Show error detail when job has failed
                if (item.job != null && item.job!.isFailed && item.job!.errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      item.job!.errorMessage!,
                      style: TextStyle(fontSize: 9, color: cs.error.withAlpha(200)),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                    ),
                  ),
                // Show Office availability hint
                if (_officeHint(item.path) != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      _officeHint(item.path)!,
                      style: TextStyle(fontSize: 9, color: Colors.orange.withAlpha(200)),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
              ],
            ),
          ),
          // Status
          if (status.isNotEmpty) ...[
            if (statusIcon != null) ...[
              Icon(statusIcon, size: 13, color: _fileStatusColor(item, cs)),
              const SizedBox(width: 3),
            ],
            Tooltip(
              message: item.job?.errorMessage ?? '',
              preferBelow: false,
              child: SizedBox(
                width: 56,
                child: Text(status,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontSize: 11,
                        color: _fileStatusColor(item, cs))),
              ),
            ),
          ] else
            const SizedBox(width: 72),
          // Remove / cancel
          if (!converting)
            GestureDetector(
              onTap: () => _removeFile(index),
              child: SizedBox(
                width: 28,
                height: 28,
                child: Icon(Icons.close, size: 14,
                    color: cs.onSurface.withAlpha(100)),
              ),
            )
          else
            const SizedBox(width: 28),
        ]),
      ),
      ),
    );
  }

  IconData _fileIconFor(_FileItem item) {
    final ext = item.inputExt;
    if (const {'mp3', 'wav', 'flac', 'aac', 'ogg', 'wma', 'm4a', 'opus'}.contains(ext)) return Icons.audio_file;
    if (const {'mp4', 'mkv', 'avi', 'webm', 'flv', 'mov', 'wmv', 'ogv'}.contains(ext)) return Icons.video_file;
    if (const {'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', 'ico', 'svg', 'tif', 'tiff'}.contains(ext)) return Icons.image;
    return Icons.insert_drive_file;
  }

    // ── Part 3: Settings panel ─────────────────────────────────

  // Per-file probe cache (duration, dimensions, FPS, bitrate from FFprobe).
  // null = not probed yet, {} = probed with no useful data.
  final Map<String, ({int sec, int w, int h, double fps, int bitrate})?> _probeCache = {};

  /// Resolve ffprobe path from ffmpeg path (same directory, replace .exe).
  String get _ffprobePath {
    final ffmpeg = widget.ffmpegPath;
    if (ffmpeg.endsWith('ffmpeg.exe')) {
      return '${ffmpeg.substring(0, ffmpeg.length - 10)}ffprobe.exe';
    }
    return ffmpeg.replaceAll('ffmpeg', 'ffprobe');
  }

  Future<({int sec, int w, int h, double fps, int bitrate})?> _getProbeAsync(String filePath) async {
    if (_probeCache.containsKey(filePath)) return _probeCache[filePath];
    try {
      // Use ffprobe for faster structured output (much faster than ffmpeg -i -f null -).
      final probePath = File(_ffprobePath).existsSync() ? _ffprobePath : widget.ffmpegPath;
      final isFfprobe = probePath.endsWith('ffprobe.exe') || probePath.endsWith('ffprobe');

      int dur = 0, br = 0, w = 0, h = 0; double fps = 0;

      if (isFfprobe) {
        // ffprobe JSON output: fast, structured, no decoding overhead.
        final result = await Process.run(
          probePath,
          ['-v', 'quiet', '-print_format', 'json', '-show_format', '-show_streams', filePath],
          environment: {'PATH': Platform.environment['PATH'] ?? ''},
        );
        final stdout = result.stdout.toString();
        try {
          final data = jsonDecode(stdout) as Map<String, dynamic>;
          final format = data['format'] as Map<String, dynamic>?;
          if (format != null) {
            final durStr = format['duration'] as String?;
            if (durStr != null) dur = double.tryParse(durStr)?.round() ?? 0;
            final brStr = format['bit_rate'] as String?;
            if (brStr != null) br = (int.tryParse(brStr) ?? 0) ~/ 1000; // bps → kbps
          }
          final streams = data['streams'] as List<dynamic>?;
          if (streams != null) {
            for (final stream in streams) {
              final s = stream as Map<String, dynamic>;
              if (s['codec_type'] == 'video') {
                w = (s['width'] as int?) ?? 0;
                h = (s['height'] as int?) ?? 0;
                final fpsStr = s['r_frame_rate'] as String?; // e.g. "30000/1001"
                if (fpsStr != null) {
                  final parts = fpsStr.split('/');
                  if (parts.length == 2) {
                    final num = double.tryParse(parts[0]) ?? 0;
                    final den = double.tryParse(parts[1]) ?? 1;
                    fps = den > 0 ? num / den : 0;
                  } else {
                    fps = double.tryParse(parts[0]) ?? 0;
                  }
                }
                // If no format bitrate, try stream bitrate
                if (br == 0) {
                  final sBr = s['bit_rate'] as String?;
                  if (sBr != null) br = (int.tryParse(sBr) ?? 0) ~/ 1000;
                }
                break;
              }
            }
          }
        } catch (_) {
          // JSON parse failed — fall through to legacy ffmpeg path below
        }
        // If we got data, cache and return
        if (dur > 0 || w > 0) {
          _probeCache[filePath] = (sec: dur, w: w, h: h, fps: fps, bitrate: br);
          if (mounted) setState(() {});
          return _probeCache[filePath];
        }
      }

      // Fallback: legacy ffmpeg -i method
      final result = await Process.run(
        widget.ffmpegPath,
        ['-i', filePath, '-f', 'null', '-'],
        environment: {'PATH': Platform.environment['PATH'] ?? ''},
      );
      final stderr = result.stderr.toString();
      final dm = RegExp(r'Duration:\s*(\d+):(\d+):(\d+)\.(\d+),\s*.*bitrate:\s*(\d+)').firstMatch(stderr);
      if (dm != null) {
        dur = int.parse(dm.group(1)!) * 3600 + int.parse(dm.group(2)!) * 60 + int.parse(dm.group(3)!);
        br = int.tryParse(dm.group(5)!) ?? 0;
      }
      final vm = RegExp(r'Video:.*?,\s*(\d+)x(\d+)').firstMatch(stderr);
      if (vm != null) {
        w = int.parse(vm.group(1)!); h = int.parse(vm.group(2)!);
        final fm = RegExp(r'Video:.*?,\s*(\d+)x(\d+)\b[^,]*,\s*([\d.]+)\s*fps').firstMatch(stderr);
        if (fm != null) fps = double.tryParse(fm.group(3)!) ?? 0;
      }
      _probeCache[filePath] = (sec: dur, w: w, h: h, fps: fps, bitrate: br);
    } catch (_) {
      _probeCache[filePath] = null;
    }
    if (mounted) setState(() {});
    return _probeCache[filePath];
  }

  ({int sec, int w, int h, double fps, int bitrate})? _getProbe(String filePath) =>
      _probeCache[filePath];

  int? _readDurationSec(String filePath) => _getProbe(filePath)?.sec;

  void _triggerProbe(String filePath) {
    if (!_probeCache.containsKey(filePath)) {
      _getProbeAsync(filePath);
    }
  }

  Widget _settingsPanel(ColorScheme cs) {
    final item = _fileItems[_selectedIndex!];
    final compatOutputs = _compatibleOutputs(item);

    // Ensure current output type is valid for this file.
    if (compatOutputs.isNotEmpty && !compatOutputs.contains(item.outputType)) {
      item.outputType = compatOutputs.first;
      item.initDefaults();
    }

    // Refresh duration cache when selected file changes
    final dur = _readDurationSec(item.path);
    if (dur != null && item.trimEnd.isEmpty) {
      item._initTrimEndFromDuration(dur);
    }
    // Also cap existing trimEnd if it exceeds actual duration
    if (dur != null && item.trimEnd.isNotEmpty) {
      final endSec = _parseTimeToSec(item.trimEnd);
      if (endSec != null && endSec > dur) {
        item._setTrimEndFromDuration(dur);
      }
    }

    // Build format dropdown items grouped by category, with current file's category first
    final myCat = _outputCategoryFor(getInputCategory(item.inputExt));
    final formatItems = _buildGroupedFormatItems(compatOutputs, preferCategory: myCat);

    return Container(
      key: ValueKey('settings_$_selectedIndex$_combineEnabled'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outline.withAlpha(60)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──
          Row(children: [
            Icon(_fileIconFor(item), size: 14, color: cs.primary),
            const SizedBox(width: 6),
            Expanded(child: Text(item.name,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface),
                overflow: TextOverflow.ellipsis)),
            _titleBtn(Icons.visibility, () => _previewFile(item), tooltip: 'Preview'),
          ]),

          const SizedBox(height: 12),
          _divider(cs),
          const SizedBox(height: 12),

          // ═══ Row 1: Format + Filename ═══
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              // Format dropdown
              SizedBox(width: 120, child:
                DropdownButtonFormField<OutputType>(
                  value: item.outputType, isDense: true, isExpanded: true,
                  decoration: _fieldDeco(),
                  style: TextStyle(fontSize: 12, color: cs.onSurface),
                  selectedItemBuilder: (_) => formatItems.map((e) {
                    final ot = e.value;
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: Text(ot?.shortLabel ?? '',
                          style: TextStyle(fontSize: 12, color: cs.onSurface)),
                    );
                  }).toList(),
                  items: formatItems.map((e) {
                    if (e is _FormatGroupHeader) {
                      return DropdownMenuItem<OutputType>(
                        value: null, enabled: false,
                        child: Row(children: [
                          Icon(e.icon, size: 13, color: cs.primary.withAlpha(200)),
                          const SizedBox(width: 5),
                          Text(e.label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.primary)),
                        ]),
                      );
                    }
                    final ot = e.value!;
                    return DropdownMenuItem(value: ot,
                      child: Text(ot.shortLabel, style: const TextStyle(fontSize: 12)));
                  }).toList(),
                  onChanged: _isConverting ? null : (v) {
                    if (v != null) { setState(() {
                      if (_combineEnabled) {
                        for (final o in _fileItems) {
                          o.outputType = v;
                          o.initDefaults();
                        }
                      } else {
                        item.outputType = v;
                        item.initDefaults();
                      }
                      _updateCombineState();
                    }); }
                  },
                ),
              ),
              const SizedBox(width: 8),
              // Filename
              Expanded(child: TextFormField(
                key: ValueKey('name_$_selectedIndex'),
                initialValue: item.outputFileName,
                style: TextStyle(fontSize: 12, color: cs.onSurface),
                readOnly: _isConverting,
                decoration: _fieldDeco(hint: 'filename'),
                onChanged: (v) {
                  item.outputFileName = v;
                  if (_combineEnabled) _syncToAllExcept(item, (o) => o.outputFileName = v);
                },
              )),
              const SizedBox(width: 4),
              Text('.${item.outputType.extension}',
                  style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(150), fontWeight: FontWeight.w600)),
            ]),
          ),

          // ═══ Row 2: Output Dir ═══
          _settingRow(cs, label: 'Dir', child: Row(children: [
            Expanded(child: TextFormField(
              key: ValueKey('dir_$_selectedIndex'),
              initialValue: item.outputDir,
              style: TextStyle(fontSize: 12, color: cs.onSurface),
              readOnly: _isConverting,
              decoration: _fieldDeco(hint: 'Source folder or custom…'),
              onChanged: (v) {
                item.outputDir = v;
                if (_combineEnabled) _syncToAllExcept(item, (o) => o.outputDir = v);
              },
            )),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: _isConverting ? null : () async {
                final dir = await FilePicker.platform.getDirectoryPath();
                if (dir != null && mounted) setState(() => item.outputDir = dir);
              },
              child: Icon(Icons.folder_open, size: 16,
                  color: _isConverting ? cs.onSurface.withAlpha(60) : cs.primary),
            ),
          ])),

          // ═══ Video section ═══
          if (item.isVideo) ...[
            const SizedBox(height: 12),
            _divider(cs),
            const SizedBox(height: 12),
            _buildVideoSettings(cs, item),
          ],

          // ═══ PDF / Document ═══
          if (item.isDoc || item.outputType == OutputType.pdf) ...[
            const SizedBox(height: 12),
            _divider(cs),
            const SizedBox(height: 12),
            _buildDocSettings(cs, item),
          ],

          // ═══ Trim (audio + video) ═══
          if (dur != null && dur > 0) ...[
            const SizedBox(height: 12),
            _divider(cs),
            const SizedBox(height: 12),
            _buildTrim(cs, item, dur),
          ],

          // ═══ Image / Transform (video + image) ═══
          if (item.isVideo || item.isImage) ...[
            const SizedBox(height: 12),
            _divider(cs),
            const SizedBox(height: 12),
            _buildImageTransform(cs, item),
          ],

          // ═══ Audio section (pure audio, or video with enableAudio) ═══
          if (item.isAudio || (item.isVideo && item.enableAudio)) ...[
            const SizedBox(height: 12),
            _divider(cs),
            const SizedBox(height: 12),
            _buildAudioSettings(cs, item),
          ],

          // ═══ Advanced ═══
          const SizedBox(height: 12),
          _divider(cs),
          const SizedBox(height: 12),
          _buildCustomCommand(cs, item),
        ],
      ),
    );
  }

  // ── Divider ──

  Widget _divider(ColorScheme cs) {
    return Divider(height: 1, thickness: 1, color: cs.outline.withAlpha(40));
  }

  // ── Grouped format dropdown ──

  List<_FormatEntry> _buildGroupedFormatItems(List<OutputType> compatOutputs, {OutputCategory? preferCategory}) {
    final cats = <OutputCategory, List<OutputType>>{};
    for (final ot in compatOutputs) {
      cats.putIfAbsent(ot.category, () => []).add(ot);
    }
    // Sort within each category by shortLabel
    for (final list in cats.values) {
      list.sort((a, b) => a.shortLabel.compareTo(b.shortLabel));
    }
    final result = <_FormatEntry>[];
    // Order: preferred category first, then the rest in fixed order
    final ordered = <OutputCategory>[
      if (preferCategory != null) preferCategory,
      ...OutputCategory.values.where((c) => c != preferCategory && c != OutputCategory.none),
    ];
    for (final cat in ordered) {
      final list = cats[cat];
      if (list == null || list.isEmpty) continue;
      result.add(_FormatGroupHeader(cat.icon, cat.name[0].toUpperCase() + cat.name.substring(1)));
      for (final ot in list) { result.add(_FormatItem(ot)); }
    }
    return result;
  }

  /// Map InputCategory to the corresponding OutputCategory for format dropdown ordering.
  OutputCategory _outputCategoryFor(InputCategory ic) {
    switch (ic) {
      case InputCategory.audio:         return OutputCategory.audio;
      case InputCategory.video:
      case InputCategory.animatedImage: return OutputCategory.video;
      case InputCategory.image:         return OutputCategory.image;
      case InputCategory.document:      return OutputCategory.document;
      case InputCategory.misc:          return OutputCategory.image; // default
    }
  }

  // ═══════════════════════════════════════════════════════════
  //  Video settings
  // ═══════════════════════════════════════════════════════════

  static const _h264Speeds = ['ultrafast', 'superfast', 'veryfast', 'faster', 'fast', 'medium', 'slow', 'slower', 'veryslow'];

  // Encoders available for each video output format
  static const _videoEncoders = <OutputType, List<(String, String)>>{
    OutputType.avi:  [('mpeg4', 'MPEG-4')],
    OutputType.mp4:  [('libx264', 'H.264'),      ('libx265', 'H.265')],
    OutputType.mkv:  [('libx264', 'H.264'),      ('libx265', 'H.265'), ('libvpx-vp9', 'VP9')],
    OutputType.ogv:  [('libtheora', 'Theora')],
    OutputType.webm: [('libvpx-vp9', 'VP9')],
  };

  bool _encoderNeedsSpeed(String enc) =>
      enc == 'libx264' || enc == 'libx265' || enc == 'h264_nvenc';

  Widget _buildVideoSettings(ColorScheme cs, _FileItem item) {
    final probe = _getProbe(item.path);
    final encoders = _videoEncoders[item.outputType] ?? const [];
    final needsSpeed = _encoderNeedsSpeed(item.videoEncoder) && item.outputType.supportsSpeedPreset;
    final srcFps = probe?.fps ?? 0;
    final srcBr = probe?.bitrate ?? 0;

    final audioCodec = switch (item.outputType) {
      OutputType.avi => 'mp3', OutputType.mp4 || OutputType.mkv => 'aac',
      OutputType.ogv || OutputType.webm => 'vorbis', _ => '',
    };
    final estBr = _estimateVideoBitrate(item.videoEncoder, item.videoQuality);

    return Column(children: [
      // Row 1 — Encoder + Speed (left, using Expanded) | Frame + orig/PFR (right, fixed)
      SizedBox(height: 24, child: Row(children: [
        // col1: Encoder label + dropdowns (flexible)
        SizedBox(width: 78, child: Text('Encoder', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(180)))),
        Expanded(child: Row(children: [
          if (item.outputType.supportsEncoderSelection && encoders.length > 1) ...[
            SizedBox(width: 100,
              child: DropdownButtonFormField<String>(
                value: item.videoEncoder, isDense: true, isExpanded: true,
                decoration: _fieldDeco(),
                style: TextStyle(fontSize: 12, color: cs.onSurface),
                items: encoders.map((e) => DropdownMenuItem(
                    value: e.$1, child: Text(e.$2, style: const TextStyle(fontSize: 12)))).toList(),
                onChanged: _isConverting ? null : (v) { if (v != null) setState(() {
                  item.videoEncoder = v;
                  if (_combineEnabled) _syncToAllExcept(item, (o) => o.videoEncoder = v);
                }); },
              ),
            ),
          ] else if (encoders.length == 1) ...[
            Text(encoders.first.$2,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.primary)),
          ],
          const SizedBox(width: 8),
          if (needsSpeed) ...[
            SizedBox(width: 78, child: Text('Speed', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(180)))),
            const SizedBox(width: 4),
            SizedBox(width: 105,
              child: DropdownButtonFormField<String>(
                value: item.videoSpeed, isDense: true, isExpanded: true,
                decoration: _fieldDeco(),
                style: TextStyle(fontSize: 12, color: cs.onSurface),
                items: _h264Speeds.map((s) => DropdownMenuItem(
                    value: s, child: Text(s, style: const TextStyle(fontSize: 12)))).toList(),
                onChanged: _isConverting ? null : (v) => setState(() => item.videoSpeed = v ?? 'medium'),
              ),
            ),
          ],
        ])),
        // col2: Frame + orig + PFR (fixed)
        SizedBox(width: 78, child: Text('Frame', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(180)))),
        const SizedBox(width: 4),
        SizedBox(width: 52, child: TextFormField(
          initialValue: item.videoFps > 0 ? '${item.videoFps}' : (srcFps > 0 ? '${srcFps.round()}' : ''),
          style: TextStyle(fontSize: 12, color: cs.onSurface),
          readOnly: _isConverting || item.videoFpsOrig,
          decoration: _fieldDeco(hint: 'auto'),
          keyboardType: TextInputType.number,
          onChanged: (v) { if (!item.videoFpsOrig) item.videoFps = int.tryParse(v) ?? 0; },
        )),
        const SizedBox(width: 4),
        SizedBox(width: 18, child: Checkbox(
          value: item.videoFpsOrig,
          onChanged: _isConverting ? null : (v) {
            setState(() { item.videoFpsOrig = v ?? false; if (v == true) item.videoFps = srcFps.round(); });
          },
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact, activeColor: cs.primary,
        )),
        const SizedBox(width: 2),
        GestureDetector(
          onTap: _isConverting ? null : () { setState(() { item.videoFpsOrig = !item.videoFpsOrig; if (item.videoFpsOrig) item.videoFps = srcFps.round(); }); },
          child: Text('orig', style: TextStyle(fontSize: 10, color: item.videoFpsOrig ? cs.primary : cs.onSurface.withAlpha(100))),
        ),
        const SizedBox(width: 8),
        if (item.outputType.supportsVFR) ...[
          SizedBox(width: 18, child: Checkbox(
            value: item.videoPFR, onChanged: _isConverting ? null : (v) => setState(() => item.videoPFR = v ?? false),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact, activeColor: cs.primary,
          )),
          const SizedBox(width: 2),
          GestureDetector(
            onTap: _isConverting ? null : () => setState(() => item.videoPFR = !item.videoPFR),
            child: Text('PFR', style: TextStyle(fontSize: 10, color: item.videoPFR ? cs.primary : cs.onSurface.withAlpha(100))),
          ),
        ],
      ])),
      const SizedBox(height: 6),

      // Row 2: CRF / Quality
      _videoQualityRow(cs, item),

      // Row 3 — Audio + bitrate info
      const SizedBox(height: 6),
      SizedBox(height: 24, child:
        _settingRow(cs, label: 'Audio', child: Row(children: [
          SizedBox(height: 24, child: Transform.scale(
            scale: 0.65,
            child: Switch(
              value: item.enableAudio, onChanged: _isConverting ? null : (v) => setState(() => item.enableAudio = v),
              activeTrackColor: cs.primary,
            ),
          )),
          if (item.enableAudio)
            Text('$audioCodec  ${item.audioBitrate}k',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: cs.primary))
          else
            Text('OFF', style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(80))),
          const Spacer(),
          if (srcBr > 0 && estBr > 0)
            Text('${srcBr}k  →  ${estBr}k  Bitrate',
                style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(140))),
        ])),
      ),
    ]);
  }

  // ── Estimated output bitrate (very rough heuristic) ──

  int _estimateVideoBitrate(String encoder, int quality) {
    // Rough CRF→kbps mapping for common encoders, purely for display
    switch (encoder) {
      case 'libx264': return (7000 * (51 - quality) / 51).round().clamp(100, 15000);
      case 'libx265': return (4000 * (51 - quality) / 51).round().clamp(80, 8000);
      case 'libvpx-vp9': return (5000 * (63 - quality) / 63).round().clamp(80, 10000);
      case 'mpeg4': return (9000 * (31 - quality) / 31).round().clamp(100, 20000);
      case 'libtheora': return (6000 * (10 - quality) / 10).round().clamp(100, 20000);
      default: return 2000;
    }
  }

  // ── Video quality range per format ──

  Widget _videoQualityRow(ColorScheme cs, _FileItem item) {
    final (min, max, label) = switch (item.outputType) {
      OutputType.avi => (0, 30, 'Quality'),
      OutputType.mp4 || OutputType.mkv => (0, 51, 'CRF'),
      OutputType.ogv => (0, 10, 'Quality'),
      OutputType.webm => (0, 63, 'CRF'),
      _ => (0, 51, 'Quality'),
    };
    return _settingRow(cs, label: label, child: Row(children: [
      Expanded(child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
          activeTrackColor: cs.primary,
          inactiveTrackColor: cs.primary.withAlpha(40),
          thumbColor: cs.primary,
          overlayColor: cs.primary.withAlpha(30),
        ),
        child: Slider(
          value: item.videoQuality.toDouble(), min: min.toDouble(), max: max.toDouble(),
          divisions: max - min,
          onChanged: _isConverting ? null : (v) => setState(() {
            item.videoQuality = v.round();
            if (_combineEnabled) _syncToAllExcept(item, (o) => o.videoQuality = v.round());
          }),
        ),
      )),
      SizedBox(width: 40, child: Text('${item.videoQuality}',
          textAlign: TextAlign.right,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.primary))),
    ]));
  }

  // ═══════════════════════════════════════════════════════════
  //  Image / Transform settings
  // ═══════════════════════════════════════════════════════════

  static const _rotationOptions = [('0°', 0), ('90°', 90), ('180°', 180), ('270°', 270)];

  /// Compute a short aspect-ratio label (e.g. "16∶9", "4∶3").
  static String _aspectRatio(int w, int h) {
    if (w <= 0 || h <= 0) return '';
    const ratios = [(16, 9), (4, 3), (3, 2), (21, 9), (1, 1), (5, 4), (16, 10)];
    final target = w / h;
    for (final (rw, rh) in ratios) {
      if ((target - rw / rh).abs() < 0.03) return '$rw∶$rh';
    }
    return '${(target * 100).round() / 100}∶1';
  }

  Widget _buildImageTransform(ColorScheme cs, _FileItem item) {
    final probe = _getProbe(item.path);
    final sw = probe?.w ?? 0;
    final sh = probe?.h ?? 0;
    final hasDims = sw > 0 && sh > 0;

    final cw = sw - item.cropLeft - item.cropRight;
    final ch = sh - item.cropTop - item.cropBottom;
    final outW = (cw * item.scale).round() + item.padLeft + item.padRight;
    final outH = (ch * item.scale).round() + item.padTop + item.padBottom;

    return Column(children: [
      // Row 1: Scale + Clamp Po2 (Po2 only for formats that support it)
      SizedBox(height: 24, child:
        _settingRow(cs, label: 'Scale', child: Row(children: [
          Expanded(child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: cs.primary, inactiveTrackColor: cs.primary.withAlpha(40),
              thumbColor: cs.primary, overlayColor: cs.primary.withAlpha(30),
            ),
            child: Slider(
              value: item.scale, min: 0.075, max: 2.0,
              onChanged: _isConverting ? null : (v) => setState(() {
                item.scale = v;
                if (_combineEnabled) _syncToAllExcept(item, (o) => o.scale = v);
              }),
            ),
          )),
          SizedBox(width: 44, child: Text('${(item.scale * 100).round()}%',
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.primary))),
          if (item.outputType.supportsClampPo2) ...[
            const SizedBox(width: 8),
            SizedBox(width: 18, child: Checkbox(
              value: item.clampPo2, onChanged: _isConverting ? null : (v) => setState(() => item.clampPo2 = v ?? false),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact, activeColor: cs.primary,
            )),
            const SizedBox(width: 2),
            GestureDetector(
              onTap: _isConverting ? null : () => setState(() => item.clampPo2 = !item.clampPo2),
              child: Text('Po2', style: TextStyle(fontSize: 10, color: item.clampPo2 ? cs.primary : cs.onSurface.withAlpha(100))),
            ),
          ],
        ])),
      ),
      const SizedBox(height: 6),

      // Row 1.5: Max Size (only for formats that support it: JPG/PNG/WebP/AVIF)
      if (item.outputType.supportsMaxSize) ...[
        SizedBox(height: 24, child:
          _settingRow(cs, label: 'Max Size', child: Row(children: [
            SizedBox(width: 90,
              child: DropdownButtonFormField<int>(
                initialValue: _maxSizeDropValue(item.imageMaxSize),
                isDense: true, isExpanded: true,
                decoration: _fieldDeco(),
                style: TextStyle(fontSize: 11, color: cs.onSurface),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('None', style: TextStyle(fontSize: 11))),
                  DropdownMenuItem(value: 256, child: Text('256', style: TextStyle(fontSize: 11))),
                  DropdownMenuItem(value: 512, child: Text('512', style: TextStyle(fontSize: 11))),
                  DropdownMenuItem(value: 1024, child: Text('1024', style: TextStyle(fontSize: 11))),
                  DropdownMenuItem(value: 2048, child: Text('2048', style: TextStyle(fontSize: 11))),
                  DropdownMenuItem(value: 4096, child: Text('4096', style: TextStyle(fontSize: 11))),
                ],
                onChanged: _isConverting ? null : (v) => setState(() => item.imageMaxSize = v ?? 0),
              ),
            ),
          ])),
        ),
        const SizedBox(height: 6),
      ],

      // Row 2: Flip + Rotate (only for full-transform formats: AVIF/GIF/ICO + videos)
      if (item.outputType.supportsFullTransform) ...[
        SizedBox(height: 24, child:
          _settingRow(cs, label: 'Flip', child: Row(children: [
            _miniBoolBtn(value: item.flipH, label: 'H', onChanged: (v) => setState(() => item.flipH = v), cs: cs),
            const SizedBox(width: 4),
            _miniBoolBtn(value: item.flipV, label: 'V', onChanged: (v) => setState(() => item.flipV = v), cs: cs),
            const Spacer(),
            SizedBox(width: 78, child: Text('Rotate', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(180)))),
            const SizedBox(width: 4),
            ..._rotationOptions.map((o) => Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _miniRadio<int>(value: o.$2, groupValue: item.rotation, label: o.$1,
                onChanged: _isConverting ? null : (v) => setState(() => item.rotation = v), cs: cs),
            )),
          ])),
        ),
        const SizedBox(height: 6),
      ],

      // Row 3: Crop LTRB (only for full-transform formats)
      if (item.outputType.supportsFullTransform) ...[
        SizedBox(height: 24, child:
          _settingRow(cs, label: 'Crop', child: Row(children: [
            _dimCell(cs, () => item.cropLeft, (v) => item.cropLeft = v, 'L'),
            const SizedBox(width: 4),
            _dimCell(cs, () => item.cropTop, (v) => item.cropTop = v, 'T'),
            const SizedBox(width: 4),
            _dimCell(cs, () => item.cropRight, (v) => item.cropRight = v, 'R'),
            const SizedBox(width: 4),
            _dimCell(cs, () => item.cropBottom, (v) => item.cropBottom = v, 'B'),
            if (hasDims) ...[
              const Spacer(),
              Text('${sw}×$sh  ${_aspectRatio(sw, sh)}',
                  style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(130))),
            ],
          ])),
        ),
        const SizedBox(height: 6),
      ],

      // Row 4: Pad LTRB + color (only for full-transform formats)
      if (item.outputType.supportsFullTransform) ...[
        SizedBox(height: 24, child:
          _settingRow(cs, label: 'Pad', child: Row(children: [
            _dimCell(cs, () => item.padLeft, (v) => item.padLeft = v, 'L'),
            const SizedBox(width: 4),
            _dimCell(cs, () => item.padTop, (v) => item.padTop = v, 'T'),
            const SizedBox(width: 4),
            _dimCell(cs, () => item.padRight, (v) => item.padRight = v, 'R'),
            const SizedBox(width: 4),
            _dimCell(cs, () => item.padBottom, (v) => item.padBottom = v, 'B'),
            const SizedBox(width: 6),
            DropdownButton<String>(
              value: _padColorValue(item.padColor),
              isDense: true, underline: const SizedBox.shrink(),
              style: TextStyle(fontSize: 10, color: cs.primary),
              items: const [
                DropdownMenuItem(value: 'black', child: Text('Black', style: TextStyle(fontSize: 10))),
                DropdownMenuItem(value: 'white', child: Text('White', style: TextStyle(fontSize: 10))),
                DropdownMenuItem(value: '_custom_', child: Text('Custom', style: TextStyle(fontSize: 10))),
              ],
              onChanged: _isConverting ? null : (v) {
                if (v == '_custom_') { setState(() => item.padColor = ''); }
                else if (v != null) { setState(() => item.padColor = v); }
              },
            ),
            const SizedBox(width: 4),
            if (item.padColor.isEmpty || !const {'black', 'white'}.contains(item.padColor))
              SizedBox(width: 60, child: TextFormField(
                initialValue: item.padColor.isEmpty ? '' : item.padColor,
                style: TextStyle(fontSize: 11, color: cs.onSurface),
                textAlign: TextAlign.center, readOnly: _isConverting,
                decoration: _fieldDeco(hint: '#000'),
                onChanged: (v) => item.padColor = v,
              )),
            if (hasDims) ...[
              const Spacer(),
              Text('→ ${outW}×$outH  ${_aspectRatio(outW, outH)}',
                  style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(130))),
            ],
          ])),
        ),
      ],
    ]);
  }

  Widget _dimCell(ColorScheme cs, int Function() get, void Function(int) set, String label) {
    return SizedBox(width: 52, child: TextFormField(
      initialValue: get() > 0 ? '${get()}' : '',
      style: TextStyle(fontSize: 11, color: cs.onSurface),
      textAlign: TextAlign.center,
      readOnly: _isConverting,
      decoration: _fieldDeco(hint: label),
      keyboardType: TextInputType.number,
      onChanged: (v) => setState(() => set(int.tryParse(v) ?? 0)),
    ));
  }

  String _padColorValue(String c) {
    if (c == 'black' || c == 'white') return c;
    return '_custom_';
  }

  /// Snap [imageMaxSize] to the nearest valid dropdown value.
  int _maxSizeDropValue(int v) {
    const opts = [0, 256, 512, 1024, 2048, 4096];
    return opts.contains(v) ? v : 0;
  }

  Widget _miniBoolBtn({required bool value, required String label, required ValueChanged<bool> onChanged, required ColorScheme cs}) {
    return GestureDetector(
      onTap: _isConverting ? null : () => onChanged(!value),
      child: Container(
        width: 28, height: 28,
        decoration: BoxDecoration(
          color: value ? cs.primary : cs.onSurface.withAlpha(15),
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: Text(label, style: TextStyle(
          fontSize: 11, fontWeight: FontWeight.w600,
          color: value ? cs.onPrimary : cs.onSurface.withAlpha(120),
        )),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  //  Audio settings per format
  // ═══════════════════════════════════════════════════════════

  Widget _buildAudioSettings(ColorScheme cs, _FileItem item) {
    // For video formats, show the right audio sub-panel
    if (item.isVideo) {
      return _buildVideoAudioSub(cs, item);
    }
    switch (item.outputType) {
      case OutputType.aac: return _audioAac(cs, item);
      case OutputType.flac: return _audioFlac(cs, item);
      case OutputType.mp3: return _audioMp3(cs, item);
      case OutputType.ogg: return _audioOgg(cs, item);
      case OutputType.wav: return _audioWav(cs, item);
      default: return const SizedBox.shrink();
    }
  }

  Widget _buildVideoAudioSub(ColorScheme cs, _FileItem item) {
    switch (item.outputType) {
      case OutputType.avi:  return _audioMp3(cs, item);   // AVI uses MP3 audio
      case OutputType.mp4:
      case OutputType.mkv:  return _audioAac(cs, item);   // MP4/MKV uses AAC
      case OutputType.ogv:
      case OutputType.webm: return _audioOgg(cs, item);   // OGV/WebM uses Vorbis
      default: return const SizedBox.shrink();
    }
  }

  static const _channelOptions = [(0, 'Same'), (1, 'Mono'), (2, 'Stereo')];

  // Shared label helper for consistent 78px label width (matches _settingRow)
  Widget _al(ColorScheme cs, String s) =>
      SizedBox(width: 78, child: Text(s, style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(180))));

  Widget _channelRow(ColorScheme cs, _FileItem item) {
    return Row(children: [
      _al(cs, 'Channel'),
      const SizedBox(width: 4),
      ..._channelOptions.map((o) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: _miniRadio<int>(
          value: o.$1, groupValue: item.audioChannels, label: o.$2,
          onChanged: _isConverting ? null : (v) => setState(() => item.audioChannels = v),
          cs: cs,
        ),
      )),
    ]);
  }

  // ── AAC ──
  static const _aacBitrates = [16, 32, 48, 64, 80, 96, 112, 128, 155, 192, 224, 256, 340, 460];

  Widget _audioAac(ColorScheme cs, _FileItem item) => Column(children: [
    _bitrateRow(cs, item, _aacBitrates, 'Quality'),
    const SizedBox(height: 5),
    _channelRow(cs, item),
  ]);

  // ── FLAC ──
  Widget _audioFlac(ColorScheme cs, _FileItem item) => _channelRow(cs, item);

  // ── MP3 ──
  static const _mp3VbrBitrates = [65, 85, 100, 115, 130, 165, 175, 190, 225, 245];
  static const _mp3CbrBitrates = [8, 16, 24, 32, 40, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];

  Widget _audioMp3(ColorScheme cs, _FileItem item) {
    final isCbr = item.audioEncMode == 'mp3CBR';
    return Column(children: [
      _bitrateRow(cs, item, isCbr ? _mp3CbrBitrates : _mp3VbrBitrates, 'Quality'),
      const SizedBox(height: 5),
      SizedBox(height: 22, child: Row(children: [
        _channelRow(cs, item),
        const Spacer(),
        _al(cs, 'Encode'),
        const SizedBox(width: 4),
        _miniRadio<String>(value: 'mp3VBR', groupValue: item.audioEncMode, label: 'VBR',
            onChanged: _isConverting ? null : (v) => setState(() { item.audioEncMode = v; item.audioBitrate = 190; }), cs: cs),
        const SizedBox(width: 8),
        _miniRadio<String>(value: 'mp3CBR', groupValue: item.audioEncMode, label: 'CBR',
            onChanged: _isConverting ? null : (v) => setState(() { item.audioEncMode = v; item.audioBitrate = 128; }), cs: cs),
      ])),
    ]);
  }

  // ── OGG ──
  static const _oggBitrates = [32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 500];

  Widget _audioOgg(ColorScheme cs, _FileItem item) => Column(children: [
    _bitrateRow(cs, item, _oggBitrates, 'Quality'),
    const SizedBox(height: 5),
    _channelRow(cs, item),
  ]);

  // ── WAV ──
  static const _wavEncodings = [('wav8', '8-bit'), ('wav16', '16-bit'), ('wav24', '24-bit'), ('wav32', '32-bit')];

  Widget _audioWav(ColorScheme cs, _FileItem item) => Column(children: [
    SizedBox(height: 22, child: Row(children: [
      _channelRow(cs, item),
      const SizedBox(width: 20),
      _al(cs, 'Encode'),
      const SizedBox(width: 4),
      ..._wavEncodings.map((e) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: _miniRadio<String>(
          value: e.$1, groupValue: item.audioEncMode, label: e.$2,
          onChanged: _isConverting ? null : (v) => setState(() => item.audioEncMode = v), cs: cs,
        ),
      )),
    ])),
  ]);

  // ── Bitrate slider ──

  Widget _bitrateRow(ColorScheme cs, _FileItem item, List<int> ticks, String label) {
    final idx = _nearestTickIdx(ticks, item.audioBitrate);
    return _settingRow(cs, label: label, child: Row(children: [
      Expanded(child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
          activeTrackColor: cs.primary,
          inactiveTrackColor: cs.primary.withAlpha(40),
          thumbColor: cs.primary,
          overlayColor: cs.primary.withAlpha(30),
        ),
        child: Slider(
          value: idx.toDouble(), min: 0, max: (ticks.length - 1).toDouble(),
          divisions: ticks.length - 1,
          onChanged: _isConverting ? null : (v) => setState(() => item.audioBitrate = ticks[v.round()]),
        ),
      )),
      SizedBox(width: 48, child: Text('${ticks[idx]}k',
          textAlign: TextAlign.right,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.primary))),
    ]));
  }

  int _nearestTickIdx(List<int> ticks, int value) {
    int best = 0, bestDist = (ticks[0] - value).abs();
    for (int i = 1; i < ticks.length; i++) {
      final d = (ticks[i] - value).abs();
      if (d < bestDist) { best = i; bestDist = d; }
    }
    return best;
  }

  // ═══════════════════════════════════════════════════════════
  //  PDF / Document settings
  // ═══════════════════════════════════════════════════════════

  static const _pageSizes = ['A4', 'Letter', 'Legal', 'A3', 'A5', 'B5'];
  static const _kPageDims = <String, (int, int)>{
    'A4': (595, 842), 'Letter': (612, 792), 'Legal': (612, 1008),
    'A3': (842, 1191), 'A5': (420, 595), 'B5': (499, 709),
  };

  Widget _buildDocSettings(ColorScheme cs, _FileItem item) {
    const labelW = 78.0;
    // Office input → PDF: page range only (doc's own layout)
    // Image input → PDF: DPI + page size (FFmpeg rasterizes + sizes)
    final isOfficeInput = isOfficeDocument(item.path);
    final dims = _kPageDims[item.pdfPageSize] ?? _kPageDims['A4']!;

    return Column(children: [
      // Image→PDF: DPI slider
      if (!isOfficeInput) ...[
        SizedBox(height: 24, child: Row(children: [
          SizedBox(width: labelW, child: Text('DPI', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(180)))),
          Expanded(child: Slider(
            value: item.pdfDpi.toDouble(), min: 72, max: 300,
            divisions: (300 - 72) ~/ 6,
            activeColor: cs.primary, label: '${item.pdfDpi}',
            onChanged: _isConverting ? null : (v) => setState(() => item.pdfDpi = v.round()),
          )),
          SizedBox(width: 42, child: Text('${item.pdfDpi}', style: TextStyle(fontSize: 12, color: cs.primary, fontWeight: FontWeight.w600))),
        ])),
        const SizedBox(height: 4),
        // Image→PDF: Page size dropdown + dims
        SizedBox(height: 28, child: Row(children: [
          SizedBox(width: labelW, child: Text('Page', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(180)))),
          SizedBox(width: 120,
            child: DropdownButtonFormField<String>(
              value: item.pdfPageSize, isDense: true, isExpanded: true,
              decoration: _fieldDeco(),
              style: TextStyle(fontSize: 12, color: cs.onSurface),
              items: _pageSizes.map((s) => DropdownMenuItem(
                  value: s, child: Text(s, style: const TextStyle(fontSize: 12)))).toList(),
              onChanged: _isConverting ? null : (v) { if (v != null) setState(() => item.pdfPageSize = v); },
            ),
          ),
          const Spacer(),
          Text('${dims.$1}×${dims.$2}pt',
              style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(130))),
        ])),
        const SizedBox(height: 4),
      ],
      // ── PDF output: Pages + Rotate + Split + Reorder ──
      if (item.outputType == OutputType.pdf) ...[
        const SizedBox(height: 4),
        // Row 1: Pages | Rotate (equal halves)
        SizedBox(height: 28, child: Row(children: [
          // Col 1: Pages
          Expanded(child: Row(children: [
            SizedBox(width: labelW, child: Text('Pages', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(180)))),
            SizedBox(width: 120,
              child: DropdownButtonFormField<String>(
                value: item.pdfPageMode, isDense: true, isExpanded: true,
                decoration: _fieldDeco(),
                style: TextStyle(fontSize: 12, color: cs.onSurface),
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('All', style: TextStyle(fontSize: 12))),
                  DropdownMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(fontSize: 12))),
                  DropdownMenuItem(value: 'custom', child: Text('Custom', style: TextStyle(fontSize: 12))),
                ],
                onChanged: _isConverting ? null : (v) { if (v != null) setState(() => item.pdfPageMode = v); },
              ),
            ),
            if (item.pdfPageMode != 'all') ...[
              const SizedBox(width: 4),
              Expanded(child: TextFormField(
                initialValue: item.pdfPageRange,
                style: TextStyle(fontSize: 12, color: cs.onSurface),
                readOnly: _isConverting,
                decoration: _fieldDeco(hint: item.pdfPageMode == 'delete' ? 'del pages' : '1-9, 1,3-5'),
                onChanged: (v) => item.pdfPageRange = v,
              )),
            ],
          ])),
          const SizedBox(width: 10),
          // Col 2: Rotate
          Expanded(child: Row(children: [
            SizedBox(width: labelW, child: Text('Rotate', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(180)))),
            Expanded(child: DropdownButtonFormField<String>(
              value: item.pdfRotate, isDense: true, isExpanded: true,
              decoration: _fieldDeco(),
              style: TextStyle(fontSize: 12, color: cs.onSurface),
              items: const [
                DropdownMenuItem(value: '0', child: Text('Off', style: TextStyle(fontSize: 12))),
                DropdownMenuItem(value: '+90', child: Text('+90°', style: TextStyle(fontSize: 12))),
                DropdownMenuItem(value: '-90', child: Text('-90°', style: TextStyle(fontSize: 12))),
                DropdownMenuItem(value: '180', child: Text('180°', style: TextStyle(fontSize: 12))),
              ],
              onChanged: _isConverting ? null : (v) { if (v != null) setState(() => item.pdfRotate = v); },
            )),
            if (item.pdfRotate != '0') ...[
              const SizedBox(width: 4),
              Expanded(child: TextFormField(
                initialValue: item.pdfRotatePages,
                style: TextStyle(fontSize: 11, color: cs.onSurface),
                readOnly: _isConverting,
                decoration: _fieldDeco(hint: 'pages'),
                onChanged: (v) => setState(() => item.pdfRotatePages = v),
              )),
            ],
          ])),
        ])),
        const SizedBox(height: 4),
        // Row 2: Split | Reorder (equal halves)
        SizedBox(height: 28, child: Row(children: [
          // Col 1: Split
          Expanded(child: Row(children: [
            SizedBox(width: labelW, child: Text('Split', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(180)))),
            SizedBox(width: 120,
              child: DropdownButtonFormField<String>(
                value: item.pdfSplitPages == -1 ? 'cus' : '${item.pdfSplitPages}', isDense: true, isExpanded: true,
                decoration: _fieldDeco(),
                style: TextStyle(fontSize: 12, color: cs.onSurface),
                items: const [
                  DropdownMenuItem(value: '0', child: Text('Off', style: TextStyle(fontSize: 12))),
                  DropdownMenuItem(value: '1', child: Text('1', style: TextStyle(fontSize: 12))),
                  DropdownMenuItem(value: '2', child: Text('2', style: TextStyle(fontSize: 12))),
                  DropdownMenuItem(value: '5', child: Text('5', style: TextStyle(fontSize: 12))),
                  DropdownMenuItem(value: '10', child: Text('10', style: TextStyle(fontSize: 12))),
                  DropdownMenuItem(value: 'cus', child: Text('Custom', style: TextStyle(fontSize: 12))),
                ],
                onChanged: _isConverting ? null : (v) {
                  if (v == null) return;
                  if (v == 'cus') { setState(() { item.pdfSplitPages = -1; item.pdfSplitCustom = 3; }); }
                  else { setState(() => item.pdfSplitPages = int.tryParse(v) ?? 0); }
                },
              ),
            ),
            if (item.pdfSplitPages == -1) ...[
              const SizedBox(width: 4),
              SizedBox(width: 40, child: TextFormField(
                initialValue: '${item.pdfSplitCustom}',
                style: TextStyle(fontSize: 12, color: cs.onSurface),
                readOnly: _isConverting,
                keyboardType: TextInputType.number,
                decoration: _fieldDeco(hint: 'N'),
                onChanged: (v) => setState(() => item.pdfSplitCustom = int.tryParse(v) ?? 1),
              )),
              Text(' pp', style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(130))),
            ],
          ])),
          const SizedBox(width: 10),
          // Col 2: Reorder
          Expanded(child: Row(children: [
            SizedBox(width: labelW, child: Text('Reorder', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(180)))),
            Expanded(child: TextFormField(
              initialValue: item.pdfPageOrder,
              style: TextStyle(fontSize: 11, color: cs.onSurface),
              readOnly: _isConverting,
              decoration: _fieldDeco(hint: '1,3,5,2,4'),
              onChanged: (v) => setState(() => item.pdfPageOrder = v),
            )),
          ])),
        ])),
      ],
      // ── qpdf Advanced toggle ──
      const SizedBox(height: 8),
      SizedBox(height: 24, child: Row(children: [
        SizedBox(width: labelW, child: Text('Advanced', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(180)))),
        const Spacer(),
        Transform.scale(
          scale: 0.7,
          child: Switch(
            value: item.pdfAdvanced,
            onChanged: _isConverting ? null : (v) => setState(() => item.pdfAdvanced = v),
            activeTrackColor: cs.primary,
          ),
        ),
      ])),
      // ── qpdf post-processing (shown only when Advanced is on) ──
      if (item.pdfAdvanced) ...[
        const SizedBox(height: 6),
        _buildQpdfSettings(cs, item),
      ],
    ]);
  }

  // ═══════════════════════════════════════════════════════════
  //  qpdf post-processing settings (optimize / linearize / encrypt)
  // ═══════════════════════════════════════════════════════════

  Widget _buildQpdfSettings(ColorScheme cs, _FileItem item) {
    const labelW = 78.0;

    return Column(children: [
      // ── Advanced optimisation: 2 per row with descriptive labels ──
      Row(children: [
  Expanded(
    child: Column(children: [
      SizedBox(
        height: 22,
        child: _switchRowInline(
          cs,
          'Optimize',
          item.pdfOptimize,
          (v) => setState(() => item.pdfOptimize = v),
        ),
      ),
      const SizedBox(height: 2),
      SizedBox(
        height: 22,
        child: _switchRowInline(
          cs,
          'Linearize',
          item.pdfLinearize,
          (v) => setState(() => item.pdfLinearize = v),
        ),
      ),
    ]),
  ),
  const SizedBox(width: 12),
  Expanded(
    child: Column(children: [
      SizedBox(
        height: 22,
        child: _switchRowInline(
          cs,
          'Optimize images',
          item.pdfOptimizeImages,
          (v) => setState(() => item.pdfOptimizeImages = v),
        ),
      ),
      const SizedBox(height: 2),
      SizedBox(
        height: 22,
        child: _switchRowInline(
          cs,
          'Normalize',
          item.pdfNormalizeContent,
          (v) => setState(() => item.pdfNormalizeContent = v),
        ),
      ),
    ]),
  ),],),
      const SizedBox(height: 4),
      // ── Watermark / Underlay ──
      SizedBox(height: 28, child: Row(children: [
        SizedBox(width: labelW, child: Text('Watermark', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(180)))),
        Expanded(child: _pathField(cs, 'PDF path for overlay', item.pdfWatermarkPath,
            (v) => setState(() => item.pdfWatermarkPath = v))),
      ])),
      const SizedBox(height: 4),
      SizedBox(height: 28, child: Row(children: [
        SizedBox(width: labelW, child: Text('Underlay', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(180)))),
        Expanded(child: _pathField(cs, 'PDF path for background', item.pdfUnderlayPath,
            (v) => setState(() => item.pdfUnderlayPath = v))),
      ])),
      const SizedBox(height: 6),
      // ── Source PDF password (decrypt encrypted source) ──
      SizedBox(height: 28, child: Row(children: [
        SizedBox(width: labelW, child: Text('Src pwd', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(180)))),
        Expanded(child: _pwdField(cs, 'password for encrypted source PDF', item.pdfSourcePassword,
            (v) => setState(() => item.pdfSourcePassword = v))),
        const SizedBox(width: 4),
        SizedBox(width: 68, height: 28, child: OutlinedButton(
          style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, side: BorderSide(color: Colors.orangeAccent.withAlpha(180)), minimumSize: const Size(0, 28)),
          onPressed: (item.pdfSourcePassword.isEmpty || _isConverting) ? null : () => _decryptSourcePdf(item),
          child: const Text('Decrypt', style: TextStyle(fontSize: 10, color: Colors.orangeAccent)))),
      ])),
      const SizedBox(height: 6),
      // ── Encrypt ──
      SizedBox(height: 22, child: _switchRowInline(cs, 'Encrypt', item.pdfEncrypt,
          (v) => setState(() => item.pdfEncrypt = v))),
      if (item.pdfEncrypt) ...[
        const SizedBox(height: 4),
        Row(children: [
          Expanded(child: _pwdField(cs, 'User pwd (required)', item.pdfEncryptUserPassword,
              (v) => setState(() => item.pdfEncryptUserPassword = v))),
          const SizedBox(width: 6),
          Expanded(child: _pwdField(cs, 'Owner pwd (required)', item.pdfEncryptOwnerPassword,
              (v) => setState(() => item.pdfEncryptOwnerPassword = v))),
        ]),
        // Show warning if passwords are incomplete
        if (item.pdfEncryptUserPassword.isEmpty || item.pdfEncryptOwnerPassword.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('Both passwords are required for encryption',
                style: TextStyle(fontSize: 9, color: Colors.orangeAccent)),
          ),
        const SizedBox(height: 4),
        SizedBox(height: 28, child: Row(children: [
          SizedBox(width: labelW, child: Text('Key', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(180)))),
          SizedBox(width: 100,
            child: DropdownButtonFormField<String>(
              value: item.pdfEncryptKeyLength, isDense: true, isExpanded: true,
              decoration: _fieldDeco(),
              style: TextStyle(fontSize: 12, color: cs.onSurface),
              items: const [
                DropdownMenuItem(value: '128', child: Text('128-bit', style: TextStyle(fontSize: 12))),
                DropdownMenuItem(value: '256', child: Text('256-bit', style: TextStyle(fontSize: 12))),
              ],
              onChanged: _isConverting ? null : (v) { if (v != null) setState(() => item.pdfEncryptKeyLength = v); },
            ),
          ),
        ])),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: Column(children: [
            SizedBox(height: 22, child: _switchRowInline(cs, 'Allow print', item.pdfAllowPrint, (v) => setState(() => item.pdfAllowPrint = v))),
            const SizedBox(height: 4),
            SizedBox(height: 22, child: _switchRowInline(cs, 'Allow modify', item.pdfAllowModify, (v) => setState(() => item.pdfAllowModify = v))),
          ])),
          const SizedBox(width: 12),
          Expanded(child: Column(children: [
            SizedBox(height: 22, child: _switchRowInline(cs, 'Allow copy', item.pdfAllowCopy, (v) => setState(() => item.pdfAllowCopy = v))),
            const SizedBox(height: 4),
            SizedBox(height: 22, child: _switchRowInline(cs, 'Allow annotate', item.pdfAllowAnnotate, (v) => setState(() => item.pdfAllowAnnotate = v))),
          ])),
        ]),
      ],
    ]);
  }

  Future<void> _decryptSourcePdf(_FileItem item) async {
    final pwd = item.pdfSourcePassword;
    if (pwd.isEmpty) return;
    setState(() {});
    final dir = File(item.path).parent.path;
    final tmpPath = '$dir\\_xmate_decr_${DateTime.now().millisecondsSinceEpoch}.tmp';
    try {
      final result = await Process.run(
          _svc!.qpdfPath, ['--password=$pwd', '--decrypt', item.path, tmpPath],
          runInShell: true);
      // qpdf exit 0 = success, 3 = success with warnings (output valid)
      if (result.exitCode == 0 || result.exitCode == 3) {
        // Replace original with decrypted temp file (copy+delete for cross-drive safety)
        try {
          File(item.path).deleteSync();
          File(tmpPath).copySync(item.path);
          File(tmpPath).deleteSync();
        } catch (_) {
          try { File(tmpPath).copySync(item.path); File(tmpPath).deleteSync(); } catch (_) {}
        }
        item.pdfSourcePassword = '';
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Source PDF decrypted'),
            duration: Duration(milliseconds: 1200),
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.only(left: 16, bottom: 8, right: 500)));
        }
      } else {
        try { File(tmpPath).deleteSync(); } catch (_) {}
        final err = (result.stderr as String).trim();
        // Filter out non-error "WARNING" lines — only show actual errors
        final errLines = err.split('\n').where((l) => l.toLowerCase().contains('error') || l.toLowerCase().contains('invalid')).join('\n');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(errLines.isNotEmpty ? 'Decrypt failed: $errLines' : 'Decrypt failed — wrong password?'),
            duration: const Duration(milliseconds: 2000),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.only(left: 16, bottom: 8, right: 500)));
        }
      }
    } catch (e) {
      try { File(tmpPath).deleteSync(); } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Decrypt error: $e'),
          duration: const Duration(milliseconds: 2000),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.only(left: 16, bottom: 8, right: 500)));
      }
    }
  }

  /// A compact labeled switch row. Label area is fixed-width so all switches align vertically.
  Widget _switchRowInline(ColorScheme cs, String label, bool value, ValueChanged<bool> onChanged, {String? hint}) {
    return Row(children: [
      SizedBox(
        width: 110,
        child: RichText(
          text: TextSpan(children: [
            TextSpan(text: label, style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(180))),
            if (hint != null)
              TextSpan(text: '  $hint', style: TextStyle(fontSize: 8, color: cs.onSurface.withAlpha(90))),
          ]),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      ),
      const Spacer(),
      Transform.scale(
        scale: 0.7,
        child: Switch(
          value: value,
          onChanged: _isConverting ? null : onChanged,
          activeTrackColor: cs.primary,
        ),
      ),
    ]);
  }

  Widget _pwdField(ColorScheme cs, String hint, String value, ValueChanged<String> onChanged) {
    return TextFormField(
      initialValue: value,
      style: TextStyle(fontSize: 12, color: cs.onSurface),
      readOnly: _isConverting,
      decoration: _fieldDeco(hint: hint),
      onChanged: onChanged,
    );
  }

  Widget _pathField(ColorScheme cs, String hint, String value, ValueChanged<String> onChanged) {
    return Row(children: [
      Expanded(child: TextFormField(
        initialValue: value,
        style: TextStyle(fontSize: 11, color: cs.onSurface),
        readOnly: _isConverting,
        decoration: _fieldDeco(hint: hint),
        onChanged: onChanged,
      )),
      const SizedBox(width: 4),
      GestureDetector(
        onTap: _isConverting
            ? null
            : () async {
                final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
                if (r != null && r.files.single.path != null) {
                  onChanged(r.files.single.path!);
                  setState(() {});
                }
              },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            color: _isConverting ? cs.onSurface.withAlpha(20) : XMateColors.highlight(context),
          ),
          child: Icon(Icons.folder_open, size: 16,
              color: _isConverting ? cs.onSurface.withAlpha(60) : cs.primary),
        ),
      ),
    ]);
  }

  // ═══════════════════════════════════════════════════════════
  //  Custom Command
  // ═══════════════════════════════════════════════════════════

  Widget _buildCustomCommand(ColorScheme cs, _FileItem item) {
    return Row(children: [
      SizedBox(height: 28, child: Transform.scale(
        scale: 0.7,
        child: Switch(
          value: item.customCmdEnabled,
          onChanged: _isConverting ? null : (v) => setState(() => item.customCmdEnabled = v),
          activeTrackColor: cs.primary,
        ),
      )),
      if (item.customCmdEnabled)
        Expanded(child: TextFormField(
          initialValue: item.customCmd,
          style: TextStyle(fontSize: 12, color: cs.onSurface),
          readOnly: _isConverting,
          decoration: _fieldDeco(hint: 'Extra args, e.g. -af "volume=2"'),
          onChanged: (v) => item.customCmd = v,
        ))
      else
        Text('Custom',
            style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(150))),
    ]);
  }

  // ═══════════════════════════════════════════════════════════
  //  Trim — RangeSlider with start / end time labels only
  // ═══════════════════════════════════════════════════════════

  int? _parseTimeToSec(String t) {
    final m = RegExp(r'^(\d+):(\d+):(\d+)').firstMatch(t.trim());
    if (m == null) return null;
    return int.parse(m.group(1)!) * 3600 + int.parse(m.group(2)!) * 60 + int.parse(m.group(3)!);
  }

  Widget _buildTrim(ColorScheme cs, _FileItem item, int? totalDuration) {
    final dur = totalDuration ?? 0;
    if (dur <= 0) return const SizedBox.shrink();

    final startSec = _parseTimeToSec(item.trimStart.isEmpty ? '00:00:00' : item.trimStart) ?? 0;
    final endSec = _parseTimeToSec(item.trimEnd) ?? dur;
    final showSpeed = item.outputType.supportsSpeed;

    return Column(children: [
      // Time labels row: start left, speed dropdown center, end right
      Row(children: [
        Text(_secToHms(startSec),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.primary)),
        const Spacer(),
        if (showSpeed) ...[
          _speedDropdown(cs, item),
          const Spacer(),
        ],
        Text(_secToHms(endSec),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.primary)),
      ]),
      const SizedBox(height: 2),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(trackHeight: 3),
        child: RangeSlider(
          values: RangeValues(startSec.toDouble().clamp(0, dur.toDouble()),
              endSec.toDouble().clamp(0, dur.toDouble())),
          min: 0, max: dur.toDouble(),
          activeColor: cs.primary,
          inactiveColor: cs.primary.withAlpha(40),
          onChanged: _isConverting ? null : (v) {
            setState(() {
              item.trimStart = _secToHms(v.start.round());
              item.trimEnd = _secToHms(v.end.round());
            });
          },
        ),
      ),
    ]);
  }

  String _secToHms(int total) {
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  static const _speedOptions = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  Widget _speedDropdown(ColorScheme cs, _FileItem item) {
    return SizedBox(
      height: 24,
      child: DropdownButton<double>(
        value: _snapSpeed(item.speedMultiplier),
        isDense: true,
        underline: const SizedBox.shrink(),
        style: TextStyle(fontSize: 11, color: cs.primary, fontWeight: FontWeight.w600),
        selectedItemBuilder: (_) => _speedOptions.map((s) {
          return Center(
            child: Text('${s.toStringAsFixed(s == 1.0 ? 1 : 2)}×',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.primary)),
          );
        }).toList(),
        items: _speedOptions.map((s) => DropdownMenuItem(
          value: s,
          child: Text('${s.toStringAsFixed(s == 1.0 ? 1 : 2)}×',
              style: TextStyle(fontSize: 11, fontWeight: s == 1.0 ? FontWeight.w600 : FontWeight.normal)),
        )).toList(),
        onChanged: _isConverting ? null : (v) {
          if (v != null) setState(() => item.speedMultiplier = v);
        },
      ),
    );
  }

  /// Snap [v] to nearest predefined speed option.
  double _snapSpeed(double v) {
    double best = 1.0;
    double bestDist = (v - 1.0).abs();
    for (final o in _speedOptions) {
      final d = (v - o).abs();
      if (d < bestDist) { best = o; bestDist = d; }
    }
    return best;
  }

  // ── Mini radio ──

  Widget _miniRadio<T>({
    required T value, required T groupValue, required String label,
    required ValueChanged<T>? onChanged, required ColorScheme cs,
  }) {
    final selected = value == groupValue;
    return GestureDetector(
      onTap: onChanged != null ? () => onChanged(value) : null,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 14, height: 14, margin: const EdgeInsets.only(right: 3),
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(
            color: selected ? cs.primary : cs.onSurface.withAlpha(100),
            width: selected ? 2 : 1,
          )),
          child: selected ? Center(child: Container(width: 6, height: 6,
              decoration: BoxDecoration(shape: BoxShape.circle, color: cs.primary))) : null,
        ),
        Text(label, style: TextStyle(
          fontSize: 11, color: selected ? cs.primary : cs.onSurface.withAlpha(150),
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        )),
      ]),
    );
  }

  // ── Setting row ──

  Widget _settingRow(ColorScheme cs,
      {required String label, required Widget child}) {
    return Row(children: [
      SizedBox(width: 78, child: Text(label,
          style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(180)))),
      Expanded(child: child),
    ]);
  }

  InputDecoration _fieldDeco({String? hint, String? suffix}) {
    final cs = Theme.of(context).colorScheme;
    return InputDecoration(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
      hintText: hint,
      hintStyle: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(80)),
      suffixText: suffix,
      suffixStyle: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(120)),
    );
  }

  // ── Part 4: Bottom bar ─────────────────────────────────────

  Widget _bottomBar(ColorScheme cs, bool isConverting) {
    final canCombine = _canCombine;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      decoration: const BoxDecoration(
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
      ),
      child: Row(children: [
        // Combine checkbox
        Container(
          height: 28,
          padding: const EdgeInsets.only(right: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: 18, height: 18,
              child: Checkbox(
                value: _combineEnabled,
                onChanged: (canCombine && !isConverting)
                    ? (v) => setState(() {
                        _combineEnabled = v ?? false;
                        if (_combineEnabled) _syncCombineSettings();
                      })
                    : null,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                activeColor: cs.primary,
              ),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: (canCombine && !isConverting)
                  ? () => setState(() {
                      _combineEnabled = !_combineEnabled;
                      if (_combineEnabled) _syncCombineSettings();
                    })
                  : null,
              child: Text('Combine',
                  style: TextStyle(
                      fontSize: 12,
                      color: canCombine
                          ? cs.onSurface.withAlpha(200)
                          : cs.onSurface.withAlpha(60))),
            ),
          ]),
        ),
        Expanded(
          child: ElevatedButton.icon(
            onPressed:
                (_fileItems.isEmpty || isConverting) ? null : _startConversion,
            icon: Icon(_combineEnabled ? Icons.merge : Icons.swap_horiz, size: 16),
            label: Text(isConverting
                ? 'Converting…'
                : _combineEnabled
                    ? 'Convert & Combine'
                    : 'Start Convert'),
            style: ElevatedButton.styleFrom(
              backgroundColor: cs.primary,
              foregroundColor: cs.onPrimary,
              disabledBackgroundColor: cs.primary.withAlpha(80),
              disabledForegroundColor: cs.onPrimary.withAlpha(150),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        if (isConverting) ...[
          const SizedBox(width: 12),
          TextButton(
            onPressed: _cancelAll,
            child:
                Text('Cancel All', style: TextStyle(color: cs.error, fontSize: 13)),
          ),
        ],
      ]),
    );
  }
}
