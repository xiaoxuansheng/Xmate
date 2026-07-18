# 文件索引 — XMate 功能 ↔ 文件快速定位

> 按功能模块列出涉及的核心文件，修改某项功能时先查此表，无需重复搜索。

## 📁 核心框架（Core）

| 功能 | Dart 文件 | C++ 文件 |
|------|-----------|----------|
| 入口 & 初始化 | [main.dart](lib/main.dart) | [main.cpp](windows/runner/main.cpp) |
| App 窗口状态机 & overlay | [app.dart](lib/app.dart) | [win32_window.cpp](windows/runner/win32_window.cpp) / [win32_window.h](windows/runner/win32_window.h) |
| 窗口管理 (WindowService) | [lib/core/window/window_manager.dart](lib/core/window/window_manager.dart) | [flutter_window.cpp](windows/runner/flutter_window.cpp) / [flutter_window.h](windows/runner/flutter_window.h) |
| 插件注册 & 基类 | [lib/core/plugin/plugin_registry.dart](lib/core/plugin/plugin_registry.dart) / [lib/core/plugin/plugin_base.dart](lib/core/plugin/plugin_base.dart) | — |
| 事件总线 | [lib/core/event/event_bus.dart](lib/core/event/event_bus.dart) | — |

## 🎨 主题 & 颜色

| 功能 | 文件 |
|------|------|
| ThemeService (单例) | [lib/core/theme/theme_service.dart](lib/core/theme/theme_service.dart) |
| AppTheme (亮/暗定义) | [lib/core/theme/app_theme.dart](lib/core/theme/app_theme.dart) |
| XMateColors token 体系 | [lib/core/theme/theme_colors.dart](lib/core/theme/theme_colors.dart) |
| 设置页主题相关 Tab | [lib/ui/settings/settings_page.dart](lib/ui/settings/settings_page.dart) |

## ⌨️ 快捷键 & 热键

| 功能 | 文件 |
|------|------|
| HotkeyManager (注册/分发) | [lib/core/hotkey/hotkey_manager.dart](lib/core/hotkey/hotkey_manager.dart) |
| 键盘钩子 (C++ 底层) | [keyboard_hook.cpp](windows/runner/native/keyboard_hook.cpp) / [keyboard_hook.h](windows/runner/native/keyboard_hook.h) |
| 入口统一注册 | [main.dart](lib/main.dart) |

## 🔍 命令面板

| 功能 | 文件 |
|------|------|
| CommandEngine (匹配/排序) | [lib/core/command/command_engine.dart](lib/core/command/command_engine.dart) |
| CommandPalette UI | [lib/core/command/command_palette.dart](lib/core/command/command_palette.dart) |
| CalculatorService | [lib/core/command/calculator_service.dart](lib/core/command/calculator_service.dart) |
| ExchangeRateService | [lib/core/command/exchange_rate_service.dart](lib/core/command/exchange_rate_service.dart) |
| TimezoneService | [lib/core/command/timezone_service.dart](lib/core/command/timezone_service.dart) |
| UserCommandService | [lib/core/command/user_command_service.dart](lib/core/command/user_command_service.dart) |
| File 子菜单服务 | [lib/core/command/file_submenu_service.dart](lib/core/command/file_submenu_service.dart) / [file_submenu_item.dart](lib/core/command/file_submenu_item.dart) |

## 🔎 File Search（文件搜索）

| 功能 | Dart 文件 | C++ 文件 |
|------|-----------|----------|
| SearchService 核心 | [lib/core/search/file_search_service.dart](lib/core/search/file_search_service.dart) | — |
| SearchEngineService | [lib/core/search/search_engine_service.dart](lib/core/search/search_engine_service.dart) | — |
| 文件索引构建 | [lib/core/search/file_index_builder.dart](lib/core/search/file_index_builder.dart) | [indexer_service.cpp](windows/runner/native/indexer_service.cpp) / [indexer_service.h](windows/runner/native/indexer_service.h) |
| 索引存储 | [lib/core/search/file_index_store.dart](lib/core/search/file_index_store.dart) | — |
| 索引配置 | [lib/core/search/file_index_config.dart](lib/core/search/file_index_config.dart) | [indexer_config.cpp](windows/runner/native/indexer_config.cpp) / [indexer_config.h](windows/runner/native/indexer_config.h) |
| 索引条目模型 | [lib/core/search/file_index_entry.dart](lib/core/search/file_index_entry.dart) | — |
| Trigram 索引 | [lib/core/search/file_trigram_index.dart](lib/core/search/file_trigram_index.dart) | — |
| 查询模型 | [lib/core/search/file_search_query.dart](lib/core/search/file_search_query.dart) | — |
| 过滤器 | [lib/core/search/file_search_filter.dart](lib/core/search/file_search_filter.dart) | — |
| 优先级模型 | [lib/core/search/file_search_priority.dart](lib/core/search/file_search_priority.dart) | — |
| Pinyin 数据 | [lib/core/search/file_pinyin_data.dart](lib/core/search/file_pinyin_data.dart) | — |
| Method Channel | [lib/core/search/file_search_channel.dart](lib/core/search/file_search_channel.dart) | — |
| C++ FileScanner | — | [file_scanner.cpp](windows/runner/native/file_scanner.cpp) / [file_scanner.h](windows/runner/native/file_scanner.h) |
| USN Journal | — | [usn_journal.cpp](windows/runner/native/usn_journal.cpp) / [usn_journal.h](windows/runner/native/usn_journal.h) |
| 设置 Tab | [lib/ui/settings/file_search_tab.dart](lib/ui/settings/file_search_tab.dart) | — |

## 🖼️ 截图 & 标注

| 功能 | Dart 文件 | C++ 文件 |
|------|-----------|----------|
| ScreenshotPlugin | [screenshot_plugin.dart](lib/plugins/screenshot/screenshot_plugin.dart) | — |
| 截图捕获 | [lib/plugins/screenshot/capture/capture_service.dart](lib/plugins/screenshot/capture/capture_service.dart) / [capture_win32.dart](lib/plugins/screenshot/capture/capture_win32.dart) | [screenshot_capture.cpp](windows/runner/native/screenshot_capture.cpp) / [screenshot_capture.h](windows/runner/native/screenshot_capture.h) |
| 标注页 | [annotate_page.dart](lib/plugins/screenshot/annotate/annotate_page.dart) / [annotate_canvas.dart](lib/plugins/screenshot/annotate/annotate_canvas.dart) / [annotate_toolbar.dart](lib/plugins/screenshot/annotate/annotate_toolbar.dart) | [annotation_overlay.cpp](windows/runner/native/annotation_overlay.cpp) / [annotation_overlay.h](windows/runner/native/annotation_overlay.h) |
| 标注模型 | [lib/core/annotate/annotate_models.dart](lib/core/annotate/annotate_models.dart) (设计阶段暂存) | — |
| OCR 服务 | [ocr_service.dart](lib/plugins/screenshot/annotate/ocr_service.dart) | [ocr_engine.cpp](windows/runner/native/ocr_engine.cpp) / [ocr_engine.h](windows/runner/native/ocr_engine.h) / [onnx_ocr_engine.cpp](windows/runner/native/onnx_ocr_engine.cpp) / [onnx_ocr_engine.h](windows/runner/native/onnx_ocr_engine.h) / [winrt_ocr_engine.cpp](windows/runner/native/winrt_ocr_engine.cpp) / [winrt_ocr_engine.h](windows/runner/native/winrt_ocr_engine.h) |
| 截图数据模型 | [screenshot_data.dart](lib/plugins/screenshot/models/screenshot_data.dart) | — |
| 滚动截图管理 | [scroll_screenshot_manager.dart](lib/plugins/screenshot/flow/scroll_screenshot_manager.dart) | — |
| 翻译集成 | [translate_service.dart](lib/plugins/screenshot/integration/translate_service.dart) | — |
| 设置 | [screenshot_settings.dart](lib/plugins/screenshot/screenshot_settings.dart) | — |

## 📌 截图 Pin（贴图）

| 功能 | Dart 文件 | C++ 文件 |
|------|-----------|----------|
| PinWindow | [pin_window.dart](lib/plugins/screenshot/pin/pin_window.dart) | [pin_window.cpp](windows/runner/native/pin_window.cpp) / [pin_window.h](windows/runner/native/pin_window.h) |
| 放大镜 | [lib/core/annotate/magnifier.dart](lib/core/annotate/magnifier.dart) | — |

## 🪟 QuickLook 预览（独立进程）

| 功能 | Dart 文件 | C++ 文件 |
|------|-----------|----------|
| QuickLookPlugin | [quicklook_plugin.dart](lib/plugins/quicklook/quicklook_plugin.dart) | — |
| QuickLookPage 主页面 | [quicklook_page.dart](lib/plugins/quicklook/quicklook_page.dart) | — |
| 工具函数 & 状态 | [lib/core/quicklook/quicklook_utils.dart](lib/core/quicklook/quicklook_utils.dart) / [quicklook_palette_state.dart](lib/core/quicklook/quicklook_palette_state.dart) | — |
| 设置 | [quicklook_settings.dart](lib/plugins/quicklook/quicklook_settings.dart) | — |
| PDF 预览 | [quicklook_pdf_view.dart](lib/plugins/quicklook/views/quicklook_pdf_view.dart) / [pdf_page_cache.dart](lib/plugins/quicklook/views/pdf_page_cache.dart) / [ql_pdf_utils.dart](lib/plugins/quicklook/views/ql_pdf_utils.dart) | PDF 页缓存 |
| 文本预览 | [quicklook_text_view.dart](lib/plugins/quicklook/views/quicklook_text_view.dart) | — |
| 富文本预览 | [quicklook_rich_view.dart](lib/plugins/quicklook/views/quicklook_rich_view.dart) | — |
| 图片预览 & 标注 | [quicklook_image_annotator.dart](lib/plugins/quicklook/quicklook_image_annotator.dart) / [image_utils.dart](lib/plugins/quicklook/parsers/image_utils.dart) | — |
| 音频预览 | [quicklook_audio_view.dart](lib/plugins/quicklook/views/quicklook_audio_view.dart) / [quicklook_media_controls.dart](lib/plugins/quicklook/views/quicklook_media_controls.dart) | — |
| 视频预览 | [quicklook_video_view.dart](lib/plugins/quicklook/views/quicklook_video_view.dart) / [quicklook_media_controls.dart](lib/plugins/quicklook/views/quicklook_media_controls.dart) | — |
| 文件夹预览 | [quicklook_folder_view.dart](lib/plugins/quicklook/views/quicklook_folder_view.dart) | — |
| 压缩包预览 | [quicklook_archive_view.dart](lib/plugins/quicklook/views/quicklook_archive_view.dart) / [archive_parser.dart](lib/plugins/quicklook/parsers/archive_parser.dart) | — |
| EPUB 预览 | [quicklook_epub_view.dart](lib/plugins/quicklook/quicklook_epub_view.dart) / [epub_zip_reader.dart](lib/plugins/quicklook/parsers/epub_zip_reader.dart) | — |
| EML 预览 | [quicklook_eml_view.dart](lib/plugins/quicklook/quicklook_eml_view.dart) / [eml_parser.dart](lib/plugins/quicklook/parsers/eml_parser.dart) | — |
| Office 预览 | [quicklook_office_view.dart](lib/plugins/quicklook/views/quicklook_office_view.dart) | [office_preview_handler.cpp](windows/runner/native/office_preview_handler.cpp) / [office_preview_handler.h](windows/runner/native/office_preview_handler.h) |
| Hex 预览 | [quicklook_hex_view.dart](lib/plugins/quicklook/views/quicklook_hex_view.dart) | — |
| 回退预览 | [quicklook_fallback_view.dart](lib/plugins/quicklook/views/quicklook_fallback_view.dart) | — |
| C++ 辅助 | — | [quicklook_helper.cpp](windows/runner/native/quicklook_helper.cpp) / [quicklook_helper.h](windows/runner/native/quicklook_helper.h) |

## 🎬 屏幕录制

| 功能 | Dart 文件 | C++ 文件 |
|------|-----------|----------|
| ScreenRecordingPlugin | [screenrecording_plugin.dart](lib/plugins/screenrecording/screenrecording_plugin.dart) | — |
| 录制引擎 | [recording_engine.dart](lib/plugins/screenrecording/recording_engine.dart) | — |
| 录制服务 | [recording_service.dart](lib/plugins/screenrecording/recording_service.dart) | — |
| 录制状态 | [recording_state.dart](lib/plugins/screenrecording/recording_state.dart) | — |
| 录制指示器 | [recording_indicator.dart](lib/plugins/screenrecording/recording_indicator.dart) | — |
| 设置面板 | [recording_settings_panel.dart](lib/plugins/screenrecording/recording_settings_panel.dart) | — |
| IPC 通信 | [ipc_client.dart](lib/plugins/screenrecording/ipc/ipc_client.dart) / [ipc_server.dart](lib/plugins/screenrecording/ipc/ipc_server.dart) / [ipc_protocol.dart](lib/plugins/screenrecording/ipc/ipc_protocol.dart) | [screenrecording_channel.cpp](windows/runner/native/screenrecording_channel.cpp) / [screenrecording_channel.h](windows/runner/native/screenrecording_channel.h) |
| 独立进程 App | [screenrecording_app.dart](lib/plugins/screenrecording/screenrecording_app.dart) | — |

## 🌐 翻译

| 功能 | Dart 文件 | C++ 文件 |
|------|-----------|----------|
| TranslatePlugin | [translate_plugin.dart](lib/plugins/translate/translate_plugin.dart) | — |
| TranslateService | [translate_service.dart](lib/plugins/translate/translate_service.dart) | — |
| TranslatePage | [translate_page.dart](lib/plugins/translate/translate_page.dart) | — |
| Python 服务管理 | [python_service.dart](lib/plugins/translate/python_service.dart) | — |
| 模型管理 | [model_manager.dart](lib/plugins/translate/model_manager.dart) | — |
| 服务端管理 | [server_manager.dart](lib/plugins/translate/server_manager.dart) | — |
| 设置 | [translate_settings.dart](lib/plugins/translate/translate_settings.dart) | — |
| C++ 引擎 | — | [translate_engine.cpp](windows/runner/native/translate_engine.cpp) / [translate_engine.h](windows/runner/native/translate_engine.h) |
| Tokenizer | — | [sp_tokenizer.cpp](windows/runner/native/sp_tokenizer.cpp) / [sp_tokenizer.h](windows/runner/native/sp_tokenizer.h) / [gpt2_bpe_tokenizer.cpp](windows/runner/native/gpt2_bpe_tokenizer.cpp) / [gpt2_bpe_tokenizer.h](windows/runner/native/gpt2_bpe_tokenizer.h) |

## 🔤 Key Echo (OSD 按键显示)

| 功能 | 文件 |
|------|------|
| KeyClassifier | [lib/plugins/key_echo/key_classifier.dart](lib/plugins/key_echo/key_classifier.dart) |
| UI Widget | [lib/plugins/key_echo/key_echo_widget.dart](lib/plugins/key_echo/key_echo_widget.dart) |
| 独立进程 App | [lib/plugins/key_echo/notification_app.dart](lib/plugins/key_echo/notification_app.dart) |

## 🖱️ OLE 拖出

| 功能 | 文件 |
|------|------|
| DragOutHelper | [lib/core/drag/drag_out_helper.dart](lib/core/drag/drag_out_helper.dart) |
| C++ 处理 | [drag_drop_handler.cpp](windows/runner/native/drag_drop_handler.cpp) / [drag_drop_handler.h](windows/runner/native/drag_drop_handler.h) |

## 📁 文件转换

| 功能 | 文件 |
|------|------|
| 插件入口 | [lib/plugins/file_converter/file_converter_plugin.dart](lib/plugins/file_converter/file_converter_plugin.dart) |
| 核心引擎 | [lib/plugins/file_converter/converter_engine.dart](lib/plugins/file_converter/converter_engine.dart) |
| 服务 | [lib/plugins/file_converter/converter_service.dart](lib/plugins/file_converter/converter_service.dart) |
| UI 页面 | [lib/plugins/file_converter/ui/converter_page.dart](lib/plugins/file_converter/ui/converter_page.dart) |
| 模型: 任务/预设/设置 | [models/conversion_job.dart](lib/plugins/file_converter/models/conversion_job.dart) / [models/conversion_preset.dart](lib/plugins/file_converter/models/conversion_preset.dart) / [models/conversion_settings.dart](lib/plugins/file_converter/models/conversion_settings.dart) / [models/input_category.dart](lib/plugins/file_converter/models/input_category.dart) / [models/output_type.dart](lib/plugins/file_converter/models/output_type.dart) |
| Office 引擎 | [lib/plugins/file_converter/engines/office_com_engine.dart](lib/plugins/file_converter/engines/office_com_engine.dart) / [office_utils.dart](lib/plugins/file_converter/engines/office_utils.dart) |
| QPDF 引擎 | [lib/plugins/file_converter/engines/qpdf_engine.dart](lib/plugins/file_converter/engines/qpdf_engine.dart) |
| FFmpeg 参数工具 | [lib/plugins/file_converter/utils/ffmpeg_args.dart](lib/plugins/file_converter/utils/ffmpeg_args.dart) |

## 📚 词典

| 功能 | 文件 |
|------|------|
| 插件入口 | [dictionary_plugin.dart](lib/plugins/dictionary/dictionary_plugin.dart) |
| 服务 | [dictionary_service.dart](lib/plugins/dictionary/dictionary_service.dart) |
| UI 页面 | [dictionary_page.dart](lib/plugins/dictionary/dictionary_page.dart) |
| 数据模型 | [dictionary_models.dart](lib/plugins/dictionary/dictionary_models.dart) |
| 设置 | [dictionary_settings.dart](lib/plugins/dictionary/dictionary_settings.dart) |

## ⚙️ 设置 & 环境

| 功能 | 文件 |
|------|------|
| SettingsService | [lib/core/settings/settings_service.dart](lib/core/settings/settings_service.dart) |
| SettingsPage UI | [lib/ui/settings/settings_page.dart](lib/ui/settings/settings_page.dart) |
| 设置: 命令注册 | [commands_tab.dart](lib/ui/settings/commands_tab.dart) |
| 设置: Bug 报告 | [bug_report_tab.dart](lib/ui/settings/bug_report_tab.dart) |
| 设置: 词典调试 | [dictionary_debug_tab.dart](lib/ui/settings/dictionary_debug_tab.dart) |
| 设置: 环境检测 | [setup_checker_tab.dart](lib/ui/settings/setup_checker_tab.dart) |
| 环境检测 | [lib/core/setup/setup_checker.dart](lib/core/setup/setup_checker.dart) |
| Help 页 | [lib/ui/help/help_page.dart](lib/ui/help/help_page.dart) |

## 🖥️ 系统托盘 & 通知

| 功能 | Dart 文件 | C++ 文件 |
|------|-----------|----------|
| TrayManager | [lib/core/tray/tray_manager.dart](lib/core/tray/tray_manager.dart) | [tray_icon.cpp](windows/runner/native/tray_icon.cpp) / [tray_icon.h](windows/runner/native/tray_icon.h) |

## 🛠️ 通用工具

| 功能 | 文件 |
|------|------|
| 文件名模板 | [lib/core/utils/filename_template.dart](lib/core/utils/filename_template.dart) |
| Logger | [lib/core/utils/logger.dart](lib/core/utils/logger.dart) |
| 截图采集服务 | [lib/core/picker/picker_service.dart](lib/core/picker/picker_service.dart) |

## 🔧 C++ 基础设施

| 功能 | 文件 |
|------|------|
| 窗口基类 (Win32) | [win32_window.cpp](windows/runner/win32_window.cpp) / [win32_window.h](windows/runner/win32_window.h) |
| Flutter 窗口 | [flutter_window.cpp](windows/runner/flutter_window.cpp) / [flutter_window.h](windows/runner/flutter_window.h) |
| 工具函数 (路径归一化等) | [utils.cpp](windows/runner/utils.cpp) / [utils.h](windows/runner/utils.h) |
| 文件操作 | [file_operations.cpp](windows/runner/native/file_operations.cpp) / [file_operations.h](windows/runner/native/file_operations.h) |
| 文件夹选择器 | [folder_picker.cpp](windows/runner/native/folder_picker.cpp) / [folder_picker.h](windows/runner/native/folder_picker.h) |
| 显示器切换 | [monitor_swap.cpp](windows/runner/native/monitor_swap.cpp) / [monitor_swap.h](windows/runner/native/monitor_swap.h) |
| 调试工具 | [debug_tools.cpp](windows/runner/native/debug_tools.cpp) / [debug_tools.h](windows/runner/native/debug_tools.h) |
| 图片库 (stb_image) | [stb_image.h](windows/runner/native/third_party/stb_image.h) / [stb_impl.cpp](windows/runner/native/third_party/stb_impl.cpp) |
