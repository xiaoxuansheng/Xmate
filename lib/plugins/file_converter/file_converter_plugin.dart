/// XMate File Converter plugin — FFmpeg-based file format conversion.
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../../core/plugin/plugin_base.dart';
import '../../core/settings/settings_service.dart';
import '../../app.dart';

class FileConverterPlugin extends XMatePlugin {
  @override
  String get id => 'file_converter';

  @override
  String get name => 'File Converter';

  @override
  String get description => 'Convert files between formats via FFmpeg';

  @override
  IconData get icon => Icons.swap_horiz;

  @override
  Map<String, HotKeyDef> get defaultHotKeys => {};

  @override
  List<CommandItem> get commands => [
        CommandItem(
          id: 'file_converter.activate',
          text: 'File Converter',
          aliases: [
            'fileconverter',
            'convert',
            'converter',
            '转换',
            '格式转换',
            '文件转换',
            'transcode'
          ],
          description: 'Convert files between formats',
          icon: Icons.swap_horiz,
          onExecute: activate,
        ),
      ];

  // ── Settings (shared with QuickLook plugin settings page) ──

  String get ffmpegPath {
    // First check File Converter's own setting
    final s = SettingsService();
    final own = s.get('file_converter.ffmpegPath') as String?;
    if (own != null && own.isNotEmpty && File(own).existsSync()) return own;

    // Fall back to screenrecording's ffmpeg path (existing installs)
    final srPath = s.get('screenrecording.ffmpegPath') as String?;
    if (srPath != null && srPath.isNotEmpty && File(srPath).existsSync()) {
      return srPath;
    }

    // Fall back: same directory as the executable (mirrors C# behaviour)
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = '$exeDir\\ffmpeg.exe';
    if (File(bundled).existsSync()) return bundled;

    return 'ffmpeg.exe'; // Final fallback: PATH
  }

  String get defaultOutputDir =>
      SettingsService().get('file_converter.defaultOutputDir') as String? ??
      '${Platform.environment['USERPROFILE'] ?? '.'}\\Documents';

  // ── No standalone settings page — merged into QuickLook plugin settings. ──
  @override
  Widget? get settingsPage => null;

  // ── Lifecycle ──

  @override
  Future<void> onInit(PluginContext context) async {}

  @override
  Future<void> onDispose() async {}

  // ── Activation ──

  void activate() {
    // Spawn file converter as independent process.
    appKey.currentState?.invalidateWindowOps();

    windowManager.hide().then((_) async {
      await Future.delayed(const Duration(milliseconds: 100));
      try {
        await Process.start(
            Platform.resolvedExecutable, ['--fileconverter'],
            mode: ProcessStartMode.detached);
      } catch (_) {}
    });
  }
}
