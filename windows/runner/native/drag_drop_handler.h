#pragma once
#include <windows.h>
#include <ole2.h>
#include <functional>
#include <string>
#include <vector>

// ── OLE Drag Source (drag OUT of XMate → Explorer / other apps) ────

enum DragDataType {
  DRAG_FILES = 0,  // CF_HDROP file path list
  DRAG_IMAGE = 1,  // CF_DIB bitmap (from a local image file)
  DRAG_TEXT  = 2,  // CF_UNICODETEXT plain text
};

/// IEnumFORMATETC for 1–3 clipboard formats.
class MultiFormatEnum : public IEnumFORMATETC {
public:
  void Add(FORMATETC fmt);
  STDMETHODIMP Next(ULONG celt, FORMATETC* rgelt, ULONG* pceltFetched) override;
  STDMETHODIMP Skip(ULONG celt) override;
  STDMETHODIMP Reset() override;
  STDMETHODIMP Clone(IEnumFORMATETC** ppenum) override;
  // IUnknown
  STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
  STDMETHODIMP_(ULONG) AddRef() override;
  STDMETHODIMP_(ULONG) Release() override;
private:
  LONG ref_ = 1;
  FORMATETC fmts_[3]{};
  int count_ = 0;
  int pos_ = 0;
};

/// IDataObject that exposes files (CF_HDROP), an image (CF_DIB),
/// and/or text (CF_UNICODETEXT) depending on the DragDataType.
class MultiFormatDragData : public IDataObject {
public:
  MultiFormatDragData();
  void SetFiles(const std::vector<std::wstring>& files);
  bool SetImageFromFile(const std::wstring& path);
  void SetText(const std::string& text);
  int FormatCount() const { return fmtCount_; }

  // IDataObject
  STDMETHODIMP GetData(FORMATETC* pFormatEtc, STGMEDIUM* pMedium) override;
  STDMETHODIMP GetDataHere(FORMATETC*, STGMEDIUM*) override { return E_NOTIMPL; }
  STDMETHODIMP QueryGetData(FORMATETC* pFormatEtc) override;
  STDMETHODIMP GetCanonicalFormatEtc(FORMATETC*, FORMATETC*) override { return DATA_S_SAMEFORMATETC; }
  STDMETHODIMP SetData(FORMATETC*, STGMEDIUM*, BOOL) override { return E_NOTIMPL; }
  STDMETHODIMP EnumFormatEtc(DWORD dwDirection, IEnumFORMATETC** ppenum) override;
  STDMETHODIMP DAdvise(FORMATETC*, DWORD, IAdviseSink*, DWORD*) override { return OLE_E_ADVISENOTSUPPORTED; }
  STDMETHODIMP DUnadvise(DWORD) override { return OLE_E_ADVISENOTSUPPORTED; }
  STDMETHODIMP EnumDAdvise(IEnumSTATDATA**) override { return OLE_E_ADVISENOTSUPPORTED; }
  // IUnknown
  STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
  STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&ref_); }
  STDMETHODIMP_(ULONG) Release() override;

private:
  LONG ref_ = 1;
  int fmtCount_ = 0;
  FORMATETC fmts_[3]{};

  // CF_HDROP payload
  std::vector<std::wstring> files_;
  // CF_DIB payload
  std::vector<uint8_t> dib_;
  // CF_UNICODETEXT payload
  std::wstring text_;

  HRESULT GetHdropData(STGMEDIUM* pMedium);
  HRESULT GetDibData(STGMEDIUM* pMedium);
  HRESULT GetTextData(STGMEDIUM* pMedium);
};

/// Minimal IDropSource.  Supports DROPEFFECT_COPY | MOVE | LINK.
class FileDragSource : public IDropSource {
public:
  STDMETHODIMP QueryContinueDrag(BOOL fEscapePressed, DWORD grfKeyState) override;
  STDMETHODIMP GiveFeedback(DWORD dwEffect) override;
  // IUnknown
  STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
  STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&ref_); }
  STDMETHODIMP_(ULONG) Release() override;
private:
  LONG ref_ = 1;
};

/// Start an OLE drag operation.  Blocks until mouse release.
/// - type=DRAG_FILES: files contains absolute paths
/// - type=DRAG_IMAGE: files[0] is path to a local image file
/// - type=DRAG_TEXT:  text contains the string to drag
bool StartDrag(HWND hwnd, DragDataType type,
               const std::vector<std::string>& files,
               const std::string& text);

// ── OLE Drop Target (drag INTO XMate from Explorer) ─────────────────

/// OLE drop target for text drags (CF_UNICODETEXT / CF_TEXT).
/// Also supports CF_HDROP as a fallback, but the primary file-drop path
/// is the parent window's WM_DROPFILES handler in FlutterWindow.
///
/// Register drag-drop on the Flutter child HWND.  This HWND may be
/// recreated by the engine — call ReRegister(newHwnd) when that happens.
class DragDropHandler : public IDropTarget {
public:
  struct DropData {
    bool isText = false;
    std::string text;
    std::vector<std::string> files;  // only populated as a fallback
  };
  using Callback = std::function<void(const DropData&)>;

  explicit DragDropHandler();
  ~DragDropHandler();

  void SetCallback(Callback cb);

  /// Register OLE drop target on hwnd and accept WM_DROPFILES on it.
  HRESULT Register(HWND hwnd);
  /// Register on a new HWND after the old one was destroyed.
  HRESULT ReRegister(HWND newHwnd);
  void Unregister();

  // IUnknown
  STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
  STDMETHODIMP_(ULONG) AddRef() override;
  STDMETHODIMP_(ULONG) Release() override;

  // IDropTarget
  STDMETHODIMP DragEnter(IDataObject* pDataObj, DWORD grfKeyState, POINTL pt, DWORD* pdwEffect) override;
  STDMETHODIMP DragOver(DWORD grfKeyState, POINTL pt, DWORD* pdwEffect) override;
  STDMETHODIMP DragLeave() override;
  STDMETHODIMP Drop(IDataObject* pDataObj, DWORD grfKeyState, POINTL pt, DWORD* pdwEffect) override;

private:
  HWND hwnd_;
  LONG oleRef_;
  Callback callback_;
  bool hasText_;
  bool hasFiles_;
};
