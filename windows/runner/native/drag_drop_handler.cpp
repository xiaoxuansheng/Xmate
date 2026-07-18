#include "drag_drop_handler.h"
#include <shellapi.h>
#include <shlobj.h>   // DROPFILES
#include <gdiplus.h>  // DIB conversion
#include <fstream>

#pragma comment(lib, "gdiplus.lib")

namespace {

std::string WstrToUtf8(const wchar_t* wstr) {
  int len = WideCharToMultiByte(CP_UTF8, 0, wstr, -1, nullptr, 0, nullptr, nullptr);
  if (len <= 0) return "";
  std::string result(static_cast<size_t>(len) - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wstr, -1, &result[0], len, nullptr, nullptr);
  return result;
}

std::wstring Utf8ToWstr(const std::string& s) {
  int len = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  if (len <= 0) return L"";
  std::wstring result(static_cast<size_t>(len) - 1, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &result[0], len);
  return result;
}

bool HasFormat(IDataObject* p, CLIPFORMAT cf) {
  FORMATETC fmt = {cf, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  return p->QueryGetData(&fmt) == S_OK;
}

FORMATETC MakeFormatEtc(CLIPFORMAT cf, TYMED tymed = TYMED_HGLOBAL) {
  FORMATETC fmt = {};
  fmt.cfFormat = cf;
  fmt.ptd = nullptr;
  fmt.dwAspect = DVASPECT_CONTENT;
  fmt.lindex = -1;
  fmt.tymed = tymed;
  return fmt;
}

// ── GDI+ one-shot init ─────────────────────────────────────────────

ULONG_PTR g_gdiToken = 0;

void EnsureGdiPlus() {
  if (g_gdiToken == 0) {
    Gdiplus::GdiplusStartupInput input;
    Gdiplus::GdiplusStartup(&g_gdiToken, &input, nullptr);
  }
}

// Read image file → Gdiplus::Bitmap → CF_DIB bytes.
// Returns empty vector on failure.
std::vector<uint8_t> ImageFileToDib(const std::wstring& path) {
  EnsureGdiPlus();
  auto* bitmap = Gdiplus::Bitmap::FromFile(path.c_str());
  if (!bitmap || bitmap->GetLastStatus() != Gdiplus::Ok) {
    delete bitmap;
    return {};
  }
  Gdiplus::Rect rc(0, 0, bitmap->GetWidth(), bitmap->GetHeight());
  Gdiplus::BitmapData bd = {};
  if (bitmap->LockBits(&rc, Gdiplus::ImageLockModeRead, PixelFormat32bppARGB, &bd) != Gdiplus::Ok) {
    delete bitmap;
    return {};
  }

  // DIB = BITMAPINFOHEADER + pixels (bottom-up)
  int w = bd.Width, h = bd.Height;
  int rowBytes = ((w * 32 + 31) / 32) * 4;
  int pixelBytes = rowBytes * h;

  BITMAPINFOHEADER bih = {};
  bih.biSize = sizeof(bih);
  bih.biWidth = w;
  bih.biHeight = h;  // positive = bottom-up
  bih.biPlanes = 1;
  bih.biBitCount = 32;
  bih.biCompression = BI_RGB;
  bih.biSizeImage = pixelBytes;

  std::vector<uint8_t> dib(sizeof(bih) + pixelBytes);
  memcpy(&dib[0], &bih, sizeof(bih));

  // GDI+ gives top-down BGRA; DIB wants bottom-up BGRA
  auto* dst = &dib[sizeof(bih)];
  auto* src = static_cast<BYTE*>(bd.Scan0);
  for (int y = 0; y < h; y++) {
    memcpy(dst + (h - 1 - y) * rowBytes, src + y * bd.Stride, rowBytes);
  }

  bitmap->UnlockBits(&bd);
  delete bitmap;
  return dib;
}

} // namespace

// ═════════════════════════════════════════════════════════════════════
// MultiFormatEnum — 1–3 formats
// ═════════════════════════════════════════════════════════════════════

void MultiFormatEnum::Add(FORMATETC fmt) {
  if (count_ < 3) { fmts_[count_] = fmt; count_++; }
}

STDMETHODIMP MultiFormatEnum::QueryInterface(REFIID riid, void** ppv) {
  if (riid == IID_IUnknown || riid == IID_IEnumFORMATETC) {
    *ppv = static_cast<IEnumFORMATETC*>(this); AddRef(); return S_OK;
  }
  *ppv = nullptr; return E_NOINTERFACE;
}
STDMETHODIMP_(ULONG) MultiFormatEnum::AddRef() { return InterlockedIncrement(&ref_); }
STDMETHODIMP_(ULONG) MultiFormatEnum::Release() {
  LONG c = InterlockedDecrement(&ref_); if (c == 0) delete this; return c;
}

STDMETHODIMP MultiFormatEnum::Next(ULONG celt, FORMATETC* rgelt, ULONG* pceltFetched) {
  if (pceltFetched) *pceltFetched = 0;
  if (celt == 0) return S_OK;
  if (pos_ >= count_) return S_FALSE;
  *rgelt = fmts_[pos_];
  pos_++;
  if (pceltFetched) *pceltFetched = 1;
  return (celt == 1 || pos_ >= count_) ? S_OK : S_FALSE;
}

STDMETHODIMP MultiFormatEnum::Skip(ULONG celt) {
  pos_ += (int)celt; if (pos_ > count_) pos_ = count_; return S_OK;
}
STDMETHODIMP MultiFormatEnum::Reset() { pos_ = 0; return S_OK; }
STDMETHODIMP MultiFormatEnum::Clone(IEnumFORMATETC**) { return E_NOTIMPL; }

// ═════════════════════════════════════════════════════════════════════
// MultiFormatDragData — CF_HDROP + CF_DIB + CF_UNICODETEXT
// ═════════════════════════════════════════════════════════════════════

MultiFormatDragData::MultiFormatDragData() {}

void MultiFormatDragData::SetFiles(const std::vector<std::wstring>& files) {
  files_ = files;
  fmts_[fmtCount_] = MakeFormatEtc(CF_HDROP);
  fmtCount_++;
}

bool MultiFormatDragData::SetImageFromFile(const std::wstring& path) {
  dib_ = ImageFileToDib(path);
  if (dib_.empty()) return false;
  fmts_[fmtCount_] = MakeFormatEtc(CF_DIB);
  fmtCount_++;
  return true;
}

void MultiFormatDragData::SetText(const std::string& text) {
  text_ = Utf8ToWstr(text);
  fmts_[fmtCount_] = MakeFormatEtc(CF_UNICODETEXT);
  fmtCount_++;
}

STDMETHODIMP MultiFormatDragData::QueryInterface(REFIID riid, void** ppv) {
  if (riid == IID_IUnknown || riid == IID_IDataObject) {
    *ppv = static_cast<IDataObject*>(this); AddRef(); return S_OK;
  }
  *ppv = nullptr; return E_NOINTERFACE;
}
STDMETHODIMP_(ULONG) MultiFormatDragData::Release() {
  LONG c = InterlockedDecrement(&ref_); if (c == 0) delete this; return c;
}

bool FormatMatches(const FORMATETC& a, const FORMATETC& b) {
  return a.cfFormat == b.cfFormat && a.dwAspect == b.dwAspect
      && (a.tymed & b.tymed) && a.lindex == b.lindex;
}

STDMETHODIMP MultiFormatDragData::GetData(FORMATETC* pf, STGMEDIUM* pMedium) {
  if (!pf || !pMedium) return E_INVALIDARG;
  ZeroMemory(pMedium, sizeof(*pMedium));
  for (int i = 0; i < fmtCount_; i++) {
    if (FormatMatches(fmts_[i], *pf)) {
      if (fmts_[i].cfFormat == CF_HDROP)   return GetHdropData(pMedium);
      if (fmts_[i].cfFormat == CF_DIB)      return GetDibData(pMedium);
      if (fmts_[i].cfFormat == CF_UNICODETEXT) return GetTextData(pMedium);
    }
  }
  return DV_E_FORMATETC;
}

STDMETHODIMP MultiFormatDragData::QueryGetData(FORMATETC* pf) {
  if (!pf) return E_INVALIDARG;
  for (int i = 0; i < fmtCount_; i++)
    if (FormatMatches(fmts_[i], *pf)) return S_OK;
  return DV_E_FORMATETC;
}

STDMETHODIMP MultiFormatDragData::EnumFormatEtc(DWORD dwDir, IEnumFORMATETC** ppenum) {
  if (!ppenum) return E_INVALIDARG; *ppenum = nullptr;
  if (dwDir == DATADIR_GET) {
    auto* e = new MultiFormatEnum();
    for (int i = 0; i < fmtCount_; i++) e->Add(fmts_[i]);
    *ppenum = e; return S_OK;
  }
  return E_NOTIMPL;
}

HRESULT MultiFormatDragData::GetHdropData(STGMEDIUM* pMedium) {
  size_t totalChars = 0;
  for (auto& f : files_) totalChars += f.size() + 1;
  totalChars += 1;
  size_t bufSize = sizeof(DROPFILES) + totalChars * sizeof(wchar_t);

  HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bufSize);
  if (!h) return E_OUTOFMEMORY;
  auto* locked = static_cast<BYTE*>(GlobalLock(h));
  if (!locked) { GlobalFree(h); return E_OUTOFMEMORY; }

  auto* df = reinterpret_cast<DROPFILES*>(locked);
  df->pFiles = sizeof(DROPFILES);
  df->pt.x = 0; df->pt.y = 0;
  df->fNC = FALSE;
  df->fWide = TRUE;

  wchar_t* base = reinterpret_cast<wchar_t*>(locked + sizeof(DROPFILES));
  wchar_t* dst = base;
  for (auto& f : files_) {
    size_t rem = totalChars - (dst - base);
    wcscpy_s(dst, rem, f.c_str());
    dst += f.size() + 1;
  }
  *dst = L'\0';

  GlobalUnlock(h);
  pMedium->tymed = TYMED_HGLOBAL;
  pMedium->hGlobal = h;
  pMedium->pUnkForRelease = nullptr;
  return S_OK;
}

HRESULT MultiFormatDragData::GetDibData(STGMEDIUM* pMedium) {
  if (dib_.empty()) return E_FAIL;
  HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, dib_.size());
  if (!h) return E_OUTOFMEMORY;
  auto* p = static_cast<BYTE*>(GlobalLock(h));
  if (!p) { GlobalFree(h); return E_OUTOFMEMORY; }
  memcpy(p, dib_.data(), dib_.size());
  GlobalUnlock(h);
  pMedium->tymed = TYMED_HGLOBAL;
  pMedium->hGlobal = h;
  pMedium->pUnkForRelease = nullptr;
  return S_OK;
}

HRESULT MultiFormatDragData::GetTextData(STGMEDIUM* pMedium) {
  size_t bytes = (text_.size() + 1) * sizeof(wchar_t);
  HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (!h) return E_OUTOFMEMORY;
  auto* p = static_cast<wchar_t*>(GlobalLock(h));
  if (!p) { GlobalFree(h); return E_OUTOFMEMORY; }
  memcpy(p, text_.c_str(), bytes);
  GlobalUnlock(h);
  pMedium->tymed = TYMED_HGLOBAL;
  pMedium->hGlobal = h;
  pMedium->pUnkForRelease = nullptr;
  return S_OK;
}

// ═════════════════════════════════════════════════════════════════════
// FileDragSource
// ═════════════════════════════════════════════════════════════════════

STDMETHODIMP FileDragSource::QueryInterface(REFIID riid, void** ppv) {
  if (riid == IID_IUnknown || riid == IID_IDropSource) {
    *ppv = static_cast<IDropSource*>(this); AddRef(); return S_OK;
  }
  *ppv = nullptr; return E_NOINTERFACE;
}
STDMETHODIMP_(ULONG) FileDragSource::Release() {
  LONG c = InterlockedDecrement(&ref_); if (c == 0) delete this; return c;
}
STDMETHODIMP FileDragSource::QueryContinueDrag(BOOL esc, DWORD keys) {
  if (esc) return DRAGDROP_S_CANCEL;
  if (!(keys & (MK_LBUTTON | MK_RBUTTON))) return DRAGDROP_S_DROP;
  return S_OK;
}
STDMETHODIMP FileDragSource::GiveFeedback(DWORD) {
  return DRAGDROP_S_USEDEFAULTCURSORS;
}

// ═════════════════════════════════════════════════════════════════════
// StartDrag — entry point
// ═════════════════════════════════════════════════════════════════════

bool StartDrag(HWND hwnd, DragDataType type,
               const std::vector<std::string>& files,
               const std::string& text) {
  if (!(GetAsyncKeyState(VK_LBUTTON) & 0x8000)) {
    OutputDebugStringW(L"[XMate] StartDrag: left button not held");
    return false;
  }

  auto* data = new MultiFormatDragData();

  switch (type) {
    case DRAG_FILES: {
      if (files.empty()) { data->Release(); return false; }
      std::vector<std::wstring> wide;
      for (auto& f : files) wide.push_back(Utf8ToWstr(f));
      data->SetFiles(wide);
      break;
    }
    case DRAG_IMAGE: {
      if (files.empty()) { data->Release(); return false; }
      if (!data->SetImageFromFile(Utf8ToWstr(files[0]))) {
        OutputDebugStringW(L"[XMate] StartDrag: image decode failed");
        data->Release(); return false;
      }
      // Also attach CF_HDROP so Explorer/Desktop can see the file
      {
        std::vector<std::wstring> wide = {Utf8ToWstr(files[0])};
        data->SetFiles(wide);
      }
      break;
    }
    case DRAG_TEXT: {
      if (text.empty()) { data->Release(); return false; }
      data->SetText(text);
      break;
    }
  }

  if (data->FormatCount() == 0) { data->Release(); return false; }

  auto* src = new FileDragSource();
  DWORD effect = 0;
  HRESULT hr = DoDragDrop(data, src,
      DROPEFFECT_COPY | DROPEFFECT_MOVE | DROPEFFECT_LINK, &effect);
  data->Release();
  src->Release();
  return hr == DRAGDROP_S_DROP;
}

// ═════════════════════════════════════════════════════════════════════
// DragDropHandler (existing drop-target code below)
// ═════════════════════════════════════════════════════════════════════

DragDropHandler::DragDropHandler()
    : hwnd_(nullptr), oleRef_(1), hasText_(false), hasFiles_(false) {}

DragDropHandler::~DragDropHandler() {
  Unregister();
}

void DragDropHandler::SetCallback(Callback cb) {
  callback_ = std::move(cb);
}

HRESULT DragDropHandler::Register(HWND hwnd) {
  if (hwnd_ == hwnd && hwnd_ != nullptr) return S_FALSE; // already registered
  Unregister();
  hwnd_ = hwnd;
  if (!hwnd_) return E_INVALIDARG;

  HRESULT hr = RegisterDragDrop(hwnd_, this);
  if (FAILED(hr)) {
    wchar_t buf[128];
    swprintf_s(buf, L"[XMate] RegisterDragDrop failed: HRESULT=0x%08lX", hr);
    OutputDebugStringW(buf);
    hwnd_ = nullptr;
    return hr;
  }
  return S_OK;
}

HRESULT DragDropHandler::ReRegister(HWND newHwnd) {
  return Register(newHwnd);
}

void DragDropHandler::Unregister() {
  if (hwnd_) {
    RevokeDragDrop(hwnd_);
    hwnd_ = nullptr;
  }
}

// -- IUnknown --------------------------------------------------------

STDMETHODIMP DragDropHandler::QueryInterface(REFIID riid, void** ppv) {
  if (riid == IID_IUnknown || riid == IID_IDropTarget) {
    *ppv = static_cast<IDropTarget*>(this);
    AddRef();
    return S_OK;
  }
  *ppv = nullptr;
  return E_NOINTERFACE;
}

STDMETHODIMP_(ULONG) DragDropHandler::AddRef() {
  return InterlockedIncrement(&oleRef_);
}

STDMETHODIMP_(ULONG) DragDropHandler::Release() {
  LONG c = InterlockedDecrement(&oleRef_);
  if (c == 0) delete this;
  return c;
}

// -- IDropTarget -----------------------------------------------------

STDMETHODIMP DragDropHandler::DragEnter(IDataObject* p, DWORD, POINTL, DWORD* pdwEffect) {
  hasFiles_ = HasFormat(p, CF_HDROP);
  hasText_  = HasFormat(p, CF_UNICODETEXT) || HasFormat(p, CF_TEXT);
  *pdwEffect = (hasFiles_ || hasText_) ? DROPEFFECT_COPY : DROPEFFECT_NONE;
  wchar_t dbg[96];
  swprintf_s(dbg, L"[XMate] OLE DragEnter hasFiles=%d hasText=%d", hasFiles_, hasText_);
  OutputDebugStringW(dbg);
  return S_OK;
}

STDMETHODIMP DragDropHandler::DragOver(DWORD, POINTL, DWORD* pdwEffect) {
  *pdwEffect = (hasFiles_ || hasText_) ? DROPEFFECT_COPY : DROPEFFECT_NONE;
  return S_OK;
}

STDMETHODIMP DragDropHandler::DragLeave() {
  hasText_ = false;
  hasFiles_ = false;
  return S_OK;
}

STDMETHODIMP DragDropHandler::Drop(IDataObject* p, DWORD, POINTL, DWORD* pdwEffect) {
  wchar_t log[96];
  swprintf_s(log, L"[XMate] OLE Drop hasFiles=%d hasText=%d", hasFiles_, hasText_);
  OutputDebugStringW(log);
  DropData data;

  // Files via CF_HDROP (fallback — primary path is parent WM_DROPFILES)
  if (hasFiles_) {
    FORMATETC fmt = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM med = {};
    if (SUCCEEDED(p->GetData(&fmt, &med))) {
      HDROP hDrop = static_cast<HDROP>(med.hGlobal);
      UINT count = DragQueryFileW(hDrop, 0xFFFFFFFF, nullptr, 0);
      for (UINT i = 0; i < count; i++) {
        wchar_t buf[MAX_PATH];
        if (DragQueryFileW(hDrop, i, buf, MAX_PATH) > 0) {
          data.files.push_back(WstrToUtf8(buf));
        }
      }
      ReleaseStgMedium(&med);
    }
  }

  // Text via CF_UNICODETEXT / CF_TEXT (primary OLE path)
  if (data.files.empty() && hasText_) {
    CLIPFORMAT formats[] = {CF_UNICODETEXT, CF_TEXT};
    for (int i = 0; i < 2; i++) {
      FORMATETC fmt = {formats[i], nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
      STGMEDIUM med = {};
      if (SUCCEEDED(p->GetData(&fmt, &med))) {
        if (formats[i] == CF_UNICODETEXT) {
          auto wstr = static_cast<const wchar_t*>(GlobalLock(med.hGlobal));
          if (wstr) { data.text = WstrToUtf8(wstr); GlobalUnlock(med.hGlobal); }
        } else {
          auto raw = static_cast<const char*>(GlobalLock(med.hGlobal));
          if (raw) { data.text = std::string(raw); GlobalUnlock(med.hGlobal); }
        }
        ReleaseStgMedium(&med);
        if (!data.text.empty()) {
          data.isText = true;
          break;
        }
      }
    }
  }

  *pdwEffect = (!data.files.empty() || data.isText) ? DROPEFFECT_COPY : DROPEFFECT_NONE;

  if ((!data.files.empty() || data.isText) && callback_) {
    callback_(data);
  }
  return S_OK;
}
