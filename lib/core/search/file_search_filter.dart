/// XMate File Search — keyword filter presets.
library;

/// A keyword-activated search filter.
///
/// When the user types `keyword ` (keyword + space) in the command palette,
/// the search switches to filter mode: only file results are shown, and
/// results are constrained by the filter's conditions.
///
/// Empty/absent fields mean "no constraint" (except for the built-in
/// `folder` filter which selects only directories).
class FileSearchFilter {
  /// Trigger word (must be unique, lowercase, no spaces).
  final String keyword;

  /// Display name shown in the filter header and settings.
  final String name;

  /// Optional folder path — results must be under this directory.
  final String? path;

  /// Extensions without dot, lowercase (e.g. `["pdf","docx"]`).
  /// Empty list = no extension restriction.
  final List<String> extensions;

  /// Optional regex matched against the filename (case-insensitive).
  final String? regex;

  /// True for the 5 hardcoded filters, false for user-defined ones.
  final bool isBuiltin;

  const FileSearchFilter({
    required this.keyword,
    required this.name,
    this.path,
    this.extensions = const [],
    this.regex,
    this.isBuiltin = false,
  });

  /// True when this filter has at least one active constraint.
  bool get hasConstraints =>
      path != null && path!.isNotEmpty ||
      extensions.isNotEmpty ||
      regex != null && regex!.isNotEmpty;

  // ── Built-in filters ──────────────────────────────────────────────────

  static const builtins = <FileSearchFilter>[
    _folder,
    _map,
    _doc,
    _pic,
    _video,
    _audio,
  ];

  /// Match keys must be unique — checked at save time.
  static const _folder = FileSearchFilter(
    keyword: 'folder', name: 'Folders', isBuiltin: true,
  );
  static const _map = FileSearchFilter(
    keyword: 'map', name: 'Map Search', isBuiltin: true,
  );
  static const _doc = FileSearchFilter(
    keyword: 'doc', name: 'Documents', isBuiltin: true,
    extensions: [
      'c','chm','cpp','cxx','doc','docm','docx','dot','dotm','dotx',
      'h','hpp','htm','html','hxx','ini','java','js','lua',
      'mdb','mht','mhtml','pdf','potm','potx','ppam','pps','ppsm','ppsx',
      'ppt','pptm','pptx','rtf','sldm','sldx','thmx','txt',
      'vsd','wpd','wps','wri','xlam','xls','xlsb','xlsm','xlsx','xltm','xltx','xml',
    ],
  );
  static const _pic = FileSearchFilter(
    keyword: 'pic', name: 'Pictures', isBuiltin: true,
    extensions: [
      'ani','bmp','gif','ico','jpe','jpeg','jpg','pcx','png','psd',
      'svg','tga','tif','tiff','webp','wmf',
    ],
  );
  static const _video = FileSearchFilter(
    keyword: 'video', name: 'Videos', isBuiltin: true,
    extensions: [
      '3g2','3gp','3gp2','3gpp','amr','asf','avi','bdmv','bik','d2v',
      'divx','drc','dsa','dsm','dss','dsv','f4v','flc','fli','flic','flv',
      'ifo','ivf','m1v','m2ts','m2v','m4b','m4p','m4v','mkv','mod','mov',
      'mp2v','mp4','mpe','mpeg','mpg','mpv2','mts','ogm','pss','pva','qt',
      'ram','ratdvd','rm','rmm','rmvb','roq','rpm','smk','swf','tp','tpr',
      'vob','vp6','webm','wm','wmp','wmv',
    ],
  );
  static const _audio = FileSearchFilter(
    keyword: 'audio', name: 'Audio', isBuiltin: true,
    extensions: [
      'aac','ac3','aif','aifc','aiff','amr','ape','au','cda','dts',
      'fla','flac','gym','it','m1a','m2a','m3u','m4a','mid','midi',
      'mka','mod','mp2','mp3','mpa','ogg','ogm','ra','rmi','snd','spc',
      'umx','vgm','vgz','voc','wav','wma','xm',
    ],
  );

  // ── JSON serialization (custom filters only — builtins are
  //     identified by keyword at load time) ──────────────────────────────

  Map<String, dynamic> toJson() => {
    'keyword': keyword,
    'name': name,
    if (path != null) 'path': path,
    if (extensions.isNotEmpty) 'extensions': extensions,
    if (regex != null) 'regex': regex,
  };

  factory FileSearchFilter.fromJson(Map<String, dynamic> json) =>
      FileSearchFilter(
        keyword: (json['keyword'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        path: json['path'] as String?,
        extensions: _stringList(json['extensions']),
        regex: json['regex'] as String?,
        isBuiltin: false,
      );

  static List<String> _stringList(dynamic v) {
    if (v is List) return v.cast<String>().map((e) => e.toLowerCase()).toList();
    return [];
  }

  // ── Equality / hash ──────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      other is FileSearchFilter && other.keyword == keyword;
  @override
  int get hashCode => keyword.hashCode;
}
