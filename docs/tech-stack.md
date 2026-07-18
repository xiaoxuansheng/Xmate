# XMate 技术选型与版本

> 版本：v2.5 | 更新：2026-07-03

## 核心框架

| 技术 | 版本 | 用途 |
|------|------|------|
| **Flutter** | 3.44.1 (stable) | 跨平台 UI |
| **Dart** | 3.12.1 | 编程语言 |

## Flutter 依赖

| 包名 | 版本 | 用途 |
|------|------|------|
| **flutter_riverpod** | ^2.6.1 | 状态管理 |
| **window_manager** | ^0.4.3 | 窗口管理（置顶/无边框/全屏） |
| **hotkey_manager** | ^0.2.2 | 全局快捷键（main.dart 统一注册） |
| **path_provider** | ^2.1.5 | 系统路径 |
| **image** | ^4.9.1 | 图片编解码 |
| **http** | ^1.2.0 | LibreTranslate API |
| **flutter_inappwebview** | ^6.0.0 | WebView2 渲染（代码/Markdown/邮件/EPUB 预览） |
| **pdfrx** | ^2.2.15 | PDF 渲染（PDFium） |
| **audioplayers** | ^6.8.1 | QuickLook 音频播放 |
| **fvp** | ^0.37.2 | QuickLook 视频播放（mdk-sdk） |

> ⚠️ **tray_manager 已移除**（0.2.4 死锁）。托盘改用原生 `Shell_NotifyIcon`。

## 原生依赖

| 技术 | 用途 |
|------|------|
| **Win32 GDI+** | 截图 + Pin 窗口 + 图标提取 + 剪贴板图片 |
| **Win32 Shell_NotifyIcon** | 系统托盘 + 开机自启 |
| **ONNX Runtime** (~15MB) | PP-OCRv6 文字识别 + MarianMT（已封存） |
| **Task Scheduler COM** | 开机自启（TASK_TRIGGER_LOGON） |
| **Windows Service** | Index Update Service（USN 后台索引） |
| **OLE Drag/Drop** | 文件/文本/图片拖出 |
| **Media Foundation** | QuickLook 音频元数据读取 |
| **IPreviewHandler** | Office 文件预览 |
| **LibreTranslate** | HTTP 翻译服务（Python 子进程） |
| **FFmpeg** | 屏幕录制（gdigrab → H.264 MP4） |

## 开发工具路径

| 工具 | 路径 |
|------|------|
| Flutter SDK | `D:\Tool\Flutter\flutter` |
| Visual Studio | `D:\Visual Studio` |
| Git | `D:\Tool\Git` |

## 平台约束

| 平台 | 最低版本 | 状态 |
|------|----------|------|
| Windows | Win10 19041+ | ✅ 当前 |
| iOS / Android | — | 🔜 预留 |
