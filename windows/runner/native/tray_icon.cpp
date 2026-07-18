#include "tray_icon.h"
#include <shellapi.h>
#include <taskschd.h>
#include <comdef.h>

#pragma comment(lib, "taskschd.lib")

static NOTIFYICONDATAW g_nid = {};
static bool g_ready = false;
static TrayCallback g_cb = nullptr;

#define ID_OPEN      5001
#define ID_AUTOSTART 5005
#define ID_SETTINGS  5003
#define ID_EXIT      5004

static const WCHAR* TASK_NAME = L"XMate Auto Start";

// ---- Auto-start via Task Scheduler (normal user privileges) --------------

// Initialize COM (call once, idempotent).
// Must be STA — OLE drag-drop requires the main thread to be STA.
static void EnsureComInit() {
    static bool init = false;
    if (!init) {
        CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        init = true;
    }
}

static HRESULT GetTaskFolder(ITaskFolder** ppFolder) {
    EnsureComInit();
    ITaskService* pService = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_TaskScheduler, nullptr, CLSCTX_INPROC_SERVER,
                                   IID_ITaskService, (void**)&pService);
    if (FAILED(hr)) return hr;
    hr = pService->Connect(_variant_t(), _variant_t(), _variant_t(), _variant_t());
    if (FAILED(hr)) { pService->Release(); return hr; }
    hr = pService->GetFolder(_bstr_t(L"\\"), ppFolder);
    pService->Release();
    return hr;
}

bool IsAutoStartEnabled() {
    EnsureComInit();
    ITaskFolder* pFolder = nullptr;
    if (FAILED(GetTaskFolder(&pFolder))) return false;
    IRegisteredTask* pRegTask = nullptr;
    HRESULT hr = pFolder->GetTask(_bstr_t(TASK_NAME), &pRegTask);
    if (pRegTask) pRegTask->Release();
    pFolder->Release();
    return SUCCEEDED(hr);
}

void ToggleAutoStart() {
    // Task Scheduler root folder requires admin to write regardless of
    // RunLevel. When not elevated, fall back to ShellExecuteEx(runas).
    bool isElevated = false;
    {
        HANDLE hToken = NULL;
        if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &hToken)) {
            TOKEN_ELEVATION elevation;
            DWORD size = sizeof(elevation);
            if (GetTokenInformation(hToken, TokenElevation, &elevation, size, &size)) {
                isElevated = elevation.TokenIsElevated != 0;
            }
            CloseHandle(hToken);
        }
    }

    if (!isElevated) {
        // Task Scheduler root folder requires admin for both read and write.
        // IsAutoStartEnabled() depends on GetTaskFolder() which fails with
        // E_ACCESSDENIED at medium IL, so we cannot even check current state
        // inline. Always relaunch elevated — the helper toggles correctly.
        // Use SEE_MASK_NOCLOSEPROCESS + WaitForSingleObject so the caller
        // (method channel handler) sees the updated state after return.
        WCHAR exePath[MAX_PATH];
        GetModuleFileNameW(NULL, exePath, MAX_PATH);
        SHELLEXECUTEINFOW sei = {};
        sei.cbSize = sizeof(sei);
        sei.fMask = SEE_MASK_NOCLOSEPROCESS;
        sei.lpVerb = L"runas";
        sei.lpFile = exePath;
        sei.lpParameters = L"--toggle-autostart";
        sei.nShow = SW_HIDE;
        if (ShellExecuteExW(&sei)) {
            if (sei.hProcess) {
                WaitForSingleObject(sei.hProcess, 30000);
                CloseHandle(sei.hProcess);
            }
        }
        return;
    }

    // --- Elevated path below ---
    EnsureComInit();
    ITaskFolder* pFolder = nullptr;
    if (FAILED(GetTaskFolder(&pFolder))) return;

    if (IsAutoStartEnabled()) {
        // Remove existing task
        pFolder->DeleteTask(_bstr_t(TASK_NAME), 0);
    } else {
        // Create task via ITaskService::NewTask
        ITaskService* pService = nullptr;
        HRESULT hr = CoCreateInstance(CLSID_TaskScheduler, nullptr, CLSCTX_INPROC_SERVER,
                                       IID_ITaskService, (void**)&pService);
        if (FAILED(hr)) { pFolder->Release(); return; }
        hr = pService->Connect(_variant_t(), _variant_t(), _variant_t(), _variant_t());
        if (FAILED(hr)) { pService->Release(); pFolder->Release(); return; }

        ITaskDefinition* pTask = nullptr;
        hr = pService->NewTask(0, &pTask);
        if (FAILED(hr) || !pTask) { pService->Release(); pFolder->Release(); return; }

        // Settings
        ITaskSettings* pSettings = nullptr;
        pTask->get_Settings(&pSettings);
        if (pSettings) {
            pSettings->put_DisallowStartIfOnBatteries(VARIANT_FALSE);
            pSettings->put_StopIfGoingOnBatteries(VARIANT_FALSE);
            pSettings->put_AllowDemandStart(VARIANT_TRUE);
            pSettings->put_StartWhenAvailable(VARIANT_TRUE);
            pSettings->Release();
        }

        // Principal: run with normal (non-elevated) privileges
        IPrincipal* pPrincipal = nullptr;
        pTask->get_Principal(&pPrincipal);
        if (pPrincipal) {
            pPrincipal->put_RunLevel(TASK_RUNLEVEL_LUA);
            pPrincipal->put_LogonType(TASK_LOGON_INTERACTIVE_TOKEN);
            pPrincipal->Release();
        }

        // Trigger: at logon
        ITriggerCollection* pTriggers = nullptr;
        pTask->get_Triggers(&pTriggers);
        if (pTriggers) {
            ITrigger* pTrigger = nullptr;
            pTriggers->Create(TASK_TRIGGER_LOGON, &pTrigger);
            if (pTrigger) {
                ILogonTrigger* pLogon = nullptr;
                pTrigger->QueryInterface(IID_ILogonTrigger, (void**)&pLogon);
                if (pLogon) {
                    pLogon->put_Id(_bstr_t(L"Logon"));
                    pLogon->Release();
                }
                pTrigger->Release();
            }
            pTriggers->Release();
        }

        // Action: launch this executable
        IActionCollection* pActions = nullptr;
        pTask->get_Actions(&pActions);
        if (pActions) {
            IAction* pAction = nullptr;
            pActions->Create(TASK_ACTION_EXEC, &pAction);
            if (pAction) {
                IExecAction* pExec = nullptr;
                pAction->QueryInterface(IID_IExecAction, (void**)&pExec);
                if (pExec) {
                    WCHAR exePath[MAX_PATH];
                    GetModuleFileNameW(nullptr, exePath, MAX_PATH);
                    pExec->put_Path(_bstr_t(exePath));
                    // Extract working directory from exe path
                    WCHAR* slash = wcsrchr(exePath, L'\\');
                    if (slash) *slash = L'\0';
                    pExec->put_WorkingDirectory(_bstr_t(exePath));
                    pExec->Release();
                }
                pAction->Release();
            }
            pActions->Release();
        }

        // Register the task
        IRegisteredTask* pRegTask = nullptr;
        hr = pFolder->RegisterTaskDefinition(
            _bstr_t(TASK_NAME), pTask,
            TASK_CREATE_OR_UPDATE,
            _variant_t(),        // current user
            _variant_t(),        // no password needed for logon trigger
            TASK_LOGON_INTERACTIVE_TOKEN,
            _variant_t(L""),
            &pRegTask);
        if (pRegTask) pRegTask->Release();
        pTask->Release();
        pService->Release();
    }
    pFolder->Release();
}

// ---- Tray icon ------------------------------------------------------------

void InitTrayIcon(HWND hwnd, TrayCallback cb) {
    g_cb = cb;

    WCHAR path[MAX_PATH];
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    WCHAR* slash = wcsrchr(path, L'\\');
    if (slash) *slash = L'\0';
    wcscat_s(path, L"\\data\\flutter_assets\\assets\\app_icon.ico");

    HICON hIcon = (HICON)LoadImageW(nullptr, path, IMAGE_ICON, 0, 0,
                                    LR_LOADFROMFILE | LR_DEFAULTSIZE);
    if (!hIcon) hIcon = LoadIcon(nullptr, IDI_APPLICATION);

    ZeroMemory(&g_nid, sizeof(g_nid));
    g_nid.cbSize = sizeof(NOTIFYICONDATAW);
    g_nid.hWnd = hwnd;
    g_nid.uID = 1;
    g_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    g_nid.uCallbackMessage = WM_XMATE_TRAY;
    g_nid.hIcon = hIcon;
    wcscpy_s(g_nid.szTip, L"XMate");

    Shell_NotifyIconW(NIM_ADD, &g_nid);
    Shell_NotifyIconW(NIM_SETVERSION, &g_nid);
    g_ready = true;
}

void RemoveTrayIcon() {
    if (g_ready) {
        Shell_NotifyIconW(NIM_DELETE, &g_nid);
        g_ready = false;
    }
}

void HandleTrayMessage(HWND hwnd, LPARAM lp) {
    switch (lp) {
    case WM_LBUTTONUP:
        if (g_cb) g_cb(1);
        break;
    case WM_RBUTTONUP: {
        POINT pt; GetCursorPos(&pt);
        HMENU m = CreatePopupMenu();

        AppendMenuW(m, MF_STRING, ID_OPEN, L"打开");   // Open

        bool autoStart = IsAutoStartEnabled();
        AppendMenuW(m, MF_STRING | (autoStart ? MF_CHECKED : MF_UNCHECKED),
            ID_AUTOSTART, L"开机启动");        // Auto-start

        AppendMenuW(m, MF_SEPARATOR, 0, nullptr);

        AppendMenuW(m, MF_STRING, ID_SETTINGS, L"设置"); // Settings

        AppendMenuW(m, MF_SEPARATOR, 0, nullptr);

        AppendMenuW(m, MF_STRING, ID_EXIT, L"退出");     // Exit

        SetForegroundWindow(hwnd);
        int cmd = (int)TrackPopupMenu(m,
            TPM_RETURNCMD | TPM_NONOTIFY | TPM_BOTTOMALIGN | TPM_LEFTALIGN,
            pt.x, pt.y, 0, hwnd, nullptr);
        DestroyMenu(m);

        if (cmd == ID_AUTOSTART) {
            ToggleAutoStart();
        } else if (cmd > 0 && g_cb) {
            int mapped = 0;
            switch (cmd) {
            case ID_OPEN:     mapped = 1; break;
            case ID_SETTINGS: mapped = 3; break;
            case ID_EXIT:     mapped = 4; break;
            }
            if (mapped) g_cb(mapped);
        }
        break;
    }
    }
}
