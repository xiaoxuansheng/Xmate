/// XMate File Search — configuration models.
library;

/// A directory root that the file indexer should scan.
class IndexPathConfig {
  final String rootPath;

  /// Update mode: "off" | time-based (minutes as int, stored as String).
  /// "0" = auto (USN-poll trigger). "" or "off" = disabled.
  final String updateMode;

  const IndexPathConfig({required this.rootPath, this.updateMode = "off"});

  Map<String, dynamic> toJson() =>
      {'rootPath': rootPath, 'updateMode': updateMode};

  factory IndexPathConfig.fromJson(Map<String, dynamic> json) =>
      IndexPathConfig(
        rootPath: json['rootPath'] as String,
        updateMode: json['updateMode'] as String? ?? "off",
      );

  @override
  bool operator ==(Object other) =>
      other is IndexPathConfig &&
      other.rootPath == rootPath &&
      other.updateMode == updateMode;
  @override
  int get hashCode => rootPath.hashCode ^ updateMode.hashCode;
}

enum SegmentStatus { notBuilt, building, ready, failed }

/// Runtime information about a loaded/indexed segment.
class SegmentInfo {
  final String rootPath;
  final SegmentStatus status;
  final int fileCount;
  final String? updatedAt;
  final DateTime? lastUpdated;
  final String? errorReason;
  final bool dirty;
  final int segmentCount; // number of segments (1=base only, 2+=base+incrementals)

  const SegmentInfo({
    required this.rootPath,
    this.status = SegmentStatus.notBuilt,
    this.fileCount = 0,
    this.updatedAt,
    this.lastUpdated,
    this.errorReason,
    this.dirty = false,
    this.segmentCount = 0,
  });
}

/// USN journal snapshot for a segment. Persisted in settings.
class SegmentUsnState {
  /// Last known USN ID for the volume (from FSCTL_QUERY_USN_JOURNAL).
  final int lastUsnId;

  /// File count at the time this USN was recorded.
  final int fileCount;

  /// When this snapshot was taken.
  final DateTime recordedAt;

  const SegmentUsnState({
    required this.lastUsnId,
    required this.fileCount,
    required this.recordedAt,
  });

  Map<String, dynamic> toJson() => {
        'lastUsnId': lastUsnId,
        'fileCount': fileCount,
        'recordedAt': recordedAt.millisecondsSinceEpoch,
      };

  factory SegmentUsnState.fromJson(Map<String, dynamic> json) =>
      SegmentUsnState(
        lastUsnId: (json['lastUsnId'] as num?)?.toInt() ?? 0,
        fileCount: (json['fileCount'] as num?)?.toInt() ?? 0,
        recordedAt: DateTime.fromMillisecondsSinceEpoch(
            (json['recordedAt'] as num?)?.toInt() ?? 0),
      );
}

/// Search configuration persisted via SettingsService.
class SearchConfig {
  final List<IndexPathConfig> indexPaths;
  final int maxRecentPaths;

  const SearchConfig({
    this.indexPaths = const [],
    this.maxRecentPaths = 256,
  });

  Map<String, dynamic> toJson() => {
        'indexPaths': indexPaths.map((p) => p.toJson()).toList(),
        'maxRecentPaths': maxRecentPaths,
      };

  factory SearchConfig.fromJson(Map<String, dynamic> json) => SearchConfig(
        indexPaths: (json['indexPaths'] as List<dynamic>?)
                ?.map((e) =>
                    IndexPathConfig.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        maxRecentPaths: json['maxRecentPaths'] as int? ?? 256,
      );
}
