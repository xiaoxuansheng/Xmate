library;

import 'dart:io';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;
import '../settings/settings_service.dart';

/// Result of a timezone conversion.
class TzResult {
  final DateTime time;
  final Duration offsetDiff; // target offset - source offset
  final bool isDst;
  final String abbreviation;
  final Duration utcOffset;

  TzResult({
    required this.time,
    required this.offsetDiff,
    required this.isDst,
    required this.abbreviation,
    required this.utcOffset,
  });
}

/// Service for timezone detection, conversion, and DST handling.
///
/// Uses the IANA timezone database via the `timezone` package — no network
/// required.  DST rules are automatically applied from the bundled tzdata.
///
/// System timezone detection uses `tzutil /g` on Windows, with a Windows →
/// IANA mapping table.
class TimezoneService {
  static bool _initialized = false;

  /// Must be called once at startup (in [main]) before any other method.
  static void ensureInitialized() {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    _initialized = true;
  }

  static const _kTargetKey = 'app.timezone.target';
  static const _kSourceKey = 'app.timezone.source';

  final _settings = SettingsService();

  // ── Timezone definitions ──

  /// 16 timezones — deduplicated by (standard offset, has DST).
  /// Each IANA zone represents a group of regions sharing the same offset + DST
  /// behaviour, labelled with the most recognisable city.
  /// Sorted from highest UTC offset to lowest (UTC+12 → UTC-8).
  static const allTimezones = [
    'Pacific/Auckland',       // UTC+12  (NZDT)
    'Australia/Sydney',       // UTC+10  (AEDT)
    'Asia/Tokyo',             // UTC+9
    'Asia/Shanghai',          // UTC+8
    'Asia/Bangkok',           // UTC+7
    'Asia/Kolkata',           // UTC+5:30
    'Asia/Dubai',             // UTC+4
    'Europe/Moscow',          // UTC+3
    'Europe/Paris',           // UTC+1   (CEST DST)
    'Europe/London',          // UTC+0   (BST DST)
    'UTC',                    // UTC+0
    'America/Sao_Paulo',      // UTC-3
    'America/New_York',       // UTC-5   (EDT DST)
    'America/Chicago',        // UTC-6   (CDT DST)
    'America/Denver',         // UTC-7   (MDT DST)
    'America/Los_Angeles',    // UTC-8   (PDT DST)
  ];

  static const _cityLabels = <String, String>{
    'Asia/Shanghai': 'Shanghai',
    'Asia/Tokyo': 'Tokyo/Seoul',
    'Asia/Bangkok': 'Bangkok',
    'Asia/Kolkata': 'Mumbai',
    'Asia/Dubai': 'Dubai',
    'Europe/Moscow': 'Moscow',
    'Europe/London': 'London',
    'Europe/Paris': 'Paris/Berlin',
    'America/New_York': 'New York',
    'America/Chicago': 'Chicago',
    'America/Denver': 'Denver',
    'America/Los_Angeles': 'Los Angeles',
    'America/Sao_Paulo': 'Sao Paulo',
    'Pacific/Auckland': 'Auckland',
    'Australia/Sydney': 'Sydney',
    'UTC': 'UTC',
  };

  /// Short city label for display (e.g. "Tokyo/Seoul", "New York").
  static String cityLabel(String iana) => _cityLabels[iana] ?? iana;

  /// Human-readable label with current UTC offset (e.g. "Shanghai (UTC+8)").
  static String displayName(String iana) {
    ensureInitialized();
    try {
      final loc = tz.getLocation(iana);
      final now = DateTime.now().millisecondsSinceEpoch;
      final zone = loc.timeZone(now);
      final label = cityLabel(iana);
      return '$label (${_formatUtcOffset(zone.offset)})';
    } catch (_) {
      return iana;
    }
  }

  // ── Windows → IANA timezone mapping ──

  static const _winToIana = <String, String>{
    'China Standard Time': 'Asia/Shanghai',
    'Taipei Standard Time': 'Asia/Shanghai',
    'Hong Kong Standard Time': 'Asia/Shanghai',
    'Singapore Standard Time': 'Asia/Shanghai',
    'Ulaanbaatar Standard Time': 'Asia/Shanghai',
    'Tokyo Standard Time': 'Asia/Tokyo',
    'Korea Standard Time': 'Asia/Seoul',  // mapped to Tokyo for our list
    'North Korea Standard Time': 'Asia/Tokyo',
    'SE Asia Standard Time': 'Asia/Bangkok',
    'India Standard Time': 'Asia/Kolkata',
    'Sri Lanka Standard Time': 'Asia/Kolkata',
    'Arabian Standard Time': 'Asia/Dubai',
    'Russian Standard Time': 'Europe/Moscow',
    'Belarus Standard Time': 'Europe/Moscow',
    'GMT Standard Time': 'Europe/London',
    'Greenwich Standard Time': 'Europe/London',
    'W. Europe Standard Time': 'Europe/Paris',
    'Romance Standard Time': 'Europe/Paris',
    'Central Europe Standard Time': 'Europe/Paris',
    'Central European Standard Time': 'Europe/Paris',
    'Eastern Standard Time': 'America/New_York',
    'US Eastern Standard Time': 'America/New_York',
    'SA Pacific Standard Time': 'America/New_York',
    'Central Standard Time': 'America/Chicago',
    'Central America Standard Time': 'America/Chicago',
    'Mexico Standard Time': 'America/Chicago',
    'Canada Central Standard Time': 'America/Chicago',
    'Mountain Standard Time': 'America/Denver',
    'US Mountain Standard Time': 'America/Denver',
    'Pacific Standard Time': 'America/Los_Angeles',
    'E. South America Standard Time': 'America/Sao_Paulo',
    'New Zealand Standard Time': 'Pacific/Auckland',
    'AUS Eastern Standard Time': 'Australia/Sydney',
    'UTC': 'UTC',
    'Coordinated Universal Time': 'UTC',
  };

  // ── System timezone ──

  /// Detect the system IANA timezone name from the OS.
  ///
  /// On Windows this runs `tzutil /g` and maps the result through a
  /// Windows → IANA table.  Falls back to the system UTC offset if
  /// detection fails.
  String detectSystemTimezone() {
    ensureInitialized();
    try {
      if (Platform.isWindows) {
        return _detectWindows();
      }
      // On macOS / Linux, tz.local works via /etc/localtime symlink.
      return tz.local.name;
    } catch (_) {
      return _guessByOffset();
    }
  }

  /// Run `tzutil /g` and map the result.
  static String _detectWindows() {
    try {
      final result = Process.runSync('cmd', ['/c', 'tzutil /g']);
      final raw = (result.stdout as String).trim();
      if (raw.isNotEmpty) {
        final mapped = _winToIana[raw];
        if (mapped != null) return mapped;
      }
    } catch (_) {}
    return _guessByOffset();
  }

  /// Fallback: use the current UTC offset to pick a timezone from our list.
  static String _guessByOffset() {
    final offset = DateTime.now().timeZoneOffset;
    for (final name in allTimezones) {
      try {
        final loc = tz.getLocation(name);
        final now = DateTime.now().millisecondsSinceEpoch;
        final zone = loc.timeZone(now);
        if (zone.offset == offset) return name;
      } catch (_) {}
    }
    return 'UTC';
  }

  /// Human-readable label for a timezone IANA name (e.g. "Shanghai (UTC+8)").
  static String label(String iana) {
    ensureInitialized();
    try {
      final loc = tz.getLocation(iana);
      final now = DateTime.now().millisecondsSinceEpoch;
      final zone = loc.timeZone(now);
      return '${cityLabel(iana)} (${_formatUtcOffset(zone.offset)})';
    } catch (_) {
      return iana;
    }
  }

  // ── Conversion ──

  /// Convert [sourceLocal] (wall-clock time in [sourceTz]) to [targetTz].
  ///
  /// Returns the target local time, offset difference, DST status, and
  /// timezone abbreviation.  Returns `null` if either timezone name is
  /// invalid or the source time is ambiguous / non-existent.
  TzResult? convert(DateTime sourceLocal, String sourceTz, String targetTz) {
    ensureInitialized();
    try {
      final sourceLoc = tz.getLocation(sourceTz);
      final targetLoc = tz.getLocation(targetTz);

      // Interpret sourceLocal as wall-clock time in sourceTz.
      final sourceTzDt = tz.TZDateTime.from(sourceLocal, sourceLoc);

      // Convert to target timezone via UTC.
      final targetTzDt = tz.TZDateTime.from(sourceTzDt, targetLoc);

      // Get zone info for both sides at the converted instant.
      final targetMs = targetTzDt.millisecondsSinceEpoch;
      final sourceZone = sourceLoc.timeZone(targetMs);
      final targetZone = targetLoc.timeZone(targetMs);

      final offsetDiff = targetZone.offset - sourceZone.offset;

      return TzResult(
        time: targetTzDt,
        offsetDiff: offsetDiff,
        isDst: targetZone.isDst,
        abbreviation: targetZone.abbreviation,
        utcOffset: targetZone.offset,
      );
    } catch (_) {
      return null;
    }
  }

  // ── Persistence ──

  /// Last-used source timezone IANA name.
  String get sourceTimezone {
    final v = _settings.get(_kSourceKey) as String?;
    if (v != null && v.isNotEmpty) return v;
    return detectSystemTimezone();
  }

  set sourceTimezone(String value) {
    _settings.set(_kSourceKey, value);
  }

  /// Last-used target timezone IANA name (defaults to 'America/New_York').
  String get targetTimezone {
    return _settings.get(_kTargetKey) as String? ?? 'America/New_York';
  }

  set targetTimezone(String value) {
    _settings.set(_kTargetKey, value);
  }

  // ── Formatting ──

  /// Format a UTC offset Duration as "UTC+8", "UTC-5", "UTC+5:30", etc.
  static String _formatUtcOffset(Duration offset) {
    if (offset == Duration.zero) return 'UTC+0';
    final sign = offset.isNegative ? '-' : '+';
    final abs = offset.abs();
    final h = abs.inHours;
    final m = abs.inMinutes.remainder(60);
    if (m == 0) return 'UTC$sign$h';
    return 'UTC$sign$h:${m.toString().padLeft(2, '0')}';
  }

  /// Format a UTC offset Duration as "UTC+8", etc. (public, same as above).
  static String formatUtcOffset(Duration offset) => _formatUtcOffset(offset);

  /// Format a Duration as a human-readable offset diff (e.g. "+3h", "-12h", "+5.5h").
  static String formatOffsetDiff(Duration diff) {
    if (diff == Duration.zero) return '+0h';
    final sign = diff.isNegative ? '-' : '+';
    final abs = diff.abs();
    final h = abs.inHours;
    final m = abs.inMinutes.remainder(60);
    if (m == 0) return '$sign${h}h';
    return '$sign$h.${(m / 6).round()}h';
  }
}
