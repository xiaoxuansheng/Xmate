#pragma once

#include <windows.h>
#include <cstdint>
#include <vector>

// Create a transparent, click-through overlay window from PNG bytes.
//
// (x, y, w, h) is the desired window rectangle in screen logical
// pixels (Flutter coordinates).  DPI-aware positioning matches
// the pin window convention: logical coords are scaled by the
// target monitor's DPI/96 ratio + rcMonitor offset.
//
// The window is layered (per-pixel alpha), transparent to mouse
// input, and always on top.  It has no chrome, no resize handles,
// and cannot receive focus.
//
// Returns an opaque handle (int64_t) on success, 0 on failure.

int64_t CreateAnnotationOverlay(const std::vector<uint8_t>& png_bytes,
                                int x, int y, int w, int h);

// Destroy a single overlay by handle.  Safe to call with an
// already-destroyed handle (no-op).
void DestroyAnnotationOverlay(int64_t handle);

// Destroy all active annotation overlays and release GDI+.
// Call from the main thread during shutdown.
void DestroyAllAnnotationOverlays();
