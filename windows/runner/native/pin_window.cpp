// Pin window implementation - see pin_window.h for overview.

#include "pin_window.h"

#include <flutter_windows.h>
#include <gdiplus.h>
#include <windowsx.h>
#include <algorithm>
#include <memory>

#pragma comment(lib, "gdiplus.lib")

namespace {

constexpr const wchar_t kPinWindowClass[] = L"XMatePinWindow";
constexpr int kResizeBorder = 6;
constexpr int kMinWidth = 60;
constexpr int kMinHeight = 40;
constexpr int kMaxWidth = 4000;
constexpr int kMaxHeight = 3000;

// ---- GDI+ init ----

ULONG_PTR g_gdiplusToken = 0;

void InitGdiPlus() {
  if (g_gdiplusToken != 0) return;
  Gdiplus::GdiplusStartupInput input;
  Gdiplus::GdiplusStartup(&g_gdiplusToken, &input, nullptr);
}

// ---- Active-pin tracking ----

HWND g_active_pin_ = nullptr;

// ---- Forward declaration ----

class PinWindow;

// ---- Global registry ----

bool g_class_registered = false;
std::vector<std::unique_ptr<PinWindow>> g_instances;

// ---- Per-instance PinWindow ----

class PinWindow {
public:
  explicit PinWindow(const std::vector<uint8_t>& png_bytes,
                     int x, int y, int w, int h)
      : png_bytes_(png_bytes),
        rect_x_(x), rect_y_(y), rect_w_(w), rect_h_(h) {}

  ~PinWindow() {
    if (bitmap_) { delete bitmap_; bitmap_ = nullptr; }
    if (hwnd_) {
      SetWindowLongPtrW(hwnd_, GWLP_USERDATA, 0);
      DestroyWindow(hwnd_);
      hwnd_ = nullptr;
    }
  }

  bool Create();
  void Show();
  HWND GetHandle() const { return hwnd_; }

  bool is_active_ = false;
  bool in_sizing_ = false;

  PinWindow(const PinWindow&) = delete;
  PinWindow& operator=(const PinWindow&) = delete;

private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);
  LRESULT HandleMessage(UINT msg, WPARAM wp, LPARAM lp);

  bool DecodePNG();
  void OnPaint();

  HWND hwnd_ = nullptr;
  const std::vector<uint8_t> png_bytes_;
  Gdiplus::Bitmap* bitmap_ = nullptr;
  int img_w_ = 0;
  int img_h_ = 0;

  int rect_x_, rect_y_, rect_w_, rect_h_;
};

// ---- Create ----

bool PinWindow::Create() {
  InitGdiPlus();

  if (!g_class_registered) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.style = CS_DBLCLKS | CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = PinWindow::WndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = nullptr;
    wc.lpszClassName = kPinWindowClass;
    if (!RegisterClassExW(&wc)) return false;
    g_class_registered = true;
  }

  if (!DecodePNG()) return false;

  POINT pt = {rect_x_, rect_y_};
  HMONITOR mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);

  MONITORINFO mi = {};
  mi.cbSize = sizeof(mi);
  if (!GetMonitorInfoW(mon, &mi)) return false;

  UINT dpi = FlutterDesktopGetDpiForMonitor(mon);
  double scale = dpi / 96.0;

  int px = mi.rcMonitor.left + static_cast<int>(rect_x_ * scale + 0.5);
  int py = mi.rcMonitor.top  + static_cast<int>(rect_y_ * scale + 0.5);
  int pw = static_cast<int>(rect_w_ * scale + 0.5);
  int ph = static_cast<int>(rect_h_ * scale + 0.5);

  if (pw < kMinWidth)  pw = kMinWidth;
  if (ph < kMinHeight) ph = kMinHeight;
  if (pw > kMaxWidth)  pw = kMaxWidth;
  if (ph > kMaxHeight) ph = kMaxHeight;

  hwnd_ = CreateWindowExW(
      WS_EX_TOPMOST,
      kPinWindowClass,
      L"XMate Pin",
      WS_POPUP,
      px, py, pw, ph,
      nullptr, nullptr, GetModuleHandleW(nullptr), this);

  if (!hwnd_) return false;

  SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);

  return true;
}

void PinWindow::Show() {
  if (hwnd_) {
    ShowWindow(hwnd_, SW_SHOW);
    UpdateWindow(hwnd_);
  }
}

// ---- GDI+ PNG decode ----

bool PinWindow::DecodePNG() {
  HGLOBAL hGlobal = GlobalAlloc(GMEM_MOVEABLE, png_bytes_.size());
  if (!hGlobal) return false;

  void* pData = GlobalLock(hGlobal);
  if (!pData) { GlobalFree(hGlobal); return false; }
  memcpy(pData, png_bytes_.data(), png_bytes_.size());
  GlobalUnlock(hGlobal);

  IStream* pStream = nullptr;
  HRESULT hr = CreateStreamOnHGlobal(hGlobal, TRUE, &pStream);
  if (FAILED(hr)) { GlobalFree(hGlobal); return false; }

  bitmap_ = Gdiplus::Bitmap::FromStream(pStream);
  pStream->Release();

  if (!bitmap_ || bitmap_->GetLastStatus() != Gdiplus::Ok) {
    if (bitmap_) { delete bitmap_; bitmap_ = nullptr; }
    return false;
  }

  img_w_ = bitmap_->GetWidth();
  img_h_ = bitmap_->GetHeight();
  return img_w_ > 0 && img_h_ > 0;
}

// ---- GDI paint ----

void PinWindow::OnPaint() {
  PAINTSTRUCT ps;
  HDC hdc = BeginPaint(hwnd_, &ps);

  RECT client;
  GetClientRect(hwnd_, &client);
  int cw = client.right - client.left;
  int ch = client.bottom - client.top;

  if (bitmap_ && img_w_ > 0 && img_h_ > 0) {
    Gdiplus::Graphics g(hdc);
    g.SetInterpolationMode(in_sizing_
        ? Gdiplus::InterpolationModeBilinear
        : Gdiplus::InterpolationModeHighQualityBicubic);
    g.DrawImage(bitmap_, 0, 0, cw, ch);
  } else {
    HBRUSH br = CreateSolidBrush(RGB(30, 30, 30));
    FillRect(hdc, &client, br);
    DeleteObject(br);
  }

  // Inner-glow: subtle semi-transparent border painted inside the window
  // edge when focused.  No outer margin; image fills full client rect.
  if (is_active_ && cw > 4 && ch > 4) {
    Gdiplus::Pen pen(Gdiplus::Color(60, 74, 108, 247), 2.0f);
    pen.SetAlignment(Gdiplus::PenAlignmentInset);
    Gdiplus::Graphics g2(hdc);
    g2.DrawRectangle(&pen, 0, 0, cw, ch);
  }

  EndPaint(hwnd_, &ps);
}

// ---- Window procedure ----

LRESULT CALLBACK PinWindow::WndProc(HWND hwnd, UINT msg,
                                     WPARAM wp, LPARAM lp) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lp);
    auto* self = static_cast<PinWindow*>(cs->lpCreateParams);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(self));
    self->hwnd_ = hwnd;
    return DefWindowProcW(hwnd, msg, wp, lp);
  }

  auto* self = reinterpret_cast<PinWindow*>(
      GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (self) {
    return self->HandleMessage(msg, wp, lp);
  }

  return DefWindowProcW(hwnd, msg, wp, lp);
}

LRESULT PinWindow::HandleMessage(UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_PAINT:
      OnPaint();
      return 0;

    case WM_ERASEBKGND:
      return 1;

    case WM_MOUSEACTIVATE:
      SetFocus(hwnd_);
      return MA_ACTIVATE;

    case WM_ACTIVATE: {
      WORD state = LOWORD(wp);
      if (state == WA_ACTIVE || state == WA_CLICKACTIVE) {
        if (g_active_pin_ && g_active_pin_ != hwnd_) {
          auto* prev = reinterpret_cast<PinWindow*>(
              GetWindowLongPtrW(g_active_pin_, GWLP_USERDATA));
          if (prev) {
            prev->is_active_ = false;
            InvalidateRect(g_active_pin_, nullptr, TRUE);
          }
        }
        g_active_pin_ = hwnd_;
        is_active_ = true;
        InvalidateRect(hwnd_, nullptr, TRUE);
      } else if (state == WA_INACTIVE) {
        if (is_active_) {
          if (g_active_pin_ == hwnd_) g_active_pin_ = nullptr;
          is_active_ = false;
          InvalidateRect(hwnd_, nullptr, TRUE);
        }
      }
      return 0;
    }

    case WM_NCLBUTTONDBLCLK:
      if (wp == HTCAPTION) {
        DestroyWindow(hwnd_);
        return 0;
      }
      break;

    case WM_LBUTTONDBLCLK:
      DestroyWindow(hwnd_);
      return 0;

    case WM_GETMINMAXINFO: {
      auto* mmi = reinterpret_cast<MINMAXINFO*>(lp);
      mmi->ptMinTrackSize.x = kMinWidth;
      mmi->ptMinTrackSize.y = kMinHeight;
      mmi->ptMaxTrackSize.x = kMaxWidth;
      mmi->ptMaxTrackSize.y = kMaxHeight;
      return 0;
    }

    case WM_ENTERSIZEMOVE:
      in_sizing_ = true;
      return 0;

    case WM_EXITSIZEMOVE:
      in_sizing_ = false;
      InvalidateRect(hwnd_, nullptr, TRUE);
      return 0;

    case WM_SIZING: {
      if (!(GetAsyncKeyState(VK_SHIFT) & 0x8000)) {
        RECT* rc = reinterpret_cast<RECT*>(lp);
        double aspect = static_cast<double>(img_w_) / img_h_;

        int cw = rc->right - rc->left;
        int ch = rc->bottom - rc->top;
        if (cw < 1) cw = 1;
        if (ch < 1) ch = 1;

        int new_cw = cw, new_ch = ch;
        switch (wp) {
          case WMSZ_LEFT:
          case WMSZ_RIGHT:
            new_ch = static_cast<int>(cw / aspect + 0.5);
            break;
          case WMSZ_TOP:
          case WMSZ_BOTTOM:
            new_cw = static_cast<int>(ch * aspect + 0.5);
            break;
          default:
            new_ch = static_cast<int>(cw / aspect + 0.5);
            break;
        }

        if (new_cw < kMinWidth)  { new_cw = kMinWidth;  new_ch = static_cast<int>(new_cw / aspect + 0.5); }
        if (new_ch < kMinHeight) { new_ch = kMinHeight; new_cw = static_cast<int>(new_ch * aspect + 0.5); }

        switch (wp) {
          case WMSZ_LEFT:         rc->left   = rc->right - new_cw; break;
          case WMSZ_RIGHT:        rc->right  = rc->left + new_cw; break;
          case WMSZ_TOP:          rc->top    = rc->bottom - new_ch; break;
          case WMSZ_BOTTOM:       rc->bottom = rc->top + new_ch; break;
          case WMSZ_TOPLEFT:      rc->left   = rc->right - new_cw; rc->top    = rc->bottom - new_ch; break;
          case WMSZ_TOPRIGHT:     rc->right  = rc->left + new_cw; rc->top    = rc->bottom - new_ch; break;
          case WMSZ_BOTTOMLEFT:   rc->left   = rc->right - new_cw; rc->bottom = rc->top + new_ch; break;
          case WMSZ_BOTTOMRIGHT:  rc->right  = rc->left + new_cw; rc->bottom = rc->top + new_ch; break;
        }
      }
      return TRUE;
    }

    case WM_NCHITTEST: {
      POINT ptc = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
      ScreenToClient(hwnd_, &ptc);

      RECT rc;
      GetClientRect(hwnd_, &rc);
      int cw = rc.right - rc.left;
      int ch = rc.bottom - rc.top;

      bool left   = ptc.x < kResizeBorder;
      bool right  = ptc.x > cw - kResizeBorder;
      bool top    = ptc.y < kResizeBorder;
      bool bottom = ptc.y > ch - kResizeBorder;

      if (top && left)     return HTTOPLEFT;
      if (top && right)    return HTTOPRIGHT;
      if (bottom && left)  return HTBOTTOMLEFT;
      if (bottom && right) return HTBOTTOMRIGHT;
      if (top)             return HTTOP;
      if (bottom)          return HTBOTTOM;
      if (left)            return HTLEFT;
      if (right)           return HTRIGHT;

      return HTCAPTION;
    }

    case WM_NCDESTROY: {
      if (g_active_pin_ == hwnd_) g_active_pin_ = nullptr;
      hwnd_ = nullptr;
      auto it = std::find_if(g_instances.begin(), g_instances.end(),
          [this](const std::unique_ptr<PinWindow>& p) {
            return p.get() == this;
          });
      if (it != g_instances.end()) {
        g_instances.erase(it);
      }
      return 0;
    }
  }

  return DefWindowProcW(hwnd_, msg, wp, lp);
}

}  // namespace

void DestroyAllPinWindows() {
  // Destroy every Pin window so their HWNDs are freed and they remove
  // themselves from g_instances on WM_NCDESTROY.
  while (!g_instances.empty()) {
    auto& pin = g_instances.back();
    if (pin && pin->GetHandle()) {
      DestroyWindow(pin->GetHandle());
    } else {
      g_instances.pop_back();
    }
  }
  // Shut down GDI+ so gdiplus.dll can be unloaded.
  if (g_gdiplusToken != 0) {
    Gdiplus::GdiplusShutdown(g_gdiplusToken);
    g_gdiplusToken = 0;
  }
}

HWND CreatePinWindowFromPNG(const std::vector<uint8_t>& png_bytes,
                             int x, int y, int w, int h) {
  auto pin = std::make_unique<PinWindow>(png_bytes, x, y, w, h);
  if (!pin->Create()) return nullptr;
  HWND hwnd = pin->GetHandle();
  pin->Show();
  g_instances.push_back(std::move(pin));
  return hwnd;
}
