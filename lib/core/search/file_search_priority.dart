/// XMate File Search — priority rules for scoring / excluding results.
library;

import 'dart:io';

/// Impact of a matched rule on search result ranking.
enum PriorityLevel { prefer, uncommon, exclude }

/// A rule that adjusts the score of file search results.
///
/// Each rule can have a [path] (directory prefix), a [regex] (filename
/// pattern), or both.  When both are set, both must match (AND).
///
/// #### Score effects
/// | Level      | Effect                          |
/// |------------|---------------------------------|
/// | `prefer`   | +0.50 added to score            |
/// | `uncommon` | score multiplied by 0.3         |
/// | `exclude`  | result removed (equivalent to `continue`) |
class PriorityRule {
  final String? path;
  final String? regex;
  final PriorityLevel level;

  const PriorityRule({this.path, this.regex, required this.level});

  bool get hasPath => path != null && path!.isNotEmpty;
  bool get hasRegex => regex != null && regex!.isNotEmpty;

  /// Normalized path for matching (backslashes → forward slashes,
  /// trailing `/` appended so startsWith also matches subdirectories).
  String get pathLower {
    final n = (path ?? '').replaceAll('\\', '/').toLowerCase();
    return n.endsWith('/') ? n : '$n/';
  }

  /// Compile and cache the regex — call once per search to amortize.
  RegExp? compileRegex() {
    if (!hasRegex) return null;
    try { return RegExp(regex!, caseSensitive: false); } catch (_) { return null; }
  }

  // ── Default seed rules ────────────────────────────────────────────────

  static List<PriorityRule> defaultRules() {
    final env = Platform.environment;
    final sd = env['SystemDrive'] ?? 'C:';
    return [
      // ── System directories ──
      PriorityRule(path: _expand('$sd\\Windows.old', env), level: PriorityLevel.uncommon),
      PriorityRule(path: _expand(r'$sd\$WINDOWS.~BT', env), level: PriorityLevel.uncommon),
      PriorityRule(path: _expand(r'$sd\$Windows.~WS', env), level: PriorityLevel.uncommon),
      PriorityRule(path: _expand(r'%ProgramData%', env), level: PriorityLevel.uncommon),
      PriorityRule(path: _expand(r'%SystemRoot%', env), level: PriorityLevel.uncommon),
      PriorityRule(path: _expand(r'%APPDATA%\Microsoft\Windows\Start Menu', env), level: PriorityLevel.prefer),
      PriorityRule(path: _expand(r'%USERPROFILE%\AppData', env), level: PriorityLevel.uncommon),
      PriorityRule(path: _expand(r'%ProgramW6432%', env), level: PriorityLevel.uncommon),
      PriorityRule(path: _expand(r'%ProgramFiles(x86)%', env), level: PriorityLevel.uncommon),
      PriorityRule(path: _expand(r'%ProgramData%\Microsoft\Windows\Start Menu\Programs', env), level: PriorityLevel.prefer),
      // ── Name / path patterns ──
      PriorityRule(regex: r'^~', level: PriorityLevel.uncommon),
      PriorityRule(regex: r'^\.', level: PriorityLevel.uncommon),
      PriorityRule(regex: r'^\$', level: PriorityLevel.uncommon),
      PriorityRule(regex: r'^node modules$', level: PriorityLevel.uncommon),
      PriorityRule(regex: r'\.stversions', level: PriorityLevel.exclude),
    ];
  }

  /// Replace `%VAR%` and `$VAR` tokens in [s] using [env].
  static String _expand(String s, Map<String, String> env) {
    // %VAR% form
    final pct = RegExp(r'%([^%]+)%');
    String result = s.replaceAllMapped(pct, (m) => env[m.group(1)!] ?? m.group(0)!);
    // $VAR form (non-recursive, at start of string only — $sd pattern)
    final dollar = RegExp(r'\$(\w+)');
    result = result.replaceAllMapped(dollar, (m) => env[m.group(1)!] ?? m.group(0)!);
    // Normalize to forward slashes
    return result.replaceAll('\\', '/');
  }

  /// Resolve environment variables in [raw] — used when saving
  /// user-entered paths that may contain %VAR% syntax.
  static String expandEnv(String raw) {
    return _expand(raw, Platform.environment);
  }

  // ── JSON serialization ───────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
    if (hasPath) 'path': path,
    if (hasRegex) 'regex': regex,
    'level': level.name,
  };

  factory PriorityRule.fromJson(Map<String, dynamic> json) => PriorityRule(
    path: json['path'] as String?,
    regex: json['regex'] as String?,
    level: _parseLevel(json['level'] as String?),
  );

  static PriorityLevel _parseLevel(String? s) {
    switch (s) {
      case 'prefer': return PriorityLevel.prefer;
      case 'exclude': return PriorityLevel.exclude;
      default: return PriorityLevel.uncommon;
    }
  }

  // ── Equality ─────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      other is PriorityRule && other.path == path && other.regex == regex && other.level == level;
  @override
  int get hashCode => Object.hash(path, regex, level);
}
