// XMate Debug Tools -- native debug dialogs for development.
//
// The icon debug dialog extracts both Shell icon (SHGetFileInfoW) and
// Resource icon (ExtractIconExW) for a given file, then displays them
// side-by-side as raw HICONs -- no GDI+ / PNG conversion involved.
#include "debug_tools.h"

#include <shellapi.h>
#include <shlobj.h>
#include <string>

#pragma comment(lib, "shell32.lib")

// -- Per-window data ----------------------------------------------------------

struct DebugIconData {
  HICON hShellLarge = nullptr;
  HICON hShellSmall = nullptr;
  HICON hResLarge = nullptr;
  HICON hResSmall = nullptr;
  std::wstring path;
};

static const WCHAR* kDebugWndClass = L"XMateDebugIconWnd";

// -- Window procedure ---------------------------------------------------------

static LRESULT CALLBACK DebugIconWndProc(HWND hwnd, UINT msg,
                                          WPARAM wp, LPARAM lp) {
  auto* data = (DebugIconData*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);

  switch (msg) {
    case WM_CREATE: {
      auto* cs = (CREATESTRUCT*)lp;
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)cs->lpCreateParams);
      return 0;
    }
    case WM_PAINT: {
      if (!data) break;
      PAINTSTRUCT ps;
      HDC hdc = BeginPaint(hwnd, &ps);
      RECT rc; GetClientRect(hwnd, &rc);

      // -- Dark background --
      HBRUSH bg = CreateSolidBrush(RGB(22, 22, 46)); // 0x1A1A2E ~ #16162E
      FillRect(hdc, &rc, bg);
      DeleteObject(bg);

      SetBkMode(hdc, TRANSPARENT);
      SetTextColor(hdc, RGB(200, 200, 210));
      HFONT hFont = CreateFontW(16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                                DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                                CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                                DEFAULT_PITCH, L"Segoe UI");
      HFONT hSmallFont = CreateFontW(13, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                                     DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                                     CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                                     DEFAULT_PITCH, L"Segoe UI");
      HFONT hBoldFont = CreateFontW(14, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
                                    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                                    CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                                    DEFAULT_PITCH, L"Segoe UI");

      HFONT oldFont = (HFONT)SelectObject(hdc, hFont);

      int cx = rc.right / 2;
      int y = 10;

      // -- Title: file path --
      SetTextColor(hdc, RGB(90, 170, 194)); // 0xFF5AAAC2
      std::wstring title = L"Path: " + data->path;
      RECT titleRc = {14, y, rc.right - 14, y + 28};
      DrawTextW(hdc, title.c_str(), -1, &titleRc,
                DT_SINGLELINE | DT_LEFT | DT_VCENTER | DT_END_ELLIPSIS);
      y += 32;

      // -- Column headers --
      SelectObject(hdc, hBoldFont);
      SetTextColor(hdc, RGB(230, 230, 240));

      RECT shellHdr = {14, y, cx - 10, y + 24};
      DrawTextW(hdc, L"Shell (SHGetFileInfoW)", -1, &shellHdr,
                DT_SINGLELINE | DT_CENTER | DT_VCENTER);

      RECT resHdr = {cx + 10, y, rc.right - 14, y + 24};
      DrawTextW(hdc, L"Resource (ExtractIconExW)", -1, &resHdr,
                DT_SINGLELINE | DT_CENTER | DT_VCENTER);
      y += 28;

      // -- Separator line --
      SelectObject(hdc, GetStockObject(DC_PEN));
      SetDCPenColor(hdc, RGB(255, 255, 255));
      MoveToEx(hdc, 14, y, nullptr);
      LineTo(hdc, rc.right - 14, y);
      y += 14;

      SelectObject(hdc, hSmallFont);
      SetTextColor(hdc, RGB(200, 200, 210));

      // -- Large icons row --
      {
        int iconY = y;
        int lx = cx / 2 - 32;       // center of left column
        int rx = cx + cx / 2 - 32;  // center of right column

        if (data->hShellLarge) {
          DrawIconEx(hdc, lx, iconY, data->hShellLarge, 64, 64, 0, nullptr, DI_NORMAL);
        }
        if (data->hResLarge) {
          DrawIconEx(hdc, rx, iconY, data->hResLarge, 64, 64, 0, nullptr, DI_NORMAL);
        }
        y += 64 + 4;

        RECT sLbl = {14, y, cx - 10, y + 20};
        DrawTextW(hdc, L"64x64 (large)", -1, &sLbl,
                  DT_SINGLELINE | DT_CENTER | DT_VCENTER);

        RECT rLbl = {cx + 10, y, rc.right - 14, y + 20};
        DrawTextW(hdc, L"64x64 (large)", -1, &rLbl,
                  DT_SINGLELINE | DT_CENTER | DT_VCENTER);
        y += 28;
      }

      // -- Small icons row --
      {
        int sy = y;
        int sx = cx / 2 - 8;       // center of left column
        int srx = cx + cx / 2 - 8; // center of right column

        if (data->hShellSmall) {
          DrawIconEx(hdc, sx, sy, data->hShellSmall, 16, 16, 0, nullptr, DI_NORMAL);
        }
        if (data->hResSmall) {
          DrawIconEx(hdc, srx, sy, data->hResSmall, 16, 16, 0, nullptr, DI_NORMAL);
        }
        y += 16 + 4;

        RECT ssLbl = {14, y, cx - 10, y + 20};
        DrawTextW(hdc, L"16x16 (small)", -1, &ssLbl,
                  DT_SINGLELINE | DT_CENTER | DT_VCENTER);

        RECT srLbl = {cx + 10, y, rc.right - 14, y + 20};
        DrawTextW(hdc, L"16x16 (small)", -1, &srLbl,
                  DT_SINGLELINE | DT_CENTER | DT_VCENTER);
        y += 20;
      }

      // -- Bottom hint --
      y += 8;
      SelectObject(hdc, hSmallFont);
      SetTextColor(hdc, RGB(120, 120, 140));
      RECT hintRc = {14, y, rc.right - 14, y + 22};
      DrawTextW(hdc, L"Press ESC or close this window to dismiss",
                -1, &hintRc, DT_SINGLELINE | DT_CENTER | DT_VCENTER);

      SelectObject(hdc, oldFont);
      DeleteObject(hFont);
      DeleteObject(hSmallFont);
      DeleteObject(hBoldFont);
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_KEYDOWN:
      if (wp == VK_ESCAPE) { DestroyWindow(hwnd); return 0; }
      break;
    case WM_DESTROY:
      if (data) {
        if (data->hShellLarge) DestroyIcon(data->hShellLarge);
        if (data->hShellSmall) DestroyIcon(data->hShellSmall);
        if (data->hResLarge)  DestroyIcon(data->hResLarge);
        if (data->hResSmall)  DestroyIcon(data->hResSmall);
        delete data;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
      }
      PostQuitMessage(0);
      return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

// -- Public API ---------------------------------------------------------------

void ShowIconDebugDialog(const std::string& filePathUtf8) {
  std::wstring pathW;
  if (filePathUtf8.empty()) return;
  int len = MultiByteToWideChar(CP_UTF8, 0, filePathUtf8.c_str(), -1,
                                nullptr, 0);
  if (len <= 1) return;
  pathW.resize(len - 1);
  MultiByteToWideChar(CP_UTF8, 0, filePathUtf8.c_str(), -1,
                      &pathW[0], len);

  DWORD attrs = GetFileAttributesW(pathW.c_str());
  if (attrs == INVALID_FILE_ATTRIBUTES) {
    MessageBoxW(nullptr, L"File not found. Please enter a valid path.",
                L"Debug Icon -- Error", MB_ICONWARNING);
    return;
  }

  // -- Extract Shell icon (SHGetFileInfoW) --
  HICON hShellLarge = nullptr, hShellSmall = nullptr;
  {
    SHFILEINFOW sfiL = {}, sfiS = {};
    if (SHGetFileInfoW(pathW.c_str(), attrs, &sfiL, sizeof(sfiL),
                       SHGFI_ICON | SHGFI_LARGEICON)) {
      hShellLarge = sfiL.hIcon;
    }
    if (SHGetFileInfoW(pathW.c_str(), attrs, &sfiS, sizeof(sfiS),
                       SHGFI_ICON | SHGFI_SMALLICON)) {
      hShellSmall = sfiS.hIcon;
    }
  }

  // -- Extract Resource icon (ExtractIconExW) --
  HICON hResLarge = nullptr, hResSmall = nullptr;
  ExtractIconExW(pathW.c_str(), 0, &hResLarge, &hResSmall, 1);

  // -- Create debug window --
  static bool classRegistered = false;
  if (!classRegistered) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = DebugIconWndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    wc.lpszClassName = kDebugWndClass;
    RegisterClassExW(&wc);
    classRegistered = true;
  }

  auto* payload = new DebugIconData{
    hShellLarge, hShellSmall,
    hResLarge, hResSmall,
    pathW
  };

  int ww = 500, wh = 320;
  int sx = GetSystemMetrics(SM_CXSCREEN);
  int sy = GetSystemMetrics(SM_CYSCREEN);

  HWND hDlg = CreateWindowExW(
      WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
      kDebugWndClass,
      L"Debug: Icon Comparison  (Shell vs Resource)",
      WS_OVERLAPPEDWINDOW & ~WS_MAXIMIZEBOX & ~WS_MINIMIZEBOX,
      (sx - ww) / 2, (sy - wh) / 2,
      ww, wh,
      nullptr, nullptr, GetModuleHandleW(nullptr), payload);
  if (!hDlg) {
    delete payload;
    return;
  }
  ShowWindow(hDlg, SW_SHOW);
  UpdateWindow(hDlg);

  // Pump messages until the debug window closes (modal to this thread).
  // This blocks the calling method channel, which is fine for a debug tool.
  MSG dm;
  HWND hFore = GetForegroundWindow();
  while (GetMessageW(&dm, nullptr, 0, 0)) {
    TranslateMessage(&dm);
    DispatchMessageW(&dm);
  }
  // Restore foreground after the debug window closes.
  if (hFore) SetForegroundWindow(hFore);
}
