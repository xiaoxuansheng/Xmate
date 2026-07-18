/// LibreTranslate server process lifecycle manager.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/settings/settings_service.dart';
import 'python_service.dart';

enum ServerState {
  unknown, notInstalled, stopped, starting, running, stopping, error,
}

class ServerManager {
  static final ServerManager _instance = ServerManager._();
  factory ServerManager() => _instance;
  ServerManager._();

  final _stateCtrl = StreamController<ServerState>.broadcast();
  Stream<ServerState> get onStateChanged => _stateCtrl.stream;

  ServerState _state = ServerState.unknown;
  ServerState get state => _state;

  Process? _process;
  Timer? _healthTimer;
  String _lastError = '';
  final List<String> _outputLines = [];
  String? _cachedPy;

  String get lastError => _lastError;

  String get host {
    final url = _resolveUrl();
    try { final uri = Uri.parse(url); return uri.host.isNotEmpty ? uri.host : '127.0.0.1'; } catch (_) { return '127.0.0.1'; }
  }

  int get port {
    final url = _resolveUrl();
    try { final uri = Uri.parse(url); return uri.hasPort ? uri.port : 5000; } catch (_) { return 5000; }
  }

  String get baseUrl {
    final u = _resolveUrl();
    return u.endsWith('/') ? u.substring(0, u.length - 1) : u;
  }

  String _resolveUrl() => _settings.get('translate.serverUrl') as String? ?? 'http://localhost:5000';
  final _settings = SettingsService();

  void _setState(ServerState s, {String error = ''}) {
    _lastError = error;
    if (_state != s) { _state = s; _stateCtrl.add(s); }
  }

  /// Sync python path — scans known install locations.
  /// Cached after first call. Async `_ensurePy()` prefills it.
  String get pythonPath {
    if (_cachedPy != null) return _cachedPy!;
    // Fast synchronous scan of common paths
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final progFiles = Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    for (final ver in ['Python312', 'Python311', 'Python310', 'Python3']) {
      // winget install location
      final p1 = '$localAppData\\Programs\\Python\\$ver\\python.exe';
      if (File(p1).existsSync()) { _cachedPy = p1; return p1; }
      // official installer location
      final p2 = '$progFiles\\Python\\$ver\\python.exe';
      if (File(p2).existsSync()) { _cachedPy = p2; return p2; }
      // root of C: drive
      final p3 = 'C:\\$ver\\python.exe';
      if (File(p3).existsSync()) { _cachedPy = p3; return p3; }
    }
    return 'python';
  }

  /// Ensure pythonPath cache is populated via async detection.
  Future<void> _ensurePy() async {
    if (_cachedPy != null) return;
    final info = await PythonService.detect();
    if (info.exePath != null) _cachedPy = info.exePath;
  }

  String get libretranslatePath {
    // 1. Try <python_dir>\Scripts\libretranslate.exe (most common)
    final py = pythonPath;
    if (py.endsWith('python.exe')) {
      final scriptsDir = '${File(py).parent.path}\\Scripts';
      final exe = '$scriptsDir\\libretranslate.exe';
      if (File(exe).existsSync()) return exe;
    }

    // 2. Scan common winget / official Python install locations
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    for (final ver in ['Python312', 'Python311', 'Python310', 'Python3']) {
      final exe = '$localAppData\\Programs\\Python\\$ver\\Scripts\\libretranslate.exe';
      if (File(exe).existsSync()) return exe;
    }

    // 3. Fall back to PATH — libretranslate.exe must be on %PATH%
    return 'libretranslate';
  }

  Future<bool> isInstalled() async {
    try {
      final result = await Process.run(libretranslatePath, ['--help'], runInShell: true);
      return result.exitCode == 0;
    } catch (_) { return false; }
  }

  Future<bool> adoptIfRunning() async {
    if (await _healthCheck()) { _setState(ServerState.running); _startHealthPolling(); return true; }
    return false;
  }

  Future<void> start({String? loadOnly}) async {
    if (_state == ServerState.running || _state == ServerState.starting) return;
    if (await _healthCheck()) { _setState(ServerState.running); _startHealthPolling(); return; }

    _setState(ServerState.starting);
    await _ensurePy();

    try {
      final args = <String>[
        '--host', host, '--port', port.toString(), '--disable-web-ui',
      ];
      if (loadOnly != null && loadOnly.isNotEmpty) args.addAll(['--load-only', loadOnly]);

      _process = await Process.start(libretranslatePath, args,
          mode: ProcessStartMode.normal, runInShell: true);
      _process!.stdout.transform(utf8.decoder).listen((s) {});
      _process!.stderr.transform(utf8.decoder).listen((s) {
        _outputLines.add('[stderr] $s');
      });

      await _writePidFile(_process!.pid);
      final ok = await _waitForReady(timeout: const Duration(seconds: 30));
      if (ok) {
        _setState(ServerState.running);
        _startHealthPolling();
      } else {
        _setState(ServerState.error,
            error: 'Server failed to respond within 30s');
        await _forceKill();
      }
    } catch (e) {
      _setState(ServerState.error, error: 'Failed to start: $e');
    }
  }

  Future<void> stop() async {
    if (_state == ServerState.stopped || _state == ServerState.stopping) return;
    _setState(ServerState.stopping);
    _healthTimer?.cancel(); _healthTimer = null;
    await _gracefulKill();
    await _deletePidFile();
    _setState(ServerState.stopped);
  }

  Future<bool> _healthCheck() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/languages')).timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (_) { return false; }
  }

  void _startHealthPolling() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      final ok = await _healthCheck();
      if (!ok && _state == ServerState.running) { _setState(ServerState.error, error: 'Server stopped responding'); _healthTimer?.cancel(); }
      else if (ok && _state == ServerState.error) { _setState(ServerState.running); }
    });
  }

  Future<bool> _waitForReady({Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _healthCheck()) return true;
      await Future.delayed(const Duration(milliseconds: 800));
    }
    return false;
  }

  Future<void> _writePidFile(int pid) async {
    try {
      final dir = await getApplicationSupportDirectory();
      await File('${dir.path}/xmate/server_pid.txt').writeAsString('$pid\n$host\n$port');
    } catch (_) {}
  }

  Future<void> _deletePidFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/xmate/server_pid.txt');
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _gracefulKill() async {
    if (_process == null) return;
    _process!.kill(ProcessSignal.sigterm);
    await Future.delayed(const Duration(seconds: 2));
    try { await Process.run('taskkill', ['/F', '/PID', _process!.pid.toString()], runInShell: true); } catch (_) {}
    _process = null;
  }

  Future<void> _forceKill() async {
    if (_process == null) return;
    try { await Process.run('taskkill', ['/F', '/PID', _process!.pid.toString()], runInShell: true); } catch (_) {}
    _process = null;
  }

  Future<void> dispose() async {
    _healthTimer?.cancel();
    _stateCtrl.close();
  }
}
