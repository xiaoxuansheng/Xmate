// XMate - Screenshot capture & clipboard handler
#pragma once
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <string>
#include <vector>

// Custom message posted by WH_MOUSE_LL hook to trigger a scroll capture.
#define WM_XMATE_SCROLL_CAPTURE (WM_APP + 201)

void HandleScreenshotMethodCall(
    const flutter::MethodCall<>& call,
    std::unique_ptr<flutter::MethodResult<>> result);

// Enumerate the top-level window under the cursor and return its
// bounding rectangle as a JSON string relative to XMate's monitor.
//
// When [outerOnly] is false (default), the returned rect depends on
// where the cursor lands:
//   - inside client area  -> client rect (content-only)
//   - inside title bar     -> title-bar rect (top edge to client top)
//   - elsewhere (borders)  -> full outer window rect
//
// When [outerOnly] is true (Shift held), the full outer window rect
// (GetWindowRect) is always returned -- no inner-frame subdivision.
//
// Returns a JSON object  {"x":int,"y":int,"w":int,"h":int}  on success,
// or the literal string  "null"  when no suitable window is found.
std::string GetWindowRectAtCursor(HWND xmateHwnd, bool outerOnly);

/// Enumerate visible windows on the virtual screen, excluding [xmateHwnd]
/// and cloaked / tool-window / invisible / iconic HWNDs.
///
/// Each result carries a "r" (rank) field -- higher = more specific.
/// Rank = (isDescendantOfForeground ? 1000 : 0) + depth * 10,
/// where depth = 0 for top-level, 1 for children, etc.
///
/// [outerOnly] controls which sub-rect is picked per window.
/// [includeChildren] recursively enumerates child HWNDs (depth-limited,
///   de-duplicated, size-filtered down to icon level).
///
/// Returns a JSON array: [{"x":int,"y":int,"w":int,"h":int,"r":int}, ...].
/// Coordinates are screen-absolute physical pixels.
std::string GetWindowRectsOnScreen(HWND xmateHwnd, bool outerOnly,
                                   bool includeChildren = false);

// ── Scroll-screenshot support ──

/// Identify the topmost visible non-XMate window occupying a screen region.
/// Returns JSON: {"hwnd":uint64,"className":"str","title":"str"} or "null".
/// [xmateHwnd] is excluded from the search.
/// Coordinates are screen-absolute physical pixels.
std::string IdentifyWindowUnderRect(HWND xmateHwnd, int rx, int ry, int rw, int rh);

/// Install a WH_MOUSE_LL hook that detects wheel events over the hole region.
/// [holeX/Y/W/H] = client-relative PHYSICAL pixels (caller already DPI-scaled).
/// Returns true on success.  Idempotent (uninstalls old hook first).
bool InstallScrollHook(HWND hwnd, int holeX, int holeY, int holeW, int holeH);

/// Uninstall the WH_MOUSE_LL hook and clear all global state.
void UninstallScrollHook();
