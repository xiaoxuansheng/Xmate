// Word preview via Windows Shell IPreviewHandler.
// Hosts the system preview handler in a child HWND embedded in the Flutter
// window.
//
// Cross-process keep-alive:  after CreateWordPreview succeeds the QL process
// marshals its IUnknown reference to a temp file and posts WM_COPYDATA to the
// main process.  The main process unmarshals the data → gets a proxy to the
// *same* Word COM server (not a new one).  When the QL process exits the main
// process proxy keeps the server alive for 120 s, so the next Alt+Q finds it
// still running and avoids the 2–10 s cold CoCreateInstance.
#include "office_preview_handler.h"

#include <shlobj.h>
#include <shlwapi.h>
#include <cstdint>
#include <fstream>
#include <mutex>
#include <unordered_map>

#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")

// ─── Helpers ────────────────────────────────────────────────────────────────

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return {};
  int len =
      MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  if (len <= 1) return {};
  std::wstring result(len - 1, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &result[0], len);
  return result;
}

// ----------------------------------------------------------------------------
// Instance state
// ----------------------------------------------------------------------------

struct WordPreviewInstance {
  HWND hwnd = nullptr;
  IPreviewHandler* handler = nullptr;
  IUnknown* init = nullptr;
};

static std::mutex g_mutex;
static std::unordered_map<int64_t, WordPreviewInstance> g_instances;
static int64_t g_nextHandle = 1;

// ─── Main-process proxy pool ────────────────────────────────────────────────

static const ULONGLONG kKeepAliveMs = 120000;

struct PoolEntry {
  IUnknown* proxy = nullptr;   // unmarshaled proxy
  ULONGLONG expiresAt = 0;
};

static std::mutex g_poolMutex;
static std::unordered_map<int, PoolEntry> g_pool;  // keyed by random token
static int g_poolToken = 1;

static void PrunePool() {
  ULONGLONG now = GetTickCount64();
  std::lock_guard<std::mutex> lock(g_poolMutex);
  auto it = g_pool.begin();
  while (it != g_pool.end()) {
    if (it->second.expiresAt <= now) {
      if (it->second.proxy) it->second.proxy->Release();
      it = g_pool.erase(it);
    } else {
      ++it;
    }
  }
}

// ─── COM marshal: QL → main process ─────────────────────────────────────────
// Best-effort — failures are silent; preview works regardless.

static void MarshalAndSend(HWND hwnd, IUnknown* handler) {
  if (!handler) return;

  // 1. Marshal to stream
  IStream* stream = nullptr;
  if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) return;

  if (FAILED(CoMarshalInterface(stream, IID_IUnknown, handler,
                                 MSHCTX_LOCAL, nullptr, MSHLFLAGS_NORMAL))) {
    stream->Release();
    return;
  }

  // 2. Read stream into buffer
  STATSTG stat;
  if (FAILED(stream->Stat(&stat, STATFLAG_NONAME))) {
    stream->Release();
    return;
  }
  ULONG size = stat.cbSize.LowPart;
  std::vector<BYTE> buf(size);
  LARGE_INTEGER li = {};
  stream->Seek(li, STREAM_SEEK_SET, nullptr);
  ULONG read;
  if (FAILED(stream->Read(buf.data(), size, &read)) || read != size) {
    stream->Release();
    return;
  }
  stream->Release();

  // 3. Write to temp file in AppData\XMate
  char appData[MAX_PATH];
  if (!GetEnvironmentVariableA("APPDATA", appData, MAX_PATH)) return;
  std::string dir = std::string(appData) + "\\XMate";
  CreateDirectoryA(dir.c_str(), nullptr);
  std::string filePath = dir + "\\wl_marshal.bin";
  {
    std::ofstream f(filePath, std::ios::binary | std::ios::trunc);
    if (!f.good()) return;
    f.write(reinterpret_cast<const char*>(buf.data()), size);
  }

  // 4. Post WM_COPYDATA to main process (async — don't block QL).
  HWND hMain = FindWindowW(nullptr, L"xmate");
  if (!hMain) return;

  std::string copy = filePath;  // for the COPYDATASTRUCT payload
  COPYDATASTRUCT cds = {};
  cds.dwData = WM_XMATE_WORD_KEEPALIVE;
  cds.cbData = static_cast<DWORD>(copy.size() + 1);
  cds.lpData = const_cast<char*>(copy.c_str());
  SendMessageW(hMain, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&cds));
}

// ─── Public API ─────────────────────────────────────────────────────────────

bool IsWordPreviewAvailable(const std::wstring& ext) {
  WCHAR clsidStr[64];
  DWORD cch = ARRAYSIZE(clsidStr);
  HRESULT hr = AssocQueryStringW(
      ASSOCF_INIT_DEFAULTTOSTAR, ASSOCSTR_SHELLEXTENSION,
      ext.c_str(),
      L"{8895b1c6-b41f-4c1c-a562-0d564250836f}",
      clsidStr, &cch);
  return SUCCEEDED(hr) && clsidStr[0] != L'\0';
}

int64_t CreateWordPreview(HWND parent, const std::string& path,
                          int x, int y, int w, int h) {
  if (w <= 0 || h <= 0) return 0;

  std::wstring wPath = Utf8ToWide(path);
  if (wPath.empty()) return 0;

  // 1. Resolve CLSID from extension ------------------------------------------
  size_t dot = wPath.rfind(L'.');
  if (dot == std::wstring::npos) return 0;
  std::wstring ext = wPath.substr(dot);

  WCHAR clsidStr[64];
  DWORD cch = ARRAYSIZE(clsidStr);
  HRESULT hr = AssocQueryStringW(
      ASSOCF_INIT_DEFAULTTOSTAR, ASSOCSTR_SHELLEXTENSION,
      ext.c_str(),
      L"{8895b1c6-b41f-4c1c-a562-0d564250836f}",
      clsidStr, &cch);
  if (FAILED(hr) || clsidStr[0] == L'\0') return 0;

  CLSID clsid;
  hr = CLSIDFromString(clsidStr, &clsid);
  if (FAILED(hr)) return 0;

  // 2. Create preview handler COM object -------------------------------------
  IPreviewHandler* handler = nullptr;
  hr = CoCreateInstance(clsid, nullptr,
                        CLSCTX_LOCAL_SERVER | CLSCTX_INPROC_SERVER,
                        IID_IPreviewHandler,
                        reinterpret_cast<void**>(&handler));
  if (FAILED(hr) || !handler) return 0;

  // 3. Initialize with file --------------------------------------------------
  IUnknown* init = nullptr;
  {
    IInitializeWithFile* initFile = nullptr;
    hr = handler->QueryInterface(IID_IInitializeWithFile,
                                 reinterpret_cast<void**>(&initFile));
    if (SUCCEEDED(hr) && initFile) {
      hr = initFile->Initialize(wPath.c_str(), STGM_READ);
      if (FAILED(hr)) {
        initFile->Release();
        handler->Release();
        return 0;
      }
      init = initFile;
    } else {
      IInitializeWithStream* initStream = nullptr;
      hr = handler->QueryInterface(IID_IInitializeWithStream,
                                   reinterpret_cast<void**>(&initStream));
      if (SUCCEEDED(hr) && initStream) {
        IStream* stream = nullptr;
        hr = SHCreateStreamOnFileW(wPath.c_str(), STGM_READ, &stream);
        if (FAILED(hr) || !stream) {
          initStream->Release();
          handler->Release();
          return 0;
        }
        hr = initStream->Initialize(stream, STGM_READ);
        stream->Release();
        if (FAILED(hr)) {
          initStream->Release();
          handler->Release();
          return 0;
        }
        init = initStream;
      } else {
        handler->Release();
        return 0;
      }
    }
  }

  // 4. Create child HWND -----------------------------------------------------
  HWND hChild = CreateWindowExW(
      0, L"Static", L"XMateWordPreview",
      WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
      x, y, w, h, parent, nullptr, GetModuleHandle(nullptr), nullptr);
  if (!hChild) {
    init->Release();
    handler->Release();
    return 0;
  }

  // 5. Set preview window and trigger render ---------------------------------
  RECT rc = {0, 0, w, h};
  hr = handler->SetWindow(hChild, &rc);
  if (FAILED(hr)) {
    DestroyWindow(hChild);
    init->Release();
    handler->Release();
    return 0;
  }

  hr = handler->SetRect(&rc);
  if (FAILED(hr)) {
    DestroyWindow(hChild);
    init->Release();
    handler->Release();
    return 0;
  }

  hr = handler->DoPreview();
  if (FAILED(hr)) {
    DestroyWindow(hChild);
    init->Release();
    handler->Release();
    return 0;
  }

  SetWindowPos(hChild, HWND_TOP, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);

  // 6. Register instance -----------------------------------------------------
  WordPreviewInstance inst;
  inst.hwnd = hChild;
  inst.handler = handler;
  inst.init = init;

  int64_t handle;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    handle = g_nextHandle++;
    g_instances[handle] = inst;
  }

  // 7. Marshal to main process (best-effort, non-blocking for QL) ------------
  // Marshal the handler — the main process gets a proxy to the SAME server.
  MarshalAndSend(hChild, handler);

  return handle;
}

void SetWordPreviewRect(int64_t instance, int x, int y, int w, int h) {
  if (instance == 0 || w <= 0 || h <= 0) return;

  std::lock_guard<std::mutex> lock(g_mutex);
  auto it = g_instances.find(instance);
  if (it == g_instances.end()) return;

  const auto& inst = it->second;
  MoveWindow(inst.hwnd, x, y, w, h, TRUE);

  RECT rc = {0, 0, w, h};
  if (inst.handler) {
    inst.handler->SetRect(&rc);
  }

  // Always re-assert z-order — Flutter may push its child HWND above ours
  // during title-bar interaction (e.g. hover → hit-test → SetFocus).
  SetWindowPos(inst.hwnd, HWND_TOP, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

void DestroyWordPreview(int64_t instance) {
  if (instance == 0) return;

  WordPreviewInstance inst;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_instances.find(instance);
    if (it == g_instances.end()) return;
    inst = it->second;
    g_instances.erase(it);
  }

  // Unload and destroy the HWND, but do NOT release the COM references.
  // The main process holds a marshaled proxy that keeps the Word COM server
  // alive for 120 s across QL restarts.
  if (inst.handler) {
    inst.handler->Unload();
    // Intentionally NOT calling handler->Release().
  }
  if (inst.hwnd) {
    DestroyWindow(inst.hwnd);
  }
  // init is intentionally NOT released.
}

void DestroyAllWordPreviews() {
  // Destroy all live preview instances.
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    for (auto& kv : g_instances) {
      auto& inst = kv.second;
      if (inst.handler) {
        inst.handler->Unload();
        inst.handler->Release(); // ← release now — we're exiting anyway
        inst.handler = nullptr;
      }
      if (inst.hwnd) {
        DestroyWindow(inst.hwnd);
        inst.hwnd = nullptr;
      }
    }
    g_instances.clear();
  }
  // Release the entire COM proxy keep-alive pool.
  {
    std::lock_guard<std::mutex> lock(g_poolMutex);
    for (auto& kv : g_pool) {
      if (kv.second.proxy) {
        kv.second.proxy->Release();
      }
    }
    g_pool.clear();
  }
}

// ─── Main-process keep-alive ────────────────────────────────────────────────

void KeepWordHandlerAlive(const std::string& filePath) {
  // 1. Read marshaled data from temp file
  std::ifstream f(filePath, std::ios::binary | std::ios::ate);
  if (!f.good()) return;
  size_t size = static_cast<size_t>(f.tellg());
  if (size == 0) return;
  f.seekg(0, std::ios::beg);
  std::vector<BYTE> buf(size);
  f.read(reinterpret_cast<char*>(buf.data()), size);
  f.close();
  DeleteFileA(filePath.c_str());

  // 2. Unmarshal → get proxy (near-instant, server is already running)
  IStream* stream = nullptr;
  if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) return;
  ULONG written;
  stream->Write(buf.data(), static_cast<ULONG>(size), &written);
  LARGE_INTEGER li = {};
  stream->Seek(li, STREAM_SEEK_SET, nullptr);

  IUnknown* proxy = nullptr;
  HRESULT hr = CoUnmarshalInterface(stream, IID_IUnknown,
                                     reinterpret_cast<void**>(&proxy));
  stream->Release();
  if (FAILED(hr) || !proxy) return;

  // 3. Prune and add to pool
  PrunePool();
  {
    std::lock_guard<std::mutex> lock(g_poolMutex);
    g_pool[g_poolToken++] = {proxy, GetTickCount64() + kKeepAliveMs};
  }
}
