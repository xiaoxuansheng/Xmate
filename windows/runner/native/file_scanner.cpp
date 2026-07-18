// XMate File Search - directory scanner + file icon extraction.
//
// Uses FindFirstFileW / FindNextFileW for fast recursive enumeration.
// Builds compact JSON array string (no external JSON library required).
#include "file_scanner.h"

#include <windows.h>
#include <shellapi.h>
#include <cctype>
#include <string>
#include <stack>
#include <thread>
#include <gdiplus.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "shell32.lib")

using namespace Gdiplus;

// -- GDI+ lifetime (ref-counted; multiple GdiplusStartup calls are safe) -----

static ULONG_PTR g_gdiplusTokenFS = 0;
static bool g_gdiplusInitFS = false;

static void InitGdiPlusFS() {
  if (!g_gdiplusInitFS) {
    GdiplusStartupInput input;
    GdiplusStartup(&g_gdiplusTokenFS, &input, nullptr);
    g_gdiplusInitFS = true;
  }
}

static int GetEncoderClsidFS(const WCHAR* format, CLSID* pClsid) {
  UINT num = 0, size = 0;
  GetImageEncodersSize(&num, &size);
  if (size == 0) return -1;
  auto info = (ImageCodecInfo*)malloc(size);
  if (!info) return -1;
  GetImageEncoders(num, size, info);
  for (UINT j = 0; j < num; ++j) {
    if (wcscmp(info[j].MimeType, format) == 0) {
      *pClsid = info[j].Clsid;
      free(info);
      return static_cast<int>(j);
    }
  }
  free(info);
  return -1;
}

// -- UTF-8 <-> wchar conversion --------------------------------------------

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

// -- Helpers ----------------------------------------------------------------

static std::string ExtractExtension(const std::string& filename) {
  auto dot = filename.rfind('.');
  if (dot == std::string::npos || dot == 0) return "";
  std::string ext = filename.substr(dot + 1);
  for (char& c : ext) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return ext;
}

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

// -- Directory scan ---------------------------------------------------------

struct DirEntry {
  std::wstring fullPath;   // absolute path (no trailing backslash)
  std::string relPath;     // relative path (with trailing "/", empty for root)
};

std::string ScanDirectory(const std::string& rootPathUtf8) {
  std::wstring rootW = Utf8ToWide(rootPathUtf8);
  if (rootW.empty()) return "[]";

  // Strip trailing backslash if present
  while (!rootW.empty() && (rootW.back() == L'\\' || rootW.back() == L'/'))
    rootW.pop_back();

  std::string result = "[";
  std::stack<DirEntry> stack;
  stack.push({rootW, ""});
  bool first = true;

  while (!stack.empty()) {
    DirEntry entry = stack.top();
    stack.pop();

    std::wstring searchPath = entry.fullPath + L"\\*";
    WIN32_FIND_DATAW fd;
    HANDLE hFind = FindFirstFileW(searchPath.c_str(), &fd);
    if (hFind == INVALID_HANDLE_VALUE) continue; // skip unreadable dirs

    do {
      std::wstring nameW(fd.cFileName);
      if (nameW == L"." || nameW == L"..") continue;

      std::string nameUtf8 = WideToUtf8(nameW);
      if (nameUtf8.empty()) continue;

      std::string extUtf8 = ExtractExtension(nameUtf8);
      // Strip extension from name field — "n" stores the base name only,
      // matching the Dart incremental-scan convention and FileIndexEntry.name.
      std::string baseName = nameUtf8;
      if (!extUtf8.empty()) {
        baseName = nameUtf8.substr(0, nameUtf8.size() - extUtf8.size() - 1);
      }
      bool isDir = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;

      if (!first) result += ",";
      first = false;

      result += "{\"n\":\"";
      result += EscapeForJson(baseName);
      result += "\",\"e\":\"";
      result += EscapeForJson(extUtf8);
      result += "\",\"p\":\"";
      result += EscapeForJson(entry.relPath);
      result += "\",\"d\":";
      result += isDir ? "true" : "false";
      result += "}";

      // Push subdirectories for DFS
      if (isDir) {
        std::wstring subPath = entry.fullPath + L"\\" + nameW;
        std::string subRel = entry.relPath + nameUtf8 + "/";
        stack.push({subPath, subRel});
      }
    } while (FindNextFileW(hFind, &fd));

    FindClose(hFind);
  }

  result += "]";
  return result;
}

// -- HICON to PNG helper ----------------------------------------------------

// -- HICON to PNG helper ----------------------------------------------------

// GDI+ Bitmap::FromHICON is unreliable for 16x16 and 32-bit alpha icons
// (produces garbled output regardless of the input HICON).  Render via GDI
// DrawIconEx onto a properly-sized 32-bpp ARGB bitmap, then encode with GDI+.
static void HIconToPng(HICON hIcon, std::vector<uint8_t>& result) {
  if (!hIcon) return;

  // Get the true icon dimensions from the color bitmap.
  ICONINFO ii = {};
  if (!GetIconInfo(hIcon, &ii)) return;
  int w = 32, h = 32;
  if (ii.hbmColor) {
    BITMAP bm = {};
    if (GetObjectW(ii.hbmColor, sizeof(bm), &bm)) { w = bm.bmWidth; h = bm.bmHeight; }
    DeleteObject(ii.hbmColor);
  }
  if (ii.hbmMask) DeleteObject(ii.hbmMask);

  // Create a 32-bpp ARGB GDI+ bitmap at the icon's real size.
  Bitmap* bmp = new Bitmap(w, h, PixelFormat32bppARGB);
  if (!bmp || bmp->GetLastStatus() != Ok) { delete bmp; return; }

  // Render the HICON via GDI DrawIconEx (same path the debug dialog uses).
  Graphics* g = Graphics::FromImage(bmp);
  if (g) {
    HDC hdc = g->GetHDC();
    if (hdc) {
      DrawIconEx(hdc, 0, 0, hIcon, w, h, 0, nullptr, DI_NORMAL);
      g->ReleaseHDC(hdc);
    }
    delete g;
  }

  CLSID pngClsid;
  if (GetEncoderClsidFS(L"image/png", &pngClsid) < 0) { delete bmp; return; }

  HGLOBAL hGlobal = GlobalAlloc(GMEM_MOVEABLE, 0);
  if (!hGlobal) { delete bmp; return; }

  IStream* pStream = nullptr;
  if (FAILED(CreateStreamOnHGlobal(hGlobal, TRUE, &pStream))) {
    GlobalFree(hGlobal);
    delete bmp;
    return;
  }

  if (bmp->Save(pStream, &pngClsid, nullptr) == Ok) {
    ULARGE_INTEGER uli{};
    LARGE_INTEGER seekZero{};
    pStream->Seek(seekZero, STREAM_SEEK_END, &uli);
    DWORD sizeLow = uli.LowPart;
    pStream->Seek(seekZero, STREAM_SEEK_SET, nullptr);
    result.resize(sizeLow);
    ULONG bytesRead = 0;
    pStream->Read(result.data(), sizeLow, &bytesRead);
    if (bytesRead != sizeLow) result.clear();
  }

  pStream->Release();
  delete bmp;
}

// -- File system icon extraction --------------------------------------------

std::vector<uint8_t> GetFileIconPng(const std::string& filePathUtf8) {
  std::wstring pathW = Utf8ToWide(filePathUtf8);
  if (pathW.empty()) return {};

  // Dart builds paths with '/', Windows APIs need '\'.
  for (auto& c : pathW) {
    if (c == L'/') c = L'\\';
  }

  InitGdiPlusFS();

  HICON hIcon = nullptr;

  // SHGetFileInfoW with the real path -- Shell resolves everything.
  // Get attributes so Shell sees FILE_ATTRIBUTE_DIRECTORY for folders.
  DWORD attrs = GetFileAttributesW(pathW.c_str());
  if (attrs != INVALID_FILE_ATTRIBUTES) {
    SHFILEINFOW sfi = {};
    if (SHGetFileInfoW(pathW.c_str(), attrs, &sfi, sizeof(sfi),
                       SHGFI_ICON | SHGFI_SMALLICON)) {
      hIcon = sfi.hIcon;
    }
  }

  // Fallback: extension-based lookup when path doesn't exist.
  if (!hIcon) {
    SHFILEINFOW sfi = {};
    if (SHGetFileInfoW(pathW.c_str(), FILE_ATTRIBUTE_NORMAL, &sfi, sizeof(sfi),
                       SHGFI_ICON | SHGFI_SMALLICON | SHGFI_USEFILEATTRIBUTES)) {
      hIcon = sfi.hIcon;
    }
  }

  if (!hIcon) return {};

  struct IconGuard { HICON h; ~IconGuard() { if (h) DestroyIcon(h); } };
  IconGuard guard{hIcon};

  std::vector<uint8_t> result;
  HIconToPng(hIcon, result);
  return result;
}

// -- Async scan (background thread) ----------------------------------------

void ScanDirectoryAsync(const std::string& rootPathUtf8,
                        flutter::BinaryMessenger* messenger,
                        int requestId) {
  // Normalize forward slashes to backslashes — Dart sends / paths
  // (e.g. FileSearchResult.fullPath) but Windows APIs require \.
  std::string path = rootPathUtf8;
  for (char& c : path) { if (c == '/') c = '\\'; }

  std::thread([path, messenger, requestId]() {
    std::string json = ScanDirectory(path);

    auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        messenger,
        "com.xmate/filesearch",
        &flutter::StandardMethodCodec::GetInstance());

    flutter::EncodableMap args;
    args[flutter::EncodableValue("requestId")] = flutter::EncodableValue(requestId);
    args[flutter::EncodableValue("result")] = flutter::EncodableValue(json);

    channel->InvokeMethod("scanResult",
        std::make_unique<flutter::EncodableValue>(args));
  }).detach();
}
