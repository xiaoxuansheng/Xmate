#pragma once
#include <windows.h>
#include <string>

/// Show a native debug dialog that compares Shell icon vs Resource icon
/// for the given file path -- rendered as raw HICON (no PNG conversion).
/// Side-by-side: Shell (SHGetFileInfoW) on the left,
/// Resource (ExtractIconExW) on the right.
void ShowIconDebugDialog(const std::string& filePathUtf8);
