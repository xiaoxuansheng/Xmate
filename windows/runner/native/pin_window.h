#pragma once

#include <windows.h>
#include <cstdint>
#include <vector>

// Create a native pin window from PNG-encoded bytes.
//
// (x, y, w, h) is the desired window rectangle in screen logical
// pixels (Flutter coordinates).  The implementation converts to
// physical pixels using the target monitor's DPI and adds the
// monitor's rcMonitor offset so the window appears at the correct
// absolute screen position.
//
// The window is topmost, draggable, resizable, and closes on
// double-click.
//
// Returns the HWND on success, nullptr on failure.
HWND CreatePinWindowFromPNG(const std::vector<uint8_t>& png_bytes,
                             int x, int y, int w, int h);

/// Destroy all active pin windows and shut down GDI+.
/// Call from the main thread during shutdown so gdiplus.dll can unload.
void DestroyAllPinWindows();
