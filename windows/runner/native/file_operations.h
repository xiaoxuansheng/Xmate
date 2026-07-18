// XMate File Operations - native shell helpers (copy, cut, delete, shortcut, pin, properties).
#pragma once

#include <windows.h>

#include <string>
#include <vector>

/// Copy [pathUtf8] to clipboard as CF_HDROP.
bool CopyFilesToClipboard(const std::string& pathUtf8);

/// Cut [pathUtf8] to clipboard (CF_HDROP + DROPEFFECT_MOVE).
bool CutFilesToClipboard(const std::string& pathUtf8);

/// Create a desktop shortcut (.lnk) for [pathUtf8].
bool CreateDesktopShortcut(const std::string& pathUtf8);

/// Delete [pathUtf8] to the Recycle Bin.
bool DeleteToRecycleBin(const std::string& pathUtf8);

/// Show the Properties dialog for [pathUtf8].
bool ShowFileProperties(const std::string& pathUtf8, HWND parentHwnd);

/// Pin [pathUtf8] to the Start menu.
bool PinToStart(const std::string& pathUtf8);

/// Open [pathUtf8] as administrator via ShellExecuteEx runas.
bool OpenFileAsAdmin(const std::string& pathUtf8, HWND parentHwnd);

/// Run a command as administrator via ShellExecuteEx runas (elevated helper).
/// [cmdPathUtf8] = executable, [argsUtf8] = argument string,
/// [workDirUtf8] = working directory (empty = use exe directory).
bool RunCommandAsAdmin(const std::string& cmdPathUtf8,
                       const std::string& argsUtf8,
                       const std::string& workDirUtf8,
                       HWND parentHwnd);

/// Pick a file using COM IFileOpenDialog.
/// Returns the selected file path (UTF-8), or empty string on cancel.
std::string PickFile(HWND parentHwnd);

/// Pick multiple files using COM IFileOpenDialog (multi-select).
/// Returns a JSON array of file paths (UTF-8), or "[]" on cancel.
std::string PickFiles(HWND parentHwnd);

/// Show the Windows "Open with" dialog for [pathUtf8] via SHOpenWithDialog.
bool OpenWithDialog(const std::string& pathUtf8, HWND parentHwnd);

/// Read audio file properties via Windows Shell (IShellItem2 property store).
/// Returns a JSON map: {"codec","sampleRate","channels","bitrate","bitsPerSample"}
/// or an empty JSON object "{}" on failure.
/// pathUtf8 is normalized to backslashes before use.
std::string GetAudioProperties(const std::string& pathUtf8);

// ---- Indexer Service management ---------------------------------------------

/// Install the XMateIndexer Windows Service.
/// Creates %ProgramData%\XMate\ with ACLs, then creates the service.
/// Returns true on success.
bool InstallIndexerService();

/// Uninstall the XMateIndexer Windows Service (stop + delete).
bool UninstallIndexerService();

/// Start the indexer service.
bool StartIndexerService();

/// Stop the indexer service gracefully.
bool StopIndexerService();

/// Returns true if the XMateIndexer service is installed.
bool IsIndexerServiceInstalled();

/// Returns true if the service is currently running.
bool IsIndexerServiceRunning();
