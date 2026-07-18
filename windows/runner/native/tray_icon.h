#pragma once
#include <windows.h>
#include <functional>

#define WM_XMATE_TRAY (WM_APP + 200)
#define WM_XMATE_QL_TRANSLATE (WM_APP + 202)

using TrayCallback = std::function<void(int cmd)>;

void InitTrayIcon(HWND hwnd, TrayCallback cb);
void RemoveTrayIcon();
void HandleTrayMessage(HWND hwnd, LPARAM lp);
bool IsAutoStartEnabled();
void ToggleAutoStart();
