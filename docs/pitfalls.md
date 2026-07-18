# 开发坑点详解

> 本文档为 27 条关键坑点的完整说明。CLAUDE.md 只保留核心 11 条速查，其余细节均在此处。每条规则都是踩过的坑，**不要违反**。

---

## 1. hotkey_manager 热键崩溃

插件内注册 USB HID 键码触发 `STATUS_STACK_BUFFER_OVERRUN`。**禁止插件自行注册快捷键**——所有快捷键由 `main.dart` 统一注册后分发。当前快捷键：空格键打开命令面板、Alt+S 触发截图（均由宿主 `main.dart` 注册，非插件内部注册）。

## 2. tray_manager 包死锁

0.2.4 版 `setIcon()` 在 Windows 阻塞主线程。已改用原生 Win32 `Shell_NotifyIcon`（`windows/runner/native/tray_icon.cpp`）。

## 3. windowManager.hide() 时机

必须在首帧渲染后调用，否则 App 卡死。通过 `waitUntilReadyToShow` 回调保证。

## 4. ICO 格式

用 .NET `System.Drawing.Icon` 从 PNG 生成，不要用 Dart 手写二进制。

## 5. 剪贴板图片

Flutter Clipboard API 不支持图片。使用 C++ 原生 `CopyToClipboard()`（`screenshot_capture.cpp`），method channel `com.xmate/screenshot.copyToClipboard`。关键坑：`CF_BITMAP`（DDB，`GetHBITMAP` 生成）跨进程粘贴失败。正确做法是 `CF_DIB`（GDI+ Save BMP stream → 去掉 14B BITMAPFILEHEADER）+ 注册 PNG 格式双通道。

## 6. C++ 文件编码

中文注释导致 MSVC C4819 编译错误。用纯英文注释或 UTF-8 BOM 编码。**所有含中文的 C++ 文件必须用 UTF-8 BOM 编码**。

## 7. 放大镜性能

`toByteData()` 每帧调用导致卡顿。需要时改用帧缓冲缓存方案。

## 8. 窗口初始化

C++ 必须 `Show()` 一次窗口让 Flutter 引擎初始化，否则命令面板渲染为空。在首帧回调中做 1×1 Show，Dart 端立即 hide。

## 9. 单实例 Mutex

`main.cpp` 启动时创建 `Global\XMate_SingleInstance` 命名 mutex。重复启动时 `FindWindowW(L"xmate")` 找到已有窗口并发送 `WM_XMATE_TRAY + WM_LBUTTONUP` 唤醒，然后退出。不要关闭 mutex 句柄，进程退出时 OS 自动释放。

## 10. 退出流程

不调 `hk.hotKeyManager.unregisterAll()`——每热键走 method channel，耗时数秒。Windows 进程退出自动清理 `RegisterHotKey`。退出顺序：`disposeAll() → tray.dispose() → windowService.dispose()`。

## 11. 托盘菜单

只保留核心功能（打开/开机启动/设置/退出），不添加业务功能项。菜单在 C++ `tray_icon.cpp` 中定义，通过 `cmd` 值回传 Dart。开机启动通过 Task Scheduler（`CLSID_TaskScheduler` COM API）实现，任务名 `"XMate Auto Start"`，`TASK_TRIGGER_LOGON` 登录触发，`TASK_RUNLEVEL_LUA` 普通权限运行。

## 12. 命令面板 Enter 按键铁律（V2.4.0）

**所有 Enter 必须统一走 TextField.onSubmitted。列表模式（`_si >= 0`）严禁从 `_handleEarlyKey` / `_onHardwareKey` 直接调 `_exec()`。**

必须 `_pendingSel = _si; _si = -1; return KeyEventResult.ignored` 放行 Enter 到 EditableText，让 EditableText 走完整收尾链 `performAction → onEditingComplete(clearComposing) → onSubmitted(_exec)`。

根因：如果早期处理器截获 Enter 直接执行，EditableText 从未感知到 Enter → `_clearComposing` 跳过 → IME 在 completion transition 中得不到 composing 清理 → 平台侧 TextInput 状态残留 → 下一次面板的 EditableText 继承脏状态 → `onSubmitted` 永不触发。

- `_handleEarlyKey` 列表模式 Enter → `_pendingSel + ignored`
- TextField `onSubmitted` → `_exec(target)`（支持 `_pendingSel`，否则 exec 第一条）
- 已保留：`textInputAction: TextInputAction.send`、`onEditingComplete: _c.clearComposing`
- **禁止**回退为列表模式直接 `_exec(_si)` 或 `widget.onClose()` 同步关闭
- **禁止**在 `_handleEarlyKey` 的 Enter 分支调 `setState`——`_pendingSel` 和 `_si` 直接赋值（避免 widget rebuild 与 EditableText 内部状态冲突）

## 13. 管理员权限 — 统一提权模式（V2.2.0）

**核心原则**：XMate 始终以普通权限运行。Windows 不能把运行中的普通权限进程临时提升为管理员，唯一正确方式是 `ShellExecuteExW(runas)` 启动**新进程** → UAC 弹窗 → 新进程以管理员权限运行 → 执行操作 → 退出。所有需要管理员权限的操作都走此模式。

**提权入口汇总**（`main.cpp` 第 18-118 行，单实例 guard 之前）：

| 操作 | 触发端 | 命令参数 | 说明 |
|------|--------|----------|------|
| 开机自启 toggle | `tray_icon.cpp` `ToggleAutoStart()` | `--toggle-autostart` | 创建/删除 Task Scheduler 任务 |
| Open file as admin | `file_operations.cpp` `OpenFileAsAdmin()` | `--open-as-admin "<path>"` | 管理员权限打开文件 |
| 自定义命令 runAsAdmin | `file_operations.cpp` `RunCommandAsAdmin()` | `--run-command "<json>"` | 管理员权限执行命令 |
| 安装 Index Update Service | `flutter_window.cpp` fileops handler | `--install-indexer` | 创建 Windows Service + ACL |
| 卸载 Index Update Service | `flutter_window.cpp` fileops handler | `--uninstall-indexer` | 停止 + 删除 Windows Service |

**注意**：`--run-service` 不在此列——它是 SCM 启动 Service 进程的入口，不走 `ShellExecuteExW(runas)`。

## 14. Index Update Service（USN 后台索引）

- Windows Service (`XMateIndexer`, DEMAND_START, SYSTEM)，纯 C++，不依赖 Flutter
- 通信：`%ProgramData%\XMate\index_config.json`（Flutter 写 / Service 读）+ `index_results\{hash}_usn.json`（Service 写 / Flutter 读）
- 安装时设置双层 ACL：目录（Users=Modify）+ Service 对象（Users=Start+Stop+Query via SDDL）
- 生命周期：任意路径 interval != 0 → `StartService`；全部 off → `StopService`
- 原子写入：`.tmp` → `ReplaceFileW`
- 优雅停止：`WaitForSingleObject(stopEvent)` 替代 `Sleep`
- 代码：`indexer_config.h/cpp`、`indexer_service.h/cpp`

## 15. 退出速度

延迟来自 Flutter 引擎关闭，非 Dart 代码。托盘图标提前在 `tray.dispose()` 中通过 `removeTray` method channel 调用 `RemoveTrayIcon()` 删除，用户看到即时响应。

## 16. 快捷键持久化

快捷键配置以 `{modifiers, key}` JSON 存入 `app.hotkey.palette` 设置。main.dart 从 settings 读取后注册，设置页通过 `HotkeyChangedCallback` 回调 main.dart 重新注册。

## 17. 文件夹选择器

新增 `com.xmate/picker` channel，C++ 用 COM `IFileOpenDialog` + `FOS_PICKFOLDERS` 实现。路径用 `WideCharToMultiByte(CP_UTF8)` 转成 UTF-8 回传 Dart。不要用 `std::string(path.begin(), path.end())` 转换 wchar_t——MSVC 报 C4244。

## 18. 设置页面导航

设置页通过 `showOverlay()` 全屏显示，不在 Navigator 中。Back 按钮调用 `WindowService.hideWindow() + clearOverlay()`。

## 19. 窗口样式 WS_POPUP

`win32_window.cpp` 用 `WS_POPUP` 创建无边框窗口（不是 `WS_OVERLAPPEDWINDOW`）。WS_POPUP 窗口通过 `DwmExtendFrameIntoClientArea` + `WM_NCCALCSIZE` 控制 NC 区域。**不要恢复 WS_OVERLAPPEDWINDOW**，否则外围框会回来。

## 20. 命令面板浮窗化

命令面板用 `showFloating()`（540×420 居中偏上），不是全屏。窗口只占部分屏幕，浮窗外桌面可正常交互。截图标注仍然全屏（`showFullscreen()` + `setFullScreen(true)`）。

## 21. 截图窗口生命周期隔离

从命令面板进入截图时，旧面板的 `refitWindow → addPostFrameCallback → setBounds` 回调会在全屏后才执行，把窗口缩回 540×48。`XMateAppState` 维护 `_windowGeneration` 令牌，`showOverlay(non-palette)` / `clearOverlay()` / 截图 `_start()` 入口调用 `invalidateWindowOps()` 递增令牌，`refitWindow` 每个 `await` 后检查令牌是否匹配。**不要绕过 invalidateWindowOps 或删除 refitWindow 中的 gen guard。**

## 22. GPU swapchain 刷新时序

`showFullscreen()` 扩大父 HWND 后 Flutter 引擎 swapchain 可能停留在旧尺寸。必须在 `showOverlay(AnnotatePage)` + 首帧渲染完成后调用 `forceChildRefresh()`（MoveWindow child 1→full），引擎才能以正确全屏尺寸重建 swapchain。**不要在 AnnotatePage 首帧前或在 showOverlay 之前调用 forceChildRefresh。**

## 23. 离线翻译模型（OPUS-MT MarianMT）

模型类型为 **Unigram**（非 BPE）。tokenizer 必须用 Viterbi 格栅解码匹配官方 SentencePiece 输出。SP 本地 ID ≠ 共享词表 ID：
- 共享词表 `vocab.json`（65,001 条）：piece → shared_id
- `shared_vocab.txt`（同内容，含 SP 分数）：shared_id ↹ piece ＋ score
- **特殊 token ID (共享词表)**：EOS/BOS=0, UNK=1, PAD=65000
- **decoder_start_token_id** = 65000 (PAD)
- encoder 输入 = shared ID 序列 + EOS=0，PAD=65000 填充
- argmax 全范围 0-65000，不 clamp
- decode 时遇 EOS=0 停止、遇 PAD=65000 跳过
- 模型文件：`translate_encoder.onnx` (200MB) + `translate_decoder.onnx` (352MB) + `vocab.json` (~1.6MB) + `shared_vocab.txt` (~1.8MB)
- `source.spm` / `target.spm` 保留为备份，供导出脚本使用
- **不要**用 `sp_vocab_en.txt` / `sp_vocab_zh.txt`（旧版拆分词表，已移除）
- **不要**在 argmax 中 clamp 到 32000（模型输出 65001 维，共享词表也是 65001 维）

## 24. Dart → C++ 路径分隔符 `/` vs `\`

Dart 端用 `/` 拼接路径（如 `FileSearchResult.fullPath`），但 Windows API（`CreateFileW`、`GetFileAttributesW`、`SHGetFileInfoW`、`PathFileExistsW` 等）只认 `\`。**所有 Dart 经 method channel 传路径到 C++ 的场景，C++ 入口必须做 `/` → `\` 归一化**，否则文件夹路径命中 `INVALID_FILE_ATTRIBUTES` → 掉进 fallback → 显示通用图标/操作失败。反之，C++ 返回给 Dart 的路径务必转成 `/`（UTF-8 场景），保证 Dart 端统一用 `/` 做匹配比对。已在 `file_scanner.cpp` 的 `GetFileIconPng` 和 `file_operations.cpp` 中做了归一化，将来新增 channel 不要漏。

## 25. 命令面板内切换 overlay 的时序陷阱

从命令面板（或其他 overlay）中打开新的 overlay（如 Translate 窗口、Settings 等）时，**必须先关闭当前 overlay，再在下一帧打开新 overlay**。`XMateAppState` 只有一个 `_overlay` 槽位——如果先调 `showTranslate()` 设了 `_overlay = TranslatePage(...)`，然后 `widget.onClose()` 立即调 `clearOverlay()` 把 `_overlay` 置 `null`，新窗口被创建后立刻被销毁，用户看到窗口闪一下后消失。正确模式：

```dart
// 在 command_palette / 子菜单 / 任何 overlay 内部：
widget.onClose();                              // 1. 关闭当前 overlay
WidgetsBinding.instance.addPostFrameCallback((_) {
  appKey.currentState?.showTranslate(...);     // 2. 下一帧打开新 overlay
});
```

**以后任何从命令面板/子菜单打开新窗口的场景都必须遵循此模式。**

## 26. File Search 后台扫描路径归一化（V2.6.3）

坑点 #24 已覆盖 `GetFileIconPng` 和 `file_operations.cpp` 中的 `/` → `\` 归一化，但 **`ScanDirectoryAsync` / `QueryUsnJournalWithDirsAsync` 原来没有做**。这两个通过 `std::thread::detach()` 在后台线程调用 `ScanDirectory` / `QueryUsnJournalWithDirs`，最终走 `FindFirstFileW`。Dart 端 `FileSearchResult.fullPath` 等字段使用 `/` 拼接 → 未经归一化的路径传入 Windows API → 部分场景（网络路径、长路径、特殊字符）`FindFirstFileW` 静默返回 `INVALID_FILE_ATTRIBUTES` → 扫描返回 `"[]"` → Dart 收到空数组 → "No files found" 但无任何报错。已修复：在 `ScanDirectoryAsync` lambda 捕获前归一化路径。**将来任何新增异步后台扫描通道，必须在线程入口归一化路径，不能依赖 API 容错。**

## 27. detached 线程 + atomic flag 反模式（V2.6.3）

V2.6.3 第一轮为修复 DLL 占用引入了 `g_engineAlive` atomic flag + detached 线程在 flag 为 false 时跳过 messenger 回调。这是错误的 anti-pattern：① 静态 `atomic<bool>` 在非正常退出后重启的边界场景初始化时序不确定；② 跳过回调 → Dart `completer` 永不 resolve → 调用者永久挂起；③ detached 线程持有 DLL 引用的问题应该通过正确 join 线程解决，而非跳过回调。已全部回退。**禁止在 method channel 异步回调路径中使用 atomic flag 做 shutdown guard**——正确做法是对 `std::thread` 做 `join()` 或使用 `std::future`。
