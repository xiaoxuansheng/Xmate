// Annotation overlay window — screen-physical coords, per-pixel alpha, click-through.

#include "annotation_overlay.h"

#include <gdiplus.h>
#include <algorithm>
#include <memory>

#pragma comment(lib, "gdiplus.lib")

namespace {

constexpr const wchar_t kOverlayClass[] = L"XMateAnnotationOverlay";

ULONG_PTR g_overlayGdiplusToken = 0;

void InitOverlayGdiPlus() {
  if (g_overlayGdiplusToken != 0) return;
  Gdiplus::GdiplusStartupInput input;
  Gdiplus::GdiplusStartup(&g_overlayGdiplusToken, &input, nullptr);
}

class AnnotationOverlay {
public:
  AnnotationOverlay(const std::vector<uint8_t>& png_bytes,
                    int x, int y, int w, int h)
      : png_bytes_(png_bytes),
        screen_x_(x), screen_y_(y), screen_w_(w), screen_h_(h) {}

  ~AnnotationOverlay() {
    if (hbitmap_) { DeleteObject(hbitmap_); hbitmap_ = nullptr; }
    if (hwnd_) {
      SetWindowLongPtrW(hwnd_, GWLP_USERDATA, 0);
      DestroyWindow(hwnd_);
      hwnd_ = nullptr;
    }
  }

  bool Create();
  int64_t Handle() const { return reinterpret_cast<int64_t>(hwnd_); }

private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);
  LRESULT HandleMessage(UINT msg, WPARAM wp, LPARAM lp);
  bool LoadPngToBitmap();
  void ShowLayered();

  HWND hwnd_ = nullptr;
  HBITMAP hbitmap_ = nullptr;
  int img_w_ = 0, img_h_ = 0;
  const std::vector<uint8_t> png_bytes_;
  int screen_x_, screen_y_, screen_w_, screen_h_;
};

bool g_overlayClassRegistered = false;
std::vector<std::unique_ptr<AnnotationOverlay>> g_overlays;

bool AnnotationOverlay::Create() {
  InitOverlayGdiPlus();

  if (!g_overlayClassRegistered) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = AnnotationOverlay::WndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.hCursor = nullptr;
    wc.hbrBackground = nullptr;
    wc.lpszClassName = kOverlayClass;
    if (!RegisterClassExW(&wc)) return false;
    g_overlayClassRegistered = true;
  }

  if (!LoadPngToBitmap()) return false;

  int pw = screen_w_ > 0 ? screen_w_ : 1;
  int ph = screen_h_ > 0 ? screen_h_ : 1;

  hwnd_ = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
      kOverlayClass, L"", WS_POPUP,
      screen_x_, screen_y_, pw, ph,
      nullptr, nullptr, GetModuleHandleW(nullptr), this);

  if (!hwnd_) return false;

  SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  ShowLayered();
  return true;
}

bool AnnotationOverlay::LoadPngToBitmap() {
  HGLOBAL hGlobal = GlobalAlloc(GMEM_MOVEABLE, png_bytes_.size());
  if (!hGlobal) return false;
  void* pData = GlobalLock(hGlobal);
  if (!pData) { GlobalFree(hGlobal); return false; }
  memcpy(pData, png_bytes_.data(), png_bytes_.size());
  GlobalUnlock(hGlobal);

  IStream* pStream = nullptr;
  if (FAILED(CreateStreamOnHGlobal(hGlobal, TRUE, &pStream))) {
    GlobalFree(hGlobal); return false;
  }
  Gdiplus::Bitmap* gdiBmp = Gdiplus::Bitmap::FromStream(pStream);
  pStream->Release();

  if (!gdiBmp || gdiBmp->GetLastStatus() != Gdiplus::Ok) {
    if (gdiBmp) delete gdiBmp;
    return false;
  }

  img_w_ = gdiBmp->GetWidth();
  img_h_ = gdiBmp->GetHeight();
  if (img_w_ < 1 || img_h_ < 1) { delete gdiBmp; return false; }

  BITMAPINFO bi = {};
  bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
  bi.bmiHeader.biWidth  = img_w_;
  bi.bmiHeader.biHeight = -img_h_;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HDC hdc = GetDC(nullptr);
  hbitmap_ = CreateDIBSection(hdc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  ReleaseDC(nullptr, hdc);

  if (!hbitmap_ || !bits) { delete gdiBmp; return false; }

  Gdiplus::BitmapData gdiData;
  Gdiplus::Rect lockRect(0, 0, img_w_, img_h_);
  gdiBmp->LockBits(&lockRect, Gdiplus::ImageLockModeRead,
                   PixelFormat32bppARGB, &gdiData);

  uint8_t* src = static_cast<uint8_t*>(gdiData.Scan0);
  uint8_t* dst = static_cast<uint8_t*>(bits);
  int stride = gdiData.Stride;

  for (int y = 0; y < img_h_; y++) {
    for (int x = 0; x < img_w_; x++) {
      int si = y * stride + x * 4;
      int di = y * (img_w_ * 4) + x * 4;
      uint8_t b = src[si + 0];
      uint8_t g = src[si + 1];
      uint8_t r = src[si + 2];
      uint8_t a = src[si + 3];
      dst[di + 0] = static_cast<uint8_t>((b * a) / 255);
      dst[di + 1] = static_cast<uint8_t>((g * a) / 255);
      dst[di + 2] = static_cast<uint8_t>((r * a) / 255);
      dst[di + 3] = a;
    }
  }

  gdiBmp->UnlockBits(&gdiData);
  delete gdiBmp;
  return true;
}

void AnnotationOverlay::ShowLayered() {
  if (!hwnd_ || !hbitmap_) return;
  HDC hdcScreen = GetDC(nullptr);
  HDC hdcMem = CreateCompatibleDC(hdcScreen);
  HBITMAP oldBmp = (HBITMAP)SelectObject(hdcMem, hbitmap_);

  BLENDFUNCTION blend = {};
  blend.BlendOp             = AC_SRC_OVER;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat         = AC_SRC_ALPHA;

  RECT rc;
  GetWindowRect(hwnd_, &rc);
  SIZE size = {rc.right - rc.left, rc.bottom - rc.top};
  POINT ptSrc = {0, 0};
  POINT ptDst = {rc.left, rc.top};

  UpdateLayeredWindow(hwnd_, hdcScreen, &ptDst, &size,
                      hdcMem, &ptSrc, 0, &blend, ULW_ALPHA);

  SelectObject(hdcMem, oldBmp);
  DeleteDC(hdcMem);
  ReleaseDC(nullptr, hdcScreen);
}

LRESULT CALLBACK AnnotationOverlay::WndProc(HWND hwnd, UINT msg,
                                            WPARAM wp, LPARAM lp) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lp);
    auto* self = static_cast<AnnotationOverlay*>(cs->lpCreateParams);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    self->hwnd_ = hwnd;
    return DefWindowProcW(hwnd, msg, wp, lp);
  }
  auto* self = reinterpret_cast<AnnotationOverlay*>(
      GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (self) return self->HandleMessage(msg, wp, lp);
  return DefWindowProcW(hwnd, msg, wp, lp);
}

LRESULT AnnotationOverlay::HandleMessage(UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_NCHITTEST:
      return HTTRANSPARENT;
    case WM_PAINT:
      ShowLayered();
      ValidateRect(hwnd_, nullptr);
      return 0;
    case WM_ERASEBKGND:
      return 1;
    case WM_NCDESTROY: {
      hwnd_ = nullptr;
      auto it = std::find_if(g_overlays.begin(), g_overlays.end(),
          [this](const std::unique_ptr<AnnotationOverlay>& p) {
            return p.get() == this;
          });
      if (it != g_overlays.end()) g_overlays.erase(it);
      return 0;
    }
  }
  return DefWindowProcW(hwnd_, msg, wp, lp);
}

}  // namespace

int64_t CreateAnnotationOverlay(const std::vector<uint8_t>& png_bytes,
                                int x, int y, int w, int h) {
  auto overlay = std::make_unique<AnnotationOverlay>(png_bytes, x, y, w, h);
  if (!overlay->Create()) return 0;
  int64_t handle = overlay->Handle();
  g_overlays.push_back(std::move(overlay));
  return handle;
}

void DestroyAnnotationOverlay(int64_t handle) {
  HWND hwnd = reinterpret_cast<HWND>(handle);
  if (!hwnd || !IsWindow(hwnd)) return;
  DestroyWindow(hwnd);
}

void DestroyAllAnnotationOverlays() {
  while (!g_overlays.empty()) {
    auto& ov = g_overlays.back();
    if (ov && ov->Handle()) {
      HWND hwnd = reinterpret_cast<HWND>(ov->Handle());
      if (IsWindow(hwnd)) DestroyWindow(hwnd);
    } else {
      g_overlays.pop_back();
    }
  }
  if (g_overlayGdiplusToken != 0) {
    Gdiplus::GdiplusShutdown(g_overlayGdiplusToken);
    g_overlayGdiplusToken = 0;
  }
}
