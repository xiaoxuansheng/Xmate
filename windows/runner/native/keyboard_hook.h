#pragma once
#include <windows.h>

/// Custom window message for the notification process.
#define WM_XMATE_KEY_ECHO   (WM_APP + 204)

/// Settings-change notification from main process to notification process.
/// wParam: bit 0 = hotkey enabled, bit 1 = status enabled.
#define WM_XMATE_KEYECHO_SETTINGS (WM_APP + 205)

/// Theme-change notification from main process to notification process.
/// wParam: theme mode (0=system, 1=light, 2=dark)
/// lParam: accent color ARGB int (e.g. 0xFF5AAAC2)
#define WM_XMATE_THEME_CHANGED   (WM_APP + 206)

/// Forward dictionary data-file path from a second --dictionary process
/// to the already-running dictionary window (via WM_COPYDATA).
#define WM_XMATE_DICT_DATA       (WM_APP + 207)

/// Forward a note command-file path to a running note window process
/// (via WM_COPYDATA). Used for append / merge / reload requests.
#define WM_XMATE_NOTE_DATA       (WM_APP + 208)

/// Install a WH_KEYBOARD_LL global low-level keyboard hook.
/// @param hwnd  Target window that will receive WM_XMATE_KEY_ECHO.
/// @return true on success.
bool InstallKeyboardHook(HWND hwnd);

/// Uninstall the keyboard hook and reset all internal state.
/// Safe to call even if the hook is not currently installed.
void UninstallKeyboardHook();

/// Classify a virtual-key code as a "functional" (non-character, non-typing)
/// key that should be displayed as key-echo.
///
/// Always returns true for: F-keys, navigation keys, media keys, lock keys,
///   browser keys, numpad keys, IME keys.
/// Always returns false for: letters A-Z, digits 0-9 (main keyboard),
///   space, OEM punctuation.
///
/// Modifier keys (VK_SHIFT / VK_CONTROL / VK_MENU / VK_LWIN / VK_RWIN) are
/// NOT in this list — pure-modifier presses are filtered at a higher level.
bool IsFunctionalKey(DWORD vkCode);

/// Encode the currently held modifier keys as a bitmask.
/// 1 = Alt, 2 = Ctrl, 4 = Shift, 8 = Win.
DWORD EncodeModifiers();
