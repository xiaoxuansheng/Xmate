// XMate - Monitor swap implementation
#include "monitor_swap.h"
#include <dwmapi.h>
#include <shellscalingapi.h>
#include <algorithm>
#include <sstream>
#include <vector>

#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "shcore.lib")

// ── Monitor info ──

struct MonitorEntry {
    int index;
    RECT rc;        // screen-absolute physical pixels
    double dpr;     // device pixel ratio (DPI / 96)
    bool isPrimary;
};

static std::vector<MonitorEntry> g_monitors;

static BOOL CALLBACK MonitorEnumProc(HMONITOR hMon, HDC /*hdc*/,
                                     LPRECT rcMon, LPARAM /*lParam*/) {
    MONITORINFOEXW mi = {};
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(hMon, &mi)) return TRUE;

    UINT dpiX = 96, dpiY = 96;
    GetDpiForMonitor(hMon, MDT_EFFECTIVE_DPI, &dpiX, &dpiY);

    MonitorEntry entry;
    entry.index     = static_cast<int>(g_monitors.size());
    entry.rc        = mi.rcMonitor;
    entry.dpr       = dpiX / 96.0;
    entry.isPrimary = (mi.dwFlags & MONITORINFOF_PRIMARY) != 0;
    g_monitors.push_back(entry);
    return TRUE;
}

static void EnumerateMonitors() {
    g_monitors.clear();
    EnumDisplayMonitors(nullptr, nullptr, MonitorEnumProc, 0);
    // Sort left-to-right so monitor 0 is the leftmost.
    std::sort(g_monitors.begin(), g_monitors.end(),
              [](const MonitorEntry& a, const MonitorEntry& b) {
                  return a.rc.left < b.rc.left;
              });
    // Re-index after sort
    for (size_t i = 0; i < g_monitors.size(); ++i) {
        g_monitors[i].index = static_cast<int>(i);
    }
}

// ── Window entry ──

struct WindowEntry {
    HWND hwnd;
    RECT rc;         // GetWindowRect in physical pixels
    bool maximized;
};

// ── Filter helpers (mirror screenshot_capture.cpp logic) ──

static bool IsDesktopShellClass(HWND hwnd) {
    WCHAR cls[64] = {};
    if (RealGetWindowClassW(hwnd, cls, 63) == 0) return false;
    return (_wcsicmp(cls, L"Progman")           == 0 ||
            _wcsicmp(cls, L"WorkerW")           == 0 ||
            _wcsicmp(cls, L"SHELLDLL_DefView")  == 0);
}

static bool PassWindowFilter(HWND hwnd, HWND xmateHwnd) {
    if (hwnd == xmateHwnd) return false;
    if (!IsWindowVisible(hwnd)) return false;
    if (IsIconic(hwnd)) return false;

    RECT cr;
    if (!GetWindowRect(hwnd, &cr)) return false;
    if (cr.right <= cr.left || cr.bottom <= cr.top) return false;

    BOOL cloaked = FALSE;
    HRESULT hr = DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED,
                                       &cloaked, sizeof(cloaked));
    if (SUCCEEDED(hr) && cloaked) return false;

    if (IsDesktopShellClass(hwnd)) return false;

    // Skip tool windows (WS_EX_TOOLWINDOW) — they are floating palettes,
    // popups, etc. that don't make sense to swap between monitors.
    LONG_PTR exStyle = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    if (exStyle & WS_EX_TOOLWINDOW) return false;

    return true;
}

/// Determine which monitor [hwnd] is primarily on by checking where its
/// center point falls. Returns monitor index or -1 if none matches.
static int GetMonitorIndexForWindow(HWND hwnd) {
    RECT rc;
    if (!GetWindowRect(hwnd, &rc)) return -1;
    POINT center = { (rc.left + rc.right) / 2, (rc.top + rc.bottom) / 2 };
    for (const auto& m : g_monitors) {
        if (center.x >= m.rc.left  && center.x < m.rc.right &&
            center.y >= m.rc.top   && center.y < m.rc.bottom) {
            return m.index;
        }
    }
    return -1;
}

// ── EnumWindows callback data ──

struct SwapEnumData {
    HWND xmateHwnd;
    std::vector<WindowEntry>* windowsA;  // windows on monitor 0
    std::vector<WindowEntry>* windowsB;  // windows on monitor 1
};

static BOOL CALLBACK SwapEnumProc(HWND hwnd, LPARAM lParam) {
    auto* data = reinterpret_cast<SwapEnumData*>(lParam);

    // Only top-level windows (GA_ROOT == self)
    HWND root = GetAncestor(hwnd, GA_ROOT);
    if (!root || root != hwnd) return TRUE;

    if (!PassWindowFilter(hwnd, data->xmateHwnd)) return TRUE;

    int monIdx = GetMonitorIndexForWindow(hwnd);

    WindowEntry entry;
    entry.hwnd = hwnd;
    GetWindowRect(hwnd, &entry.rc);
    entry.maximized = (IsZoomed(hwnd) != FALSE);

    if (monIdx == 0) {
        data->windowsA->push_back(entry);
    } else if (monIdx == 1) {
        data->windowsB->push_back(entry);
    }
    // Windows on other monitors (> 1) are ignored.

    return TRUE;
}

// ── Main swap logic ──

static void MoveWindowToMonitor(const WindowEntry& win,
                                const MonitorEntry& srcMon,
                                const MonitorEntry& dstMon) {
    // Proportional position on source monitor (0..1)
    double ratioX = (double)(win.rc.left - srcMon.rc.left) /
                    (double)(srcMon.rc.right - srcMon.rc.left);
    double ratioY = (double)(win.rc.top - srcMon.rc.top) /
                    (double)(srcMon.rc.bottom - srcMon.rc.top);

    // Clamp ratios to [0..1] — handles off-screen / partially visible windows
    if (ratioX < 0.0) ratioX = 0.0;
    if (ratioX > 1.0) ratioX = 1.0;
    if (ratioY < 0.0) ratioY = 0.0;
    if (ratioY > 1.0) ratioY = 1.0;

    int srcW = win.rc.right - win.rc.left;
    int srcH = win.rc.bottom - win.rc.top;

    int srcMonW = srcMon.rc.right - srcMon.rc.left;
    int srcMonH = srcMon.rc.bottom - srcMon.rc.top;
    int dstW = dstMon.rc.right - dstMon.rc.left;
    int dstH = dstMon.rc.bottom - dstMon.rc.top;

    // Proportional size: a window at 1/3 of source screen stays at 1/3 of
    // target screen.  Uses physical-pixel screen-dimension ratio — this
    // correctly handles both resolution differences and DPI differences
    // (rcMonitor is always physical pixels under PMA V2).
    double widthRatio  = (double)srcW / (double)srcMonW;
    double heightRatio = (double)srcH / (double)srcMonH;

    int newW = static_cast<int>(widthRatio  * dstW);
    int newH = static_cast<int>(heightRatio * dstH);

    // Clamp to target monitor bounds so window doesn't go off-screen
    if (newW > dstW) newW = dstW;
    if (newH > dstH) newH = dstH;

    int newX = dstMon.rc.left + static_cast<int>(ratioX * dstW);
    int newY = dstMon.rc.top  + static_cast<int>(ratioY * dstH);

    // Ensure at least part of the title bar is visible on the target monitor
    if (newX + newW < dstMon.rc.left + 40)  newX = dstMon.rc.left;
    if (newY + 40 < dstMon.rc.top)          newY = dstMon.rc.top;

    if (win.maximized) {
        // Restore first so SetWindowPos works on a normal window,
        // then move, then re-maximize on the target monitor.
        ShowWindow(win.hwnd, SW_RESTORE);
        SetWindowPos(win.hwnd, nullptr,
                     newX, newY, newW, newH,
                     SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
        ShowWindow(win.hwnd, SW_MAXIMIZE);
    } else {
        SetWindowPos(win.hwnd, nullptr,
                     newX, newY, newW, newH,
                     SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    }
}

std::string SwapMonitors(HWND xmateHwnd) {
    EnumerateMonitors();

    if (g_monitors.size() < 2) {
        return R"({"error":"Need at least 2 monitors"})";
    }

    // Enumerate windows on monitors 0 and 1
    std::vector<WindowEntry> windowsA, windowsB;
    SwapEnumData data = {};
    data.xmateHwnd  = xmateHwnd;
    data.windowsA   = &windowsA;
    data.windowsB   = &windowsB;
    EnumWindows(SwapEnumProc, reinterpret_cast<LPARAM>(&data));

    const auto& mon0 = g_monitors[0];
    const auto& mon1 = g_monitors[1];

    int moved = 0, skipped = 0;

    // Move windows from monitor 0 → monitor 1
    for (const auto& w : windowsA) {
        MoveWindowToMonitor(w, mon0, mon1);
        moved++;
    }

    // Move windows from monitor 1 → monitor 0
    for (const auto& w : windowsB) {
        MoveWindowToMonitor(w, mon1, mon0);
        moved++;
    }

    // Build result JSON
    // Use narrow strings to avoid encoding issues in Flutter method channel
    char buf[128];
    snprintf(buf, sizeof(buf),
             R"({"moved":%d,"skipped":%d,"monitor0":"%d x %d","monitor1":"%d x %d"})",
             moved, skipped,
             mon0.rc.right - mon0.rc.left, mon0.rc.bottom - mon0.rc.top,
             mon1.rc.right - mon1.rc.left, mon1.rc.bottom - mon1.rc.top);
    return std::string(buf);
}
