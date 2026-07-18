#pragma once
#include <windows.h>
#include <string>

// Open a native folder picker dialog.
std::wstring PickFolder(HWND parent);

// Open a native file picker dialog.
// title: dialog title (UTF-8). Returns selected file path or empty.
std::wstring PickFile(HWND parent, const std::string& title);
