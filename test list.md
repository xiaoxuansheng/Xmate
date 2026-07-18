# XMate 测试清单

**当前版本**: V3.4.0 | **日期**: 2026-07-18

**V3.4.0** — GitHub 在线更新正式发布：安全清理 + 相对路径 + 安装包上传 GitHub Release
- 改动文件：
  `lib/core/services/update_service.dart`（填入 GitHub owner xiaoxuansheng），
  `pubspec.yaml`（3.4.0），
  `scripts/installer_v340.iss`（新 Inno Setup 打包脚本），
  `build_vs.bat` / `launch_xmate.bat` / `clean_build.ps1` / `scripts/patch_pdf_view.py` / `scripts/installer_v*.iss`（硬编码路径 → 相对路径），
  `CLAUDE.md`（版本号 + 路径改为通用占位符），
  `docs/environment-setup.md`（工具路径改为通用占位符），
  `windows/runner/native/onnx_ocr_engine.cpp` / `translate_engine.cpp`（C++ 回退路径改为相对），
  `assets/donate_qr.png`（已删除），
  `.gitignore`（完善排除规则）
- 核心测试：
  1. 编译 `flutter build windows --release` 无错误
  2. 运行 Inno Setup 编译 `installer_v340.iss` → 生成 `XMate_Setup_v3.4.0.exe`（约 130MB）
  3. 上传安装包到 GitHub Release `v3.4.0`（tag + asset）
  4. 设置页 General → 版本号旁显示 "Update" 按钮（本地版本 3.4.0，远端的 Release 标记更新时弹出）
  5. 点击 Update → 确认弹窗 → 下载进度条 → 启动安装程序
