# 插件独立窗口模式 — 开发指引

> 当插件需要一个完全独立的原生窗口时，参考 QuickLook 模式。

## 适用场景

| 模式 | 适用 | 不适用 |
|------|------|--------|
| Overlay（`_overlay` 槽位） | 与命令面板互斥的全屏页面（截图/设置/翻译） | 需要与命令面板**同时显示** |
| 独立进程 | 与主窗口共存、多个实例、不抢焦点的浮窗 | 简单弹窗 |

## 实现步骤

### 1. C++ main.cpp — 启动模式分支

```cpp
// 在 wWinMain 中，Mutex guard 之前检查参数
if (command_line && wcsstr(command_line, L"--my-plugin")) {
  // 提取参数 ...
  FlutterWindow window(project, "my_plugin_mode", myData);
  window.Create(L"xmate_myplugin", origin, size); // 独立标题
  window.SetQuitOnClose(true);
  // 标准消息循环 ...
  return EXIT_SUCCESS;
}
```

### 2. C++ flutter_window — 模式传递 channel

```cpp
// flutter_window.h: 新增构造函数 + 成员
FlutterWindow(const flutter::DartProject& project,
              const std::string& startupMode,
              const std::string& startupData);

// flutter_window.cpp: 在 OnCreate 最前面注册
app_channel_->SetMethodCallHandler([](...) {
  if (method == "getStartupMode") result->Success(startup_mode_);
  if (method == "getStartupData")  result->Success(startup_data_);
});
```

### 3. Dart main.dart — 启动分支 + UI

```dart
void main() async {
  // Query startup mode BEFORE initMainWindow.
  final mode = await appChannel.invokeMethod<String>('getStartupMode');
  if (mode == 'my_plugin_mode') {
    await windowManager.ensureInitialized();
    // Don't call hide() in waitUntilReadyToShow!
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(size: Size(1,1), skipTaskbar: true,
                          backgroundColor: Colors.transparent),
      () async { /* keep shown */ },
    );
    runApp(MyPluginApp());
    return;
  }
  // ... normal init path
}
```

### 4. 子进程启动

```dart
Future<void> _openMyPlugin() async {
  try {
    await const MethodChannel('com.xmate/myplugin')
        .invokeMethod('closeExistingWindows'); // optional single-instance
  } catch (_) {}
  await io.Process.start(
    io.Platform.resolvedExecutable,
    ['--my-plugin', data],
    mode: io.ProcessStartMode.detached,
  );
}
```

## 关键约束

1. **不要 `hide()`** — `waitUntilReadyToShow` 回调中保持窗口可见（不做 hide），否则 window_manager 内部 `_isWindowVisible = false`，`startDragging`/`setAlwaysOnTop`/`setSize` 全部短路。
2. **`showNoActivate` + `windowManager.show()`** — 先用 native channel 显示（`SWP_NOACTIVATE`），再用 `windowManager.show()` 同步 `_isWindowVisible`。
3. **禁止 `setAlwaysOnTop`** — 会触发 `SetWindowPos(HWND_TOPMOST)` → `WM_ACTIVATE` 抢走 Explorer 焦点。
4. **C++ `WM_ACTIVATE` guard** — 对独立窗口模式，在 `FlutterWindow::MessageHandler` 中拦截非点击触发的 `WM_ACTIVATE`（`return 0`），只放行 `WA_CLICKACTIVE`。
5. **Mutex 绕过** — 独立窗口在 `main.cpp` 中 `--my-plugin` 检测必须在 `CreateMutex` 之前，否则被单实例逻辑拦截。
6. **退出清理** — 主进程 `onExit` 中调 channel 关闭子进程窗口。
