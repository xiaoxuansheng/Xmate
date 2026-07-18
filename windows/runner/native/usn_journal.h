// XMate File Search - USN Journal change detection.
//
// Uses FSCTL_READ_USN_JOURNAL to detect file additions/removals/renames.
// Returns the current USN ID for the volume containing rootPath and
// whether any file changes occurred since lastUsnId.
#pragma once
#include <string>
#include <cstdint>
#include <flutter/binary_messenger.h>

/// Query USN journal for changes on the volume containing [rootPathUtf8].
///
/// [lastUsnId] = the USN ID from the previous query (0 on first call).
///
/// Returns JSON:
///   {"nextUsn":<int64>, "dirty":bool}
std::string QueryUsnJournal(const std::string& rootPathUtf8, int64_t lastUsnId);

/// Query USN journal with parent directory resolution.
/// Returns JSON with dirtyDirs and deletedDirs arrays:
///   {"nextUsn":<int64>, "dirty":bool,
///    "dirtyDirs":["sub1/",...], "deletedDirs":["old_dir/",...]}
///
/// dirtyDirs = parent directories of created/deleted/renamed files
///             (relative to rootPathUtf8, forward slashes, with trailing /).
/// deletedDirs = entire directories that were deleted (same format).
std::string QueryUsnJournalWithDirs(const std::string& rootPathUtf8,
                                     int64_t lastUsnId);

/// Same as QueryUsnJournalWithDirs on a background thread.
/// Returns immediately. Result is sent back to Dart via
/// messenger InvokeMethod("usnResult", {requestId, resultJson}).
void QueryUsnJournalWithDirsAsync(const std::string& rootPathUtf8,
                                  int64_t lastUsnId,
                                  flutter::BinaryMessenger* messenger,
                                  int requestId);
