/// Python detection and installation service.
///
/// On Windows, Python is installed via winget (built-in on Win10 1709+).
/// The flow:
///   1. Scan known install paths for a working python.exe
///   2. Verify it's real (not the Microsoft Store stub)
///   3. If not found, offer to install via winget
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Result of a Python detection scan.
class PythonInfo {
  final bool found;
  final String? exePath; // e.g. C:\Users\...\Python312\python.exe
  final String? version; // e.g. "3.12.10"

  const PythonInfo({required this.found, this.exePath, this.version});

  factory PythonInfo.notFound() => const PythonInfo(found: false);
}

class PythonService {
  static final PythonService _instance = PythonService._();
  factory PythonService() => _instance;
  PythonService._();

  // ── Detection ──────────────────────────────────────────────────

  /// Find a working Python executable, excluding the Windows Store stub.
  static Future<PythonInfo> detect() async {
    // 1. Scan known install paths (winget, official installer, embedded)
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final programFiles = Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final programFilesX86 = Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';

    final candidates = <String>[
      // winget install location (most common)
      '$localAppData\\Programs\\Python\\Python312\\python.exe',
      '$localAppData\\Programs\\Python\\Python311\\python.exe',
      '$localAppData\\Programs\\Python\\Python310\\python.exe',
      // official installer locations
      r'C:\Python312\python.exe',
      r'C:\Python311\python.exe',
      r'C:\Python310\python.exe',
      r'C:\Python3\python.exe',
      '$programFiles\\Python312\\python.exe',
      '$programFiles\\Python311\\python.exe',
      '$programFiles\\Python310\\python.exe',
      '$programFilesX86\\Python312\\python.exe',
      '$programFilesX86\\Python311\\python.exe',
    ];

    for (final p in candidates) {
      if (File(p).existsSync()) {
        final info = await _verify(p);
        if (info != null) return info;
      }
    }

    // 2. Try 'python' on PATH (but filter out Store stub)
    try {
      final result = await Process.run('python', ['--version'], runInShell: true);
      if (result.exitCode == 0) {
        final v = (result.stdout as String).trim();
        if (v.startsWith('Python ') && !v.contains('Microsoft Store')) {
          // Resolve full path so callers can derive Scripts/ etc.
          String? exePath;
          try {
            final whereResult = await Process.run('where', ['python'], runInShell: true);
            if (whereResult.exitCode == 0) {
              final lines = (whereResult.stdout as String).trim().split('\n');
              if (lines.isNotEmpty && lines.first.trim().isNotEmpty) {
                exePath = lines.first.trim();
              }
            }
          } catch (_) {}
          // Fallback: ask Python itself
          exePath ??= await _queryPythonExecutable();
          return PythonInfo(found: true, exePath: exePath, version: v.replaceFirst('Python ', ''));
        }
      }
    } catch (_) {}

    return PythonInfo.notFound();
  }

  /// Verify a python.exe is real (not Win Store stub) by running --version.
  static Future<PythonInfo?> _verify(String path) async {
    try {
      final result = await Process.run(path, ['--version'], runInShell: true);
      if (result.exitCode != 0) return null;
      final v = (result.stdout as String).trim();
      // Windows Store stub outputs something like "Python was not found..."
      if (v.startsWith('Python ') && !v.contains('Microsoft Store') && !v.contains('not found')) {
        return PythonInfo(found: true, exePath: path, version: v.replaceFirst('Python ', ''));
      }
    } catch (_) {}
    return null;
  }

  /// Ask the Python interpreter for its own executable path.
  /// Works regardless of whether python is on PATH or installed
  /// in a nonstandard location.
  static Future<String?> _queryPythonExecutable() async {
    try {
      final result = await Process.run(
        'python', ['-c', 'import sys; print(sys.executable)'],
        runInShell: true,
      );
      if (result.exitCode == 0) {
        final path = (result.stdout as String).trim();
        if (path.isNotEmpty && File(path).existsSync()) return path;
      }
    } catch (_) {}
    return null;
  }

  // ── Installation ───────────────────────────────────────────────

  /// Check if winget is available for Python installation.
  static Future<bool> get canInstall async {
    try {
      final result = await Process.run('winget', ['--version'], runInShell: true);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Install Python 3.12 via winget.
  /// Streams progress lines via [onLog].
  /// Returns true on success.
  static Future<bool> install({void Function(String line)? onLog}) async {
    try {
      onLog?.call('Installing Python 3.12 via winget...');
      onLog?.call('This may take a few minutes depending on download speed.');

      final proc = await Process.start(
        'winget',
        [
          'install',
          '--id', 'Python.Python.3.12',
          '--silent',
          '--accept-package-agreements',
          '--accept-source-agreements',
        ],
        mode: ProcessStartMode.normal,
        runInShell: true,
      );

      // Drain output
      final sub1 = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (line.trim().isNotEmpty) onLog?.call(line);
      });
      final sub2 = proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (line.trim().isNotEmpty) onLog?.call('[winget] $line');
      });

      final exitCode = await proc.exitCode;
      await sub1.cancel();
      await sub2.cancel();

      if (exitCode != 0) {
        onLog?.call('Python installation failed (exit $exitCode)');
        // winget exit codes: 0=success, other=fail/-1=admin required
        if (exitCode == -1978335189 || exitCode == -1) {
          onLog?.call('Hint: winget may require running as admin.');
          onLog?.call('Try: winget install --id Python.Python.3.12 --silent');
        }
        return false;
      }

      // Verify installation
      onLog?.call('Python installed. Verifying...');
      final info = await detect();
      if (info.found) {
        onLog?.call('Python ${info.version} detected at ${info.exePath}');
        return true;
      } else {
        onLog?.call('Python installation completed but could not be detected.');
        onLog?.call('Try restarting XMate and checking Settings → Plugins → Translate.');
        return false;
      }
    } catch (e) {
      onLog?.call('Installation error: $e');
      return false;
    }
  }
}
