#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>
#include <string>

#include <fcntl.h>
#include <io.h>
#include <cstring>
#include <thread>
#include <set>
#include <vector>

#include "flutter_window.h"
#include "native/tray_icon.h"
#include "native/indexer_service.h"
#include "native/file_operations.h"
#include "native/screenrecording_channel.h"
#include "native/keyboard_hook.h"
#include "utils.h"

// ── stderr filter: suppress Flutter accessibility bridge noise ──────────
//
// XMate uses _overlay swap (full widget tree replacement) to switch pages.
// This triggers the Flutter engine's accessibility bridge to repeatedly
// log errors (13, 4, 5, 7, 11, 14, 16, …) because the new AXTree root is
// never a child of the previous root.  Rather than fighting the engine's
// tree validation, we filter the noise at the output layer.
//
// The filter thread reads stderr line by line and drops any line that
// contains "accessibility_bridge.cc", forwarding everything else to the
// real stderr.
static void StartStderrFilter() {
  // Safety: in GUI mode (no console, e.g. user double-click), stderr may
  // not have a valid file descriptor.  _fileno(stderr) returns -2
  // (_NO_CONSOLE_FILENO) in that case.  Calling _dup / _dup2 with an
  // invalid fd corrupts the CRT fd table and causes a stack buffer overrun
  // (STATUS_STACK_BUFFER_OVERRUN) when the CRT later checks its internal
  // structures.  Skip the filter entirely when stderr is unavailable.
  int stderr_fd = _fileno(stderr);
  if (stderr_fd < 0) return;  // no console → nothing to filter

  int pipe_fds[2];
  if (_pipe(pipe_fds, 65536, _O_TEXT | _O_NOINHERIT) != 0) return;

  int saved_fd  = _dup(stderr_fd);         // save real stderr
  if (saved_fd < 0) {
    _close(pipe_fds[0]);
    _close(pipe_fds[1]);
    return;
  }
  if (_dup2(pipe_fds[1], stderr_fd) < 0) {  // redirect stderr → pipe write
    _close(saved_fd);
    _close(pipe_fds[0]);
    _close(pipe_fds[1]);
    return;
  }
  _close(pipe_fds[1]);

  std::thread([=]() {
    char line[8192];
    FILE* src = _fdopen(pipe_fds[0], "r");
    FILE* dst = _fdopen(saved_fd, "w");
    if (!src || !dst) return;
    while (fgets(line, sizeof(line), src)) {
      if (!std::strstr(line, "accessibility_bridge.cc")) {
        fputs(line, dst);
        fflush(dst);
      }
    }
    fclose(src);  // also closes pipe_fds[0]
    fclose(dst);  // also closes saved_fd
  }).detach();
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {

  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

  // Suppress Flutter accessibility_bridge.cc error spam before any engine init.
  StartStderrFilter();
  if (command_line && wcsstr(command_line, L"--toggle-autostart")) {
    ToggleAutoStart();   // runs elevated via ShellExecuteEx(runas) from tray code
    return EXIT_SUCCESS;
  }

  // --open-as-admin <path>: elevated helper that opens a file with
  // administrator privileges then exits.
  if (command_line && wcsstr(command_line, L"--open-as-admin")) {
    const wchar_t* flag = wcsstr(command_line, L"--open-as-admin");
    const wchar_t* p = flag + wcslen(L"--open-as-admin");
    while (*p == L' ') p++;
    std::wstring filePath;
    if (*p == L'"') {
      p++;
      while (*p && *p != L'"') { filePath += *p; p++; }
    } else {
      while (*p && *p != L' ') { filePath += *p; p++; }
    }
    if (!filePath.empty()) {
      // Process is already elevated — use default verb, not runas.
      SHELLEXECUTEINFOW sei = {};
      sei.cbSize = sizeof(sei);
      sei.lpFile = filePath.c_str();
      sei.nShow = SW_SHOWNORMAL;
      ShellExecuteExW(&sei);
    }
    return EXIT_SUCCESS;
  }

  // --run-command <json>: elevated helper that runs a command as admin,
  // then exits.  JSON format: {"p":"exe","a":"args","d":"dir"}.
  if (command_line && wcsstr(command_line, L"--run-command")) {
    const wchar_t* flag = wcsstr(command_line, L"--run-command");
    const wchar_t* p = flag + wcslen(L"--run-command");
    while (*p == L' ') p++;
    if (*p == L'"') {
      p++;
      std::wstring json;
      while (*p && *p != L'"') { json += *p; p++; }

      // Minimal JSON parser for {"p":"...","a":"...","d":"..."}
      auto jsonField = [&](const wchar_t* key) -> std::wstring {
        std::wstring search = std::wstring(L"\"") + key + L"\":\"";
        size_t pos = json.find(search);
        if (pos == std::wstring::npos) return {};
        const wchar_t* q = json.c_str() + pos + search.size();
        std::wstring val;
        while (*q) {
          if (*q == L'\\' && (q[1] == L'\\' || q[1] == L'"')) {
            val += q[1]; q += 2;
          } else if (*q == L'"') {
            break;
          } else {
            val += *q; q++;
          }
        }
        return val;
      };

      std::wstring cmdPath = jsonField(L"p");
      std::wstring cmdArgs = jsonField(L"a");
      std::wstring workDir = jsonField(L"d");

      if (!cmdPath.empty()) {
        SHELLEXECUTEINFOW sei = {};
        sei.cbSize = sizeof(sei);
        sei.lpFile = cmdPath.c_str();
        sei.lpParameters = cmdArgs.empty() ? nullptr : cmdArgs.c_str();
        sei.lpDirectory = workDir.empty() ? nullptr : workDir.c_str();
        sei.nShow = SW_SHOWNORMAL;
        ShellExecuteExW(&sei);
      }
    }
    return EXIT_SUCCESS;
  }

  // --install-indexer: elevated helper that installs the XMateIndexer
  // Windows Service (creates directory + ACL + service) then exits.
  if (command_line && wcsstr(command_line, L"--install-indexer")) {
    InstallIndexerService();
    return EXIT_SUCCESS;
  }

  // --uninstall-indexer: elevated helper that uninstalls the XMateIndexer
  // Windows Service (stop + delete) then exits.
  if (command_line && wcsstr(command_line, L"--uninstall-indexer")) {
    UninstallIndexerService();
    return EXIT_SUCCESS;
  }

  // --quicklook <path>: standalone preview window (no mutex, no tray, no service).
  // Multiple quicklook instances can coexist independently.
  bool quicklookMode = (command_line && wcsstr(command_line, L"--quicklook"));

  if (quicklookMode) {
    // Extract the file path from command line.
    const wchar_t* flag = wcsstr(command_line, L"--quicklook");
    const wchar_t* p = flag + wcslen(L"--quicklook");
    while (*p == L' ') p++;
    std::wstring qlPath;
    if (*p == L'"') {
      p++;
      while (*p && *p != L'"') { qlPath += *p; p++; }
    } else {
      while (*p && *p != L' ') { qlPath += *p; p++; }
    }

    // Convert to UTF-8.
    char qlPathUtf8[1024] = {};
    WideCharToMultiByte(CP_UTF8, 0, qlPath.c_str(), -1, qlPathUtf8, sizeof(qlPathUtf8), nullptr, nullptr);

    // Parse --ql-restore <hex> — the HWND to return focus to after loading.
    std::string qlRestoreHwnd;
    const wchar_t* restoreFlag = wcsstr(command_line, L"--ql-restore");
    if (restoreFlag) {
      const wchar_t* rp = restoreFlag + wcslen(L"--ql-restore");
      while (*rp == L' ') rp++;
      char restoreHwndUtf8[64] = {};
      WideCharToMultiByte(CP_UTF8, 0, rp, -1, restoreHwndUtf8, sizeof(restoreHwndUtf8), nullptr, nullptr);
      qlRestoreHwnd = restoreHwndUtf8;
    }

    ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    flutter::DartProject project(L"data");

    FlutterWindow window(project, "quicklook", qlPathUtf8, qlRestoreHwnd);
    Win32Window::Point origin(10, 10);
    Win32Window::Size size(1, 1);
    if (!window.Create(L"xmate_ql", origin, size)) {
      ::CoUninitialize();
      return EXIT_FAILURE;
    }
    window.SetQuitOnClose(true);

    // Show at 1x1 without activating — same pattern as main process.
    // Dart _onReady will resize to the proper size later.
    ::ShowWindow(window.GetHandle(), SW_SHOWNOACTIVATE);

    ::MSG msg;
    while (::GetMessage(&msg, nullptr, 0, 0)) {
      ::TranslateMessage(&msg);
      ::DispatchMessage(&msg);
    }
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  // --screenrecording: standalone recording subprocess.
  // Same pattern as QuickLook: no mutex, no tray, no service.
  bool srMode = (command_line && wcsstr(command_line, L"--screenrecording"));

  if (srMode) {
    auto srData = ParseScreenRecordingArgs(command_line);
    if (!srData.ok) return EXIT_FAILURE;

    std::string srJson = SrDataToJson(srData);

    ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    flutter::DartProject project(L"data");

    FlutterWindow window(project, "screenrecording", srJson, "");
    Win32Window::Point origin(10, 10);
    Win32Window::Size size(1, 1);
    if (!window.Create(L"xmate_sr", origin, size)) {
      ::CoUninitialize();
      return EXIT_FAILURE;
    }
    window.SetQuitOnClose(true);

    ::ShowWindow(window.GetHandle(), SW_SHOWNOACTIVATE);

    ::MSG msg;
    while (::GetMessage(&msg, nullptr, 0, 0)) {
      ::TranslateMessage(&msg);
      ::DispatchMessage(&msg);
    }
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }


  // --fileconverter: standalone file converter window.
  // Single-instance: close existing before creating new one.
  bool fileconverterMode = (command_line && wcsstr(command_line, L"--fileconverter"));

  if (fileconverterMode) {
    HWND hExistingFc = FindWindowW(nullptr, L"xmate_fileconverter");
    if (hExistingFc) {
      PostMessageW(hExistingFc, WM_CLOSE, 0, 0);
      Sleep(200);
    }

    ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    flutter::DartProject project(L"data");

    FlutterWindow window(project, "fileconverter", "", "");
    Win32Window::Point origin(10, 10);
    Win32Window::Size size(1, 1);
    if (!window.Create(L"xmate_fileconverter", origin, size)) {
      ::CoUninitialize();
      return EXIT_FAILURE;
    }
    window.SetQuitOnClose(true);

    ::ShowWindow(window.GetHandle(), SW_SHOWNOACTIVATE);

    ::MSG msg;
    while (::GetMessage(&msg, nullptr, 0, 0)) {
      ::TranslateMessage(&msg);
      ::DispatchMessage(&msg);
    }
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  // --notification: content-aware key-echo overlay (top-right corner).
  // Starts at 1x1 (hidden).  Dart calls resizeContent() when content appears.
  // TOPMOST, no focus, no Alt+Tab.  Single-instance guard.
  bool notificationMode = (command_line && wcsstr(command_line, L"--notification"));

  if (notificationMode) {
    if (FindWindowW(nullptr, L"xmate_notify")) {
      return EXIT_SUCCESS;
    }

    ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    flutter::DartProject project(L"data");

    FlutterWindow window(project, "notification", "", "");
    Win32Window::Point origin(0, 0);
    Win32Window::Size size(1, 1);
    if (!window.Create(L"xmate_notify", origin, size)) {
      ::CoUninitialize();
      return EXIT_FAILURE;
    }
    window.SetQuitOnClose(true);

    ::ShowWindow(window.GetHandle(), SW_SHOWNOACTIVATE);

    ::MSG msg;
    while (::GetMessage(&msg, nullptr, 0, 0)) {
      ::TranslateMessage(&msg);
      ::DispatchMessage(&msg);
    }
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  // --run-service: start as Windows Service (XMateIndexer).
  // Launched by SCM — no Flutter engine, no window, no single-instance mutex.
  if (command_line && wcsstr(command_line, L"--run-service")) {
    return IndexerServiceMain();
  }

  // --note <id>: standalone sticky-note window (no mutex, multi-instance).
  // One process per note. Window title is "xmate_note_<id>" so other
  // processes can find / enumerate note windows by title prefix.
  bool noteMode = (command_line && wcsstr(command_line, L"--note "));

  if (noteMode) {
    // Extract the note id from command line.
    const wchar_t* ntFlag = wcsstr(command_line, L"--note");
    const wchar_t* ntP = ntFlag + wcslen(L"--note");
    while (*ntP == L' ') ntP++;
    std::wstring noteId;
    if (*ntP == L'"') {
      ntP++;
      while (*ntP && *ntP != L'"') { noteId += *ntP; ntP++; }
    } else {
      while (*ntP && *ntP != L' ') { noteId += *ntP; ntP++; }
    }
    if (noteId.empty()) return EXIT_FAILURE;

    // Per-note single instance: if this note's window already exists,
    // just surface it and exit.
    std::wstring noteTitle = L"xmate_note_" + noteId;
    HWND hExistNote = FindWindowW(nullptr, noteTitle.c_str());
    if (hExistNote) {
      ShowWindow(hExistNote, SW_SHOWNOACTIVATE);
      SetForegroundWindow(hExistNote);
      return EXIT_SUCCESS;
    }

    char noteIdUtf8[256] = {};
    WideCharToMultiByte(CP_UTF8, 0, noteId.c_str(), -1,
                        noteIdUtf8, sizeof(noteIdUtf8), nullptr, nullptr);

    ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    flutter::DartProject noteProject(L"data");

    FlutterWindow noteWindow(noteProject, "note", noteIdUtf8, "");
    Win32Window::Point noteOrigin(10, 10);
    Win32Window::Size noteSize(1, 1);
    if (!noteWindow.Create(noteTitle.c_str(), noteOrigin, noteSize)) {
      ::CoUninitialize();
      return EXIT_FAILURE;
    }
    noteWindow.SetQuitOnClose(true);

    ::ShowWindow(noteWindow.GetHandle(), SW_SHOWNOACTIVATE);

    ::MSG noteMsg;
    while (::GetMessage(&noteMsg, nullptr, 0, 0)) {
      ::TranslateMessage(&noteMsg);
      ::DispatchMessage(&noteMsg);
    }
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  // --dictionary [data-file]: standalone dictionary window (single-instance).
  bool dictMode = (command_line && wcsstr(command_line, L"--dictionary"));

  if (dictMode) {
    // Extract the data file path from command line (same pattern as --translate).
    const wchar_t* dcFlag = wcsstr(command_line, L"--dictionary");
    const wchar_t* dcP = dcFlag + wcslen(L"--dictionary");
    while (*dcP == L' ') dcP++;
    std::wstring dictDataPath;
    if (*dcP == L'"') {
      dcP++;
      while (*dcP && *dcP != L'"') { dictDataPath += *dcP; dcP++; }
    } else {
      while (*dcP && *dcP != L' ') { dictDataPath += *dcP; dcP++; }
    }

    char dcDataUtf8[4096] = {};
    WideCharToMultiByte(CP_UTF8, 0, dictDataPath.c_str(), -1,
                        dcDataUtf8, sizeof(dcDataUtf8), nullptr, nullptr);

    // If a dictionary window is already running, forward the data path
    // and show it — no need to start a new process.
    HWND hExist = FindWindowW(nullptr, L"xmate_dict");
    if (hExist) {
      if (dcDataUtf8[0] != '\0') {
        COPYDATASTRUCT cds = {};
        cds.dwData = WM_XMATE_DICT_DATA;
        cds.cbData = (DWORD)(strlen(dcDataUtf8) + 1);
        cds.lpData = (PVOID)dcDataUtf8;
        SendMessageW(hExist, WM_COPYDATA, 0, (LPARAM)&cds);
      }
      ShowWindow(hExist, SW_SHOWNOACTIVATE);
      SetForegroundWindow(hExist);
      return EXIT_SUCCESS;
    }

    ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    flutter::DartProject dictProject(L"data");

    FlutterWindow dictWindow(dictProject, "dictionary", dcDataUtf8, "");
    Win32Window::Point dictOrigin(10, 10);
    Win32Window::Size dictSize(1, 1);
    if (!dictWindow.Create(L"xmate_dict", dictOrigin, dictSize)) {
      ::CoUninitialize();
      return EXIT_FAILURE;
    }
    dictWindow.SetQuitOnClose(true);

    ::ShowWindow(dictWindow.GetHandle(), SW_SHOWNOACTIVATE);

    ::MSG dictMsg;
    while (::GetMessage(&dictMsg, nullptr, 0, 0)) {
      ::TranslateMessage(&dictMsg);
      ::DispatchMessage(&dictMsg);
    }
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  // --translate <data-file>: standalone translation window.
  // Single-instance: only one translate window at a time (belt-and-suspenders —
  // the Dart side also calls closeTranslateWindows before spawning).
  bool translateMode = (command_line && wcsstr(command_line, L"--translate"));

  if (translateMode) {
    if (FindWindowW(nullptr, L"xmate_translate")) {
      return EXIT_SUCCESS;  // already running
    }

    // Extract the data file path from command line.
    const wchar_t* trFlag = wcsstr(command_line, L"--translate");
    const wchar_t* trP = trFlag + wcslen(L"--translate");
    while (*trP == L' ') trP++;
    std::wstring translateDataPath;
    if (*trP == L'"') {
      trP++;
      while (*trP && *trP != L'"') { translateDataPath += *trP; trP++; }
    } else {
      while (*trP && *trP != L' ') { translateDataPath += *trP; trP++; }
    }

    char trDataUtf8[4096] = {};
    WideCharToMultiByte(CP_UTF8, 0, translateDataPath.c_str(), -1,
                        trDataUtf8, sizeof(trDataUtf8), nullptr, nullptr);

    ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    flutter::DartProject trProject(L"data");

    FlutterWindow trWindow(trProject, "translate", trDataUtf8, "");
    Win32Window::Point trOrigin(10, 10);
    Win32Window::Size trSize(1, 1);
    if (!trWindow.Create(L"xmate_translate", trOrigin, trSize)) {
      ::CoUninitialize();
      return EXIT_FAILURE;
    }
    trWindow.SetQuitOnClose(true);

    ::ShowWindow(trWindow.GetHandle(), SW_SHOWNOACTIVATE);

    ::MSG trMsg;
    while (::GetMessage(&trMsg, nullptr, 0, 0)) {
      ::TranslateMessage(&trMsg);
      ::DispatchMessage(&trMsg);
    }
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  // --- Single-instance guard ---
  HANDLE hMutex = CreateMutexW(NULL, TRUE, L"Global\\XMate_SingleInstance");
  if (hMutex && GetLastError() == ERROR_ALREADY_EXISTS) {
    // Another instance is running — wake it up instead of starting a new one
    HWND hExisting = FindWindowW(NULL, L"xmate");
    if (hExisting) {
      PostMessageW(hExisting, WM_XMATE_TRAY, 0, WM_LBUTTONUP);
    }
    if (hMutex) CloseHandle(hMutex);
    return EXIT_SUCCESS;
  }
  // hMutex stays alive until process exit (OS frees it) — keeps the lock.

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"xmate", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // ── Graceful child-process shutdown on exit ─────────────────────
  // Belt-and-suspenders: runs even when the Dart onExit callback
  // doesn't fire (e.g. flutter run q abort, crash).
  //
  // Strategy: EnumWindows to find all child HWNDs by title, send one
  // WM_CLOSE per window, then WaitForSingleObject on each PID.
  // Sequential (not concurrent) to avoid GPU-driver contention from
  // tearing down multiple Flutter engines simultaneously.
  {
    // Exact-match child titles, plus one prefix entry for note windows
    // (each note window is titled "xmate_note_<id>").
    const wchar_t* childTitles[] = {
      L"xmate_notify", L"xmate_ql", L"xmate_ql_pinned",
      L"xmate_sr", L"xmate_translate", L"xmate_dict",
      L"xmate_fileconverter", L"xmate_note_",
    };

    struct EnumCtx {
      const wchar_t* title;
      bool prefix;
      std::vector<HWND> windows;
    };

    for (auto title : childTitles) {
      EnumCtx ctx;
      ctx.title = title;
      // Titles ending in '_' are treated as prefixes (note windows).
      ctx.prefix = (title[wcslen(title) - 1] == L'_');
      EnumWindows(
          [](HWND h, LPARAM lp) -> BOOL {
            auto* c = reinterpret_cast<EnumCtx*>(lp);
            wchar_t buf[256] = {};
            GetWindowTextW(h, buf, 256);
            bool match = c->prefix
                ? (wcsncmp(buf, c->title, wcslen(c->title)) == 0)
                : (wcscmp(buf, c->title) == 0);
            if (match) {
              c->windows.push_back(h);
            }
            return TRUE;
          },
          reinterpret_cast<LPARAM>(&ctx));

      if (ctx.windows.empty()) continue;

      // Extract unique PIDs, send one WM_CLOSE per window.
      std::set<DWORD> pids;
      for (auto hw : ctx.windows) {
        DWORD pid = 0;
        GetWindowThreadProcessId(hw, &pid);
        if (pid != 0) pids.insert(pid);
        PostMessageW(hw, WM_CLOSE, 0, 0);
      }

      // Wait for each process to exit (max 3 s per process).
      for (auto pid : pids) {
        HANDLE hProc = OpenProcess(SYNCHRONIZE, FALSE, pid);
        if (hProc) {
          WaitForSingleObject(hProc, 3000);
          CloseHandle(hProc);
        }
      }
    }

    // Stop the indexer Windows Service so it doesn't linger.
    StopIndexerService();
  }

  ::CoUninitialize();
  if (hMutex) CloseHandle(hMutex);
  return EXIT_SUCCESS;
}
