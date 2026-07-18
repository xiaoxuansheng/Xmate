# XMate

**Windows 私人助理工具合集 App** — 系统托盘常驻，命令面板 + 快捷键驱动，极简高效。

## 功能

| 功能 | 说明 |
|------|------|
| 📸 截图标注 | 截图后标注、马赛克、OCR 文字识别 |
| 🎬 屏幕录制 | 区域录制 + FFmpeg 编码 |
| 🔍 文件搜索 | 快速搜索文件，USN 增量索引 |
| 👁️ QuickLook | 快速预览文件内容（图片、文档、代码等） |
| 🌐 离线翻译 | 基于 LibreTranslate 的本地翻译服务 |
| 📝 便签 | 加密便签、定时提醒、Markdown 编辑 |
| 🎨 主题系统 | 深色/浅色/跟随 Windows + 自定义主题色 + 透明度 |

## 系统要求

- Windows 10 19041+（x64）
- 无需管理员权限

## 开发

```bash
flutter build windows --release  # 编译
```

打包：使用 Inno Setup（`scripts/installer_v*.iss`），生成安装包到 `installer/`。

## 第三方组件许可

- **FFmpeg** (GPL): bundled `ffmpeg.exe` from [gyan.dev](https://github.com/GyanD/codexffmpeg/releases). Source: `https://github.com/GyanD/codexffmpeg`
- **Flutter/Dart**: BSD-3
- **ONNX Runtime**: MIT
- **qpdf**: Apache-2.0
- **MDK SDK**: BSD
- **7-zip**: LGPL

## 作者

萧  Gabriel — Built with Claude Code (DeepSeek V4 Pro)
