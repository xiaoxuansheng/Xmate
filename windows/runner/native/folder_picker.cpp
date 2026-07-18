#include "folder_picker.h"
#include <shobjidl.h>
#include <shlobj.h>
#include <vector>

std::wstring PickFolder(HWND parent) {
    std::wstring result;

    // Initialize COM on the calling thread if not already done
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    bool needsUninit = SUCCEEDED(hr);
    if (hr == RPC_E_CHANGED_MODE) {
        needsUninit = false; // COM already initialized with different mode
    }

    IFileOpenDialog* pDlg = NULL;
    hr = CoCreateInstance(CLSID_FileOpenDialog, NULL, CLSCTX_ALL,
        IID_PPV_ARGS(&pDlg));
    if (FAILED(hr)) {
        if (needsUninit) CoUninitialize();
        return result;
    }

    // Configure for folder selection
    DWORD flags;
    pDlg->GetOptions(&flags);
    pDlg->SetOptions(flags | FOS_PICKFOLDERS);
    pDlg->SetTitle(L"Select Screenshot Save Folder");

    hr = pDlg->Show(parent);
    if (SUCCEEDED(hr)) {
        IShellItem* pItem = NULL;
        hr = pDlg->GetResult(&pItem);
        if (SUCCEEDED(hr)) {
            PWSTR pPath = NULL;
            hr = pItem->GetDisplayName(SIGDN_FILESYSPATH, &pPath);
            if (SUCCEEDED(hr)) {
                result = pPath;
                CoTaskMemFree(pPath);
            }
            pItem->Release();
        }
    }

    pDlg->Release();
    if (needsUninit) CoUninitialize();
    return result;
}

std::wstring PickFile(HWND parent, const std::string& title) {
    std::wstring result;

    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    bool needsUninit = SUCCEEDED(hr);
    if (hr == RPC_E_CHANGED_MODE) {
        needsUninit = false;
    }

    IFileOpenDialog* pDlg = NULL;
    hr = CoCreateInstance(CLSID_FileOpenDialog, NULL, CLSCTX_ALL,
        IID_PPV_ARGS(&pDlg));
    if (FAILED(hr)) {
        if (needsUninit) CoUninitialize();
        return result;
    }

    DWORD flags;
    pDlg->GetOptions(&flags);
    // No FOS_PICKFOLDERS — this is a file picker.
    pDlg->SetOptions(flags | FOS_FILEMUSTEXIST);

    if (!title.empty()) {
        int wlen = MultiByteToWideChar(CP_UTF8, 0, title.c_str(), -1, NULL, 0);
        if (wlen > 0) {
            std::vector<WCHAR> wtitle(wlen);
            MultiByteToWideChar(CP_UTF8, 0, title.c_str(), -1, wtitle.data(), wlen);
            pDlg->SetTitle(wtitle.data());
        }
    }

    hr = pDlg->Show(parent);
    if (SUCCEEDED(hr)) {
        IShellItem* pItem = NULL;
        hr = pDlg->GetResult(&pItem);
        if (SUCCEEDED(hr)) {
            PWSTR pPath = NULL;
            hr = pItem->GetDisplayName(SIGDN_FILESYSPATH, &pPath);
            if (SUCCEEDED(hr)) {
                result = pPath;
                CoTaskMemFree(pPath);
            }
            pItem->Release();
        }
    }

    pDlg->Release();
    if (needsUninit) CoUninitialize();
    return result;
}
