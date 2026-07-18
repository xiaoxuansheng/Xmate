# XMate 测试清单

**当前版本**: V3.3.2 | **日期**: 2026-07-18

**V3.3.2** — GitHub 在线更新：设置页版本号旁检测新版本 + Update Available 按钮 + 下载安装包
- 改动文件：
  `lib/core/services/update_service.dart`（新增 —— GitHub Releases API 版本检查 + 缓存 + 安装包下载），
  `lib/ui/settings/settings_page.dart`（_VersionRow 加入更新检查、Update 按钮、下载进度条、确认对话框），
  `.gitignore`（新增 XMate 排除规则），
  `README.md`（替换默认模板，加入项目说明和第三方许可），
  `LICENSE`（新增 MIT 许可证），
  `pubspec.yaml`（3.3.2）
- 核心测试：
  1. 打开设置页 General → 等待数秒 → 无网络下静默降级不弹错误
  2. 修改版本号为低版本（如 0.0.1）→ 打开设置页 → 版本号旁出现 "Update" 按钮
  3. 点击 Update → 弹出确认对话框显示新旧版本号 → 确认后下载进度条 + 百分比显示
  4. 下载完成后自动启动安装程序（新版本 v3.3.2 需先上传 GitHub Release）
  5. 已是最新版本时 → 版本号旁无额外按钮（正常显示）
