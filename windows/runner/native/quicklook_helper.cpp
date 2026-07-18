// QuickLook helper: query the active Explorer window for the selected file.
// Uses COM IShellWindows -> IShellBrowser -> IFolderView -> IShellItem.
// Only CabinetWClass / ExploreWClass. Returns JSON with forward-slash paths.

#include "quicklook_helper.h"
#include <windows.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <sstream>

#include <exdisp.h>

#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")

namespace {

template <typename T>
class ComPtr {
 public:
  ComPtr() : ptr_(nullptr) {}
  explicit ComPtr(T* p) : ptr_(p) {}
  ~ComPtr() { if (ptr_) ptr_->Release(); }
  T* operator->() { return ptr_; }
  T** operator&() { ptr_ = nullptr; return &ptr_; }
  T* get() const { return ptr_; }
  bool ok() const { return ptr_ != nullptr; }
 private:
  T* ptr_;
  ComPtr(const ComPtr&) = delete;
  ComPtr& operator=(const ComPtr&) = delete;
};

std::string WideToUtf8(const wchar_t* ws) {
  if (!ws || !*ws) return "";
  int len = WideCharToMultiByte(CP_UTF8, 0, ws, -1, nullptr, 0, nullptr, nullptr);
  if (len <= 0) return "";
  std::string result(len - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, ws, -1, &result[0], len, nullptr, nullptr);
  return result;
}

void NormalizeSlashes(std::string& s) {
  for (auto& c : s) if (c == '\\') c = '/';
}

std::string GetItemPath(IShellItem* item) {
  if (!item) return "";
  wchar_t* displayName = nullptr;
  HRESULT hr = item->GetDisplayName(SIGDN_FILESYSPATH, &displayName);
  if (FAILED(hr) || !displayName) return "";
  std::string path = WideToUtf8(displayName);
  CoTaskMemFree(displayName);
  NormalizeSlashes(path);
  return path;
}

const char* kEmpty = R"({"path":"","count":0})";

std::string GetSelectionFromView(IShellView* shellView) {
  ComPtr<IFolderView> folderView;
  HRESULT hr = shellView->QueryInterface(IID_IFolderView, (void**)&folderView);
  if (FAILED(hr) || !folderView.ok()) return kEmpty;

  int selCount = 0;
  if (FAILED(folderView->ItemCount(SVGIO_SELECTION, &selCount)) || selCount == 0)
    return kEmpty;

  ComPtr<IFolderView2> folderView2;
  hr = shellView->QueryInterface(IID_IFolderView2, (void**)&folderView2);
  if (FAILED(hr) || !folderView2.ok()) return kEmpty;

  ComPtr<IShellItemArray> selItems;
  hr = folderView2->Items(SVGIO_SELECTION, IID_PPV_ARGS(&selItems));
  if (FAILED(hr) || !selItems.ok()) return kEmpty;

  DWORD itemCount = 0;
  if (FAILED(selItems->GetCount(&itemCount)) || itemCount == 0) return kEmpty;

  ComPtr<IShellItem> item;
  hr = selItems->GetItemAt(0, &item);
  if (FAILED(hr) || !item.ok()) return kEmpty;

  std::string path = GetItemPath(item.get());
  if (path.empty()) return kEmpty;

  std::ostringstream json;
  json << R"({"path":")" << path << R"(","count":)" << itemCount << "}";
  return json.str();
}

}  // namespace

std::string GetExplorerSelection() {
  HWND fg = GetForegroundWindow();
  if (!fg) return kEmpty;

  // Only CabinetWClass and ExploreWClass - skip Progman/WorkerW (desktop).
  wchar_t cls[256] = {};
  GetClassNameW(fg, cls, 256);
  if (_wcsicmp(cls, L"CabinetWClass") != 0 &&
      _wcsicmp(cls, L"ExploreWClass") != 0) {
    return kEmpty;
  }

  ComPtr<IShellWindows> shellWindows;
  HRESULT hr = CoCreateInstance(CLSID_ShellWindows, nullptr, CLSCTX_ALL,
                                 IID_PPV_ARGS(&shellWindows));
  if (FAILED(hr) || !shellWindows.ok()) return kEmpty;

  long count = 0;
  if (FAILED(shellWindows->get_Count(&count))) return kEmpty;

  for (long i = 0; i < count; ++i) {
    ComPtr<IDispatch> disp;
    VARIANT idx;
    VariantInit(&idx);
    idx.vt = VT_I4;
    idx.lVal = i;
    hr = shellWindows->Item(idx, &disp);
    VariantClear(&idx);
    if (FAILED(hr) || !disp.ok()) continue;

    ComPtr<IWebBrowserApp> browser;
    hr = disp->QueryInterface(IID_IWebBrowserApp, (void**)&browser);
    if (FAILED(hr) || !browser.ok()) continue;

    SHANDLE_PTR browserHwnd = 0;
    if (FAILED(browser->get_HWND(&browserHwnd)) || (HWND)browserHwnd != fg)
      continue;

    ComPtr<IServiceProvider> sp;
    hr = browser->QueryInterface(IID_IServiceProvider, (void**)&sp);
    if (FAILED(hr) || !sp.ok()) continue;

    ComPtr<IShellBrowser> shellBrowser;
    hr = sp->QueryService(SID_STopLevelBrowser, IID_IShellBrowser,
                           (void**)&shellBrowser);
    if (FAILED(hr) || !shellBrowser.ok()) continue;

    ComPtr<IShellView> shellView;
    hr = shellBrowser->QueryActiveShellView(&shellView);
    if (FAILED(hr) || !shellView.ok()) continue;

    std::string result = GetSelectionFromView(shellView.get());
    if (result != kEmpty) return result;
  }

  return kEmpty;
}

int CloseQuickLookWindows(bool includePinned) {
  struct CloseContext {
    int count = 0;
    bool includePinned = false;
  } ctx;
  ctx.includePinned = includePinned;

  EnumWindows([](HWND hwnd, LPARAM lp) -> BOOL {
    CloseContext* pCtx = reinterpret_cast<CloseContext*>(lp);
    wchar_t title[256] = {};
    GetWindowTextW(hwnd, title, 256);
    if (_wcsicmp(title, L"xmate_ql") == 0) {
      SendMessageW(hwnd, WM_CLOSE, 0, 0);
      pCtx->count++;
    } else if (pCtx->includePinned && _wcsicmp(title, L"xmate_ql_pinned") == 0) {
      SendMessageW(hwnd, WM_CLOSE, 0, 0);
      pCtx->count++;
    }
    return TRUE;
  }, reinterpret_cast<LPARAM>(&ctx));
  return ctx.count;
}
