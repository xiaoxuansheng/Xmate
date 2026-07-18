// XMate - Screen capture & clipboard via Win32
#include <windows.h>
#include <gdiplus.h>
#include "screenshot_capture.h"
#include <dwmapi.h>
#include <vector>
#include <cstring>
#include <string>
#include <sstream>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shellscalingapi.h>

#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "Shcore.lib")

using namespace Gdiplus;

#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "ole32.lib")

static ULONG_PTR g_gdiplusToken = 0;
static bool g_gdiplusInit = false;

static void InitGdiPlus() {
    if (!g_gdiplusInit) {
        GdiplusStartupInput input;
        GdiplusStartup(&g_gdiplusToken, &input, nullptr);
        g_gdiplusInit = true;
    }
}

static int GetEncoderClsid(const WCHAR* format, CLSID* pClsid) {
    UINT num = 0, size = 0;
    GetImageEncodersSize(&num, &size);
    if (size == 0) return -1;
    auto info = (ImageCodecInfo*)malloc(size);
    if (!info) return -1;
    GetImageEncoders(num, size, info);
    for (UINT j = 0; j < num; ++j) {
        if (wcscmp(info[j].MimeType, format) == 0) {
            *pClsid = info[j].Clsid;
            free(info);
            return j;
        }
    }
    free(info);
    return -1;
}

static std::vector<uint8_t> BitmapToPng(HBITMAP hBitmap) {
    std::vector<uint8_t> result;
    InitGdiPlus();
    Bitmap* bmp = Bitmap::FromHBITMAP(hBitmap, nullptr);
    if (!bmp) return result;

    CLSID clsid;
    if (GetEncoderClsid(L"image/png", &clsid) < 0) { delete bmp; return result; }

    IStream* stream = nullptr;
    if (CreateStreamOnHGlobal(nullptr, TRUE, &stream) != S_OK) { delete bmp; return result; }
    if (bmp->Save(stream, &clsid, nullptr) != Ok) { stream->Release(); delete bmp; return result; }

    LARGE_INTEGER li = {};
    stream->Seek(li, STREAM_SEEK_SET, nullptr);
    STATSTG stg = {};
    stream->Stat(&stg, STATFLAG_NONAME);
    ULONG size = (ULONG)stg.cbSize.QuadPart;

    result.resize(size);
    stream->Seek(li, STREAM_SEEK_SET, nullptr);
    ULONG read = 0;
    stream->Read(result.data(), size, &read);

    stream->Release();
    delete bmp;
    return result;
}

// ── Multi-monitor capture result ──
struct ScreenCaptureResult {
    std::vector<uint8_t> png;
    double dpr = 1.0;
    int monX = 0, monY = 0;   // rcMonitor origin (virtual-desktop coords)
    int monW = 0, monH = 0;   // rcMonitor dimensions (physical pixels)
    bool ok = false;
};

/// Capture only the monitor the cursor is currently on.
///
/// Uses GetCursorPos → MonitorFromPoint → GetMonitorInfo to determine the
/// target monitor, then BitBlt from that monitor's rcMonitor origin (not
/// the primary-screen (0,0) as CaptureFullScreen did).
///
/// Also returns the monitor's DPI (GetDpiForMonitor) and virtual-desktop
/// rectangle so the Dart side can convert physical↔logical coordinates
/// without relying on displays.first or MediaQuery.
static ScreenCaptureResult CaptureFullScreenEx() {
    ScreenCaptureResult out;

    POINT pt;
    if (!GetCursorPos(&pt)) return out;

    HMONITOR hMon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = {};
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(hMon, &mi)) return out;

    int mw = mi.rcMonitor.right  - mi.rcMonitor.left;
    int mh = mi.rcMonitor.bottom - mi.rcMonitor.top;
    if (mw <= 0 || mh <= 0) return out;

    HDC hdc = GetDC(nullptr);
    HDC mem = CreateCompatibleDC(hdc);
    HBITMAP bmp = CreateCompatibleBitmap(hdc, mw, mh);
    HBITMAP old = (HBITMAP)SelectObject(mem, bmp);
    BitBlt(mem, 0, 0, mw, mh, hdc,
           mi.rcMonitor.left, mi.rcMonitor.top, SRCCOPY);
    SelectObject(mem, old);
    DeleteDC(mem);
    ReleaseDC(nullptr, hdc);

    out.png = BitmapToPng(bmp);
    DeleteObject(bmp);

    if (out.png.empty()) return out;

    // Per-monitor DPI so Dart can convert physical ↔ logical correctly
    UINT dpiX = 96, dpiY = 96;
    GetDpiForMonitor(hMon, MDT_EFFECTIVE_DPI, &dpiX, &dpiY);
    out.dpr = dpiX / 96.0;
    out.monX = mi.rcMonitor.left;
    out.monY = mi.rcMonitor.top;
    out.monW = mw;
    out.monH = mh;
    out.ok = true;
    return out;
}

// Copy PNG bytes to clipboard as CF_DIB + PNG (dual format).
//
// Pitfalls avoided:
//  1. CF_BITMAP (DDB via GetHBITMAP) is device-dependent — fails cross-process.
//     Use CF_DIB (device-independent) instead.
//  2. Manual DIB construction from LockBits is fragile (stride, channel order).
//     Use GDI+ Save to BMP stream, then strip the 14-byte BITMAPFILEHEADER.
//  3. Raw PNG as a secondary format via RegisterClipboardFormatW("PNG")
//     lets modern apps (browsers, Office, WeChat) paste without re-encoding.
static bool CopyToClipboard(const uint8_t* data, size_t len) {
    InitGdiPlus();

    // Decode PNG via GDI+ stream
    HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, len);
    if (!hMem) return false;
    void* pMem = GlobalLock(hMem);
    if (!pMem) { GlobalFree(hMem); return false; }
    std::memcpy(pMem, data, len);
    GlobalUnlock(hMem);

    IStream* stream = nullptr;
    if (CreateStreamOnHGlobal(hMem, TRUE, &stream) != S_OK) {
        GlobalFree(hMem);
        return false;
    }

    Bitmap* bmp = Bitmap::FromStream(stream);
    stream->Release();
    if (!bmp) return false;

    int w = bmp->GetWidth();
    int h = bmp->GetHeight();
    if (w <= 0 || h <= 0) { delete bmp; return false; }

    // ── 1. CF_DIB: GDI+ Save to BMP stream → strip BITMAPFILEHEADER (14 bytes) ──
    CLSID bmpClsid;
    if (GetEncoderClsid(L"image/bmp", &bmpClsid) < 0) {
        delete bmp;
        return false;
    }

    IStream* bmpStream = nullptr;
    if (CreateStreamOnHGlobal(nullptr, TRUE, &bmpStream) != S_OK) {
        delete bmp;
        return false;
    }

    Status saveStatus = bmp->Save(bmpStream, &bmpClsid, nullptr);
    if (saveStatus != Ok) {
        bmpStream->Release();
        delete bmp;
        return false;
    }

    STATSTG stg = {};
    bmpStream->Stat(&stg, STATFLAG_NONAME);
    ULONG bmpTotal = (ULONG)stg.cbSize.QuadPart;
    if (bmpTotal <= 14) {
        bmpStream->Release();
        delete bmp;
        return false;
    }
    ULONG dibSize = bmpTotal - 14;
    HGLOBAL hDib = GlobalAlloc(GMEM_MOVEABLE, dibSize);
    if (!hDib) {
        bmpStream->Release();
        delete bmp;
        return false;
    }
    void* pDib = GlobalLock(hDib);
    if (!pDib) {
        GlobalFree(hDib);
        bmpStream->Release();
        delete bmp;
        return false;
    }
    LARGE_INTEGER liZero = {};
    bmpStream->Seek(liZero, STREAM_SEEK_SET, nullptr);
    BYTE skipBuf[14];
    ULONG skipRead = 0;
    bmpStream->Read(skipBuf, 14, &skipRead);
    ULONG dibRead = 0;
    bmpStream->Read(pDib, dibSize, &dibRead);
    bmpStream->Release();
    GlobalUnlock(hDib);
    delete bmp;

    if (dibRead != dibSize) {
        GlobalFree(hDib);
        return false;
    }

    // ── 2. Raw PNG format (modern apps: browsers, Office, WeChat etc.) ──
    UINT cfPng = RegisterClipboardFormatW(L"PNG");
    HGLOBAL hPng = GlobalAlloc(GMEM_MOVEABLE, len);
    void* pPng = nullptr;
    if (hPng) {
        pPng = GlobalLock(hPng);
        if (pPng) {
            std::memcpy(pPng, data, len);
            GlobalUnlock(hPng);
        } else {
            GlobalFree(hPng);
            hPng = nullptr;
        }
    }

    // ── 3. Place both formats on clipboard ──
    if (!OpenClipboard(nullptr)) {
        GlobalFree(hDib);
        if (hPng) GlobalFree(hPng);
        return false;
    }
    EmptyClipboard();
    SetClipboardData(CF_DIB, hDib);
    if (hPng) SetClipboardData(cfPng, hPng);
    CloseClipboard();

    return true;
}

// ----------------------------------------------------------
// Window-under-cursor detection for snap-to-window (Task 1)
// ----------------------------------------------------------

#ifndef DWMWA_CLOAKED
#define DWMWA_CLOAKED 14
#endif

struct SnapResult {
    int x, y, w, h;
    bool valid;
    SnapResult() : x(0), y(0), w(0), h(0), valid(false) {}
};

// Compute client/title/outer sub-rect for [hwndRoot] at cursor [pt].
// Raw screen coordinates (not monitor-relative).
static SnapResult ComputeSnapRect(HWND hwndRoot, const POINT& pt, bool outerOnly) {
    SnapResult out;
    RECT outerRect;
    if (!GetWindowRect(hwndRoot, &outerRect)) return out;

    RECT cr;
    if (!GetClientRect(hwndRoot, &cr)) return out;
    POINT clientOrigin = {cr.left, cr.top};
    ClientToScreen(hwndRoot, &clientOrigin);
    RECT clientScreen;
    clientScreen.left   = clientOrigin.x;
    clientScreen.top    = clientOrigin.y;
    clientScreen.right  = clientOrigin.x + (cr.right  - cr.left);
    clientScreen.bottom = clientOrigin.y + (cr.bottom - cr.top);

    RECT resultRect;
    if (outerOnly) {
        resultRect = outerRect;
    } else if (PtInRect(&clientScreen, pt)) {
        resultRect = clientScreen;
    } else {
        RECT titleRect;
        titleRect.left   = outerRect.left;
        titleRect.top    = outerRect.top;
        titleRect.right  = outerRect.right;
        titleRect.bottom = clientScreen.top;
        if (PtInRect(&titleRect, pt)) {
            resultRect = titleRect;
        } else {
            resultRect = outerRect;
        }
    }

    out.x = resultRect.left;
    out.y = resultRect.top;
    out.w = resultRect.right  - resultRect.left;
    out.h = resultRect.bottom - resultRect.top;
    out.valid = (out.w > 0 && out.h > 0);
    return out;
}

// Convert screen-physical SnapResult to monitor-relative JSON.
static std::string SnapToJson(HWND xmateHwnd, const SnapResult& sr) {
    if (!sr.valid) return "null";
    HMONITOR mon = MonitorFromWindow(xmateHwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = {};
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(mon, &mi)) return "null";
    int rx = sr.x - mi.rcMonitor.left;
    int ry = sr.y - mi.rcMonitor.top;
    if (sr.w <= 0 || sr.h <= 0) return "null";
    std::ostringstream json;
    json << "{\"x\":" << rx << ",\"y\":" << ry
         << ",\"w\":" << sr.w << ",\"h\":" << sr.h << "}";
    return json.str();
}

std::string GetWindowRectAtCursor(HWND xmateHwnd, bool outerOnly) {
    POINT pt;
    if (!GetCursorPos(&pt)) return "null";

    HWND hwnd = WindowFromPoint(pt);
    if (!hwnd) return "null";

    HWND hwndRoot = GetAncestor(hwnd, GA_ROOT);
    if (!hwndRoot || hwndRoot == GetDesktopWindow()) return "null";

    // -- Phase A: strict filtering --
    if (hwndRoot != xmateHwnd &&
        IsWindowVisible(hwndRoot) &&
        !IsIconic(hwndRoot)) {

        LONG_PTR exStyle = GetWindowLongPtr(hwndRoot, GWL_EXSTYLE);
        BOOL cloaked = FALSE;
        HRESULT hr = DwmGetWindowAttribute(hwndRoot, DWMWA_CLOAKED,
                                           &cloaked, sizeof(cloaked));
        bool isCloaked = SUCCEEDED(hr) && cloaked;
        bool isToolWindow = (exStyle & WS_EX_TOOLWINDOW) != 0;

        if (!isToolWindow && !isCloaked) {
            SnapResult sr = ComputeSnapRect(hwndRoot, pt, outerOnly);
            if (sr.valid) return SnapToJson(xmateHwnd, sr);
        }
    }

    // -- Phase B: fallback (skip ToolWindow & Cloaked) --
    if (hwndRoot != xmateHwnd &&
        IsWindowVisible(hwndRoot) &&
        !IsIconic(hwndRoot) &&
        hwndRoot != GetDesktopWindow()) {

        SnapResult sr = ComputeSnapRect(hwndRoot, pt, outerOnly);
        if (sr.valid) return SnapToJson(xmateHwnd, sr);
    }

    return "null";
}

// ── EnumWindows / EnumChildWindows callback data ──

#include <set>
#include <sstream>

struct SnapResultWithRank {
    int x, y, w, h, rank;
    bool valid;
    SnapResultWithRank() : x(0), y(0), w(0), h(0), rank(0), valid(false) {}
};

struct EnumWindowsData {
    HWND xmateHwnd;
    HWND foregroundHwnd; // GetForegroundWindow() captured once at entry
    bool outerOnly;
    bool includeChildren;
    std::vector<SnapResultWithRank>* results;
    // Dedup key: HWND value (uniquely identifies a window, prevents duplicates
    // from nested / overlapping child chains)
    std::set<HWND>* seenHwnds;
    int depth;           // current recursion depth (0 = top-level)
    static constexpr int kMaxDepth  = 6;   // deep enough for toolbar buttons / icons
    static constexpr int kMaxResults = 500;
    static constexpr int kMinSize   = 3;   // skip single-pixel specks
    static constexpr int kForegroundBonus = 1000;
    static constexpr int kDepthMultiplier = 10;
};

/// Check that [hwnd] passes the basic visibility / style filters.
/// Does NOT filter WS_EX_TOOLWINDOW — user wants to see controls
/// (buttons, menus, dropdowns, toolbars, etc.) not just regular windows.
static bool passWindowFilter(HWND hwnd, HWND xmateHwnd) {
    if (hwnd == xmateHwnd) return false;
    if (!IsWindowVisible(hwnd)) return false;
    if (IsIconic(hwnd)) return false;

    // Skip zero-size windows explicitly (GetWindowRect returns empty)
    RECT cr;
    if (!GetWindowRect(hwnd, &cr)) return false;
    if (cr.right <= cr.left || cr.bottom <= cr.top) return false;

    BOOL cloaked = FALSE;
    HRESULT hr = DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED,
                                       &cloaked, sizeof(cloaked));
    if (SUCCEEDED(hr) && cloaked) return false;

    return true;
}

/// Compute whether [hwnd] belongs to the foreground window chain.
/// True when [hwnd] == foregroundHwnd or is a descendant of foregroundHwnd.
static bool isDescendantOfForeground(HWND hwnd, HWND foregroundHwnd) {
    if (!foregroundHwnd) return false;
    if (hwnd == foregroundHwnd) return true;
    return IsChild(foregroundHwnd, hwnd) != FALSE;
}

/// True when [hwnd] has a desktop/shell class name (Progman, WorkerW).
/// These classes represent the desktop background and always cover the full
/// screen — they should never win the auto-snap hit-test.
static bool isDesktopShellWindow(HWND hwnd) {
    WCHAR cls[64] = {};
    if (RealGetWindowClassW(hwnd, cls, 63) == 0) return false;
    return (_wcsicmp(cls, L"Progman")   == 0 ||
            _wcsicmp(cls, L"WorkerW")   == 0 ||
            _wcsicmp(cls, L"SHELLDLL_DefView") == 0);
}

/// Compute the rank for [hwnd] at [depth].
static int computeRank(HWND hwnd, HWND foregroundHwnd, int depth) {
    // Desktop shell windows always rank dead last so they never win hit-test.
    if (isDesktopShellWindow(hwnd)) return -9999;

    int r = depth * EnumWindowsData::kDepthMultiplier;
    if (isDescendantOfForeground(hwnd, foregroundHwnd)) {
        r += EnumWindowsData::kForegroundBonus;
    }
    return r;
}

/// Compute the snap rect for [hwnd] (outer or client-based), screen-absolute.
/// Returns a valid SnapResultWithRank on success; invalid otherwise.
static SnapResultWithRank rectForWindow(HWND hwnd, bool outerOnly) {
    SnapResultWithRank sr;
    RECT r;
    if (!GetWindowRect(hwnd, &r)) return sr;

    sr.x  = r.left;
    sr.y  = r.top;
    sr.w  = r.right  - r.left;
    sr.h  = r.bottom - r.top;
    sr.valid = (sr.w > 0 && sr.h > 0);
    if (!sr.valid) return sr;

    if (!outerOnly) {
        RECT cr;
        if (GetClientRect(hwnd, &cr)) {
            POINT clientOrigin = {cr.left, cr.top};
            ClientToScreen(hwnd, &clientOrigin);
            int clientW = cr.right  - cr.left;
            int clientH = cr.bottom - cr.top;
            int clientX = clientOrigin.x;
            int clientY = clientOrigin.y;

            if (clientW > sr.w * 0.3 && clientH > sr.h * 0.3) {
                sr.x = clientX;
                sr.y = clientY;
                sr.w = clientW;
                sr.h = clientH;
            }
        }
    }
    return sr;
}

/// Try to add [sr] to results.  Returns true if added (or already seen),
/// false if results are full.
static bool tryAddResult(SnapResultWithRank& sr, EnumWindowsData* data) {
    if (sr.w < EnumWindowsData::kMinSize || sr.h < EnumWindowsData::kMinSize)
        return true; // too small — skip but continue

    if (data->results->size() >= EnumWindowsData::kMaxResults) return false;

    // Dedup by HWND — identical HWNDs can't have meaningfully different rects
    // within a single enumeration cycle.
    // (seenHwnds is unused below because dedup happens at the per-HWND level
    //  via hwnd insertion; we store them in results directly since tryAddResult
    //  is called once per valid HWND.)
    data->results->push_back(sr);
    return true;
}

// Forward-declare for recursion.
static void enumChildWindowsRecurse(HWND parent, EnumWindowsData* data);

static BOOL CALLBACK EnumChildProc(HWND child, LPARAM lParam) {
    auto* data = reinterpret_cast<EnumWindowsData*>(lParam);

    // Depth guard
    if (data->depth >= EnumWindowsData::kMaxDepth) return TRUE;
    if (data->results->size() >= EnumWindowsData::kMaxResults) return FALSE;

    if (!passWindowFilter(child, data->xmateHwnd)) return TRUE;

    // Dedup by HWND
    if (!data->seenHwnds->insert(child).second) return TRUE;

    SnapResultWithRank sr = rectForWindow(child, data->outerOnly);
    if (!sr.valid) return TRUE;

    sr.rank = computeRank(child, data->foregroundHwnd, data->depth);

    if (!tryAddResult(sr, data)) return FALSE;

    // Recurse into grandchildren
    EnumWindowsData childData = *data;
    childData.depth = data->depth + 1;
    enumChildWindowsRecurse(child, &childData);

    return (data->results->size() < EnumWindowsData::kMaxResults) ? TRUE : FALSE;
}

static void enumChildWindowsRecurse(HWND parent, EnumWindowsData* data) {
    EnumChildWindows(parent, EnumChildProc, reinterpret_cast<LPARAM>(data));
}

// ── Top-level EnumWindows callback ──

static BOOL CALLBACK EnumWindowsProc(HWND hwnd, LPARAM lParam) {
    auto* data = reinterpret_cast<EnumWindowsData*>(lParam);

    if (data->results->size() >= EnumWindowsData::kMaxResults) return FALSE;

    if (!passWindowFilter(hwnd, data->xmateHwnd)) return TRUE;

    HWND hwndRoot = GetAncestor(hwnd, GA_ROOT);
    if (!hwndRoot || hwndRoot == GetDesktopWindow()) return TRUE;

    // Dedup: only process root windows (GA_ROOT == self)
    if (hwnd != hwndRoot) return TRUE;

    // Dedup by HWND
    if (!data->seenHwnds->insert(hwndRoot).second) return TRUE;

    SnapResultWithRank sr = rectForWindow(hwndRoot, data->outerOnly);
    if (!sr.valid) return TRUE;

    sr.rank = computeRank(hwndRoot, data->foregroundHwnd, 0);

    if (!tryAddResult(sr, data)) return FALSE;

    // Recursively enumerate child windows under this top-level window
    if (data->includeChildren) {
        EnumWindowsData childData = *data;
        childData.depth = 1;
        enumChildWindowsRecurse(hwndRoot, &childData);
    }

    return (data->results->size() < EnumWindowsData::kMaxResults) ? TRUE : FALSE;
}

std::string GetWindowRectsOnScreen(HWND xmateHwnd, bool outerOnly,
                                   bool includeChildren) {
    std::vector<SnapResultWithRank> results;
    std::set<HWND> seenHwnds;
    EnumWindowsData data = {};
    data.xmateHwnd       = xmateHwnd;
    data.foregroundHwnd  = GetForegroundWindow();
    data.outerOnly        = outerOnly;
    data.includeChildren  = includeChildren;
    data.results          = &results;
    data.seenHwnds        = &seenHwnds;
    data.depth            = 0;

    EnumWindows(EnumWindowsProc, reinterpret_cast<LPARAM>(&data));

    // Also enumerate children of the desktop window — many controls
    // (popup menus, dropdown lists, floating toolbars) live here.
    if (includeChildren && results.size() < EnumWindowsData::kMaxResults) {
        EnumWindowsData desktopData = data;
        desktopData.depth = 1; // desktop children are depth 1
        HWND hwndDesktop = GetDesktopWindow();
        if (hwndDesktop) {
            enumChildWindowsRecurse(hwndDesktop, &desktopData);
        }
    }

    if (results.size() >= 500) {
        OutputDebugStringA("[XMate] GetWindowRectsOnScreen: hit max results (500), truncated.\n");
    }

    std::ostringstream json;
    json << "[";
    for (size_t i = 0; i < results.size(); i++) {
        if (i > 0) json << ",";
        json << "{\"x\":" << results[i].x
             << ",\"y\":" << results[i].y
             << ",\"w\":" << results[i].w
             << ",\"h\":" << results[i].h
             << ",\"r\":" << results[i].rank << "}";
    }
    json << "]";
    return json.str();
}

// ----------------------------------------------------------
// ── Scroll-screenshot support ──
// ----------------------------------------------------------

/// Capture a specific screen rectangle (screen-absolute physical pixels).
/// Returns PNG bytes + DPR info for the monitor that contains the rect.
static ScreenCaptureResult CaptureRect(int rx, int ry, int rw, int rh) {
    ScreenCaptureResult out;
    if (rw <= 0 || rh <= 0) return out;

    // Determine which monitor the rect is on (use center point)
    POINT center = {rx + rw / 2, ry + rh / 2};
    HMONITOR hMon = MonitorFromPoint(center, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = {};
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(hMon, &mi)) return out;

    HDC hdc = GetDC(nullptr);
    HDC mem = CreateCompatibleDC(hdc);
    HBITMAP bmp = CreateCompatibleBitmap(hdc, rw, rh);
    HBITMAP old = (HBITMAP)SelectObject(mem, bmp);
    BitBlt(mem, 0, 0, rw, rh, hdc, rx, ry, SRCCOPY);
    SelectObject(mem, old);
    DeleteDC(mem);
    ReleaseDC(nullptr, hdc);

    out.png = BitmapToPng(bmp);
    DeleteObject(bmp);

    if (out.png.empty()) return out;

    UINT dpiX = 96, dpiY = 96;
    GetDpiForMonitor(hMon, MDT_EFFECTIVE_DPI, &dpiX, &dpiY);
    out.dpr = dpiX / 96.0;
    out.monX = mi.rcMonitor.left;
    out.monY = mi.rcMonitor.top;
    out.monW = mi.rcMonitor.right - mi.rcMonitor.left;
    out.monH = mi.rcMonitor.bottom - mi.rcMonitor.top;
    out.ok = true;
    return out;
}

/// Send a mouse wheel event via SendInput.
/// [delta] is the wheel delta (typically +/-120 per notch, WHEEL_DELTA).
static void SendMouseWheel(int delta) {
    INPUT input = {};
    input.type = INPUT_MOUSE;
    input.mi.dwFlags = MOUSEEVENTF_WHEEL;
    input.mi.mouseData = static_cast<DWORD>(delta) << 16;
    input.mi.dwExtraInfo = 0;
    SendInput(1, &input, sizeof(input));
}

/// Identify the topmost visible non-XMate window that occupies a screen region.
/// Returns JSON: {"hwnd":<uint64>,"className":"...","title":"..."} or "null".
std::string IdentifyWindowUnderRect(HWND xmateHwnd, int rx, int ry, int rw, int rh) {
    RECT target;
    target.left   = rx;
    target.top    = ry;
    target.right  = rx + rw;
    target.bottom = ry + rh;

    struct BestMatch {
        HWND hwnd = nullptr;
        LONG area = 0;
    } best;

    // We need to capture the top-level window list before our screen capture.
    // EnumWindows enumerates in Z-order (topmost first), so the first match
    // with the largest intersection area wins.
    struct Ctx {
        HWND xmateHwnd;
        RECT target;
        BestMatch best;
    } ctx = {xmateHwnd, target};

    EnumWindows([](HWND hwnd, LPARAM lParam) -> BOOL {
        auto* c = reinterpret_cast<Ctx*>(lParam);
        if (hwnd == c->xmateHwnd) return TRUE;
        if (!IsWindowVisible(hwnd)) return TRUE;
        if (IsIconic(hwnd)) return TRUE;

        // Skip cloaked windows
        BOOL cloaked = FALSE;
        DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
        if (cloaked) return TRUE;

        RECT wr;
        if (!GetWindowRect(hwnd, &wr)) return TRUE;

        // Compute intersection area
        LONG ix = std::max(wr.left, c->target.left);
        LONG iy = std::max(wr.top, c->target.top);
        LONG iw = std::min(wr.right, c->target.right) - ix;
        LONG ih = std::min(wr.bottom, c->target.bottom) - iy;
        if (iw <= 0 || ih <= 0) return TRUE;

        LONG area = iw * ih;
        if (area > c->best.area) {
            c->best.hwnd = hwnd;
            c->best.area = area;
        }
        return TRUE;
    }, reinterpret_cast<LPARAM>(&ctx));

    if (!ctx.best.hwnd) return "null";

    WCHAR cls[128] = {};
    RealGetWindowClassW(ctx.best.hwnd, cls, 127);

    WCHAR title[256] = {};
    GetWindowTextW(ctx.best.hwnd, title, 255);

    // Convert to UTF-8
    int clsLen = WideCharToMultiByte(CP_UTF8, 0, cls, -1, nullptr, 0, nullptr, nullptr);
    int titleLen = WideCharToMultiByte(CP_UTF8, 0, title, -1, nullptr, 0, nullptr, nullptr);
    std::string clsUtf8(clsLen > 0 ? clsLen : 0, '\0');
    std::string titleUtf8(titleLen > 0 ? titleLen : 0, '\0');
    if (clsLen > 0) WideCharToMultiByte(CP_UTF8, 0, cls, -1, &clsUtf8[0], clsLen, nullptr, nullptr);
    if (titleLen > 0) WideCharToMultiByte(CP_UTF8, 0, title, -1, &titleUtf8[0], titleLen, nullptr, nullptr);

    // Trim null terminators
    while (!clsUtf8.empty() && clsUtf8.back() == '\0') clsUtf8.pop_back();
    while (!titleUtf8.empty() && titleUtf8.back() == '\0') titleUtf8.pop_back();

    // Escape JSON strings (simple: only need to escape backslash and quote)
    auto esc = [](const std::string& s) -> std::string {
        std::string out;
        for (char c : s) {
            if (c == '\\') out += "\\\\";
            else if (c == '"') out += "\\\"";
            else out += c;
        }
        return out;
    };

    std::ostringstream json;
    json << "{\"hwnd\":" << reinterpret_cast<uint64_t>(ctx.best.hwnd)
         << ",\"className\":\"" << esc(clsUtf8) << "\""
         << ",\"title\":\"" << esc(titleUtf8) << "\"}";
    return json.str();
}

// ----------------------------------------------------------

void HandleScreenshotMethodCall(
    const flutter::MethodCall<>& call,
    std::unique_ptr<flutter::MethodResult<>> result) {

    if (call.method_name() == "captureFullScreen") {
        auto cap = CaptureFullScreenEx();
        if (!cap.ok || cap.png.empty()) {
            result->Error("CAPTURE_FAILED", "Screen capture failed");
            return;
        }
        flutter::EncodableMap map;
        map[flutter::EncodableValue("png")]  = flutter::EncodableValue(cap.png);
        map[flutter::EncodableValue("dpr")]  = flutter::EncodableValue(cap.dpr);
        map[flutter::EncodableValue("monX")] = flutter::EncodableValue(static_cast<int32_t>(cap.monX));
        map[flutter::EncodableValue("monY")] = flutter::EncodableValue(static_cast<int32_t>(cap.monY));
        map[flutter::EncodableValue("monW")] = flutter::EncodableValue(static_cast<int32_t>(cap.monW));
        map[flutter::EncodableValue("monH")] = flutter::EncodableValue(static_cast<int32_t>(cap.monH));
        result->Success(flutter::EncodableValue(map));
        return;
    }

    if (call.method_name() == "copyToClipboard") {
        auto args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args) { result->Error("INVALID_ARGS", "Expected byte array"); return; }
        auto it = args->find(flutter::EncodableValue("data"));
        if (it == args->end()) { result->Error("INVALID_ARGS", "Missing data"); return; }
        auto vec = std::get_if<std::vector<uint8_t>>(&it->second);
        if (!vec) { result->Error("INVALID_ARGS", "data not bytes"); return; }

        bool ok = CopyToClipboard(vec->data(), vec->size());
        result->Success(flutter::EncodableValue(ok));
        return;
    }

    if (call.method_name() == "captureRect") {
        auto args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args) { result->Error("INVALID_ARGS", "Expected map"); return; }
        auto getInt = [&](const char* key) -> int {
            auto it = args->find(flutter::EncodableValue(key));
            if (it == args->end()) return 0;
            auto* p = std::get_if<int32_t>(&it->second);
            return p ? *p : 0;
        };
        int rx = getInt("x"), ry = getInt("y"), rw = getInt("w"), rh = getInt("h");
        auto cap = CaptureRect(rx, ry, rw, rh);
        if (!cap.ok || cap.png.empty()) {
            result->Error("CAPTURE_FAILED", "Region capture failed");
            return;
        }
        flutter::EncodableMap map;
        map[flutter::EncodableValue("png")]  = flutter::EncodableValue(cap.png);
        map[flutter::EncodableValue("dpr")]  = flutter::EncodableValue(cap.dpr);
        map[flutter::EncodableValue("monX")] = flutter::EncodableValue(static_cast<int32_t>(cap.monX));
        map[flutter::EncodableValue("monY")] = flutter::EncodableValue(static_cast<int32_t>(cap.monY));
        map[flutter::EncodableValue("monW")] = flutter::EncodableValue(static_cast<int32_t>(cap.monW));
        map[flutter::EncodableValue("monH")] = flutter::EncodableValue(static_cast<int32_t>(cap.monH));
        result->Success(flutter::EncodableValue(map));
        return;
    }

    if (call.method_name() == "sendMouseWheel") {
        auto args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args) { result->Error("INVALID_ARGS", "Expected map"); return; }
        auto it = args->find(flutter::EncodableValue("delta"));
        if (it == args->end()) { result->Error("INVALID_ARGS", "Missing delta"); return; }
        auto* p = std::get_if<int32_t>(&it->second);
        if (!p) { result->Error("INVALID_ARGS", "delta not int"); return; }
        SendMouseWheel(*p);
        result->Success(flutter::EncodableValue(true));
        return;
    }

    if (call.method_name() == "postScrollMessage") {
        auto args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args) { result->Error("INVALID_ARGS", "Expected map"); return; }
        auto hit = args->find(flutter::EncodableValue("hwnd"));
        auto dit = args->find(flutter::EncodableValue("delta"));
        if (hit == args->end() || dit == args->end()) {
            result->Error("INVALID_ARGS", "Missing hwnd or delta"); return;
        }
        auto* hwndPtr = std::get_if<int64_t>(&hit->second);
        auto* deltaPtr = std::get_if<int32_t>(&dit->second);
        if (!hwndPtr || !deltaPtr) {
            result->Error("INVALID_ARGS", "hwnd or delta wrong type"); return;
        }
        HWND target = reinterpret_cast<HWND>(static_cast<intptr_t>(*hwndPtr));
        if (!IsWindow(target)) {
            result->Error("INVALID_HWND", "Target window no longer exists");
            return;
        }
        // Post WM_MOUSEWHEEL to the target window — no need to hide XMate
        int delta = *deltaPtr;
        WPARAM wParam = MAKEWPARAM(0, static_cast<WORD>(delta));
        // lParam is mouse screen position; use window center as fallback
        RECT r;
        GetWindowRect(target, &r);
        int cx = (r.left + r.right) / 2;
        int cy = (r.top + r.bottom) / 2;
        LPARAM lParam = MAKELPARAM(cx, cy);
        PostMessage(target, WM_MOUSEWHEEL, wParam, lParam);
        result->Success(flutter::EncodableValue(true));
        return;
    }

    result->NotImplemented();
}

// ----------------------------------------------------------
// ── Scroll-screenshot WH_MOUSE_LL hook ──
// ----------------------------------------------------------

// Global state — idempotent, cleared on uninstall.
static HHOOK     g_scrollHook   = NULL;
static HWND      g_scrollHwnd   = NULL;
static RECT      g_scrollHole   = {};

// WH_MOUSE_LL callback — just signals Dart to capture; no position tracking.
static LRESULT CALLBACK MouseLLProc(int nCode, WPARAM wParam, LPARAM lParam) {
    if (nCode >= 0 && wParam == WM_MOUSEWHEEL
        && g_scrollHwnd != NULL && IsWindow(g_scrollHwnd)) {
        MSLLHOOKSTRUCT* p = (MSLLHOOKSTRUCT*)lParam;
        POINT pt = p->pt;
        ScreenToClient(g_scrollHwnd, &pt);
        if (PtInRect(&g_scrollHole, pt)) {
            PostMessage(g_scrollHwnd, WM_XMATE_SCROLL_CAPTURE, (WPARAM)(short)HIWORD(p->mouseData), 0);
        }
    }
    return CallNextHookEx(g_scrollHook, nCode, wParam, lParam);
}

// holeX/Y/W/H = client-relative PHYSICAL pixels (caller already applied DPI scale).
bool InstallScrollHook(HWND hwnd, int holeX, int holeY, int holeW, int holeH) {
    UninstallScrollHook();
    g_scrollHwnd = hwnd;
    g_scrollHole = {holeX, holeY, holeX + holeW, holeY + holeH};
    g_scrollHook = SetWindowsHookEx(WH_MOUSE_LL, MouseLLProc,
        GetModuleHandle(NULL), 0);
    return g_scrollHook != NULL;
}

void UninstallScrollHook() {
    if (g_scrollHook) { UnhookWindowsHookEx(g_scrollHook); g_scrollHook = NULL; }
    g_scrollHwnd = NULL;
    ZeroMemory(&g_scrollHole, sizeof(g_scrollHole));
}
