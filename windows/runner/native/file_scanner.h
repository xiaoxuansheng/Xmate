// XMate File Search - directory scanner (C++ native).
//
// Uses FindFirstFileW / FindNextFileW for fast recursive enumeration.
// Results returned as a compact JSON string via MethodChannel.
#pragma once

#include <string>
#include <vector>
#include <cstdint>
#include <flutter/binary_messenger.h>

/// Scan [rootPathUtf8] recursively.
///
/// Returns a compact JSON array string (no whitespace):
///   [{"n":"readme","e":"txt","p":"docs/","d":false},...]
///
/// Fields:
///   n = base name without extension (UTF-8, no path component)
///   e = extension (lowercase, without leading dot, empty string if none)
///   p = directory path relative to rootPath (with trailing "/", empty "" for root)
///   d = isDirectory (bool)
///
/// Paths use forward-slash separators.
/// Returns "[]" on failure (e.g. access denied, path not found).
std::string ScanDirectory(const std::string& rootPathUtf8);

/// Return the system small icon for [filePathUtf8] as PNG bytes.
///
/// Uses SHGetFileInfoW with SHGFI_ICON | SHGFI_SMALLICON to retrieve the
/// 16×16 icon the shell associates with the file (by extension or by exe
/// resource).  The icon is rendered to a GDI+ bitmap and encoded as PNG.
///
/// Returns empty vector on failure.
std::vector<uint8_t> GetFileIconPng(const std::string& filePathUtf8);

/// Same as ScanDirectory on a background thread.
/// Returns immediately. Result is sent back to Dart via
/// messenger InvokeMethod("scanResult", {requestId, resultJson}).
void ScanDirectoryAsync(const std::string& rootPathUtf8,
                        flutter::BinaryMessenger* messenger,
                        int requestId);
