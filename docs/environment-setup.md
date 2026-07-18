# XMate 开发环境

> 版本：v1.1 | 更新：2026-07-03

## 当前环境

| 工具 | 路径 |
|------|------|
| Flutter SDK | `D:\Tool\Flutter\flutter` |
| Visual Studio 2022 | `D:\Visual Studio` |
| Git | `D:\Tool\Git` |

## 环境要求

- **Flutter SDK**（当前 3.44.1）— [下载](https://docs.flutter.dev/get-started/install/windows)
- **Visual Studio 2022** — 勾选"使用 C++ 的桌面开发"工作负载 + Windows 10 SDK
- **Git for Windows** — [下载](https://git-scm.com/download/win)

## 验证环境

```bash
flutter doctor -v          # 确认 Windows desktop 显示 ✓
flutter build windows --debug  # 确认能编译
```

## 常见问题

| 问题 | 解决 |
|------|------|
| `flutter doctor` 报找不到 Git | 安装 [Git for Windows](https://git-scm.com/download/win) |
| 找不到 MSBuild | 确认 VS 安装了 C++ 工作负载，重启终端 |
| VS Code 提示 "Flutter SDK not available" | 设置 `flutter.sdkPath` 为 Flutter SDK 路径 |
