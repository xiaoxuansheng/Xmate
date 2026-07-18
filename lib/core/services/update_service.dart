/// XMate Update Service
///
/// Checks GitHub Releases for new versions and downloads installer updates.
/// Uses GitHub REST API without authentication (60 req/hr — sufficient for
/// periodic update checks with 5-minute caching).
///
/// Configure [_githubOwner] and [_githubRepo] before use.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../settings/settings_service.dart';
import '../utils/logger.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Configuration — fill in your GitHub username and repo name
// ═══════════════════════════════════════════════════════════════════════════

const _githubOwner = 'xiaoxuansheng'; // TODO: replace with actual username
const _githubRepo = 'Xmate';                 // TODO: replace with actual repo name

// ═══════════════════════════════════════════════════════════════════════════

/// Result of an update check.
enum UpdateStatus {
  /// Still checking the remote API.
  checking,

  /// Local version >= remote version — no update needed.
  upToDate,

  /// A newer version is available on GitHub.
  updateAvailable,

  /// Failed to check (network error, rate limit, etc.) — silently degrade.
  error,
}

class UpdateCheckResult {
  final UpdateStatus status;
  final String? latestVersion; // e.g. "3.3.2"
  final String? downloadUrl;   // installer asset URL
  final String? releaseUrl;    // GitHub release page URL (fallback)
  final String? errorMessage;

  const UpdateCheckResult({
    required this.status,
    this.latestVersion,
    this.downloadUrl,
    this.releaseUrl,
    this.errorMessage,
  });

  /// Convenience: still checking.
  static const checking = UpdateCheckResult(status: UpdateStatus.checking);

  /// Convenience: no update available.
  static const upToDate = UpdateCheckResult(status: UpdateStatus.upToDate);

  /// Convenience: error occurred.
  static UpdateCheckResult error(String msg) =>
      UpdateCheckResult(status: UpdateStatus.error, errorMessage: msg);
}

class UpdateService {
  static final UpdateService _instance = UpdateService._();
  factory UpdateService() => _instance;
  UpdateService._();

  static const _cacheMaxAge = Duration(minutes: 5);

  static const _kCheckTimestamp = 'app.update.last_check';
  static const _kCachedVersion = 'app.update.cached_version';
  static const _kCachedDownloadUrl = 'app.update.cached_download_url';
  static const _kCachedReleaseUrl = 'app.update.cached_release_url';

  String get _apiUrl =>
      'https://api.github.com/repos/$_githubOwner/$_githubRepo/releases/latest';

  final _settings = SettingsService();

  // ── Public API ──────────────────────────────────────────────────────────

  /// Check GitHub for a newer version.
  ///
  /// [localVersion] is the current app version (e.g. "3.3.1"), read from
  /// the bundled pubspec.yaml asset by the caller.
  ///
  /// Results are cached for 5 minutes to avoid hitting GitHub's rate limit
  /// (60 req/hr unauthenticated). Call [forceCheck] to bypass the cache.
  Future<UpdateCheckResult> checkForUpdate(String localVersion,
      {bool force = false}) async {
    // ── Cache check ──
    if (!force) {
      final lastCheck = _settings.get(_kCheckTimestamp);
      if (lastCheck is int) {
        final age = DateTime.now().difference(
          DateTime.fromMillisecondsSinceEpoch(lastCheck),
        );
        if (age < _cacheMaxAge) {
          final cachedVersion =
              _settings.getWithDefault<String?>(_kCachedVersion, null);
          final cachedDownloadUrl =
              _settings.getWithDefault<String?>(_kCachedDownloadUrl, null);
          final cachedReleaseUrl =
              _settings.getWithDefault<String?>(_kCachedReleaseUrl, null);

          if (cachedVersion != null) {
            if (_compareVersions(cachedVersion, localVersion) > 0) {
              return UpdateCheckResult(
                status: UpdateStatus.updateAvailable,
                latestVersion: cachedVersion,
                downloadUrl: cachedDownloadUrl,
                releaseUrl: cachedReleaseUrl,
              );
            }
            return UpdateCheckResult.upToDate;
          }
        }
      }
    }

    // ── Fetch from GitHub ──
    try {
      final response = await http
          .get(Uri.parse(_apiUrl), headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'XMate-UpdateChecker/1.0',
          })
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 403) {
        // Rate limited — log and silently fail
        logger.warn('GitHub API rate limited');
        return _fallbackToCache();
      }

      if (response.statusCode == 404) {
        logger.warn('GitHub repo not found: $_githubOwner/$_githubRepo');
        return UpdateCheckResult.error('Repository not found');
      }

      if (response.statusCode != 200) {
        logger.warn(
            'GitHub API returned ${response.statusCode}');
        return _fallbackToCache();
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;

      // Parse tag — remove leading 'v' if present
      final tag = json['tag_name'] as String?;
      if (tag == null || tag.isEmpty) {
        return UpdateCheckResult.error('No tag found');
      }
      final remoteVersion = tag.startsWith('v') ? tag.substring(1) : tag;

      // Validate version format (X.Y.Z)
      if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(remoteVersion)) {
        logger.warn('Unexpected version format: $remoteVersion');
        return UpdateCheckResult.error('Invalid version format');
      }

      // Find installer asset (.exe)
      final assets = json['assets'] as List<dynamic>? ?? [];
      String? downloadUrl;
      for (final a in assets) {
        final name = a['name'] as String? ?? '';
        final url = a['browser_download_url'] as String?;
        if (name.endsWith('.exe') && url != null) {
          downloadUrl = url;
          break;
        }
      }

      final releaseUrl = json['html_url'] as String?;

      // ── Cache result ──
      final now = DateTime.now().millisecondsSinceEpoch;
      await _settings.set(_kCheckTimestamp, now);
      await _settings.set(_kCachedVersion, remoteVersion);
      if (downloadUrl != null) {
        await _settings.set(_kCachedDownloadUrl, downloadUrl);
      }
      if (releaseUrl != null) {
        await _settings.set(_kCachedReleaseUrl, releaseUrl);
      }

      // ── Compare ──
      if (_compareVersions(remoteVersion, localVersion) > 0) {
        logger.info(
            'Update available: $localVersion → $remoteVersion');
        return UpdateCheckResult(
          status: UpdateStatus.updateAvailable,
          latestVersion: remoteVersion,
          downloadUrl: downloadUrl,
          releaseUrl: releaseUrl,
        );
      }

      return UpdateCheckResult.upToDate;
    } on http.ClientException catch (e) {
      logger.warn('Update check network error: ${e.message}');
      return _fallbackToCache();
    } catch (e) {
      logger.warn('Update check failed: $e');
      return _fallbackToCache();
    }
  }

  /// Download the installer to a temporary file.
  ///
  /// Returns the path to the downloaded file, or null on failure.
  Future<String?> downloadInstaller(String url,
      {void Function(double progress)? onProgress}) async {
    try {
      final request = http.Request('GET', Uri.parse(url));
      final streamedResponse = await request
          .send()
          .timeout(const Duration(minutes: 10));

      if (streamedResponse.statusCode != 200) {
        logger.error(
            'Download failed: HTTP ${streamedResponse.statusCode}');
        return null;
      }

      final totalBytes = streamedResponse.contentLength ?? 0;
      var receivedBytes = 0;
      final chunks = <int>[];

      await for (final chunk in streamedResponse.stream) {
        chunks.addAll(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0 && onProgress != null) {
          onProgress(receivedBytes / totalBytes);
        }
      }

      // Extract filename from URL or use default
      final uri = Uri.parse(url);
      final segments = uri.pathSegments;
      final filename =
          segments.isNotEmpty ? segments.last : 'XMate_Setup.exe';

      // Save to temp directory
      final tempDir = Directory.systemTemp;
      final filePath = '${tempDir.path}/$filename';
      final file = File(filePath);
      await file.writeAsBytes(chunks);

      logger.info('Installer downloaded: $filePath');
      return filePath;
    } catch (e) {
      logger.error('Download failed', e);
      return null;
    }
  }

  /// Launch the downloaded installer.
  Future<bool> runInstaller(String path) async {
    try {
      final result = await Process.run(path, [], runInShell: true);
      return result.exitCode == 0;
    } catch (e) {
      logger.error('Failed to launch installer', e);
      return false;
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  /// Compare two semver strings. Returns >0 if a > b, <0 if a < b, 0 if equal.
  int _compareVersions(String a, String b) {
    try {
      final aParts = a.split('.').map(int.parse).toList();
      final bParts = b.split('.').map(int.parse).toList();
      for (var i = 0; i < 3; i++) {
        final av = i < aParts.length ? aParts[i] : 0;
        final bv = i < bParts.length ? bParts[i] : 0;
        if (av != bv) return av - bv;
      }
      return 0;
    } catch (_) {
      return 0;
    }
  }

  /// Fallback to cached version info when API fails.
  UpdateCheckResult _fallbackToCache() {
    final cachedVersion =
        _settings.getWithDefault<String?>(_kCachedVersion, null);
    if (cachedVersion != null) {
      final cachedDownloadUrl =
          _settings.getWithDefault<String?>(_kCachedDownloadUrl, null);
      final cachedReleaseUrl =
          _settings.getWithDefault<String?>(_kCachedReleaseUrl, null);
      return UpdateCheckResult(
        status: UpdateStatus.upToDate, // stale cache → show up-to-date
        latestVersion: cachedVersion,
        downloadUrl: cachedDownloadUrl,
        releaseUrl: cachedReleaseUrl,
      );
    }
    return UpdateCheckResult.error('Network unavailable');
  }
}
