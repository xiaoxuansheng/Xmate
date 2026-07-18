// XMate File Operations -- native shell helpers.
#include "file_operations.h"

#include <shellapi.h>
#include <shlobj.h>
#include <shlguid.h>
#include <cstring>
#include <sstream>
#include <string>

#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")

// ---- UTF-8 -> wchar conversion -------------------------------------------

static std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return {};
  int len = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1,
                                nullptr, 0);
  if (len <= 1) return {};
  std::wstring result(len - 1, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1,
                      &result[0], len);
  return result;
}

// ---- CF_HDROP helpers -----------------------------------------------------

static HGLOBAL BuildDropFiles(const std::wstring& path, bool preferMove) {
  // DROPFILES + null-terminated path + double-null terminator.
  //
  // Layout:  [DROPFILES header (pFiles offset -> path data)]
  //          [path wchar_t data] [\0] [\0]  <- explicit double-null
  const size_t pathChars = path.size();
  const size_t dataChars = pathChars + 2;          // path + NUL + NUL
  const size_t dataBytes = dataChars * sizeof(wchar_t);
  const size_t totalSize = sizeof(DROPFILES) + dataBytes;

  HGLOBAL hGlobal = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, totalSize);
  if (!hGlobal) return nullptr;

  DROPFILES* df = static_cast<DROPFILES*>(GlobalLock(hGlobal));
  if (!df) { GlobalFree(hGlobal); return nullptr; }
  df->pFiles = sizeof(DROPFILES);
  df->fWide = TRUE;
  if (preferMove) df->fNC = TRUE;

  // Copy path + explicit double-null (no reliance on wcscpy_s / GMEM_ZEROINIT)
  auto* dest = reinterpret_cast<wchar_t*>(
      reinterpret_cast<unsigned char*>(df) + sizeof(DROPFILES));
  wmemcpy(dest, path.c_str(), pathChars + 1);  // +1 includes the NUL
  dest[pathChars + 1] = L'\0';                  // second NUL — explicit

  GlobalUnlock(hGlobal);
  return hGlobal;
}

bool CopyFilesToClipboard(const std::string& pathUtf8) {
  std::wstring path = Utf8ToWide(pathUtf8);
  if (path.empty()) return false;

  HGLOBAL hDrop = BuildDropFiles(path, false);
  if (!hDrop) return false;

  if (!OpenClipboard(nullptr)) { GlobalFree(hDrop); return false; }
  EmptyClipboard();
  SetClipboardData(CF_HDROP, hDrop);
  CloseClipboard();
  return true;
}

bool CutFilesToClipboard(const std::string& pathUtf8) {
  std::wstring path = Utf8ToWide(pathUtf8);
  if (path.empty()) return false;

  HGLOBAL hDrop = BuildDropFiles(path, true);
  if (!hDrop) return false;

  if (!OpenClipboard(nullptr)) { GlobalFree(hDrop); return false; }
  EmptyClipboard();

  // Set DROPEFFECT_MOVE via CFSTR_PREFERREDDROPEFFECT
  HGLOBAL hEffect = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(DWORD));
  if (hEffect) {
    DWORD* effect = static_cast<DWORD*>(GlobalLock(hEffect));
    if (effect) { *effect = DROPEFFECT_MOVE; GlobalUnlock(hEffect); }
    SetClipboardData(RegisterClipboardFormatW(CFSTR_PREFERREDDROPEFFECT), hEffect);
  }

  SetClipboardData(CF_HDROP, hDrop);
  CloseClipboard();
  return true;
}

// ---- Desktop shortcut -----------------------------------------------------

bool CreateDesktopShortcut(const std::string& pathUtf8) {
  std::wstring path = Utf8ToWide(pathUtf8);
  if (path.empty()) return false;

  // Extract filename for the shortcut name
  auto lastSlash = path.find_last_of(L"\\/");
  std::wstring name = (lastSlash != std::wstring::npos) ? path.substr(lastSlash + 1) : path;
  auto dot = name.rfind(L'.');
  if (dot != std::wstring::npos) name = name.substr(0, dot);
  name += L".lnk";

  // Get Desktop path
  wchar_t desktopPath[MAX_PATH];
  if (FAILED(SHGetFolderPathW(nullptr, CSIDL_DESKTOPDIRECTORY, nullptr, 0, desktopPath))) {
    return false;
  }
  std::wstring lnkPath = std::wstring(desktopPath) + L"\\" + name;

  HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  bool needUninit = (SUCCEEDED(hr));

  IShellLinkW* pShellLink = nullptr;
  hr = CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                        IID_IShellLinkW, reinterpret_cast<void**>(&pShellLink));
  if (FAILED(hr)) { if (needUninit) CoUninitialize(); return false; }

  pShellLink->SetPath(path.c_str());
  pShellLink->SetWorkingDirectory(path.substr(0, lastSlash).c_str());

  IPersistFile* pPersistFile = nullptr;
  hr = pShellLink->QueryInterface(IID_IPersistFile, reinterpret_cast<void**>(&pPersistFile));
  if (SUCCEEDED(hr)) {
    hr = pPersistFile->Save(lnkPath.c_str(), TRUE);
    pPersistFile->Release();
  }

  pShellLink->Release();
  if (needUninit) CoUninitialize();
  return SUCCEEDED(hr);
}

// ---- Delete to Recycle Bin -------------------------------------------------

bool DeleteToRecycleBin(const std::string& pathUtf8) {
  std::wstring path = Utf8ToWide(pathUtf8);
  if (path.empty()) return false;

  // SHFileOperation requires double-null-terminated path
  std::wstring padded = path + L'\0' + L'\0';

  SHFILEOPSTRUCTW fos = {};
  fos.wFunc = FO_DELETE;
  fos.pFrom = padded.c_str();
  fos.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT;

  int ret = SHFileOperationW(&fos);
  return ret == 0;
}

// ---- Show File Properties --------------------------------------------------

bool ShowFileProperties(const std::string& pathUtf8, HWND parentHwnd) {
  std::wstring path = Utf8ToWide(pathUtf8);
  if (path.empty()) return false;

  SHELLEXECUTEINFOW sei = {};
  sei.cbSize = sizeof(sei);
  sei.fMask = SEE_MASK_INVOKEIDLIST;
  sei.lpVerb = L"properties";
  sei.lpFile = path.c_str();
  sei.hwnd = parentHwnd;
  sei.nShow = SW_SHOW;

  return ShellExecuteExW(&sei) == TRUE;
}

// ---- Pin to Start ----------------------------------------------------------

bool PinToStart(const std::string& pathUtf8) {
  std::wstring path = Utf8ToWide(pathUtf8);
  if (path.empty()) return false;

  HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  bool needUninit = (SUCCEEDED(hr));

  IShellItem* pItem = nullptr;
  hr = SHCreateItemFromParsingName(path.c_str(), nullptr, IID_PPV_ARGS(&pItem));
  if (FAILED(hr) || !pItem) { if (needUninit) CoUninitialize(); return false; }

  // Get parent folder to obtain IContextMenu
  IShellItem* pParent = nullptr;
  hr = pItem->GetParent(&pParent);
  if (FAILED(hr) || !pParent) { pItem->Release(); if (needUninit) CoUninitialize(); return false; }

  IContextMenu* pCtxMenu = nullptr;
  hr = pParent->BindToHandler(nullptr, BHID_SFUIObject, IID_PPV_ARGS(&pCtxMenu));
  pParent->Release();
  if (FAILED(hr) || !pCtxMenu) { pItem->Release(); if (needUninit) CoUninitialize(); return false; }

  // Build menu and invoke "startpin"
  HMENU hMenu = CreatePopupMenu();
  hr = pCtxMenu->QueryContextMenu(hMenu, 0, 1, 0x7FFF, CMF_DEFAULTONLY);
  if (SUCCEEDED(hr)) {
    CMINVOKECOMMANDINFOEX iciEx = {};
    iciEx.cbSize = sizeof(iciEx);
    iciEx.fMask = CMIC_MASK_UNICODE;
    iciEx.lpVerbW = L"startpin";
    iciEx.nShow = SW_SHOWNORMAL;
    hr = pCtxMenu->InvokeCommand(reinterpret_cast<LPCMINVOKECOMMANDINFO>(&iciEx));
  }
  DestroyMenu(hMenu);

  pCtxMenu->Release();
  pItem->Release();
  if (needUninit) CoUninitialize();
  return SUCCEEDED(hr);
}

// ---- Open as Administrator ------------------------------------------------

bool OpenFileAsAdmin(const std::string& pathUtf8, HWND parentHwnd) {
  std::wstring path = Utf8ToWide(pathUtf8);
  if (path.empty()) return false;

  // Windows cannot elevate a running process.
  // Launch a NEW elevated instance of ourselves that opens the target file
  // and exits immediately (same pattern as ToggleAutoStart / --toggle-autostart).
  WCHAR exePath[MAX_PATH];
  GetModuleFileNameW(NULL, exePath, MAX_PATH);

  // Build quoted parameter: --open-as-admin "<path>"
  std::wstring params = L"--open-as-admin \"";
  params += path;
  params += L"\"";

  SHELLEXECUTEINFOW sei = {};
  sei.cbSize = sizeof(sei);
  sei.lpVerb = L"runas";
  sei.lpFile = exePath;
  sei.lpParameters = params.c_str();
  sei.hwnd = parentHwnd;
  sei.nShow = SW_HIDE;

  return ShellExecuteExW(&sei) == TRUE;
}

// ---- Run Command as Administrator ------------------------------------------

// Simple JSON string escape: \ → \\, " → \"
static std::wstring JsonEscape(const std::wstring& s) {
  std::wstring r;
  r.reserve(s.size() + 8);
  for (wchar_t c : s) {
    if (c == L'\\') { r += L"\\\\"; }
    else if (c == L'"') { r += L"\\\""; }
    else { r += c; }
  }
  return r;
}

bool RunCommandAsAdmin(const std::string& cmdPathUtf8,
                       const std::string& argsUtf8,
                       const std::string& workDirUtf8,
                       HWND parentHwnd) {
  std::wstring cmdPath = Utf8ToWide(cmdPathUtf8);
  std::wstring args = Utf8ToWide(argsUtf8);
  std::wstring workDir = Utf8ToWide(workDirUtf8);
  if (cmdPath.empty()) return false;

  WCHAR exePath[MAX_PATH];
  GetModuleFileNameW(NULL, exePath, MAX_PATH);

  // Build JSON payload: {"p":"...","a":"...","d":"..."}
  std::wstring json = L"{\"p\":\"";
  json += JsonEscape(cmdPath);
  json += L"\",\"a\":\"";
  json += JsonEscape(args);
  json += L"\",\"d\":\"";
  json += JsonEscape(workDir);
  json += L"\"}";

  // Build parameter: --run-command "<json>"
  std::wstring params = L"--run-command \"";
  params += json;
  params += L"\"";

  SHELLEXECUTEINFOW sei = {};
  sei.cbSize = sizeof(sei);
  sei.lpVerb = L"runas";
  sei.lpFile = exePath;
  sei.lpParameters = params.c_str();
  sei.hwnd = parentHwnd;
  sei.nShow = SW_HIDE;

  return ShellExecuteExW(&sei) == TRUE;
}

// ---- Open With dialog (SHOpenWithDialog) ------------------------------------

bool OpenWithDialog(const std::string& pathUtf8, HWND parentHwnd) {
  std::wstring path = Utf8ToWide(pathUtf8);
  if (path.empty()) return false;

  OPENASINFO oaInfo = {};
  oaInfo.pcszFile = path.c_str();
  oaInfo.pcszClass = nullptr;
  oaInfo.oaifInFlags = OAIF_ALLOW_REGISTRATION | OAIF_EXEC;

  return SUCCEEDED(SHOpenWithDialog(parentHwnd, &oaInfo));
}

// ---- File picker (COM IFileOpenDialog) ------------------------------------

#include <shobjidl.h>

std::string PickFile(HWND parentHwnd) {
  HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  bool needUninit = (SUCCEEDED(hr));

  IFileOpenDialog* pDialog = nullptr;
  hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                        IID_PPV_ARGS(&pDialog));
  if (FAILED(hr) || !pDialog) {
    if (needUninit) CoUninitialize();
    return {};
  }

  // Configure the dialog
  DWORD flags;
  pDialog->GetOptions(&flags);
  pDialog->SetOptions(flags | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_FILEMUSTEXIST);

  // Show the dialog
  hr = pDialog->Show(parentHwnd);
  std::string result;
  if (SUCCEEDED(hr)) {
    IShellItem* pItem = nullptr;
    hr = pDialog->GetResult(&pItem);
    if (SUCCEEDED(hr) && pItem) {
      PWSTR pszPath = nullptr;
      hr = pItem->GetDisplayName(SIGDN_FILESYSPATH, &pszPath);
      if (SUCCEEDED(hr) && pszPath) {
        // Convert wstring to UTF-8
        int len = WideCharToMultiByte(CP_UTF8, 0, pszPath, -1,
                                      nullptr, 0, nullptr, nullptr);
        if (len > 1) {
          result.resize(len - 1);
          WideCharToMultiByte(CP_UTF8, 0, pszPath, -1,
                              &result[0], len, nullptr, nullptr);
        }
        CoTaskMemFree(pszPath);
      }
      pItem->Release();
    }
  }
  pDialog->Release();
  if (needUninit) CoUninitialize();
  return result;
}

std::string PickFiles(HWND parentHwnd) {
  HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  bool needUninit = (SUCCEEDED(hr));

  IFileOpenDialog* pDialog = nullptr;
  hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                        IID_PPV_ARGS(&pDialog));
  if (FAILED(hr) || !pDialog) {
    if (needUninit) CoUninitialize();
    return "[]";
  }

  DWORD flags;
  pDialog->GetOptions(&flags);
  pDialog->SetOptions(flags | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_FILEMUSTEXIST | FOS_ALLOWMULTISELECT);

  hr = pDialog->Show(parentHwnd);
  std::string resultJson = "[]";
  if (SUCCEEDED(hr)) {
    IShellItemArray* pResults = nullptr;
    hr = pDialog->GetResults(&pResults);
    if (SUCCEEDED(hr) && pResults) {
      DWORD count = 0;
      pResults->GetCount(&count);

      std::ostringstream json;
      json << "[";
      for (DWORD i = 0; i < count; i++) {
        if (i > 0) json << ",";
        IShellItem* pItem = nullptr;
        if (SUCCEEDED(pResults->GetItemAt(i, &pItem)) && pItem) {
          PWSTR pszPath = nullptr;
          if (SUCCEEDED(pItem->GetDisplayName(SIGDN_FILESYSPATH, &pszPath)) && pszPath) {
            int len = WideCharToMultiByte(CP_UTF8, 0, pszPath, -1, nullptr, 0, nullptr, nullptr);
            if (len > 1) {
              std::string path(len - 1, '\0');
              WideCharToMultiByte(CP_UTF8, 0, pszPath, -1, &path[0], len, nullptr, nullptr);
              json << "\"";
              for (char c : path) {
                if (c == '\\') { json << '/'; }  // normalize to forward slash
                else if (c == '"') { json << "\\\""; }
                else { json << c; }
              }
              json << "\"";
            }
            CoTaskMemFree(pszPath);
          }
          pItem->Release();
        }
      }
      json << "]";
      resultJson = json.str();
      pResults->Release();
    }
  }
  pDialog->Release();
  if (needUninit) CoUninitialize();
  return resultJson;
}

// ---- Indexer Service management ---------------------------------------------

#include <aclapi.h>
#include <accctrl.h>
#include <sddl.h>
#include <shlobj.h>

static std::wstring GetXmateDataDir() {
  wchar_t* p = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_ProgramData, 0, nullptr, &p)))
    return {};
  std::wstring d(p);
  CoTaskMemFree(p);
  if (!d.empty() && d.back() != L'\\') d += L'\\';
  d += L"XMate";
  return d;
}

static const wchar_t* SVC_NAME = L"XMateIndexer";

// ---- Helper: open service control manager -----------------------------------

static SC_HANDLE OpenSCM(DWORD access) {
  return OpenSCManagerW(nullptr, nullptr, access);
}

// ---- Helper: open the XMateIndexer service ----------------------------------

static SC_HANDLE OpenSvc(DWORD access) {
  SC_HANDLE scm = OpenSCM(SC_MANAGER_CONNECT);
  if (!scm) return nullptr;
  SC_HANDLE svc = OpenServiceW(scm, SVC_NAME, access);
  CloseServiceHandle(scm);
  return svc;
}

// ---- Set up directory ACL (SYSTEM=Full, Admins=Full, Users=Modify) ----------

static bool SetupDataDirAcl(const std::wstring& dir) {
  CreateDirectoryW(dir.c_str(), nullptr);

  // Get existing DACL
  PACL pOldDacl = nullptr;
  PSECURITY_DESCRIPTOR pSD = nullptr;
  DWORD rc = GetNamedSecurityInfoW(
      dir.c_str(), SE_FILE_OBJECT,
      DACL_SECURITY_INFORMATION,
      nullptr, nullptr, &pOldDacl, nullptr, &pSD);
  if (rc != ERROR_SUCCESS || !pSD) {
    // If we can't read, just create the directory — ACL will be done
    // by the runas helper.
    CreateDirectoryW(dir.c_str(), nullptr);
    return true;
  }

  // Build new ACEs in an EXPLICIT_ACCESS array
  EXPLICIT_ACCESSW ea[3] = {};
  // SYSTEM: Full control
  ea[0].grfAccessPermissions = GENERIC_ALL;
  ea[0].grfAccessMode = SET_ACCESS;
  ea[0].grfInheritance = SUB_CONTAINERS_AND_OBJECTS_INHERIT;
  ea[0].Trustee.TrusteeForm = TRUSTEE_IS_NAME;
  ea[0].Trustee.TrusteeType = TRUSTEE_IS_WELL_KNOWN_GROUP;
  ea[0].Trustee.ptstrName = const_cast<LPWSTR>(L"SYSTEM");

  // Administrators: Full control
  ea[1].grfAccessPermissions = GENERIC_ALL;
  ea[1].grfAccessMode = SET_ACCESS;
  ea[1].grfInheritance = SUB_CONTAINERS_AND_OBJECTS_INHERIT;
  ea[1].Trustee.TrusteeForm = TRUSTEE_IS_NAME;
  ea[1].Trustee.TrusteeType = TRUSTEE_IS_WELL_KNOWN_GROUP;
  ea[1].Trustee.ptstrName = const_cast<LPWSTR>(L"Administrators");

  // Authenticated Users: Modify
  ea[2].grfAccessPermissions =
      GENERIC_READ | GENERIC_WRITE | GENERIC_EXECUTE | DELETE;
  ea[2].grfAccessMode = SET_ACCESS;
  ea[2].grfInheritance = SUB_CONTAINERS_AND_OBJECTS_INHERIT;
  ea[2].Trustee.TrusteeForm = TRUSTEE_IS_NAME;
  ea[2].Trustee.TrusteeType = TRUSTEE_IS_WELL_KNOWN_GROUP;
  ea[2].Trustee.ptstrName = const_cast<LPWSTR>(L"Authenticated Users");

  PACL pNewDacl = nullptr;
  rc = SetEntriesInAclW(3, ea, pOldDacl, &pNewDacl);
  if (rc != ERROR_SUCCESS) {
    LocalFree(pSD);
    return false;
  }

  rc = SetNamedSecurityInfoW(
      const_cast<LPWSTR>(dir.c_str()), SE_FILE_OBJECT,
      DACL_SECURITY_INFORMATION,
      nullptr, nullptr, pNewDacl, nullptr);

  LocalFree(pNewDacl);
  LocalFree(pSD);
  return rc == ERROR_SUCCESS;
}

// ---- Setup service ACL (grant Users START + QUERY_STATUS) -------------------

static bool SetupServiceAcl(SC_HANDLE svc) {
  // Full SDDL:
  //   SY: SYSTEM = full control
  //   BA: Built-in Admins = full control
  //   IU: Interactive Users = start + stop + query (WP=Stop, RP=Start, CC=QC, LC=QS)
  const wchar_t* sddl =
      L"D:"
      L"(A;;CCLCSWRPWPDTLOCRRC;;;SY)"
      L"(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)"
      L"(A;;CCLCRPWPRC;;;IU)";

  PSECURITY_DESCRIPTOR pSD = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          sddl, SDDL_REVISION_1, &pSD, nullptr))
    return false;

  BOOL ok = SetServiceObjectSecurity(svc, DACL_SECURITY_INFORMATION, pSD);
  LocalFree(pSD);
  return ok == TRUE;
}

// ---- Public API -------------------------------------------------------------

bool InstallIndexerService() {
  // 1. Create data directory with ACL
  std::wstring dataDir = GetXmateDataDir();
  SetupDataDirAcl(dataDir);
  std::wstring resultsDir = dataDir + L"\\index_results";
  CreateDirectoryW(resultsDir.c_str(), nullptr);

  // 2. Copy the service binary (and its DLL dependencies) to a standalone
  //    directory so that rebuilds of the main output directory don't lock
  //    files the service is holding open (WebView2Loader.dll, xmate.exe, etc.).
  //    The service runs from %ProgramData%\XMate\bin\ — completely decoupled
  //    from the build output.
  std::wstring binDir = dataDir + L"\\bin";
  CreateDirectoryW(binDir.c_str(), nullptr);

  WCHAR exePath[MAX_PATH];
  GetModuleFileNameW(nullptr, exePath, MAX_PATH);
  std::wstring srcDir = exePath;
  size_t lastSlash = srcDir.find_last_of(L'\\');
  if (lastSlash != std::wstring::npos) srcDir = srcDir.substr(0, lastSlash + 1);

  // Copy all DLLs from the source directory so the service can start.
  // flutter_windows.dll cascades into ~100 MB of plugin / runtime DLLs —
  // copying everything is simpler than chasing the dependency chain.
  WIN32_FIND_DATAW fd;
  HANDLE hFind = FindFirstFileW((srcDir + L"*.dll").c_str(), &fd);
  if (hFind != INVALID_HANDLE_VALUE) {
    do {
      CopyFileW((srcDir + fd.cFileName).c_str(),
                (binDir + L"\\" + fd.cFileName).c_str(), FALSE);
    } while (FindNextFileW(hFind, &fd));
    FindClose(hFind);
  }
  CopyFileW((srcDir + L"xmate.exe").c_str(), (binDir + L"\\xmate.exe").c_str(), FALSE);
  CopyFileW((srcDir + L"7za.exe").c_str(), (binDir + L"\\7za.exe").c_str(), FALSE);

  std::wstring cmdLine = L"\"" + binDir + L"\\xmate.exe\" --run-service";

  // 3. Create service
  SC_HANDLE scm = OpenSCM(SC_MANAGER_CREATE_SERVICE);
  if (!scm) return false;

  SC_HANDLE svc = CreateServiceW(
      scm, SVC_NAME, L"XMate Index Update Service",
      SERVICE_QUERY_STATUS | SERVICE_START | SERVICE_STOP |
          READ_CONTROL | WRITE_DAC,
      SERVICE_WIN32_OWN_PROCESS,
      SERVICE_DEMAND_START,
      SERVICE_ERROR_NORMAL,
      cmdLine.c_str(),
      nullptr, nullptr, nullptr, nullptr, nullptr);
  if (!svc) {
    // Already exists — open for ACL update.  Also update the binary path
    // in case the build output moved.
    svc = OpenServiceW(scm, SVC_NAME,
                       SERVICE_QUERY_STATUS | READ_CONTROL | WRITE_DAC |
                       SERVICE_CHANGE_CONFIG);
    if (svc) {
      // Update binary path to point at the standalone copy
      ChangeServiceConfigW(svc, SERVICE_NO_CHANGE, SERVICE_NO_CHANGE,
                           SERVICE_NO_CHANGE, cmdLine.c_str(),
                           nullptr, nullptr, nullptr, nullptr, nullptr, nullptr);
    }
  }

  if (svc) {
    SetupServiceAcl(svc);
    CloseServiceHandle(svc);
  }

  CloseServiceHandle(scm);
  return svc != nullptr;
}

bool UninstallIndexerService() {
  SC_HANDLE svc = OpenSvc(SERVICE_STOP | DELETE);
  if (!svc) return false;

  // Stop first
  SERVICE_STATUS ss = {};
  ControlService(svc, SERVICE_CONTROL_STOP, &ss);

  BOOL ok = DeleteService(svc);
  CloseServiceHandle(svc);

  // Clean up the standalone bin directory
  std::wstring binDir = GetXmateDataDir() + L"\\bin";
  // Remove all files in the bin directory, then the directory itself.
  WIN32_FIND_DATAW fd;
  HANDLE hFind = FindFirstFileW((binDir + L"\\*.*").c_str(), &fd);
  if (hFind != INVALID_HANDLE_VALUE) {
    do {
      if (wcscmp(fd.cFileName, L".") != 0 && wcscmp(fd.cFileName, L"..") != 0) {
        DeleteFileW((binDir + L"\\" + fd.cFileName).c_str());
      }
    } while (FindNextFileW(hFind, &fd));
    FindClose(hFind);
  }
  RemoveDirectoryW(binDir.c_str());

  return ok == TRUE;
}

bool StartIndexerService() {
  SC_HANDLE svc = OpenSvc(SERVICE_START);
  if (!svc) return false;

  BOOL ok = StartServiceW(svc, 0, nullptr);
  CloseServiceHandle(svc);
  return ok == TRUE;
}

bool StopIndexerService() {
  SC_HANDLE svc = OpenSvc(SERVICE_STOP);
  if (!svc) return false;

  SERVICE_STATUS ss = {};
  ControlService(svc, SERVICE_CONTROL_STOP, &ss);
  CloseServiceHandle(svc);
  return true;
}

bool IsIndexerServiceInstalled() {
  SC_HANDLE svc = OpenSvc(SERVICE_QUERY_STATUS);
  if (!svc) return false;
  CloseServiceHandle(svc);
  return true;
}

bool IsIndexerServiceRunning() {
  SC_HANDLE svc = OpenSvc(SERVICE_QUERY_STATUS);
  if (!svc) return false;

  SERVICE_STATUS ss = {};
  BOOL ok = QueryServiceStatus(svc, &ss);
  CloseServiceHandle(svc);
  return ok && ss.dwCurrentState == SERVICE_RUNNING;
}

// ---- Audio properties via Media Foundation ----------------------------------
// Media Foundation reads audio metadata directly from the media pipeline,
// supporting any format with a codec installed (MP3/WAV/FLAC/M4A/AAC/WMA/OPUS/OGG).

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <shlwapi.h>
#include <propkey.h>
#include <propvarutil.h>
#include <shobjidl.h>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "shlwapi.lib")

#ifndef INTERNET_MAX_URL_LENGTH
#define INTERNET_MAX_URL_LENGTH 2084
#endif

// MF often doesn't define ALAW/MULAW GUIDs — provide them here.
// (Opus/FLAC/Vorbis/ALAC are already declared in Win10 19041+ SDK mfapi.h.)
#ifndef MFAudioFormat_ALAW
static const GUID MFAudioFormat_ALAW =
    { 0x0006, 0x0000, 0x0010, { 0x80,0x00,0x00,0xAA,0x00,0x38,0x9B,0x71 } };
#endif
#ifndef MFAudioFormat_MULAW
static const GUID MFAudioFormat_MULAW =
    { 0x0007, 0x0000, 0x0010, { 0x80,0x00,0x00,0xAA,0x00,0x38,0x9B,0x71 } };
#endif

static std::string WideToUtf8(const std::wstring& ws) {
  if (ws.empty()) return {};
  int len = WideCharToMultiByte(CP_UTF8, 0, ws.c_str(), -1, nullptr, 0, nullptr, nullptr);
  if (len <= 1) return {};
  std::string result(len - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, ws.c_str(), -1, &result[0], len, nullptr, nullptr);
  return result;
}

static std::string JsonEscape(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 4);
  for (char c : s) {
    switch (c) {
      case '"':  out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:   out += c;
    }
  }
  return out;
}

// Map Media Foundation audio subtype GUID → friendly name.
static std::string MfSubtypeName(REFGUID subtype) {
  // GUIDs are {XXXXXXXX-0000-0010-8000-00AA00389B71} where X is the WAVEFORMATEX tag.
  struct { const GUID* guid; const char* name; } map[] = {
    {&MFAudioFormat_PCM,         "PCM"},
    {&MFAudioFormat_Float,       "IEEE Float"},
    {&MFAudioFormat_MP3,         "MP3"},
    {&MFAudioFormat_WMAudioV8,   "WMA"},
    {&MFAudioFormat_WMAudioV9,   "WMA"},
    {&MFAudioFormat_WMAudio_Lossless, "WMA Lossless"},
    {&MFAudioFormat_AAC,         "AAC"},
    {&MFAudioFormat_ADTS,        "ADTS AAC"},
    {&MFAudioFormat_ALAC,        "ALAC"},
    {&MFAudioFormat_Opus,        "OPUS"},
    {&MFAudioFormat_FLAC,        "FLAC"},
    {&MFAudioFormat_Vorbis,      "Vorbis"},
    {&MFAudioFormat_AMR_NB,      "AMR-NB"},
    {&MFAudioFormat_AMR_WB,      "AMR-WB"},
    {&MFAudioFormat_Dolby_AC3,   "AC3"},
    {&MFAudioFormat_Dolby_DDPlus, "Dolby DD+"},
    {&MFAudioFormat_DTS,         "DTS"},
    {&MFAudioFormat_MPEG,        "MPEG Audio"},
    {&MFAudioFormat_ALAW,        "ALAW"},
    {&MFAudioFormat_MULAW,       "MULAW"},
  };
  for (const auto& m : map) {
    if (*m.guid == subtype) return m.name;
  }
  // Fallback: format as GUID string.
  OLECHAR buf[64];
  StringFromGUID2(subtype, buf, 64);
  return WideToUtf8(buf);
}

std::string GetAudioProperties(const std::string& pathUtf8) {
  // Normalize slashes.
  std::string path = pathUtf8;
  for (char& c : path) { if (c == '/') c = '\\'; }

  std::wstring wpath = Utf8ToWide(path);
  if (wpath.empty()) return "{}";

  std::ostringstream json;
  json << "{";
  bool first = true;
  bool mfStarted = false;

  // Initialize COM + Media Foundation (both are ref-counted, safe to nest).
  HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  bool coInited = SUCCEEDED(hr) || hr == S_FALSE;
  hr = MFStartup(MF_VERSION);
  mfStarted = SUCCEEDED(hr);

  // Build file:// URL from Windows path.
  wchar_t url[INTERNET_MAX_URL_LENGTH] = {};
  DWORD urlLen = INTERNET_MAX_URL_LENGTH;
  if (FAILED(UrlCreateFromPathW(wpath.c_str(), url, &urlLen, 0)) || url[0] == 0) {
    // Fallback: manual construction (works for paths without special chars).
    std::wstring manual;
    manual.reserve(wpath.size() + 16);
    manual += L"file:///";
    for (wchar_t c : wpath) {
      manual += (c == L'\\') ? L'/' : c;
    }
    wcsncpy_s(url, INTERNET_MAX_URL_LENGTH, manual.c_str(), _TRUNCATE);
  }

  IMFSourceReader* reader = nullptr;
  if (mfStarted) {
    hr = MFCreateSourceReaderFromURL(url, nullptr, &reader);
  }

  if (SUCCEEDED(hr) && reader) {
    // ── Duration ──
    {
      PROPVARIANT var;
      PropVariantInit(&var);
      if (SUCCEEDED(reader->GetPresentationAttribute(
              (DWORD)MF_SOURCE_READER_MEDIASOURCE, MF_PD_DURATION, &var)) &&
          var.vt == VT_UI8) {
        // MF_PD_DURATION is in 100-nanosecond units.
        LONGLONG durMs = var.uhVal.QuadPart / 10000LL;
        if (durMs > 0) {
          if (!first) json << ","; first = false;
          json << "\"durationMs\":" << durMs;
        }
      }
      PropVariantClear(&var);
    }

    // Select the first audio stream.
    reader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE);

    // Get media type of the first audio stream.
    IMFMediaType* mediaType = nullptr;
    hr = reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM,
                                     &mediaType);
    if (SUCCEEDED(hr) && mediaType) {
      // ── Codec (subtype GUID) ──
      GUID subtype = {};
      if (SUCCEEDED(mediaType->GetGUID(MF_MT_SUBTYPE, &subtype))) {
        if (!first) json << ","; first = false;
        json << "\"codec\":\"" << JsonEscape(MfSubtypeName(subtype)) << "\"";
      }

      // ── Sample rate ──
      UINT32 val = 0;
      if (SUCCEEDED(mediaType->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &val)) && val > 0) {
        if (!first) json << ","; first = false;
        json << "\"sampleRate\":" << val;
      }

      // ── Channels ──
      val = 0;
      if (SUCCEEDED(mediaType->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &val)) && val > 0) {
        if (!first) json << ","; first = false;
        json << "\"channels\":" << val;
      }

      // ── Bits per sample ──
      val = 0;
      if (SUCCEEDED(mediaType->GetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, &val)) && val > 0) {
        if (!first) json << ","; first = false;
        json << "\"bitsPerSample\":" << val;
      }

      // ── Average bitrate (bytes/sec → bits/sec) ──
      val = 0;
      if (SUCCEEDED(mediaType->GetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, &val)) && val > 0) {
        if (!first) json << ","; first = false;
        json << "\"bitrate\":" << (val * 8);
      }

      mediaType->Release();
    }
    reader->Release();
  }

  // If MF completely failed, try Shell properties as fallback.
  if (first) {
    IShellItem2* pItem = nullptr;
    hr = SHCreateItemFromParsingName(wpath.c_str(), nullptr, IID_PPV_ARGS(&pItem));
    if (SUCCEEDED(hr) && pItem) {
      IPropertyStore* pStore = nullptr;
      hr = pItem->GetPropertyStore(GPS_READWRITE, IID_PPV_ARGS(&pStore));
      if (SUCCEEDED(hr) && pStore) {
        PROPVARIANT pv;

        auto addUInt = [&](REFPROPERTYKEY key, const char* name) {
          PropVariantInit(&pv);
          if (SUCCEEDED(pStore->GetValue(key, &pv)) && pv.vt == VT_UI4 && pv.ulVal > 0) {
            if (!first) json << ","; first = false;
            json << "\"" << name << "\":" << pv.ulVal;
          }
          PropVariantClear(&pv);
        };

        auto addStr = [&](REFPROPERTYKEY key, const char* name) {
          PropVariantInit(&pv);
          if (SUCCEEDED(pStore->GetValue(key, &pv)) && pv.vt == VT_LPWSTR && pv.pwszVal && pv.pwszVal[0]) {
            if (!first) json << ","; first = false;
            json << "\"" << name << "\":\"" << JsonEscape(WideToUtf8(pv.pwszVal)) << "\"";
          }
          PropVariantClear(&pv);
        };

        addUInt(PKEY_Audio_EncodingBitrate, "bitrate");
        addUInt(PKEY_Audio_ChannelCount, "channels");
        addUInt(PKEY_Audio_SampleRate, "sampleRate");
        addUInt(PKEY_Audio_SampleSize, "bitsPerSample");
        addStr(PKEY_Audio_Format, "codec");

        pStore->Release();
      }
      pItem->Release();
    }
  }

  json << "}";
  if (mfStarted) MFShutdown();
  if (coInited) CoUninitialize();
  return json.str();
}
