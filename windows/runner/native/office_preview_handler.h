#pragma once
#include <windows.h>
#include <string>
#include <cstdint>

/// Custom message: QL → main process, payload is a marshaled COM reference
/// that keeps the Word COM server alive across QL process restarts.
#define WM_XMATE_WORD_KEEPALIVE (WM_APP + 203)

/// Convert UTF-8 std::string to wide string (shared utility).
std::wstring Utf8ToWide(const std::string& s);

/// Check whether a registered preview handler exists for the given extension.
bool IsWordPreviewAvailable(const std::wstring& ext);

/// Create a Word preview child window hosting the system preview handler.
int64_t CreateWordPreview(HWND parent, const std::string& path,
                          int x, int y, int w, int h);

/// Update the preview window position and size.
void SetWordPreviewRect(int64_t instance, int x, int y, int w, int h);

/// Destroy the preview child window.  The COM handler is NOT released —
/// a marshaled proxy in the main process keeps the Word server alive.
void DestroyWordPreview(int64_t instance);

/// Called from main-process WM_COPYDATA.  Unmarshals the serialised
/// IUnknown reference sent by the QL process and holds it for 120 s.
/// filePath: temp file containing the CoMarshalInterface output.
void KeepWordHandlerAlive(const std::string& filePath);

/// Destroy every active Office preview handler instance and release
/// the COM proxy pool.  Call during shutdown so ole32.dll doesn't
/// hold outstanding references.
void DestroyAllWordPreviews();
