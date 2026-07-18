// XMate Indexer Service — Windows Service implementation.
#include "indexer_service.h"
#include "indexer_config.h"
#include "usn_journal.h"

#include <windows.h>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <sstream>
#include <vector>

// ---- Globals (service lifetime) --------------------------------------------

static SERVICE_STATUS        g_svcStatus = {};
static SERVICE_STATUS_HANDLE g_svcHandle = nullptr;
static HANDLE                g_stopEvent = nullptr;

static const wchar_t* SVC_NAME = L"XMateIndexer";

// ---- DJB2 hash (matches Dart FileIndexStore._hashRootPath) ------------------

static uint32_t Djb2(const std::string& s) {
  uint32_t hash = 5381;
  for (char c : s)
    hash = ((hash << 5) + hash + static_cast<unsigned char>(c)) & 0x7FFFFFFF;
  return hash;
}

static std::string HashHex(const std::string& s) {
  char buf[16];
  snprintf(buf, sizeof(buf), "%08X", Djb2(s));
  return buf;
}

// ---- JSON helpers -----------------------------------------------------------

static std::string JsonStr(const std::string& s) {
  std::string r = "\"";
  for (char c : s) {
    if (c == '\\') r += "\\\\";
    else if (c == '"') r += "\\\"";
    else r += c;
  }
  r += "\"";
  return r;
}

// ---- Atomic file write ------------------------------------------------------

static bool WriteResultsFile(const std::wstring& filePath, const std::string& json) {
  std::wstring tmpPath = filePath + L".tmp";

  FILE* f = nullptr;
  _wfopen_s(&f, tmpPath.c_str(), L"wb");
  if (!f) return false;

  fwrite(json.data(), 1, json.size(), f);
  fflush(f);
  fclose(f);

  if (!ReplaceFileW(filePath.c_str(), tmpPath.c_str(), nullptr, 0, nullptr, nullptr)) {
    // Target may not exist yet — MoveFileEx fallback
    MoveFileExW(tmpPath.c_str(), filePath.c_str(), MOVEFILE_REPLACE_EXISTING);
  }
  return true;
}

// ---- USN query for a single path --------------------------------------------

static std::pair<int64_t, std::string> QueryPath(const std::string& pathUtf8,
                                                  int64_t lastUsn) {
  std::string json = QueryUsnJournalWithDirs(pathUtf8, lastUsn);
  // Parse nextUsn from the JSON (simple extract)
  int64_t nextUsn = 0;
  auto pos = json.find("\"nextUsn\"");
  if (pos != std::string::npos) {
    auto colon = json.find(':', pos);
    if (colon != std::string::npos) {
      size_t n = colon + 1;
      while (n < json.size() && (json[n] == ' ' || json[n] == '\t' || json[n] == '\r' || json[n] == '\n')) n++;
      std::string num;
      while (n < json.size() && (json[n] >= '0' && json[n] <= '9' || json[n] == '-')) {
        num += json[n];
        n++;
      }
      if (!num.empty()) nextUsn = _strtoi64(num.c_str(), nullptr, 10);
    }
  }
  return {nextUsn, json};
}

// ---- Service control handler ------------------------------------------------

static DWORD WINAPI HandlerEx(DWORD ctrl, DWORD, LPVOID, LPVOID) {
  switch (ctrl) {
    case SERVICE_CONTROL_STOP:
      g_svcStatus.dwCurrentState = SERVICE_STOP_PENDING;
      SetServiceStatus(g_svcHandle, &g_svcStatus);
      SetEvent(g_stopEvent);
      return NO_ERROR;
    case SERVICE_CONTROL_INTERROGATE:
      return NO_ERROR;
  }
  return ERROR_CALL_NOT_IMPLEMENTED;
}

// ---- Report status to SCM ---------------------------------------------------

static void ReportStatus(DWORD state, DWORD exitCode = NO_ERROR) {
  g_svcStatus.dwCurrentState = state;
  g_svcStatus.dwWin32ExitCode = exitCode;
  if (state == SERVICE_RUNNING) {
    g_svcStatus.dwControlsAccepted = SERVICE_ACCEPT_STOP;
    g_svcStatus.dwCheckPoint = 0;
    g_svcStatus.dwWaitHint = 0;
  }
  SetServiceStatus(g_svcHandle, &g_svcStatus);
}

// ---- Service main callback --------------------------------------------------

static VOID WINAPI ServiceMain(DWORD, LPWSTR*) {
  g_svcHandle = RegisterServiceCtrlHandlerExW(SVC_NAME, HandlerEx, nullptr);
  if (!g_svcHandle) return;

  g_svcStatus.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
  ReportStatus(SERVICE_START_PENDING);

  g_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!g_stopEvent) {
    ReportStatus(SERVICE_STOPPED, GetLastError());
    return;
  }

  ReportStatus(SERVICE_RUNNING);

  // ---- Main polling loop ----

  // Per-path USN cursors (keyed by path)
  std::map<std::string, int64_t> cursors;

  for (;;) {
    IndexerConfig cfg = LoadIndexerConfig();

    if (!cfg.paths.empty()) {
      std::wstring resultsDir = GetIndexerResultsDir();
      CreateDirectoryW(resultsDir.c_str(), nullptr);

      for (const auto& path : cfg.paths) {
        int64_t lastUsn = cursors[path];  // defaults to 0 if not present
        auto [nextUsn, json] = QueryPath(path, lastUsn);

        // Write results to {hash}_usn.json
        std::string hash = HashHex(path);
        std::wstring fileName = resultsDir + L"\\";
        fileName += std::wstring(hash.begin(), hash.end());
        fileName += L"_usn.json";

        // Build the results file content (add timestamp)
        std::string result;
        result += "{\"t\":";
        result += std::to_string(GetTickCount64());
        result += ",\"path\":";
        result += JsonStr(path);
        result += ",\"usn\":";
        result += json;
        result += "}";

        WriteResultsFile(fileName, result);

        if (nextUsn > 0) cursors[path] = nextUsn;
      }
    }

    // Wait for interval or stop signal
    DWORD waitMs = (cfg.intervalSec > 0) ? cfg.intervalSec * 1000 : 60000;
    DWORD rc = WaitForSingleObject(g_stopEvent, waitMs);
    if (rc == WAIT_OBJECT_0) break;
  }

  CloseHandle(g_stopEvent);
  g_stopEvent = nullptr;
  ReportStatus(SERVICE_STOPPED);
}

// ---- Public entry point -----------------------------------------------------

int IndexerServiceMain() {
  SERVICE_TABLE_ENTRYW table[] = {
    { const_cast<LPWSTR>(SVC_NAME), ServiceMain },
    { nullptr, nullptr }
  };

  if (!StartServiceCtrlDispatcherW(table)) {
    return EXIT_FAILURE;
  }
  return EXIT_SUCCESS;
}
