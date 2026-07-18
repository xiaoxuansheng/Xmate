// XMate - Monitor swap: swap windows between two monitors
#pragma once
#include <string>
#include <windows.h>

// Swap all visible top-level windows between the first two monitors.
//
// Enumerates monitors via EnumDisplayMonitors, classifies visible top-level
// windows by which monitor their center is on, then moves each window from
// monitor 0 -> monitor 1 and monitor 1 -> monitor 0 using proportional
// coordinate mapping + DPI-aware size scaling.
//
// [xmateHwnd] is excluded from the swap (XMate itself stays put).
// Minimized, cloaked, and zero-size windows are skipped.
// Maximized windows are restored -> moved -> re-maximized on the target monitor.
//
// Returns a JSON object:
//   {"moved":N,"skipped":N}
// or on error (e.g. < 2 monitors):
//   {"error":"Need at least 2 monitors"}
std::string SwapMonitors(HWND xmateHwnd);
