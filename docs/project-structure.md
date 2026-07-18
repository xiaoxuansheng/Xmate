# XMate 目录结构

> 版本：v2.4 | 更新：2026-07-03

```
xmate/
├── docs/                              # 📚 开发文档
│   ├── requirements.md / architecture.md / tech-stack.md
│   ├── code-standards.md / project-structure.md / plugin-protocol.md
│   ├── development-workflow.md / environment-setup.md
│   ├── quicklook.md / file-search.md / screenshot-annotate.md
│   ├── libretranslate.md / plugin-independent-window.md
│   ├── ole-drag-out.md / pitfalls.md / ocr-internal-flow.md
│
├── devlog/                            # 📝 开发日志（天级）
│   └── YYYY-MM-DD.md
│
├── lib/                               # 💻 Dart 源代码
│   ├── main.dart                      # 入口：初始化 + 启动分支 + 热键注册
│   ├── app.dart                       # XMateAppState + overlay 管理
│   │
│   ├── core/                          # 🔧 核心框架（不依赖业务）
│   │   ├── plugin/                    # 插件基类 + 注册表
│   │   ├── command/                   # 命令面板 + 子菜单 + 用户命令
│   │   ├── hotkey/                    # 快捷键管理
│   │   ├── tray/                      # 系统托盘
│   │   ├── window/                    # 窗口管理（WindowService）
│   │   ├── settings/                  # 设置服务（JSON 持久化）
│   │   ├── event/                     # 事件总线
│   │   ├── picker/                    # 文件夹选择器
│   │   ├── search/                    # 文件搜索（trigram 索引）
│   │   ├── quicklook/                 # QL IPC 状态 + 公共工具
│   │   ├── drag/                      # 拖出组件
│   │   ├── annotate/                  # 标注模型 + 工具函数
│   │   └── utils/                     # logger 等工具
│   │
│   ├── plugins/                       # 🧩 业务插件
│   │   ├── screenshot/                # 截图 + 标注 + 录制设置
│   │   ├── screenrecording/           # 屏幕录制（独立子进程）
│   │   ├── quicklook/                 # 文件预览（独立子进程）
│   │   └── translate/                 # 离线翻译（LibreTranslate）
│   │
│   └── ui/settings/                   # 设置页 UI
│
├── assets/                            # 🖼️ 静态资源
├── scripts/                           # 🐍 Python 脚本 + Inno Setup
│   ├── translate_model_manager.py     # ArgosTranslate 模型管理
│   ├── download_minisbd.py            # MiniSBD 下载
│   ├── download_gpt2_bpe.py           # GPT-2 BPE 词表
│   ├── generate_pinyin_table.py       # 拼音表生成
│   └── installer_v*.iss               # Inno Setup 打包脚本
│
├── windows/runner/                    # 🪟 Windows 原生
│   ├── main.cpp                       # Win32 入口 + 提权分支 + 单实例
│   ├── flutter_window.cpp/h           # Flutter 窗口宿主 + method channels
│   ├── win32_window.cpp/h             # Win32 WS_POPUP 窗口封装
│   └── native/                        # 原生方法通道实现
│       ├── screenshot_capture.cpp/h   # GDI+ 截图 + 剪贴板
│       ├── file_operations.cpp/h      # 文件操作（复制/删除/属性/音频元数据）
│       ├── file_scanner.cpp/h         # 目录扫描 + 图标提取
│       ├── usn_journal.cpp/h          # USN Journal 变化检测
│       ├── indexer_config.cpp/h       # Indexer 配置读写
│       ├── indexer_service.cpp/h      # Windows Service 主循环
│       ├── tray_icon.cpp/h            # Shell_NotifyIcon 托盘 + 开机自启
│       ├── folder_picker.cpp/h        # COM 文件夹选择器
│       ├── pin_window.cpp/h           # GDI+ Pin 窗口
│       ├── drag_drop_handler.cpp/h    # OLE 拖出/拖入
│       ├── annotation_overlay.cpp/h   # 录屏标注透明叠加层
│       ├── quicklook_helper.cpp/h     # COM Explorer 选中查询
│       ├── office_preview_handler.cpp/h # Office IPreviewHandler 嵌入
│       ├── screenrecording_channel.cpp/h # 录屏子进程 IPC
│       ├── onnx_ocr_engine.cpp/h      # PP-OCRv6 ONNX 文字识别
│       ├── translate_engine.cpp/h     # MarianMT 引擎（已封存）
│       ├── sp_tokenizer.cpp/h         # SentencePiece 分词器
│       ├── gpt2_bpe_tokenizer.cpp/h   # GPT-2 BPE 词边界
│       ├── ocr_engine.cpp/h           # OCR 引擎基类
│       └── debug_tools.cpp/h          # 调试工具
│
├── pubspec.yaml / pubspec.lock / analysis_options.yaml
├── CLAUDE.md / README.md / test list.md
```

## 目录约定

- `core/` — 不涉及业务，不知道"截图"是什么
- `plugins/` — 所有业务逻辑，一个插件一个文件夹

每个插件至少需要 `{name}_plugin.dart`（实现 `XMatePlugin`）+ `models/` + 功能子文件夹。
