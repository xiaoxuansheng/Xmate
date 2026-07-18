/// XMate File Search — index entry model.
library;

/// A single file entry in the search index.
class FileIndexEntry {
  final int id; // sequential within segment (0-based)
  final String name; // filename (without extension, stored with original case)
  final String ext; // lowercase extension, no dot ("" if none)
  final String path; // relative path from root (forward-slash separators)
  final bool isDir;

  FileIndexEntry({
    required this.id,
    required this.name,
    required this.ext,
    required this.path,
    this.isDir = false,
  });

  /// The full absolute path when combined with a root path.
  String fullPath(String rootPath) {
    final rp = rootPath.endsWith('/') || rootPath.endsWith('\\')
        ? rootPath
        : '$rootPath/';
    return '$rp$path$name${ext.isNotEmpty ? '.$ext' : ''}';
  }

  /// Normalized name for trigram indexing (lowercased).
  String get nameNormal => name.toLowerCase();

  /// Pinyin initials for the name (used for pinyin search).
  /// Must be set after indexing; not stored in binary format.
  String pinyinInitials = '';

  @override
  String toString() => 'FileIndexEntry(#$id $name${ext.isNotEmpty ? '.$ext' : ''} @ $path)';
}
