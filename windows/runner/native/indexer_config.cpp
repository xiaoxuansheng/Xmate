// XMate Indexer Service — shared config file I/O.
#include "indexer_config.h"

#include <shlobj.h>
#include <windows.h>
#include <cstdio>
#include <cstring>

// ---- Helpers ----------------------------------------------------------------

static std::wstring GetProgramDataDir() {
  wchar_t* p = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_ProgramData, 0, nullptr, &p)))
    return {};
  std::wstring dir(p);
  CoTaskMemFree(p);
  return dir;
}

static std::wstring GetXmateDataDir() {
  std::wstring d = GetProgramDataDir();
  if (d.empty()) return {};
  if (d.back() != L'\\') d += L'\\';
  d += L"XMate";
  return d;
}

static void EnsureDir(const std::wstring& dir) {
  CreateDirectoryW(dir.c_str(), nullptr);
}

// ---- Public API -------------------------------------------------------------

std::wstring GetIndexerConfigPath() {
  return GetXmateDataDir() + L"\\index_config.json";
}

std::wstring GetIndexerResultsDir() {
  return GetXmateDataDir() + L"\\index_results";
}

IndexerConfig LoadIndexerConfig() {
  IndexerConfig cfg;

  std::wstring path = GetIndexerConfigPath();
  FILE* f = nullptr;
  _wfopen_s(&f, path.c_str(), L"rb");
  if (!f) return cfg;  // no config yet — return defaults

  fseek(f, 0, SEEK_END);
  long sz = ftell(f);
  if (sz <= 0) { fclose(f); return cfg; }
  fseek(f, 0, SEEK_SET);

  std::string raw(sz, '\0');
  fread(&raw[0], 1, sz, f);
  fclose(f);

  // Minimal JSON parser — only handles our exact format:
  // {"paths":["...","..."],"intervalSec":60}

  // Extract paths array
  auto pathsPos = raw.find("\"paths\"");
  if (pathsPos != std::string::npos) {
    auto arrStart = raw.find('[', pathsPos);
    auto arrEnd = raw.find(']', pathsPos);
    if (arrStart != std::string::npos && arrEnd != std::string::npos) {
      std::string arr = raw.substr(arrStart + 1, arrEnd - arrStart - 1);
      size_t pos = 0;
      while (pos < arr.size()) {
        auto q1 = arr.find('"', pos);
        if (q1 == std::string::npos) break;
        auto q2 = arr.find('"', q1 + 1);
        if (q2 == std::string::npos) break;
        cfg.paths.push_back(arr.substr(q1 + 1, q2 - q1 - 1));
        pos = q2 + 1;
      }
    }
  }

  // Extract intervalSec
  auto ivPos = raw.find("\"intervalSec\"");
  if (ivPos != std::string::npos) {
    auto colon = raw.find(':', ivPos);
    if (colon != std::string::npos) {
      // skip whitespace
      size_t n = colon + 1;
      while (n < raw.size() && (raw[n] == ' ' || raw[n] == '\t')) n++;
      std::string num;
      while (n < raw.size() && raw[n] >= '0' && raw[n] <= '9') {
        num += raw[n];
        n++;
      }
      if (!num.empty()) cfg.intervalSec = std::stoi(num);
    }
  }

  return cfg;
}

bool SaveIndexerConfig(const IndexerConfig& cfg) {
  std::wstring dir = GetXmateDataDir();
  EnsureDir(dir);

  // Build JSON by hand (no library dependency)
  std::string json = "{\"paths\":[";
  for (size_t i = 0; i < cfg.paths.size(); i++) {
    if (i > 0) json += ",";
    json += "\"";
    // Escape backslash and double-quote
    for (char c : cfg.paths[i]) {
      if (c == '\\') json += "\\\\";
      else if (c == '"') json += "\\\"";
      else json += c;
    }
    json += "\"";
  }
  json += "],\"intervalSec\":";
  json += std::to_string(cfg.intervalSec);
  json += "}";

  std::wstring path = GetIndexerConfigPath();

  // Atomic write: .tmp then rename
  std::wstring tmpPath = path + L".tmp";
  FILE* f = nullptr;
  _wfopen_s(&f, tmpPath.c_str(), L"wb");
  if (!f) return false;

  fwrite(json.data(), 1, json.size(), f);
  fflush(f);
  fclose(f);

  if (!ReplaceFileW(path.c_str(), tmpPath.c_str(), nullptr, 0, nullptr, nullptr)) {
    // If target doesn't exist, MoveFile is fine
    MoveFileExW(tmpPath.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING);
  }

  return true;
}
