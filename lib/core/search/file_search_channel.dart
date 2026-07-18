/// XMate File Search -- MethodChannel wrapper for C++ file scanner + USN.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

class FileSearchChannel {
  static const _channel = MethodChannel('com.xmate/filesearch');

  // -- Async request tracking (C++ background thread results) --------

  static int _nextRequestId = 0;
  static final _pendingScans = <int, Completer<List<Map<String, dynamic>>>>{};
  static final _pendingUsnQueries = <int, Completer<Map<String, dynamic>>>{};
  static bool _handlerRegistered = false;

  static void _ensureHandler() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'scanResult') {
        final args = call.arguments as Map;
        final rid = args['requestId'] as int;
        final json = args['result'] as String;
        final c = _pendingScans.remove(rid);
        if (c != null && !c.isCompleted) {
          if (json == '[]') {
            c.complete([]);
          } else {
            final list = jsonDecode(json) as List<dynamic>;
            c.complete(list.cast<Map<String, dynamic>>());
          }
        }
      } else if (call.method == 'usnResult') {
        final args = call.arguments as Map;
        final rid = args['requestId'] as int;
        final json = args['result'] as String;
        final c = _pendingUsnQueries.remove(rid);
        if (c != null && !c.isCompleted) {
          if (json == '{}' || json.isEmpty) {
            c.complete({});
          } else {
            c.complete(jsonDecode(json) as Map<String, dynamic>);
          }
        }
      }
    });
  }

  // -- Sync methods (keep for fast operations) -----------------------

  /// Scan [rootPath] recursively using native FindFirstFileW.
  Future<List<Map<String, dynamic>>> scanDirectory(String rootPath) async {
    try {
      final json = await _channel.invokeMethod<String>('scanDirectory', {
        'rootPath': rootPath,
      });
      if (json == null || json == '[]') return [];
      final list = jsonDecode(json) as List<dynamic>;
      return list.cast<Map<String, dynamic>>();
    } catch (e) {
      return [];
    }
  }

  /// Same as scanDirectory but runs on a C++ background thread.
  /// The UI remains responsive during the scan.
  ///
  /// Returns empty list on timeout (5 minutes) or if the C++ thread
  /// fails to call back.  The caller ([rebuildPath]) handles empty
  /// results by showing "No files found".
  Future<List<Map<String, dynamic>>> scanDirectoryAsync(String rootPath) async {
    _ensureHandler();
    final requestId = _nextRequestId++;
    final completer = Completer<List<Map<String, dynamic>>>();
    _pendingScans[requestId] = completer;

    try {
      await _channel.invokeMethod('scanDirectoryAsync', {
        'rootPath': rootPath,
        'requestId': requestId,
      });
    } catch (_) {
      _pendingScans.remove(requestId);
      if (!completer.isCompleted) completer.complete([]);
    }

    // Guard against C++ thread failures — the scan runs on a detached
    // std::thread and may never call back if the thread crashes or the
    // path is inaccessible.  5 minutes is generous for even the largest
    // directory trees.
    return completer.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        _pendingScans.remove(requestId);
        return [];
      },
    );
  }

  /// Query USN journal for changes since [lastUsnId].
  /// Returns:
  ///   {"nextUsn": `&lt;int&gt;`, "dirty": `&lt;bool&gt;`}
  /// On error/unavailable, returns {"nextUsn": 0, "dirty": false}.
  Future<Map<String, dynamic>> queryUsn(
      String rootPath, int lastUsnId) async {
    try {
      final json = await _channel.invokeMethod<String>('queryUsn', {
        'rootPath': rootPath,
        'lastUsnId': lastUsnId,
      });
      if (json == null || json == '{}') return {};
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (e) {
      return {};
    }
  }

  /// Query USN journal with directory resolution.
  /// Returns dirtyDirs (parent dirs of changed files) and deletedDirs
  /// (whole directories that were deleted) relative to rootPath.
  Future<Map<String, dynamic>> queryUsnWithDirs(
      String rootPath, int lastUsnId) async {
    try {
      final json = await _channel.invokeMethod<String>('queryUsnWithDirs', {
        'rootPath': rootPath,
        'lastUsnId': lastUsnId,
      });
      if (json == null || json == '{}') return {};
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (e) {
      return {};
    }
  }

  /// Same as queryUsnWithDirs but runs on a C++ background thread.
  Future<Map<String, dynamic>> queryUsnWithDirsAsync(
      String rootPath, int lastUsnId) async {
    _ensureHandler();
    final requestId = _nextRequestId++;
    final completer = Completer<Map<String, dynamic>>();
    _pendingUsnQueries[requestId] = completer;

    try {
      await _channel.invokeMethod('queryUsnWithDirsAsync', {
        'rootPath': rootPath,
        'lastUsnId': lastUsnId,
        'requestId': requestId,
      });
    } catch (_) {
      _pendingUsnQueries.remove(requestId);
      completer.complete({});
    }

    return completer.future;
  }

  /// Retrieve the system small icon for [filePath] as PNG bytes.
  /// Uses SHGetFileInfoW via the native method channel.
  Future<Uint8List?> getFileIcon(String filePath) async {
    try {
      final result = await _channel.invokeMethod('getFileIcon', {'path': filePath});
      if (result is Uint8List && result.isNotEmpty) return result;
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Pick a file using native COM IFileOpenDialog.
  Future<String?> pickFile() async {
    try {
      final path = await _channel.invokeMethod<String>('pickFile');
      if (path != null && path.isNotEmpty) return path.replaceAll('\\', '/');
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Pick a folder using native COM IFileOpenDialog.
  Future<String?> pickFolder() async {
    try {
      final json = await _channel.invokeMethod<String>('pickFolder');
      return json;
    } catch (e) {
      return null;
    }
  }

  // -- Indexer Service management (via com.xmate/fileops) ---------------

  static const _svcChannel = MethodChannel('com.xmate/fileops');

  Future<bool> installIndexerService() async {
    try {
      final r = await _svcChannel.invokeMethod<bool>('installIndexerService');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> uninstallIndexerService() async {
    try {
      final r = await _svcChannel.invokeMethod<bool>('uninstallIndexerService');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> startIndexerService() async {
    try {
      final r = await _svcChannel.invokeMethod<bool>('startIndexerService');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> stopIndexerService() async {
    try {
      await _svcChannel.invokeMethod('stopIndexerService');
    } catch (_) {}
  }

  Future<bool> isIndexerServiceInstalled() async {
    try {
      final r = await _svcChannel.invokeMethod<bool>('isIndexerServiceInstalled');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isIndexerServiceRunning() async {
    try {
      final r = await _svcChannel.invokeMethod<bool>('isIndexerServiceRunning');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> writeIndexerConfig(List<String> paths, int intervalSec) async {
    try {
      await _svcChannel.invokeMethod('writeIndexerConfig', {
        'paths': paths,
        'intervalSec': intervalSec,
      });
    } catch (_) {}
  }

  /// Read USN result from the indexer service (JSON string or empty).
  Future<String?> readUsnResult(String hash) async {
    try {
      final r = await _svcChannel.invokeMethod<String>('readUsnResult', {
        'hash': hash,
      });
      return r;
    } catch (_) {
      return null;
    }
  }
}
