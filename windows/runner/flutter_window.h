#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <memory>
#include "win32_window.h"
#include "native/drag_drop_handler.h"

class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  FlutterWindow(const flutter::DartProject& project,
                const std::string& startupMode,
                const std::string& quickLookPath,
                const std::string& qlRestoreHwnd);
  virtual ~FlutterWindow();

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const msg, WPARAM wp, LPARAM lp) noexcept override;

 private:
  flutter::DartProject project_;
  std::string startup_mode_;
  std::string quicklook_path_;
  std::string ql_restore_hwnd_;
  std::string sr_data_json_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> app_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> screenshot_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> tray_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> picker_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> pin_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> ocr_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> translate_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> filesearch_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> fileops_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> debug_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> dragdrop_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> dragout_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> scroll_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> quicklook_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> notes_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> officepreview_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> screenrecording_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> overlay_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> keyecho_channel_;
  std::shared_ptr<DragDropHandler> drag_drop_handler_;
  std::shared_ptr<DragDropHandler> drag_drop_child_handler_;
  void OnTrayCommand(int cmd);
};

#endif
