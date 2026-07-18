#include "flutter_window.h"
#include <fstream>
#include <ole2.h>
#include <optional>
#include <sstream>
#include "flutter/generated_plugin_registrant.h"
#include "native/folder_picker.h"
#include "native/pin_window.h"
#include "native/screenshot_capture.h"
#include "native/tray_icon.h"
#include "native/ocr_engine.h"
#include "native/translate_engine.h"
#include "native/file_scanner.h"
#include "native/usn_journal.h"
#include "native/file_operations.h"
#include "native/indexer_config.h"
#include "native/debug_tools.h"
#include "native/quicklook_helper.h"
#include "native/office_preview_handler.h"
#include "native/screenrecording_channel.h"
#include "native/annotation_overlay.h"
#include "native/keyboard_hook.h"
#include "native/monitor_swap.h"
#include "native/winrt_ocr_engine.h"
#include <mmdeviceapi.h>
#include <endpointvolume.h>

// ── Notification: content-aware window sizing ─────────────────────
// The notification window starts at 1×1 (hidden).  Dart calculates the
// bounding rectangle of visible content and calls resizeContent() to
// reposition+show the window, or hideContent() when both panels are empty.
// This avoids the fullscreen click-through problem entirely — when hidden
// the window is effectively invisible; when shown it only covers the exact
// content area (a few percent of the screen).

namespace {
constexpr UINT_PTR kWatchdogTimerId = 301;
}  // namespace


// V2.0.0: extended entry point — same as OcrFromPNG but accepts crop offset
// and optional UVDoc unwarping toggle.
std::string OcrFromPNGWithOffset(const std::vector<uint8_t>& pngBytes,
                                 int cropX, int cropY, bool enableUnwarp);

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project),
      startup_mode_("normal"),
      quicklook_path_("") {}

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                               const std::string& startupMode,
                               const std::string& quickLookPath,
                               const std::string& qlRestoreHwnd)
    : project_(project),
      startup_mode_(startupMode),
      quicklook_path_(quickLookPath),
      ql_restore_hwnd_(qlRestoreHwnd) {
  if (startupMode == "screenrecording") {
    sr_data_json_ = quickLookPath;
  }
}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) return false;

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      1, 1, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) return false;

  // Register app channel BEFORE RegisterPlugins — Dart main() may query it
  // synchronously during init (e.g., QuickLook standalone mode detection).
  app_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/app",
          &flutter::StandardMethodCodec::GetInstance());
  app_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "getStartupMode") {
          result->Success(flutter::EncodableValue(startup_mode_));
        } else if (call.method_name() == "getQuickLookPath") {
          result->Success(flutter::EncodableValue(quicklook_path_));
        } else if (call.method_name() == "getQlRestoreHwnd") {
          result->Success(flutter::EncodableValue(ql_restore_hwnd_));
        } else if (call.method_name() == "getForegroundHwnd") {
          result->Success(flutter::EncodableValue(
              reinterpret_cast<int64_t>(GetForegroundWindow())));
        } else if (call.method_name() == "getScreenRecordingData") {
          result->Success(flutter::EncodableValue(sr_data_json_));
        } else if (call.method_name() == "closeTranslateWindows") {
          int closed = 0;
          HWND hTr = FindWindowW(nullptr, L"xmate_translate");
          if (hTr) { PostMessageW(hTr, WM_CLOSE, 0, 0); closed++; }
          result->Success(flutter::EncodableValue(closed));
        } else if (call.method_name() == "closeDictionaryWindows") {
          int closed = 0;
          HWND hDi = FindWindowW(nullptr, L"xmate_dict");
          if (hDi) { PostMessageW(hDi, WM_CLOSE, 0, 0); closed++; }
          result->Success(flutter::EncodableValue(closed));
        } else if (call.method_name() == "closeSettingsWindows") {
          int closed = 0;
          HWND hSt = FindWindowW(nullptr, L"xmate_settings");
          if (hSt) { PostMessageW(hSt, WM_CLOSE, 0, 0); closed++; }
          result->Success(flutter::EncodableValue(closed));
        } else if (call.method_name() == "getSelectedText") {
          // Wait for the user to release Alt (the Alt+Space hotkey), then
          // send Ctrl+C to grab the current text selection.  The clipboard
          // is saved beforehand and restored afterwards so the operation is
          // invisible.

          std::string savedUtf8;

          // 1. Save current clipboard text
          if (OpenClipboard(nullptr)) {
            if (HGLOBAL hSaved = GetClipboardData(CF_UNICODETEXT)) {
              if (const wchar_t* pSaved =
                      static_cast<const wchar_t*>(GlobalLock(hSaved))) {
                int len = WideCharToMultiByte(CP_UTF8, 0, pSaved, -1, nullptr,
                                              0, nullptr, nullptr);
                if (len > 1) {
                  savedUtf8.resize(len - 1);
                  WideCharToMultiByte(CP_UTF8, 0, pSaved, -1, &savedUtf8[0],
                                      len, nullptr, nullptr);
                }
                GlobalUnlock(hSaved);
              }
            }
            CloseClipboard();
          }

          // 2. Wait until Alt is released (poll at 20 ms intervals, 500 ms
          //    hard cap so the palette never hangs).
          for (int i = 0; i < 25; ++i) {
            if (!(GetAsyncKeyState(VK_MENU) & 0x8000)) break;
            Sleep(20);
          }

          // 3. Send Ctrl+C — clean copy, Alt is already up
          INPUT copy[4] = {};
          copy[0].type = INPUT_KEYBOARD;
          copy[0].ki.wVk = VK_CONTROL;
          copy[1].type = INPUT_KEYBOARD;
          copy[1].ki.wVk = 'C';
          copy[2].type = INPUT_KEYBOARD;
          copy[2].ki.wVk = 'C';
          copy[2].ki.dwFlags = KEYEVENTF_KEYUP;
          copy[3].type = INPUT_KEYBOARD;
          copy[3].ki.wVk = VK_CONTROL;
          copy[3].ki.dwFlags = KEYEVENTF_KEYUP;
          SendInput(4, copy, sizeof(INPUT));

          // 4. Poll clipboard until content differs from saved (or timeout).
          //    Some apps populate the clipboard asynchronously; retrying
          //    up to 150 ms in 30 ms steps covers them without adding
          //    noticeable latency.
          std::string selectedUtf8;
          bool gotNew = false;
          for (int attempt = 0; attempt < 5; ++attempt) {
            Sleep(30);
            if (OpenClipboard(nullptr)) {
              if (HGLOBAL hSelected = GetClipboardData(CF_UNICODETEXT)) {
                if (const wchar_t* pSelected =
                        static_cast<const wchar_t*>(GlobalLock(hSelected))) {
                  int len = WideCharToMultiByte(CP_UTF8, 0, pSelected, -1,
                                                nullptr, 0, nullptr, nullptr);
                  if (len > 1) {
                    std::string utf8(len - 1, '\0');
                    WideCharToMultiByte(CP_UTF8, 0, pSelected, -1, &utf8[0],
                                        len, nullptr, nullptr);
                    if (utf8 != savedUtf8) {
                      selectedUtf8 = utf8;
                      gotNew = true;
                    }
                  } else {
                    // Clipboard is now empty but was non-empty before —
                    // something cleared it (unlikely), treat as change.
                    if (!savedUtf8.empty()) gotNew = true;
                  }
                  GlobalUnlock(hSelected);
                }
              }
              // 5. Restore original clipboard content
              if (!savedUtf8.empty()) {
                EmptyClipboard();
                int wlen = MultiByteToWideChar(CP_UTF8, 0, savedUtf8.c_str(),
                                               -1, nullptr, 0);
                if (wlen > 0) {
                  std::wstring wsaved(wlen, L'\0');
                  MultiByteToWideChar(CP_UTF8, 0, savedUtf8.c_str(), -1,
                                      &wsaved[0], wlen);
                  size_t size = wsaved.length() * sizeof(wchar_t);
                  if (HGLOBAL hRestore = GlobalAlloc(GMEM_MOVEABLE, size)) {
                    if (wchar_t* pRestore =
                            static_cast<wchar_t*>(GlobalLock(hRestore))) {
                      memcpy(pRestore, wsaved.c_str(), size);
                      GlobalUnlock(hRestore);
                      SetClipboardData(CF_UNICODETEXT, hRestore);
                    }
                  }
                }
              }
              CloseClipboard();
            }
            if (gotNew) break;
          }

          // Strip trailing newline (added by some apps on Ctrl+C)
          if (!selectedUtf8.empty() && selectedUtf8.back() == '\n') {
            selectedUtf8.pop_back();
          }
          if (!selectedUtf8.empty() && selectedUtf8.back() == '\r') {
            selectedUtf8.pop_back();
          }

          result->Success(flutter::EncodableValue(selectedUtf8));
        } else {
          result->NotImplemented();
        }
      });

  RegisterPlugins(flutter_controller_->engine());

  screenshot_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/screenshot",
          &flutter::StandardMethodCodec::GetInstance());
  screenshot_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "getWindowRectAtCursor") {
          auto args = std::get_if<flutter::EncodableMap>(call.arguments());
          bool outerOnly = false;
          if (args) {
            auto it = args->find(flutter::EncodableValue("outerOnly"));
            if (it != args->end()) {
              if (auto* b = std::get_if<bool>(&it->second)) {
                outerOnly = *b;
              }
            }
          }
          std::string json = GetWindowRectAtCursor(GetHandle(), outerOnly);
          result->Success(flutter::EncodableValue(json));
          return;
        }
        if (call.method_name() == "getWindowRects") {
          auto args = std::get_if<flutter::EncodableMap>(call.arguments());
          bool outerOnly = false;
          bool includeChildren = false;
          if (args) {
            auto it1 = args->find(flutter::EncodableValue("outerOnly"));
            if (it1 != args->end()) {
              if (auto* b = std::get_if<bool>(&it1->second)) outerOnly = *b;
            }
            auto it2 = args->find(flutter::EncodableValue("includeChildren"));
            if (it2 != args->end()) {
              if (auto* b = std::get_if<bool>(&it2->second)) includeChildren = *b;
            }
          }
          std::string json = GetWindowRectsOnScreen(GetHandle(), outerOnly, includeChildren);
          result->Success(flutter::EncodableValue(json));
          return;
        }
        if (call.method_name() == "identifyWindowUnderRect") {
          auto args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) { result->Error("INVALID_ARGS", "Expected map"); return; }
          auto getInt = [&](const char* key) -> int {
            auto it = args->find(flutter::EncodableValue(key));
            if (it == args->end()) return 0;
            auto* p = std::get_if<int32_t>(&it->second);
            return p ? *p : 0;
          };
          int rx = getInt("x"), ry = getInt("y"), rw = getInt("w"), rh = getInt("h");
          std::string json = IdentifyWindowUnderRect(GetHandle(), rx, ry, rw, rh);
          result->Success(flutter::EncodableValue(json));
          return;
        }
        if (call.method_name() == "installScrollHook") {
          auto args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) { result->Error("INVALID_ARGS", "Expected map"); return; }
          auto getInt = [&](const char* key) -> int {
            auto it = args->find(flutter::EncodableValue(key));
            if (it == args->end()) return 0;
            auto* p = std::get_if<int32_t>(&it->second);
            return p ? *p : 0;
          };
          int x = getInt("x"), y = getInt("y"), w = getInt("w"), h = getInt("h");
          // Dart already sent physical px (× dpr) — C++ uses directly.
          bool ok = InstallScrollHook(GetHandle(), x, y, w, h);
          result->Success(flutter::EncodableValue(ok));
          return;
        }
        if (call.method_name() == "uninstallScrollHook") {
          UninstallScrollHook();
          result->Success(flutter::EncodableValue(true));
          return;
        }
        HandleScreenshotMethodCall(call, std::move(result));
      });

  tray_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/tray",
          &flutter::StandardMethodCodec::GetInstance());
  tray_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "initTray") {
          InitTrayIcon(GetHandle(),
              [this](int cmd) { OnTrayCommand(cmd); });
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "removeTray") {
          RemoveTrayIcon();
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "isAutoStart") {
          result->Success(flutter::EncodableValue(IsAutoStartEnabled()));
        } else if (call.method_name() == "toggleAutoStart") {
          ToggleAutoStart();
          result->Success(flutter::EncodableValue(IsAutoStartEnabled()));
        } else {
          result->NotImplemented();
        }
      });

  picker_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/picker",
          &flutter::StandardMethodCodec::GetInstance());
  picker_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "pickFolder") {
          std::wstring path = PickFolder(
              flutter_controller_->view()->GetNativeWindow());
          int len = WideCharToMultiByte(CP_UTF8, 0, path.c_str(), -1,
              nullptr, 0, nullptr, nullptr);
          std::string utf8(len - 1, '\0');
          WideCharToMultiByte(CP_UTF8, 0, path.c_str(), -1,
              &utf8[0], len, nullptr, nullptr);
          result->Success(flutter::EncodableValue(utf8));
        } else if (call.method_name() == "pickFile") {
          std::string title;
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args) {
            auto it = args->find(flutter::EncodableValue("title"));
            if (it != args->end()) {
              if (auto* s = std::get_if<std::string>(&it->second)) {
                title = *s;
              }
            }
          }
          std::wstring path = PickFile(
              flutter_controller_->view()->GetNativeWindow(), title);
          int len = WideCharToMultiByte(CP_UTF8, 0, path.c_str(), -1,
              nullptr, 0, nullptr, nullptr);
          if (len > 1) {
            std::string utf8(len - 1, '\0');
            WideCharToMultiByte(CP_UTF8, 0, path.c_str(), -1,
                &utf8[0], len, nullptr, nullptr);
            result->Success(flutter::EncodableValue(utf8));
          } else {
            result->Success(flutter::EncodableValue(std::string("")));
          }
        } else {
          result->NotImplemented();
        }
      });

  pin_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/pin",
          &flutter::StandardMethodCodec::GetInstance());
  pin_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "createPin") {
          const auto& args_val = *call.arguments();
          const auto* map =
              std::get_if<flutter::EncodableMap>(&args_val);
          if (!map) {
            result->Error("INVALID_ARG", "Expected Map");
            return;
          }

          // Numeric helper: Dart sends doubles for coordinate fields.
          // Handle int32_t, int64_t, and double encodings.
          auto getInt = [&](const char* key) -> int {
            auto it = map->find(flutter::EncodableValue(key));
            if (it == map->end()) return 0;
            const auto& v = it->second;
            if (auto* i = std::get_if<int32_t>(&v)) return *i;
            if (auto* l = std::get_if<int64_t>(&v)) return static_cast<int>(*l);
            if (auto* d = std::get_if<double>(&v)) return static_cast<int>(*d + 0.5);
            return 0;
          };

          auto it_png = map->find(flutter::EncodableValue("png"));
          if (it_png == map->end()) {
            result->Error("INVALID_ARG", "Missing 'png'");
            return;
          }
          const auto* png =
              std::get_if<std::vector<uint8_t>>(&it_png->second);
          if (!png) {
            result->Error("INVALID_ARG", "'png' must be binary");
            return;
          }

          int x = getInt("x");
          int y = getInt("y");
          int w = getInt("width");
          int h = getInt("height");

          HWND hwnd = CreatePinWindowFromPNG(*png, x, y, w, h);
          if (hwnd) {
            result->Success(flutter::EncodableValue(true));
          } else {
            result->Error("PIN_FAILED", "Failed to create pin window");
          }
        } else {
          result->NotImplemented();
        }
      });

  ocr_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/ocr",
          &flutter::StandardMethodCodec::GetInstance());
  ocr_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "recognize") {
          const auto& args_val = *call.arguments();
          const auto* map =
              std::get_if<flutter::EncodableMap>(&args_val);
          if (!map) {
            result->Error("INVALID_ARG", "Expected Map");
            return;
          }
          auto it = map->find(flutter::EncodableValue("pngBytes"));
          if (it == map->end()) {
            result->Error("INVALID_ARG", "Missing 'pngBytes'");
            return;
          }
          const auto* vec =
              std::get_if<std::vector<uint8_t>>(&it->second);
          if (!vec) {
            result->Error("INVALID_ARG", "'pngBytes' must be binary");
            return;
          }
          // V2.0.0: read crop offset from Dart args (default 0,0)
          int cropX = 0, cropY = 0;
          auto cx = map->find(flutter::EncodableValue("cropX"));
          if (cx != map->end()) {
            if (auto* v = std::get_if<int32_t>(&cx->second)) cropX = *v;
            else if (auto* v2 = std::get_if<int64_t>(&cx->second)) cropX = (int)*v2;
          }
          auto cy = map->find(flutter::EncodableValue("cropY"));
          if (cy != map->end()) {
            if (auto* v = std::get_if<int32_t>(&cy->second)) cropY = *v;
            else if (auto* v2 = std::get_if<int64_t>(&cy->second)) cropY = (int)*v2;
          }
          bool enableUnwarp = false;
          auto eu = map->find(flutter::EncodableValue("enableUnwarp"));
          if (eu != map->end()) {
            if (auto* v = std::get_if<bool>(&eu->second)) enableUnwarp = *v;
          }
          // V3.1.7: engine dispatch — "winrt" → WinRT, else → PP-OCRv6
          std::string engine = "ppocrv6";
          auto engIt = map->find(flutter::EncodableValue("engine"));
          if (engIt != map->end()) {
            if (auto* s = std::get_if<std::string>(&engIt->second)) {
              engine = *s;
            }
          }
          std::string language = "ch";
          auto langIt = map->find(flutter::EncodableValue("language"));
          if (langIt != map->end()) {
            if (auto* s = std::get_if<std::string>(&langIt->second)) {
              language = *s;
            }
          }
          std::string json;
          if (engine == "winrt") {
            json = WinRTOcrFromPNG(*vec, cropX, cropY, language);
          } else {
            json = OcrFromPNGWithOffset(*vec, cropX, cropY, enableUnwarp);
          }
          result->Success(flutter::EncodableValue(json));
        } else {
          result->NotImplemented();
        }
      });

  translate_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/translate",
          &flutter::StandardMethodCodec::GetInstance());
  translate_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "translate") {
          const auto& args_val = *call.arguments();
          const auto* map =
              std::get_if<flutter::EncodableMap>(&args_val);
          if (!map) {
            result->Error("INVALID_ARG", "Expected Map");
            return;
          }
          auto it = map->find(flutter::EncodableValue("texts"));
          if (it == map->end()) {
            result->Error("INVALID_ARG", "Missing 'texts'");
            return;
          }
          const auto* textsArr =
              std::get_if<std::vector<flutter::EncodableValue>>(&it->second);
          if (!textsArr) {
            result->Error("INVALID_ARG", "'texts' must be an array");
            return;
          }

          // Build JSON input for TranslateBatch
          std::ostringstream json;
          json << "{\"texts\":[";
          for (size_t i = 0; i < textsArr->size(); i++) {
            if (i) json << ",";
            const auto* s = std::get_if<std::string>(&(*textsArr)[i]);
            json << "\"" << (s ? *s : "") << "\"";
          }
          json << "],\"from\":\"en\",\"to\":\"zh\"}";

          std::string resultJson = TranslateBatch(json.str());
          result->Success(flutter::EncodableValue(resultJson));
        } else {
          result->NotImplemented();
        }
      });

  filesearch_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/filesearch",
          &flutter::StandardMethodCodec::GetInstance());
  auto* filesearch_messenger = flutter_controller_->engine()->messenger();
  filesearch_channel_->SetMethodCallHandler(
      [filesearch_messenger](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "scanDirectory") {
          const auto& args =
              std::get<flutter::EncodableMap>(*call.arguments());
          const auto& rootPath = std::get<std::string>(
              args.at(flutter::EncodableValue("rootPath")));
          std::string json = ScanDirectory(rootPath);
          result->Success(flutter::EncodableValue(json));
        } else if (call.method_name() == "queryUsn") {
          const auto& args =
              std::get<flutter::EncodableMap>(*call.arguments());
          const auto& rootPath = std::get<std::string>(
              args.at(flutter::EncodableValue("rootPath")));
          int64_t lastUsnId = 0;
          auto it = args.find(flutter::EncodableValue("lastUsnId"));
          if (it != args.end()) {
            if (auto* i = std::get_if<int64_t>(&it->second))
              lastUsnId = *i;
            else if (auto* i2 = std::get_if<int32_t>(&it->second))
              lastUsnId = *i2;
          }
          std::string info = QueryUsnJournal(rootPath, lastUsnId);
          result->Success(flutter::EncodableValue(info));
        } else if (call.method_name() == "queryUsnWithDirs") {
          const auto& args =
              std::get<flutter::EncodableMap>(*call.arguments());
          const auto& rootPath = std::get<std::string>(
              args.at(flutter::EncodableValue("rootPath")));
          int64_t lastUsnId = 0;
          auto it = args.find(flutter::EncodableValue("lastUsnId"));
          if (it != args.end()) {
            if (auto* i = std::get_if<int64_t>(&it->second))
              lastUsnId = *i;
            else if (auto* i2 = std::get_if<int32_t>(&it->second))
              lastUsnId = *i2;
          }
          std::string info = QueryUsnJournalWithDirs(rootPath, lastUsnId);
          result->Success(flutter::EncodableValue(info));
        } else if (call.method_name() == "scanDirectoryAsync") {
          const auto& args =
              std::get<flutter::EncodableMap>(*call.arguments());
          const auto& rootPath = std::get<std::string>(
              args.at(flutter::EncodableValue("rootPath")));
          int requestId = std::get<int32_t>(
              args.at(flutter::EncodableValue("requestId")));
          ScanDirectoryAsync(rootPath, filesearch_messenger, requestId);
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "queryUsnWithDirsAsync") {
          const auto& args =
              std::get<flutter::EncodableMap>(*call.arguments());
          const auto& rootPath = std::get<std::string>(
              args.at(flutter::EncodableValue("rootPath")));
          int64_t lastUsnId = 0;
          auto it = args.find(flutter::EncodableValue("lastUsnId"));
          if (it != args.end()) {
            if (auto* i = std::get_if<int64_t>(&it->second))
              lastUsnId = *i;
            else if (auto* i2 = std::get_if<int32_t>(&it->second))
              lastUsnId = *i2;
          }
          int requestId = std::get<int32_t>(
              args.at(flutter::EncodableValue("requestId")));
          QueryUsnJournalWithDirsAsync(rootPath, lastUsnId,
              filesearch_messenger, requestId);
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "getFileIcon") {
          const auto& args =
              std::get<flutter::EncodableMap>(*call.arguments());
          const auto& path = std::get<std::string>(
              args.at(flutter::EncodableValue("path")));
          std::vector<uint8_t> png = GetFileIconPng(path);
          result->Success(flutter::EncodableValue(png));
        } else if (call.method_name() == "pickFolder") {
          std::wstring path = PickFolder(nullptr);
          int len = WideCharToMultiByte(CP_UTF8, 0, path.c_str(), -1,
              nullptr, 0, nullptr, nullptr);
          std::string utf8(len - 1, '\0');
          WideCharToMultiByte(CP_UTF8, 0, path.c_str(), -1,
              &utf8[0], len, nullptr, nullptr);
          result->Success(flutter::EncodableValue(utf8));
        } else if (call.method_name() == "pickFile") {
          std::string path = PickFile(nullptr);
          result->Success(flutter::EncodableValue(path));
        } else if (call.method_name() == "pickFiles") {
          std::string paths = PickFiles(nullptr);
          result->Success(flutter::EncodableValue(paths));
        } else {
          result->NotImplemented();
        }
      });

  fileops_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/fileops",
          &flutter::StandardMethodCodec::GetInstance());
  fileops_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        auto getPath = [&]() {
          const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
          auto it = args.find(flutter::EncodableValue("path"));
          if (it != args.end()) {
            if (auto* s = std::get_if<std::string>(&it->second)) {
              std::string path = *s;
              // Normalize forward slashes to backslashes — Dart sends / paths
              // (e.g. FileSearchResult.fullPath) but Windows APIs require \.
              for (char& c : path) {
                if (c == '/') c = '\\';
              }
              return path;
            }
          }
          return std::string{};
        };
        HWND hwnd = GetHandle();
        if (call.method_name() == "copyToClipboard") {
          result->Success(flutter::EncodableValue(CopyFilesToClipboard(getPath())));
        } else if (call.method_name() == "cutToClipboard") {
          result->Success(flutter::EncodableValue(CutFilesToClipboard(getPath())));
        } else if (call.method_name() == "createShortcut") {
          result->Success(flutter::EncodableValue(CreateDesktopShortcut(getPath())));
        } else if (call.method_name() == "deleteToRecycleBin") {
          result->Success(flutter::EncodableValue(DeleteToRecycleBin(getPath())));
        } else if (call.method_name() == "showProperties") {
          result->Success(flutter::EncodableValue(ShowFileProperties(getPath(), hwnd)));
        } else if (call.method_name() == "pinToStart") {
          result->Success(flutter::EncodableValue(PinToStart(getPath())));
        } else if (call.method_name() == "openAsAdmin") {
          result->Success(flutter::EncodableValue(OpenFileAsAdmin(getPath(), hwnd)));
        } else if (call.method_name() == "runCommandAsAdmin") {
          const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
          auto getStr = [&](const char* key) -> std::string {
            auto it = args.find(flutter::EncodableValue(key));
            if (it != args.end()) {
              if (auto* s = std::get_if<std::string>(&it->second)) return *s;
            }
            return {};
          };
          std::string cmdPath = getStr("cmdPath");
          std::string cmdArgs = getStr("args");
          std::string workDir = getStr("workDir");
          // Normalize slashes in paths (belt-and-suspenders)
          for (char& c : cmdPath) { if (c == '/') c = '\\'; }
          for (char& c : workDir) { if (c == '/') c = '\\'; }
          result->Success(flutter::EncodableValue(
              RunCommandAsAdmin(cmdPath, cmdArgs, workDir, hwnd)));
        } else if (call.method_name() == "openWithDialog") {
          result->Success(flutter::EncodableValue(OpenWithDialog(getPath(), hwnd)));
        } else if (call.method_name() == "getAudioProperties") {
          result->Success(flutter::EncodableValue(GetAudioProperties(getPath())));
        } else if (call.method_name() == "installIndexerService") {
          // Needs admin — launch elevated helper (same pattern as ToggleAutoStart).
          WCHAR exePath[MAX_PATH];
          GetModuleFileNameW(NULL, exePath, MAX_PATH);
          SHELLEXECUTEINFOW seiInst = {};
          seiInst.cbSize = sizeof(seiInst);
          seiInst.lpVerb = L"runas";
          seiInst.lpFile = exePath;
          seiInst.lpParameters = L"--install-indexer";
          seiInst.nShow = SW_HIDE;
          result->Success(flutter::EncodableValue(
              ShellExecuteExW(&seiInst) == TRUE));
        } else if (call.method_name() == "uninstallIndexerService") {
          WCHAR exePath[MAX_PATH];
          GetModuleFileNameW(NULL, exePath, MAX_PATH);
          SHELLEXECUTEINFOW seiUn = {};
          seiUn.cbSize = sizeof(seiUn);
          seiUn.lpVerb = L"runas";
          seiUn.lpFile = exePath;
          seiUn.lpParameters = L"--uninstall-indexer";
          seiUn.nShow = SW_HIDE;
          result->Success(flutter::EncodableValue(
              ShellExecuteExW(&seiUn) == TRUE));
        } else if (call.method_name() == "startIndexerService") {
          result->Success(flutter::EncodableValue(StartIndexerService()));
        } else if (call.method_name() == "stopIndexerService") {
          result->Success(flutter::EncodableValue(StopIndexerService()));
        } else if (call.method_name() == "isIndexerServiceInstalled") {
          result->Success(flutter::EncodableValue(IsIndexerServiceInstalled()));
        } else if (call.method_name() == "isIndexerServiceRunning") {
          result->Success(flutter::EncodableValue(IsIndexerServiceRunning()));
        } else if (call.method_name() == "writeIndexerConfig") {
          const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
          IndexerConfig cfg;
          auto itPaths = args.find(flutter::EncodableValue("paths"));
          if (itPaths != args.end()) {
            if (auto* arr = std::get_if<flutter::EncodableList>(&itPaths->second)) {
              for (const auto& v : *arr) {
                if (auto* s = std::get_if<std::string>(&v))
                  cfg.paths.push_back(*s);
              }
            }
          }
          auto itIv = args.find(flutter::EncodableValue("intervalSec"));
          if (itIv != args.end()) {
            if (auto* n = std::get_if<int32_t>(&itIv->second))
              cfg.intervalSec = *n;
          }
          result->Success(flutter::EncodableValue(SaveIndexerConfig(cfg)));
        } else if (call.method_name() == "readUsnResult") {
          auto it = std::get<flutter::EncodableMap>(*call.arguments())
                        .find(flutter::EncodableValue("hash"));
          std::string resultJson;
          if (it != std::get<flutter::EncodableMap>(*call.arguments()).end()) {
            if (auto* hash = std::get_if<std::string>(&it->second)) {
              std::wstring dir = GetIndexerResultsDir();
              std::wstring fileName = dir + L"\\";
              fileName += std::wstring(hash->begin(), hash->end());
              fileName += L"_usn.json";
              FILE* f = nullptr;
              _wfopen_s(&f, fileName.c_str(), L"rb");
              if (f) {
                fseek(f, 0, SEEK_END);
                long sz = ftell(f);
                if (sz > 0) {
                  fseek(f, 0, SEEK_SET);
                  resultJson.resize(sz);
                  fread(&resultJson[0], 1, sz, f);
                }
                fclose(f);
              }
            }
          }
          result->Success(flutter::EncodableValue(resultJson));
        } else if (call.method_name() == "decodeFilename") {
          // Decode raw bytes using the system ANSI codepage (CP_ACP).
          // On Chinese Windows this is GBK/CP936; on Japanese it's Shift-JIS.
          const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
          auto it = args.find(flutter::EncodableValue("bytes"));
          if (it != args.end()) {
            if (auto* vec = std::get_if<std::vector<uint8_t>>(&it->second)) {
              if (!vec->empty()) {
                int wideLen = MultiByteToWideChar(CP_ACP, MB_ERR_INVALID_CHARS,
                    reinterpret_cast<LPCCH>(vec->data()),
                    static_cast<int>(vec->size()), nullptr, 0);
                if (wideLen > 0) {
                  std::wstring wide(wideLen, L'\0');
                  MultiByteToWideChar(CP_ACP, 0,
                      reinterpret_cast<LPCCH>(vec->data()),
                      static_cast<int>(vec->size()), &wide[0], wideLen);
                  int utf8Len = WideCharToMultiByte(CP_UTF8, 0,
                      wide.data(), wideLen, nullptr, 0, nullptr, nullptr);
                  std::string utf8Str(utf8Len, '\0');
                  WideCharToMultiByte(CP_UTF8, 0, wide.data(), wideLen,
                      &utf8Str[0], utf8Len, nullptr, nullptr);
                  result->Success(flutter::EncodableValue(utf8Str));
                  return;
                }
              }
            }
          }
          result->Success(flutter::EncodableValue(std::string{}));
        } else {
          result->NotImplemented();
        }
      });

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "setFullScreen") {
          HWND hwnd = GetHandle();
          // Use cursor position to pick the monitor, not the window's
          // current monitor — so the fullscreen overlay lands on the
          // same screen the user is looking at (multi-monitor support).
          POINT pt;
          GetCursorPos(&pt);
          HMONITOR monitor = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
          MONITORINFO info = {};
          info.cbSize = sizeof(info);
          if (GetMonitorInfoW(monitor, &info)) {
            SetWindowPos(hwnd, HWND_TOPMOST,
                info.rcMonitor.left, info.rcMonitor.top,
                info.rcMonitor.right - info.rcMonitor.left,
                info.rcMonitor.bottom - info.rcMonitor.top,
                SWP_SHOWWINDOW);
            result->Success(flutter::EncodableValue(true));
          } else {
            result->Error("FULLSCREEN_FAILED", "GetMonitorInfo failed");
          }
        } else if (call.method_name() == "forceChildRefresh") {
          HWND hwnd = GetHandle();
          HWND child = FindWindowEx(hwnd, nullptr, L"FLUTTERVIEW", nullptr);
          if (child) {
            RECT cr; GetClientRect(hwnd, &cr);
            int cw = cr.right - cr.left;
            int ch = cr.bottom - cr.top;
            // Dramatic shrink-then-expand to force engine swapchain rebuild.
            MoveWindow(child, 0, 0, 1, 1, TRUE);
            MoveWindow(child, 0, 0, cw, ch, TRUE);
          }
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "moveCursor") {
          const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
          int dx = std::get<int>(args.at(flutter::EncodableValue("dx")));
          int dy = std::get<int>(args.at(flutter::EncodableValue("dy")));
          POINT pt;
          GetCursorPos(&pt);
          SetCursorPos(pt.x + dx, pt.y + dy);
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "setBounds") {
          const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
          int x = std::get<int>(args.at(flutter::EncodableValue("x")));
          int y = std::get<int>(args.at(flutter::EncodableValue("y")));
          int w = std::get<int>(args.at(flutter::EncodableValue("width")));
          int h = std::get<int>(args.at(flutter::EncodableValue("height")));
          HWND hwnd = GetHandle();
          // Dart sends logical pixels; SetWindowPos expects physical pixels.
          UINT dpi = GetDpiForWindow(hwnd);
          double scale = dpi / 96.0;
          SetWindowPos(hwnd, HWND_TOPMOST,
              static_cast<int>(x * scale),
              static_cast<int>(y * scale),
              static_cast<int>(w * scale),
              static_cast<int>(h * scale),
              SWP_NOACTIVATE);
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "showNoActivate") {
          const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
          int x = std::get<int>(args.at(flutter::EncodableValue("x")));
          int y = std::get<int>(args.at(flutter::EncodableValue("y")));
          int w = std::get<int>(args.at(flutter::EncodableValue("width")));
          int h = std::get<int>(args.at(flutter::EncodableValue("height")));
          HWND hwnd = GetHandle();
          UINT dpi = GetDpiForWindow(hwnd);
          double scale = dpi / 96.0;
          // Position, size, and show without activating. Use HWND_TOP
          // (not HWND_TOPMOST) — the window should only be topmost when
          // the user explicitly toggles Pin (via setAlwaysOnTop).
          SetWindowPos(hwnd, nullptr,
              static_cast<int>(x * scale),
              static_cast<int>(y * scale),
              static_cast<int>(w * scale),
              static_cast<int>(h * scale),
              SWP_NOACTIVATE | SWP_NOZORDER);
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "setWindowHole") {
          const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
          int x = std::get<int>(args.at(flutter::EncodableValue("x")));
          int y = std::get<int>(args.at(flutter::EncodableValue("y")));
          int w = std::get<int>(args.at(flutter::EncodableValue("w")));
          int h = std::get<int>(args.at(flutter::EncodableValue("h")));
          HWND hwnd = GetHandle();
          UINT dpi = GetDpiForWindow(hwnd);
          double scale = dpi / 96.0;
          int px = static_cast<int>(x * scale);
          int py = static_cast<int>(y * scale);
          int pw = static_cast<int>(w * scale);
          int ph = static_cast<int>(h * scale);
          RECT cr;
          GetClientRect(hwnd, &cr);
          int cw = cr.right - cr.left;
          int ch = cr.bottom - cr.top;
          HRGN hole = CreateRectRgn(px, py, px + pw, py + ph);
          HRGN full = CreateRectRgn(0, 0, cw, ch);
          CombineRgn(full, full, hole, RGN_DIFF);
          SetWindowRgn(hwnd, full, TRUE);
          DeleteObject(hole);
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "clearWindowHole") {
          SetWindowRgn(GetHandle(), NULL, TRUE);
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "restoreForeground") {
          const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
          auto it = args.find(flutter::EncodableValue("hwnd"));
          if (it != args.end()) {
            if (auto* n = std::get_if<int64_t>(&it->second)) {
              HWND target = reinterpret_cast<HWND>(*n);
              AllowSetForegroundWindow(ASFW_ANY);
              SetForegroundWindow(target);
            }
          }
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "getSystemTheme") {
          // Read Windows personalization registry setting.
          // Returns true if system AppsUseLightTheme == 1 (light mode).
          DWORD value = 0;
          DWORD size = sizeof(value);
          LSTATUS status = RegGetValueW(
              HKEY_CURRENT_USER,
              L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
              L"AppsUseLightTheme",
              RRF_RT_REG_DWORD,
              nullptr,
              &value,
              &size);
          result->Success(flutter::EncodableValue(status == ERROR_SUCCESS && value == 1));
        } else if (call.method_name() == "setTaskbarIcon") {
          const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
          const auto& name = std::get<std::string>(
              args.at(flutter::EncodableValue("name")));
          WCHAR path[MAX_PATH];
          GetModuleFileNameW(nullptr, path, MAX_PATH);
          WCHAR* slash = wcsrchr(path, L'\\');
          if (slash) *slash = L'\0';
          std::wstring iconFile = std::wstring(path) +
              L"\\data\\flutter_assets\\assets\\" +
              std::wstring(name.begin(), name.end());
          HICON hIcon = (HICON)LoadImageW(nullptr, iconFile.c_str(),
              IMAGE_ICON, 0, 0, LR_LOADFROMFILE | LR_DEFAULTSIZE);
          if (hIcon) {
            HWND hwnd = GetHandle();
            SendMessage(hwnd, WM_SETICON, ICON_BIG,
                reinterpret_cast<LPARAM>(hIcon));
            SendMessage(hwnd, WM_SETICON, ICON_SMALL,
                reinterpret_cast<LPARAM>(hIcon));
            result->Success(flutter::EncodableValue(true));
          } else {
            result->Error("ICON_LOAD_FAILED", "Failed to load icon");
          }
        } else if (call.method_name() == "swapMonitors") {
          std::string json = SwapMonitors(GetHandle());
          result->Success(flutter::EncodableValue(json));
        } else {
          result->NotImplemented();
        }
      });

  debug_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/debug",
          &flutter::StandardMethodCodec::GetInstance());
  debug_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "closeNotificationWindows") {
          int closed = 0;
          HWND h = FindWindowW(nullptr, L"xmate_notify");
          if (h) { PostMessageW(h, WM_CLOSE, 0, 0); closed++; }
          result->Success(flutter::EncodableValue(closed));
        } else if (call.method_name() == "sendKeyEchoSettings") {
          const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
          bool hotkey = std::get<bool>(args.at(flutter::EncodableValue("hotkey")));
          bool status = std::get<bool>(args.at(flutter::EncodableValue("status")));
          HWND hNotify = FindWindowW(nullptr, L"xmate_notify");
          if (hNotify) {
            WPARAM wParam = (hotkey ? 1 : 0) | (status ? 2 : 0);
            SendMessageW(hNotify, WM_XMATE_KEYECHO_SETTINGS, wParam, 0);
          }
          result->Success(flutter::EncodableValue(hNotify != nullptr));
        } else if (call.method_name() == "sendThemeChanged") {
          const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
          // Helper: Dart ints may arrive as int32 or int64 depending on value.
          auto getInt = [&](const char* key) -> int {
            auto it = args.find(flutter::EncodableValue(key));
            if (it == args.end()) return 0;
            if (auto* p = std::get_if<int32_t>(&it->second)) return *p;
            if (auto* p2 = std::get_if<int64_t>(&it->second)) return static_cast<int>(*p2);
            return 0;
          };
          int mode = getInt("mode");
          int accent = getInt("accent");
          HWND hNotify = FindWindowW(nullptr, L"xmate_notify");
          if (hNotify) {
            SendMessageW(hNotify, WM_XMATE_THEME_CHANGED,
                         static_cast<WPARAM>(mode),
                         static_cast<LPARAM>(accent));
          }
          result->Success(flutter::EncodableValue(hNotify != nullptr));
        } else if (call.method_name() == "showIconDebug") {
          const auto& args =
              std::get<flutter::EncodableMap>(*call.arguments());
          const auto& path = std::get<std::string>(
              args.at(flutter::EncodableValue("path")));
          ShowIconDebugDialog(path);
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "testWinRTOcr") {
          const auto& args =
              std::get<flutter::EncodableMap>(*call.arguments());

          // Extract PNG bytes
          auto it = args.find(flutter::EncodableValue("pngBytes"));
          if (it == args.end()) {
            result->Error("INVALID_ARG", "Missing 'pngBytes'");
            return;
          }
          const auto* vec =
              std::get_if<std::vector<uint8_t>>(&it->second);
          if (!vec) {
            result->Error("INVALID_ARG", "'pngBytes' must be binary");
            return;
          }

          // Extract language (optional, default "en")
          std::string language = "en";
          auto langIt = args.find(flutter::EncodableValue("language"));
          if (langIt != args.end()) {
            if (auto* s = std::get_if<std::string>(&langIt->second)) {
              language = *s;
            }
          }

          std::string json = WinRTOcrFromPNG(*vec, 0, 0, language);
          result->Success(flutter::EncodableValue(json));
        } else {
          result->NotImplemented();
        }
      });

  // - Drag-drop setup (process runs at medium IL — no UIPI needed) ----
  OleInitialize(nullptr);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Scroll capture channel (C++ -> Dart notification)
  scroll_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/scroll",
          &flutter::StandardMethodCodec::GetInstance());

  // QuickLook channel: query Explorer selection
  quicklook_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/quicklook",
          &flutter::StandardMethodCodec::GetInstance());
  quicklook_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "getExplorerSelection") {
          std::string json = GetExplorerSelection();
          result->Success(flutter::EncodableValue(json));
        } else if (call.method_name() == "closeQuickLookWindows") {
          bool includePinned = false;
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args) {
            auto it = args->find(flutter::EncodableValue("includePinned"));
            if (it != args->end()) {
              includePinned = std::get<bool>(it->second);
            }
          }
          int closed = CloseQuickLookWindows(includePinned);
          result->Success(flutter::EncodableValue(closed));
        } else if (call.method_name() == "isQuickLookRunning") {
          // Check both unpinned and pinned windows.
          HWND h = FindWindowW(L"xmate_ql", nullptr);
          if (!h) h = FindWindowW(L"xmate_ql_pinned", nullptr);
          result->Success(flutter::EncodableValue(h != nullptr));
        } else if (call.method_name() == "setPinned") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args) {
            auto it = args->find(flutter::EncodableValue("pinned"));
            if (it != args->end()) {
              bool pinned = std::get<bool>(it->second);
              SetWindowTextW(GetHandle(), pinned ? L"xmate_ql_pinned" : L"xmate_ql");
            }
          }
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "requestTranslate") {
          // QL process wants the main process to open the translate window.
          // Wake the main window — it will read ql_translate_req.json.
          HWND hMain = FindWindowW(NULL, L"xmate");
          if (hMain) {
            PostMessageW(hMain, WM_XMATE_QL_TRANSLATE, 0, 0);
          }
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });

  // Notes channel: sticky-note window discovery + cross-process messaging.
  // Registered unconditionally so both the main process and note processes
  // can use it.
  notes_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/notes",
          &flutter::StandardMethodCodec::GetInstance());
  notes_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "listNoteWindows") {
          // Enumerate all windows titled "xmate_note_<id>", return JSON
          // [{"id":"...","l":..,"t":..,"r":..,"b":..}] (physical pixels).
          struct NoteEnumCtx { std::string json; bool first; };
          NoteEnumCtx ctx{ "[", true };
          EnumWindows(
              [](HWND h, LPARAM lp) -> BOOL {
                auto* c = reinterpret_cast<NoteEnumCtx*>(lp);
                wchar_t buf[256] = {};
                GetWindowTextW(h, buf, 256);
                const wchar_t* prefix = L"xmate_note_";
                size_t plen = wcslen(prefix);
                if (wcsncmp(buf, prefix, plen) != 0) return TRUE;
                if (!IsWindowVisible(h)) return TRUE;
                RECT rc = {};
                if (!GetWindowRect(h, &rc)) return TRUE;
                // Extract note id (after the prefix) as UTF-8.
                char idUtf8[256] = {};
                WideCharToMultiByte(CP_UTF8, 0, buf + plen, -1, idUtf8,
                                    sizeof(idUtf8), nullptr, nullptr);
                if (!c->first) c->json += ",";
                c->first = false;
                c->json += "{\"id\":\"";
                c->json += idUtf8;
                c->json += "\",\"l\":" + std::to_string(rc.left) +
                           ",\"t\":" + std::to_string(rc.top) +
                           ",\"r\":" + std::to_string(rc.right) +
                           ",\"b\":" + std::to_string(rc.bottom) + "}";
                return TRUE;
              },
              reinterpret_cast<LPARAM>(&ctx));
          ctx.json += "]";
          result->Success(flutter::EncodableValue(ctx.json));
        } else if (call.method_name() == "sendNoteData") {
          // Deliver a command-file path to a running note window via
          // WM_COPYDATA. Returns false when the window does not exist
          // (caller falls back to writing the note file directly).
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          std::string id, dataPath;
          if (args) {
            auto itId = args->find(flutter::EncodableValue("id"));
            if (itId != args->end())
              if (auto* s = std::get_if<std::string>(&itId->second)) id = *s;
            auto itPath = args->find(flutter::EncodableValue("dataPath"));
            if (itPath != args->end())
              if (auto* s = std::get_if<std::string>(&itPath->second)) dataPath = *s;
          }
          if (id.empty() || dataPath.empty()) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          std::wstring title = L"xmate_note_" + Utf8ToWide(id);
          HWND hNote = FindWindowW(nullptr, title.c_str());
          if (!hNote) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          COPYDATASTRUCT cds = {};
          cds.dwData = WM_XMATE_NOTE_DATA;
          cds.cbData = (DWORD)(dataPath.size() + 1);
          cds.lpData = (PVOID)dataPath.c_str();
          SendMessageW(hNote, WM_COPYDATA, 0, (LPARAM)&cds);
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "closeNoteWindow") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          std::string id;
          if (args) {
            auto it = args->find(flutter::EncodableValue("id"));
            if (it != args->end())
              if (auto* s = std::get_if<std::string>(&it->second)) id = *s;
          }
          bool closed = false;
          if (!id.empty()) {
            std::wstring title = L"xmate_note_" + Utf8ToWide(id);
            HWND hNote = FindWindowW(nullptr, title.c_str());
            if (hNote) { PostMessageW(hNote, WM_CLOSE, 0, 0); closed = true; }
          }
          result->Success(flutter::EncodableValue(closed));
        } else if (call.method_name() == "focusNoteWindow") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          std::string id;
          if (args) {
            auto it = args->find(flutter::EncodableValue("id"));
            if (it != args->end())
              if (auto* s = std::get_if<std::string>(&it->second)) id = *s;
          }
          bool found = false;
          if (!id.empty()) {
            std::wstring title = L"xmate_note_" + Utf8ToWide(id);
            HWND hNote = FindWindowW(nullptr, title.c_str());
            if (hNote) {
              ShowWindow(hNote, SW_SHOW);
              SetForegroundWindow(hNote);
              found = true;
            }
          }
          result->Success(flutter::EncodableValue(found));
        } else if (call.method_name() == "beep") {
          MessageBeep(MB_OK);
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });

  // Office preview channel: Word document preview via IPreviewHandler
  officepreview_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/officepreview",
          &flutter::StandardMethodCodec::GetInstance());
  officepreview_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "check") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) { result->Success(flutter::EncodableValue(false)); return; }
          auto it = args->find(flutter::EncodableValue("ext"));
          if (it != args->end()) {
            if (auto* s = std::get_if<std::string>(&it->second)) {
              std::wstring ext = Utf8ToWide(*s);
              result->Success(
                  flutter::EncodableValue(IsWordPreviewAvailable(ext)));
              return;
            }
          }
          result->Success(flutter::EncodableValue(false));
        } else if (call.method_name() == "create") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) { result->Success(flutter::EncodableValue(0)); return; }
          auto getStr = [&](const char* key) -> std::string {
            auto it = args->find(flutter::EncodableValue(key));
            if (it != args->end())
              if (auto* s = std::get_if<std::string>(&it->second)) return *s;
            return {};
          };
          auto getInt = [&](const char* key) -> int {
            auto it = args->find(flutter::EncodableValue(key));
            if (it != args->end()) {
              if (auto* a = std::get_if<int32_t>(&it->second)) return *a;
              if (auto* b = std::get_if<int64_t>(&it->second)) return static_cast<int>(*b);
            }
            return 0;
          };
          std::string path = getStr("path");
          // Normalise slashes
          for (char& c : path) { if (c == '/') c = '\\'; }
          int x = getInt("x"), y = getInt("y");
          int w = getInt("w"), h = getInt("h");
          int64_t instance = CreateWordPreview(GetHandle(), path, x, y, w, h);
          result->Success(flutter::EncodableValue(static_cast<int64_t>(instance)));
        } else if (call.method_name() == "setRect") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) { result->Success(); return; }
          auto getInt = [&](const char* key) -> int {
            auto it = args->find(flutter::EncodableValue(key));
            if (it != args->end()) {
              if (auto* a = std::get_if<int32_t>(&it->second)) return *a;
              if (auto* b = std::get_if<int64_t>(&it->second)) return static_cast<int>(*b);
            }
            return 0;
          };
          int64_t instance = getInt("instance");
          int x = getInt("x"), y = getInt("y");
          int w = getInt("w"), h = getInt("h");
          SetWordPreviewRect(instance, x, y, w, h);
          result->Success();
        } else if (call.method_name() == "destroy") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args) {
            auto it = args->find(flutter::EncodableValue("instance"));
            if (it != args->end()) {
              int64_t instance = 0;
              if (auto* p = std::get_if<int32_t>(&it->second)) instance = *p;
              else if (auto* q = std::get_if<int64_t>(&it->second)) instance = *q;
              DestroyWordPreview(instance);
            }
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  // Screen recording channel
  screenrecording_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/screenrecording",
          &flutter::StandardMethodCodec::GetInstance());
  screenrecording_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "closeSrWindows") {
          int closed = 0;
          EnumWindows([](HWND h, LPARAM lp) -> BOOL {
            int* count = reinterpret_cast<int*>(lp);
            wchar_t title[64] = {};
            GetWindowTextW(h, title, 64);
            if (wcscmp(title, L"xmate_sr") == 0) {
              PostMessage(h, WM_CLOSE, 0, 0);
              (*count)++;
            }
            return TRUE;
          }, reinterpret_cast<LPARAM>(&closed));
          result->Success(flutter::EncodableValue(closed));
        } else if (call.method_name() == "findFFmpegPath") {
          result->Success(flutter::EncodableValue(FindFFmpegPath()));
        } else {
          result->NotImplemented();
        }
      });

  // Annotation overlay channel
  overlay_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/overlay",
          &flutter::StandardMethodCodec::GetInstance());
  overlay_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "createOverlay") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) { result->Success(flutter::EncodableValue(0)); return; }

          auto getInt = [&](const char* key) -> int {
            auto it = args->find(flutter::EncodableValue(key));
            if (it == args->end()) return 0;
            if (auto* p = std::get_if<int32_t>(&it->second)) return *p;
            if (auto* q = std::get_if<int64_t>(&it->second)) return static_cast<int>(*q);
            return 0;
          };

          auto it_png = args->find(flutter::EncodableValue("png"));
          if (it_png == args->end()) { result->Success(flutter::EncodableValue(0)); return; }
          const auto* png = std::get_if<std::vector<uint8_t>>(&it_png->second);
          if (!png) { result->Success(flutter::EncodableValue(0)); return; }

          int x = getInt("x"), y = getInt("y");
          int w = getInt("w"), h = getInt("h");

          int64_t handle = CreateAnnotationOverlay(*png, x, y, w, h);
          result->Success(flutter::EncodableValue(handle));
        } else if (call.method_name() == "destroyOverlay") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args) {
            auto it = args->find(flutter::EncodableValue("handle"));
            if (it != args->end()) {
              int64_t handle = 0;
              if (auto* p = std::get_if<int64_t>(&it->second)) handle = *p;
              else if (auto* q = std::get_if<int32_t>(&it->second)) handle = *q;
              DestroyAnnotationOverlay(handle);
            }
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  // Drag-drop channel (C++ -> Dart)
  dragdrop_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/dragdrop",
          &flutter::StandardMethodCodec::GetInstance());

  // Drag-out channel (Dart -> C++): start an OLE file drag to Explorer
  dragout_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.xmate/dragout",
          &flutter::StandardMethodCodec::GetInstance());
  dragout_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "start") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) { result->Success(flutter::EncodableValue(false)); return; }

          auto getStr = [&](const char* key) -> std::string {
            auto it = args->find(flutter::EncodableValue(key));
            if (it != args->end())
              if (auto* s = std::get_if<std::string>(&it->second)) return *s;
            return {};
          };

          std::string mode = getStr("mode"); // "file" | "image" | "text"

          DragDataType dragType = DRAG_FILES;
          std::vector<std::string> files;
          std::string text;

          if (mode == "image") {
            dragType = DRAG_IMAGE;
            auto path = getStr("path");
            if (path.empty()) { result->Success(flutter::EncodableValue(false)); return; }
            files.push_back(path);
          } else if (mode == "text") {
            dragType = DRAG_TEXT;
            text = getStr("text");
            if (text.empty()) { result->Success(flutter::EncodableValue(false)); return; }
          } else {
            // "file" (default)
            auto it = args->find(flutter::EncodableValue("files"));
            if (it != args->end()) {
              if (auto* arr = std::get_if<flutter::EncodableList>(&it->second)) {
                for (const auto& v : *arr)
                  if (auto* s = std::get_if<std::string>(&v)) files.push_back(*s);
              }
            }
            if (files.empty()) { result->Success(flutter::EncodableValue(false)); return; }
          }

          bool needOleUninit = (OleInitialize(nullptr) == S_OK);
          bool ok = StartDrag(GetHandle(), dragType, files, text);
          result->Success(flutter::EncodableValue(ok));
          if (needOleUninit) OleUninitialize();
        } else {
          result->NotImplemented();
        }
      });

  auto sendDropToDart = [this](bool isText, const std::string& text,
                                const std::vector<std::string>& files) {
    if (!dragdrop_channel_) return;
    auto args = flutter::EncodableMap{};
    if (isText) {
      args[flutter::EncodableValue("type")] = flutter::EncodableValue("text");
      args[flutter::EncodableValue("text")] = flutter::EncodableValue(text);
    } else {
      args[flutter::EncodableValue("type")] = flutter::EncodableValue("files");
      flutter::EncodableList list;
      for (const auto& f : files)
        list.push_back(flutter::EncodableValue(f));
      args[flutter::EncodableValue("files")] = flutter::EncodableValue(list);
    }
    dragdrop_channel_->InvokeMethod(
        "onDrop", std::make_unique<flutter::EncodableValue>(args));
  };

  // File chain: DragAcceptFiles on PARENT only — Windows shell walks the
  // parent chain when looking for WM_DROPFILES targets.
  DragAcceptFiles(GetHandle(), TRUE);

  // OLE drop target on BOTH parent and child. Explorer uses OLE exclusively
  // and WindowFromPoint may return either HWND depending on hit-test details.
  HWND childHwnd = flutter_controller_->view()->GetNativeWindow();
  // (info debug output removed)

  // Parent OLE target (backup)
  drag_drop_handler_ = std::make_shared<DragDropHandler>();
  drag_drop_handler_->SetCallback(
      [sendDropToDart](const DragDropHandler::DropData& dd) {
        sendDropToDart(dd.isText, dd.text, dd.files);
      });
  drag_drop_handler_->Register(GetHandle());

  // Child OLE target (primary)
  drag_drop_child_handler_ = std::make_shared<DragDropHandler>();
  drag_drop_child_handler_->SetCallback(
      [sendDropToDart](const DragDropHandler::DropData& dd) {
        sendDropToDart(dd.isText, dd.text, dd.files);
      });
  drag_drop_child_handler_->Register(childHwnd);

  // ── Key Echo channel (notification process) ─────────────────────────
  if (startup_mode_ == "notification") {
    keyecho_channel_ =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            flutter_controller_->engine()->messenger(),
            "com.xmate/keyecho",
            &flutter::StandardMethodCodec::GetInstance());
    keyecho_channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
          if (call.method_name() == "getInitialState") {
            flutter::EncodableMap state;
            state[flutter::EncodableValue("capsLock")] =
                flutter::EncodableValue((GetKeyState(VK_CAPITAL) & 1) != 0);
            state[flutter::EncodableValue("numLock")] =
                flutter::EncodableValue((GetKeyState(VK_NUMLOCK) & 1) != 0);
            state[flutter::EncodableValue("scrollLock")] =
                flutter::EncodableValue((GetKeyState(VK_SCROLL) & 1) != 0);
            state[flutter::EncodableValue("insertLock")] =
                flutter::EncodableValue((GetKeyState(VK_INSERT) & 1) != 0);
            result->Success(flutter::EncodableValue(state));
          } else if (call.method_name() == "startHook") {
            bool ok = InstallKeyboardHook(GetHandle());
            result->Success(flutter::EncodableValue(ok));
          } else if (call.method_name() == "stopHook") {
            UninstallKeyboardHook();
            result->Success(flutter::EncodableValue(true));
          } else if (call.method_name() == "resizeContent") {
            // Position + size only — does NOT show the window.
            // Dart calls this first, then showContent after a frame callback
            // so Flutter renders content before the window becomes visible.
            const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
            int x = std::get<int32_t>(args.at(flutter::EncodableValue("x")));
            int y = std::get<int32_t>(args.at(flutter::EncodableValue("y")));
            int w = std::get<int32_t>(args.at(flutter::EncodableValue("w")));
            int h = std::get<int32_t>(args.at(flutter::EncodableValue("h")));

            HWND hwnd = GetHandle();
            UINT dpi = GetDpiForWindow(hwnd);
            double scale = dpi / 96.0;
            SetWindowPos(hwnd, HWND_TOPMOST,
                static_cast<int>(x * scale),
                static_cast<int>(y * scale),
                static_cast<int>(w * scale),
                static_cast<int>(h * scale),
                SWP_NOACTIVATE);  // position + TOPMOST, but stay hidden

            // Force swapchain rebuild after resize.
            HWND child = FindWindowExW(hwnd, nullptr, L"FLUTTERVIEW", nullptr);
            if (child) {
              int cw = static_cast<int>(w * scale);
              int ch = static_cast<int>(h * scale);
              MoveWindow(child, 0, 0, 1, 1, TRUE);
              MoveWindow(child, 0, 0, cw, ch, TRUE);
            }
            result->Success(flutter::EncodableValue(true));
          } else if (call.method_name() == "showContent") {
            HWND hwnd = GetHandle();
            ShowWindow(hwnd, SW_SHOW);
            result->Success(flutter::EncodableValue(true));
          } else if (call.method_name() == "hideContent") {
            HWND hwnd = GetHandle();
            ShowWindow(hwnd, SW_HIDE);
            result->Success(flutter::EncodableValue(true));
          } else if (call.method_name() == "getSystemVolume") {
            int vol = -1;
            IMMDeviceEnumerator* enumerator = nullptr;
            IMMDevice* device = nullptr;
            IAudioEndpointVolume* endpointVolume = nullptr;
            HRESULT hr = CoCreateInstance(
                __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_INPROC_SERVER,
                __uuidof(IMMDeviceEnumerator), (void**)&enumerator);
            if (SUCCEEDED(hr)) {
              hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
              if (SUCCEEDED(hr)) {
                hr = device->Activate(__uuidof(IAudioEndpointVolume),
                    CLSCTX_INPROC_SERVER, nullptr, (void**)&endpointVolume);
                if (SUCCEEDED(hr)) {
                  float level = 0.0f;
                  hr = endpointVolume->GetMasterVolumeLevelScalar(&level);
                  if (SUCCEEDED(hr)) {
                    vol = static_cast<int>(level * 100.0f + 0.5f);
                  }
                  endpointVolume->Release();
                }
                device->Release();
              }
              enumerator->Release();
            }
            result->Success(flutter::EncodableValue(vol));
          } else {
            result->NotImplemented();
          }
        });

    // ── Notification window: small, TOPMOST, no TRANSPARENT ──────
    // Window starts at 1×1, hidden.  Dart calls resizeContent() when
    // content appears and hideContent() when both panels are empty.
    // The small content area naturally blocks mouse input, but only
    // when there's content to show — impact is minimal.
    {
      HWND hwnd = GetHandle();
      LONG ex = GetWindowLongW(hwnd, GWL_EXSTYLE);
      ex |= WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
      SetWindowLongW(hwnd, GWL_EXSTYLE, ex);
    }
  }

  // First frame: setup that requires the engine HWND to exist.
  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    HWND childHwnd = flutter_controller_->view()->GetNativeWindow();

    if (startup_mode_ != "notification") {
      SetWindowPos(childHwnd, nullptr, 0, 0, 1, 1,
          SWP_SHOWWINDOW | SWP_NOACTIVATE);
    } else {
      // Notification watchdog: periodically check if the main xmate
      // window exists.  If the main process dies abruptly (flutter run q,
      // crash), the notification process exits automatically within ~3s.
      SetTimer(GetHandle(), kWatchdogTimerId, 3000, nullptr);
    }

    if (drag_drop_child_handler_) {
      drag_drop_child_handler_->ReRegister(childHwnd);
    }
  });
  flutter_controller_->ForceRedraw();
  return true;
}

void FlutterWindow::OnDestroy() {
  // Uninstall the global WH_MOUSE_LL scroll hook before any DLL teardown.
  // A live hook keeps our host EXE/DLL loaded in every 32-bit process,
  // which blocks uninstallers from deleting files.
  UninstallScrollHook();

  // Destroy all pin windows and shut down GDI+ so gdiplus.dll can be unloaded.
  DestroyAllPinWindows();

  // Destroy all Office preview handler instances — each holds COM references
  // to Word/Excel/PowerPoint that would otherwise persist past our exit.
  DestroyAllWordPreviews();

  DragAcceptFiles(GetHandle(), FALSE);
  drag_drop_child_handler_.reset();
  drag_drop_handler_.reset();
  dragdrop_channel_ = nullptr;
  RemoveTrayIcon();
  app_channel_ = nullptr;
  screenshot_channel_ = nullptr;
  tray_channel_ = nullptr;
  picker_channel_ = nullptr;
  pin_channel_ = nullptr;
  ocr_channel_ = nullptr;
  translate_channel_ = nullptr;
  filesearch_channel_ = nullptr;
  fileops_channel_ = nullptr;
  window_channel_ = nullptr;
  debug_channel_ = nullptr;
  scroll_channel_ = nullptr;
  quicklook_channel_ = nullptr;
  officepreview_channel_ = nullptr;
  screenrecording_channel_ = nullptr;
  DestroyAllAnnotationOverlays();
  overlay_channel_ = nullptr;
  keyecho_channel_ = nullptr;
  OleUninitialize();
  Win32Window::OnDestroy();
}

void FlutterWindow::OnTrayCommand(int cmd) {
  if (!tray_channel_) return;
  auto args = flutter::EncodableMap{
      {flutter::EncodableValue("cmd"), flutter::EncodableValue(cmd)},
  };
  tray_channel_->InvokeMethod("trayCmd",
      std::make_unique<flutter::EncodableValue>(args));
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT const msg,
                                       WPARAM wp, LPARAM lp) noexcept {
  // WM_NCCALCSIZE: prevent window_manager plugin from adding NC area borders.
  // WS_POPUP windows have no title bar / frame, so client area = full window.
  if (msg == WM_NCCALCSIZE && wp == TRUE) {
    return 0;
  }

  // Notification: never activate — small content window, no interactivity needed.
  if (startup_mode_ == "notification") {
    if (msg == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
    if (msg == WM_ACTIVATE) return 0;
    if (msg == WM_TIMER && wp == kWatchdogTimerId) {
      // If the main xmate window is gone (parent process died abruptly,
      // e.g. flutter run q), exit this notification process.
      if (!FindWindowW(nullptr, L"xmate")) {
        PostQuitMessage(0);
        return 0;
      }
    }
  }

  // QuickLook / ScreenRecording / FileConverter:
  // never activate programmatically.  Only activate on direct user click.
  if (startup_mode_ == "quicklook" || startup_mode_ == "screenrecording" ||
      startup_mode_ == "fileconverter") {
    if (msg == WM_MOUSEACTIVATE) {
      // Click = user wants to interact → allow activation.
      return MA_ACTIVATE;
    }
    if (msg == WM_ACTIVATE) {
      UINT reason = LOWORD(wp);
      if (reason != WA_CLICKACTIVE) {
        // Eat the activation silently — don't call SetForegroundWindow
        // (avoid focus ping-pong), just tell Windows we handled it.
        return 0;
      }
    }
  }

  // WM_DROPFILES: handle BEFORE Flutter's HandleTopLevelWindowProc which
  // would otherwise swallow it (forwards to child which has no handler).
  if (msg == WM_DROPFILES) {
    HDROP hDrop = reinterpret_cast<HDROP>(wp);
    UINT count = DragQueryFileW(hDrop, 0xFFFFFFFF, nullptr, 0);
    if (count == 1 && dragdrop_channel_) {
      wchar_t buf[MAX_PATH];
      if (DragQueryFileW(hDrop, 0, buf, MAX_PATH) > 0) {
        int len = WideCharToMultiByte(CP_UTF8, 0, buf, -1, nullptr, 0, nullptr, nullptr);
        std::string path(len > 0 ? len - 1 : 0, '\0');
        if (len > 0) {
          WideCharToMultiByte(CP_UTF8, 0, buf, -1, &path[0], len, nullptr, nullptr);
        }
        auto args = flutter::EncodableMap{
            {flutter::EncodableValue("type"), flutter::EncodableValue("files")},
            {flutter::EncodableValue("files"),
             flutter::EncodableValue(flutter::EncodableList{
                 flutter::EncodableValue(path)})},
        };
        dragdrop_channel_->InvokeMethod(
            "onDrop", std::make_unique<flutter::EncodableValue>(args));
      }
    }
    DragFinish(hDrop);
    return 0;
  }

// ── Key Echo messages (notification process) ──────────────────────

  if (msg == WM_XMATE_KEY_ECHO && keyecho_channel_) {
    DWORD vkCode    = static_cast<DWORD>(wp);
    DWORD modMask   = static_cast<DWORD>(lp & 0xFF);
    DWORD scanCode  = static_cast<DWORD>((lp >> 16) & 0xFF);
    DWORD lockBits  = static_cast<DWORD>((lp >> 24) & 0x0F);

    flutter::EncodableMap args;
    args[flutter::EncodableValue("vkCode")]    = flutter::EncodableValue(static_cast<int32_t>(vkCode));
    args[flutter::EncodableValue("modifiers")] = flutter::EncodableValue(static_cast<int32_t>(modMask));
    args[flutter::EncodableValue("scanCode")]  = flutter::EncodableValue(static_cast<int32_t>(scanCode));
    args[flutter::EncodableValue("capsLock")]    = flutter::EncodableValue((lockBits & 1) != 0);
    args[flutter::EncodableValue("numLock")]     = flutter::EncodableValue((lockBits & 2) != 0);
    args[flutter::EncodableValue("scrollLock")]  = flutter::EncodableValue((lockBits & 4) != 0);
    args[flutter::EncodableValue("insertLock")]  = flutter::EncodableValue((lockBits & 8) != 0);

    keyecho_channel_->InvokeMethod("onKeyEvent",
        std::make_unique<flutter::EncodableValue>(args));
    return 0;
  }

  // Settings change pushed from main process → forward to Dart.
  if (msg == WM_XMATE_KEYECHO_SETTINGS && keyecho_channel_) {
    bool hotkeyEnabled = (wp & 1) != 0;
    bool statusEnabled = (wp & 2) != 0;
    flutter::EncodableMap args;
    args[flutter::EncodableValue("hotkey")] = flutter::EncodableValue(hotkeyEnabled);
    args[flutter::EncodableValue("status")] = flutter::EncodableValue(statusEnabled);
    keyecho_channel_->InvokeMethod("onSettingsChanged",
        std::make_unique<flutter::EncodableValue>(args));
    return 0;
  }

  // Theme change pushed from main process → forward to Dart.
  if (msg == WM_XMATE_THEME_CHANGED && keyecho_channel_) {
    int themeMode = static_cast<int>(wp);   // 0=system, 1=light, 2=dark
    int accentColor = static_cast<int>(lp); // ARGB int
    flutter::EncodableMap args;
    args[flutter::EncodableValue("mode")] = flutter::EncodableValue(themeMode);
    args[flutter::EncodableValue("accent")] = flutter::EncodableValue(accentColor);
    keyecho_channel_->InvokeMethod("onThemeChanged",
        std::make_unique<flutter::EncodableValue>(args));
    return 0;
  }

  if (msg == WM_XMATE_SCROLL_CAPTURE) {
    if (scroll_channel_) {
      short wheelDelta = (short)wp;
      flutter::EncodableMap args;
      args[flutter::EncodableValue("wheelDelta")] = flutter::EncodableValue((int32_t)wheelDelta);
      scroll_channel_->InvokeMethod("capture",
          std::make_unique<flutter::EncodableValue>(args));
    }
    return 0;
  }

  if (flutter_controller_) {
    std::optional<LRESULT> r =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, msg, wp, lp);
    if (r) return *r;
  }
  switch (msg) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_COPYDATA: {
      auto* cds = reinterpret_cast<COPYDATASTRUCT*>(lp);
      if (cds && cds->dwData == WM_XMATE_WORD_KEEPALIVE && cds->lpData) {
        std::string filePath(static_cast<const char*>(cds->lpData));
        KeepWordHandlerAlive(filePath);
      }
      if (cds && cds->dwData == WM_XMATE_DICT_DATA && cds->lpData) {
        std::string dataPath(static_cast<const char*>(cds->lpData));
        if (app_channel_) {
          app_channel_->InvokeMethod("dictionaryDataRequest",
              std::make_unique<flutter::EncodableValue>(dataPath));
        }
      }
      if (cds && cds->dwData == WM_XMATE_NOTE_DATA && cds->lpData) {
        std::string dataPath(static_cast<const char*>(cds->lpData));
        if (app_channel_) {
          app_channel_->InvokeMethod("noteDataRequest",
              std::make_unique<flutter::EncodableValue>(dataPath));
        }
      }
      return 0;
    }
    case WM_XMATE_TRAY:
      HandleTrayMessage(hwnd, lp);
      break;
    case WM_XMATE_QL_TRANSLATE: {
      // QL subprocess requested a translate.  Read the request file and
      // fire the request to Dart so it can showTranslate().
      char appData[MAX_PATH];
      if (GetEnvironmentVariableA("APPDATA", appData, MAX_PATH)) {
        std::string reqPath = std::string(appData) + "\\XMate\\ql_translate_req.json";
        std::ifstream f(reqPath, std::ios::binary);
        if (f.good()) {
          std::string json((std::istreambuf_iterator<char>(f)),
                            std::istreambuf_iterator<char>());
          f.close();
          DeleteFileA(reqPath.c_str());
          // Minimal JSON extract: {"path":"C:/..."}
          size_t p = json.find("\"path\":\"");
          if (p != std::string::npos) {
            p += 8; // skip "path":"
            size_t e = json.find("\"", p);
            if (e != std::string::npos) {
              std::string path = json.substr(p, e - p);
              if (app_channel_) {
                app_channel_->InvokeMethod("translateFileRequest",
                  std::make_unique<flutter::EncodableValue>(path));
              }
            }
          }
        }
      }
      break;
    }
  }
  return Win32Window::MessageHandler(hwnd, msg, wp, lp);
}
