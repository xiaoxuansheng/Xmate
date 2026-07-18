// XMate File Search - USN Journal implementation.
//
// Opens the volume containing rootPath, queries the USN journal for records
// since lastUsnId, and returns whether any file changes (create/delete/rename)
// occurred, along with resolved parent directory paths.
#include "usn_journal.h"
#include <windows.h>
#include <string>
#include <sstream>
#include <set>
#include <thread>
#include <unordered_map>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

// ── Debug printf disabled ─────────────────────────────────────────────────
#define DEBUG_PRINTF(...) do { } while(0)

// ── Helpers ────────────────────────────────────────────────────────────────

static std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return {};
  int len = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  if (len <= 1) return {};
  std::wstring result(len - 1, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &result[0], len);
  return result;
}

static std::string WideToUtf8(const std::wstring& ws) {
  if (ws.empty()) return {};
  int len = WideCharToMultiByte(CP_UTF8, 0, ws.c_str(), -1,
                                nullptr, 0, nullptr, nullptr);
  if (len <= 1) return {};
  std::string result(len - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, ws.c_str(), -1,
                      &result[0], len, nullptr, nullptr);
  return result;
}

// Get volume root for a path (e.g. "C:\Users" -> "\\.\C:")
static std::wstring GetVolumeRoot(const std::wstring& path) {
  wchar_t volumeRoot[64] = {};
  if (GetVolumePathNameW(path.c_str(), volumeRoot, 64)) {
    std::wstring result = L"\\\\.\\";
    if (volumeRoot[1] == L':') {
      result += volumeRoot[0];
      result += L':';
    }
    return result;
  }
  return L"";
}

// Enable SE_BACKUP_NAME privilege so we can open volume handles.
// Returns true on success; failing to enable means we can't read USN.
static bool EnableBackupPrivilege() {
  HANDLE hToken = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(),
          TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &hToken)) {
    return false;
  }
  TOKEN_PRIVILEGES tp = {};
  if (LookupPrivilegeValueW(nullptr, SE_BACKUP_NAME, &tp.Privileges[0].Luid)) {
    tp.PrivilegeCount = 1;
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    AdjustTokenPrivileges(hToken, FALSE, &tp, sizeof(tp), nullptr, nullptr);
  }
  DWORD err = GetLastError();
  CloseHandle(hToken);
  return err == ERROR_SUCCESS;
}

// Write string with JSON escaping (reuses logic from file_scanner)
static std::string EscapeForJson(const std::string& s) {
  std::string out;
  for (char c : s) {
    switch (c) {
      case '\\': out += "\\\\"; break;
      case '"':  out += "\\\""; break;
      case '\n': out += "\\n";  break;
      case '\r': out += "\\r";  break;
      case '\t': out += "\\t";  break;
      default:   out += c;
    }
  }
  return out;
}

// ── FRN → path cache ───────────────────────────────────────────────────────

struct FrnCache {
  HANDLE hVol;
  std::unordered_map<DWORDLONG, std::wstring> map;

  explicit FrnCache(HANDLE vol) : hVol(vol) {}

  // Resolve a parent FRN to its full path (cached).
  std::wstring Resolve(DWORDLONG frn) {
    auto it = map.find(frn);
    if (it != map.end()) return it->second;

    std::wstring result;
    FILE_ID_DESCRIPTOR fid = {};
    fid.dwSize = sizeof(fid);
    fid.Type = FileIdType;
    fid.FileId.QuadPart = static_cast<LONGLONG>(frn);

    HANDLE hFile = OpenFileById(hVol, &fid, GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
        FILE_FLAG_BACKUP_SEMANTICS);
    if (hFile != INVALID_HANDLE_VALUE) {
      wchar_t pathBuf[MAX_PATH * 2] = {};
      DWORD len = GetFinalPathNameByHandleW(hFile, pathBuf,
          MAX_PATH * 2, FILE_NAME_NORMALIZED);
      if (len > 0 && len < MAX_PATH * 2) {
        result = pathBuf;
      }
      CloseHandle(hFile);
    }

    map[frn] = result;
    return result;
  }
};

// Strip volume prefix (e.g. "\\?\D:\Tool\sub1" → "Tool\sub1").
// rootW is e.g. "D:\Tool". Returns relative path with forward slashes,
// no trailing slash. Returns "" for the root directory itself.
static std::string RelativeFromRoot(const std::wstring& fullPath,
                                     const std::wstring& rootW) {
  if (fullPath.size() < rootW.size()) return "";

  // Strip "\\?\" prefix if present
  size_t start = 0;
  if (fullPath.size() >= 4 && fullPath[0] == L'\\' && fullPath[1] == L'\\' &&
      fullPath[2] == L'?' && fullPath[3] == L'\\') {
    start = 4;
  }

  // Skip drive letter if present
  if (fullPath.size() > start + 2 && fullPath[start + 1] == L':') {
    start += 2;
    if (start < fullPath.size() && fullPath[start] == L'\\') start++;
  }

  // rootW normalized: strip its drive prefix too
  size_t rootStart = 0;
  if (rootW.size() > 2 && rootW[1] == L':') {
    rootStart = 2;
    if (rootStart < rootW.size() && rootW[rootStart] == L'\\') rootStart++;
  }

  if (start >= fullPath.size()) return "";

  // Compare normalized root against normalized fullPath prefix
  std::wstring relPart = fullPath.substr(start);
  std::wstring rootPart = rootW.substr(rootStart);
  // Case-insensitive prefix match (Windows)
  if (relPart.size() < rootPart.size()) return "";
  if (_wcsnicmp(relPart.c_str(), rootPart.c_str(), rootPart.size()) != 0)
    return "";

  if (relPart.size() == rootPart.size()) return ""; // exact match = root dir

  size_t relOff = rootPart.size();
  if (relOff < relPart.size() && relPart[relOff] == L'\\') relOff++;
  if (relOff >= relPart.size()) return "";

  std::string utf8 = WideToUtf8(relPart.substr(relOff));
  // Replace backslashes with forward slashes
  for (char& c : utf8) if (c == '\\') c = '/';
  return utf8;
}

// ── USN Query ──────────────────────────────────────────────────────────────

std::string QueryUsnJournal(const std::string& rootPathUtf8, int64_t lastUsnId) {
  std::wstring rootW = Utf8ToWide(rootPathUtf8);
  if (rootW.empty()) return "{}";

  std::wstring volRoot = GetVolumeRoot(rootW);
  if (volRoot.empty()) return "{}";

  if (rootW.length() >= 2 && rootW[1] == L':') {
    wchar_t rootPath[4] = {rootW[0], L':', L'\\', L'\0'};
    UINT dt = GetDriveTypeW(rootPath);
    if (dt != DRIVE_FIXED) return "{}";
  }

  // Try multiple approaches to open a USN-capable handle:
  // 1. Volume handle (\\.\D:) — needs admin + backup privilege
  // 2. Root directory handle (D:\) — works without admin on Win10 1709+
  HANDLE hVol = INVALID_HANDLE_VALUE;

  EnableBackupPrivilege();
  hVol = CreateFileW(
      volRoot.c_str(), GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE,
      nullptr, OPEN_EXISTING, 0, nullptr);

  if (hVol == INVALID_HANDLE_VALUE) {
    // Fall back to root directory handle (no admin needed on Win10+ 1709)
    std::wstring rootDir = rootW.substr(0, 2) + L"\\";
    hVol = CreateFileW(
        rootDir.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  }

  if (hVol == INVALID_HANDLE_VALUE) return "{}";

  int64_t nextUsn = static_cast<int64_t>(lastUsnId);

  USN_JOURNAL_DATA_V0 ujd = {};
  DWORD bytesRet = 0;
  if (DeviceIoControl(hVol, FSCTL_QUERY_USN_JOURNAL,
                      nullptr, 0, &ujd, sizeof(ujd),
                      &bytesRet, nullptr)) {
    nextUsn = static_cast<int64_t>(ujd.NextUsn);
  } else {
    CloseHandle(hVol);
    return "{}";
  }

  if (lastUsnId == 0) {
    CloseHandle(hVol);
    std::ostringstream out;
    out << "{\"nextUsn\":" << nextUsn << ",\"dirty\":false}";
    return out.str();
  }

  READ_USN_JOURNAL_DATA_V0 rujd = {};
  rujd.StartUsn = static_cast<USN>(lastUsnId);
  rujd.ReasonMask = USN_REASON_FILE_CREATE | USN_REASON_FILE_DELETE |
                    USN_REASON_RENAME_NEW_NAME | USN_REASON_RENAME_OLD_NAME;
  rujd.ReturnOnlyOnClose = 0;
  rujd.Timeout = 0;
  rujd.BytesToWaitFor = 0;
  rujd.UsnJournalID = ujd.UsnJournalID;

  const DWORD kBufSize = 256 * 1024;
  char buf[kBufSize] = {};
  bool dirty = false;

  if (DeviceIoControl(hVol, FSCTL_READ_USN_JOURNAL,
                      &rujd, sizeof(rujd),
                      buf, kBufSize, &bytesRet, nullptr) && bytesRet >= sizeof(USN)) {
    DWORD offset = 0;
    while (offset < bytesRet) {
      USN_RECORD_V2* rec = reinterpret_cast<USN_RECORD_V2*>(buf + offset);
      if (rec->RecordLength == 0) break;

      USN reason = rec->Reason;
      if (reason & (USN_REASON_FILE_CREATE | USN_REASON_FILE_DELETE |
                    USN_REASON_RENAME_NEW_NAME | USN_REASON_RENAME_OLD_NAME)) {
        dirty = true;
        break;
      }
      offset += rec->RecordLength;
    }
  }

  CloseHandle(hVol);

  std::ostringstream out;
  out << "{\"nextUsn\":" << nextUsn << ",\"dirty\":" << (dirty ? "true" : "false") << "}";
  return out.str();
}

// ── USN Query with directory resolution ─────────────────────────────────────

std::string QueryUsnJournalWithDirs(const std::string& rootPathUtf8,
                                     int64_t lastUsnId) {
  DEBUG_PRINTF("[USN-dirs] QueryUsnJournalWithDirs root=%s lastUsnId=%lld\n",
         rootPathUtf8.c_str(), (long long)lastUsnId);

  std::wstring rootW = Utf8ToWide(rootPathUtf8);
  if (rootW.empty()) {
    printf("[USN-dirs] FAIL: Utf8ToWide returned empty\n"); fflush(stdout);
    return "{}";
  }

  // Normalize rootW: strip trailing backslash
  while (!rootW.empty() && (rootW.back() == L'\\' || rootW.back() == L'/'))
    rootW.pop_back();

  std::wstring volRoot = GetVolumeRoot(rootW);
  if (volRoot.empty()) {
    printf("[USN-dirs] FAIL: GetVolumeRoot returned empty\n"); fflush(stdout);
    return "{}";
  }
  DEBUG_PRINTF("[USN-dirs] volRoot resolved\n");

  if (rootW.length() >= 2 && rootW[1] == L':') {
    wchar_t rootPath[4] = {rootW[0], L':', L'\\', L'\0'};
    UINT dt = GetDriveTypeW(rootPath);
    DEBUG_PRINTF("[USN-dirs] driveType=%u\n", (unsigned)dt);
    if (dt != DRIVE_FIXED) {
      printf("[USN-dirs] FAIL: not a fixed drive (dt=%u)\n", (unsigned)dt); fflush(stdout);
      return "{}";
    }
  }

  // Enable backup privilege so we can open the volume handle
  DEBUG_PRINTF("[USN-dirs] enabling SE_BACKUP_NAME...\n");
  bool privOk = EnableBackupPrivilege();
  DEBUG_PRINTF("[USN-dirs] SE_BACKUP_NAME %s\n", privOk ? "OK" : "FAILED");
  (void)privOk; // silence unused-variable warning in Release

  // Try volume handle first, then root directory handle as fallback
  HANDLE hVol = CreateFileW(
      volRoot.c_str(), GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE,
      nullptr, OPEN_EXISTING, 0, nullptr);

  if (hVol == INVALID_HANDLE_VALUE) {
    DWORD err1 = GetLastError();
    printf("[USN-dirs] volume handle failed (err=%u), trying dir handle...\n",
           (unsigned)err1); fflush(stdout);
    std::wstring rootDir = rootW.substr(0, 2) + L"\\";
    hVol = CreateFileW(
        rootDir.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    if (hVol == INVALID_HANDLE_VALUE) {
      printf("[USN-dirs] FAIL: dir handle also failed (err=%u)\n",
             (unsigned)GetLastError()); fflush(stdout);
      return "{}";
    }
    DEBUG_PRINTF("[USN-dirs] dir handle opened OK (fallback)\n");
  } else {
    DEBUG_PRINTF("[USN-dirs] volume handle opened OK\n");
  }

  int64_t nextUsn = static_cast<int64_t>(lastUsnId);

  USN_JOURNAL_DATA_V0 ujd = {};
  DWORD bytesRet = 0;
  if (DeviceIoControl(hVol, FSCTL_QUERY_USN_JOURNAL,
                      nullptr, 0, &ujd, sizeof(ujd),
                      &bytesRet, nullptr)) {
    nextUsn = static_cast<int64_t>(ujd.NextUsn);
    DEBUG_PRINTF("[USN-dirs] FSCTL_QUERY OK: NextUsn=%llu MaxSize=%llu\n",
           (unsigned long long)ujd.NextUsn,
           (unsigned long long)ujd.MaximumSize);
  } else {
    printf("[USN-dirs] FAIL: FSCTL_QUERY_USN_JOURNAL failed (err=%u)\n",
           (unsigned)GetLastError()); fflush(stdout);
    CloseHandle(hVol);
    return "{}";
  }

  if (lastUsnId == 0) {
    DEBUG_PRINTF("[USN-dirs] lastUsnId=0 → cursor-only, returning\n");
    CloseHandle(hVol);
    std::ostringstream out;
    out << "{\"nextUsn\":" << nextUsn << ",\"dirty\":false"
        << ",\"dirtyDirs\":[],\"deletedDirs\":[]}";
    return out.str();
  }

  DEBUG_PRINTF("[USN-dirs] reading records since USN %llu...\n",
         (unsigned long long)lastUsnId);

  FrnCache cache(hVol);

  READ_USN_JOURNAL_DATA_V0 rujd = {};
  rujd.StartUsn = static_cast<USN>(lastUsnId);
  rujd.ReasonMask = USN_REASON_FILE_CREATE | USN_REASON_FILE_DELETE |
                    USN_REASON_RENAME_NEW_NAME | USN_REASON_RENAME_OLD_NAME;
  rujd.ReturnOnlyOnClose = 0;
  rujd.Timeout = 0;
  rujd.BytesToWaitFor = 0;
  rujd.UsnJournalID = ujd.UsnJournalID;

  const DWORD kBufSize = 256 * 1024;
  char buf[kBufSize] = {};
  bool dirty = false;
  std::set<std::string> dirtyDirs;
  std::set<std::string> deletedDirs;
  int totalRecords = 0;
  int createCount = 0, deleteCount = 0, renameCount = 0, renamedDirCount = 0;
  int frnFailCount = 0, relFailCount = 0;

  if (DeviceIoControl(hVol, FSCTL_READ_USN_JOURNAL,
                      &rujd, sizeof(rujd),
                      buf, kBufSize, &bytesRet, nullptr) && bytesRet >= sizeof(USN)) {
    DEBUG_PRINTF("[USN-dirs] FSCTL_READ returned %u bytes\n", (unsigned)bytesRet);
    DWORD offset = 0;
    while (offset < bytesRet) {
      USN_RECORD_V2* rec = reinterpret_cast<USN_RECORD_V2*>(buf + offset);
      if (rec->RecordLength == 0) break;

      totalRecords++;
      USN reason = rec->Reason;
      bool isCreate = (reason & USN_REASON_FILE_CREATE) != 0;
      bool isDelete = (reason & USN_REASON_FILE_DELETE) != 0;
      bool isRenameNew = (reason & USN_REASON_RENAME_NEW_NAME) != 0;
      bool isRenameOld = (reason & USN_REASON_RENAME_OLD_NAME) != 0;
      bool isDir = (rec->FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;

      if (isCreate) {
        createCount++;
        dirty = true;
        std::wstring parentPath = cache.Resolve(rec->ParentFileReferenceNumber);
        if (parentPath.empty()) { frnFailCount++; }
        else {
          std::string rel = RelativeFromRoot(parentPath, rootW);
          if (rel.empty()) { relFailCount++; dirtyDirs.insert(""); }
          else dirtyDirs.insert(rel);
        }
      } else if (isRenameNew && isDir) {
        // Directory renamed to a new name — bump counter to accelerate
        // compaction (empty segments → full rebuild fixes indexing).
        renameCount++;
        renamedDirCount++;
        dirty = true;
        std::wstring parentPath = cache.Resolve(rec->ParentFileReferenceNumber);
        if (parentPath.empty()) { frnFailCount++; }
        else {
          std::string rel = RelativeFromRoot(parentPath, rootW);
          if (rel.empty()) { relFailCount++; dirtyDirs.insert(""); }
          else dirtyDirs.insert(rel);
        }
      } else if (isRenameNew && !isDir) {
        renameCount++;
        dirty = true;
        std::wstring parentPath = cache.Resolve(rec->ParentFileReferenceNumber);
        if (parentPath.empty()) { frnFailCount++; }
        else {
          std::string rel = RelativeFromRoot(parentPath, rootW);
          if (rel.empty()) { relFailCount++; dirtyDirs.insert(""); }
          else dirtyDirs.insert(rel);
        }
      } else if ((isDelete && isDir) || (isRenameOld && isDir)) {
        // Deleted or renamed-away directory — add to deletedDirs so the
        // entire subtree is hidden via D| prefix immediately.
        if (isDelete) deleteCount++; else renameCount++;
        dirty = true;
        std::wstring parentPath = cache.Resolve(rec->ParentFileReferenceNumber);
        std::wstring nameW(rec->FileName, rec->FileNameLength / sizeof(WCHAR));
        std::string parentRel = RelativeFromRoot(parentPath, rootW);
        std::string nameUtf8 = WideToUtf8(nameW);
        std::string fullRel = parentRel.empty()
            ? nameUtf8
            : parentRel + "/" + nameUtf8;
        if (parentRel.empty() && parentPath.empty()) { frnFailCount++; }
        deletedDirs.insert(fullRel);
      } else if (isDelete && !isDir) {
        deleteCount++;
        dirty = true;
        std::wstring parentPath = cache.Resolve(rec->ParentFileReferenceNumber);
        if (parentPath.empty()) { frnFailCount++; }
        else {
          std::string rel = RelativeFromRoot(parentPath, rootW);
          if (rel.empty()) { relFailCount++; dirtyDirs.insert(""); }
          else dirtyDirs.insert(rel);
        }
      } else if (isRenameOld && !isDir) {
        renameCount++;
        dirty = true;
        std::wstring parentPath = cache.Resolve(rec->ParentFileReferenceNumber);
        if (parentPath.empty()) { frnFailCount++; }
        else {
          std::string rel = RelativeFromRoot(parentPath, rootW);
          if (rel.empty()) { relFailCount++; dirtyDirs.insert(""); }
          else dirtyDirs.insert(rel);
        }
      }

      offset += rec->RecordLength;
    }
  } else {
    printf("[USN-dirs] FSCTL_READ returned no data or failed (bytesRet=%u)\n",
           (unsigned)bytesRet); fflush(stdout);
  }

  printf("[USN-dirs] summary: totalRec=%d create=%d delete=%d rename=%d renamedDir=%d "
         "dirtyDirs=%zu deletedDirs=%zu frnFail=%d relFail=%d\n",
         totalRecords, createCount, deleteCount, renameCount, renamedDirCount,
         dirtyDirs.size(), deletedDirs.size(), frnFailCount, relFailCount);
  fflush(stdout);

  CloseHandle(hVol);

  std::ostringstream out;
  out << "{\"nextUsn\":" << nextUsn
      << ",\"dirty\":" << (dirty ? "true" : "false")
      << ",\"dirtyDirs\":[";

  bool first = true;
  for (const auto& d : dirtyDirs) {
    if (!first) out << ",";
    first = false;
    out << "\"" << EscapeForJson(d) << "\"";
  }

  out << "],\"deletedDirs\":[";
  first = true;
  for (const auto& d : deletedDirs) {
    if (!first) out << ",";
    first = false;
    out << "\"" << EscapeForJson(d) << "\"";
  }

  out << "],\"renamedDirs\":" << renamedDirCount << "}";
  return out.str();
}

// -- Async USN query (background thread) ---------------------------------

void QueryUsnJournalWithDirsAsync(const std::string& rootPathUtf8,
                                  int64_t lastUsnId,
                                  flutter::BinaryMessenger* messenger,
                                  int requestId) {
  std::thread([rootPathUtf8, lastUsnId, messenger, requestId]() {
    std::string json = QueryUsnJournalWithDirs(rootPathUtf8, lastUsnId);

    auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        messenger,
        "com.xmate/filesearch",
        &flutter::StandardMethodCodec::GetInstance());

    flutter::EncodableMap args;
    args[flutter::EncodableValue("requestId")] = flutter::EncodableValue(requestId);
    args[flutter::EncodableValue("result")] = flutter::EncodableValue(json);

    channel->InvokeMethod("usnResult",
        std::make_unique<flutter::EncodableValue>(args));
  }).detach();
}
