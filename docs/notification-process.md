# 通知进程 (Notification Process)

> V2.7.10 按键回显功能——右上角 TOPMOST 覆盖层，显示按键组合回显 + 锁定键/IME/Insert 状态。

## 架构

```
Main Process (xmate.exe)
  └── spawn → xmate.exe --notification (detached, 单实例)
        ├── C++ main.cpp: FlutterWindow("notification", "", "") + window class "xmate_notify"
        ├── Dart: startupMode == "notification" → NotificationApp
        ├── C++ WH_KEYBOARD_LL 全局钩子 → PostMessage(WM_XMATE_KEY_ECHO)
        ├── IME 检测：钩子回调中通过 GetForegroundWindow 线程获取键盘布局
        └── 退出: closeNotificationWindows → FindWindowW("xmate_notify") → WM_CLOSE
```

## 关键技术决策

### 鼠标穿透 — 放弃全屏覆盖，改用内容自适应窗口

| 尝试 | 结果 |
|------|------|
| `WS_EX_TRANSPARENT` 全屏窗口 | 父窗口返回 HTTRANSPARENT，但 Flutter 子窗口 FLUTTERVIEW 返回 HTCLIENT，截断穿透链 |
| 子窗口子类化 + HTTRANSPARENT | 理论上正确，但 Flutter 引擎在运行时可能覆盖 WNDPROC，不可靠 |
| `WS_EX_LAYERED` + SetLayeredWindowAttributes (仿 annotation_overlay) | 破坏 Flutter 的 DirectX 渲染管道 |
| **最终方案** | 放弃全屏。窗口仅在有内容时显示，尺寸恰好覆盖内容区域（屏幕 3%-15%）。TOPMOST，无 TRANSPARENT。鼠标阻断范围极小，对桌面操作影响可忽略 |

### 窗口尺寸

- 启动：1×1（隐藏）
- 有内容：Dart 计算内容区域 → `resizeContent(x, y, w, h)` → Flutter 渲染后下一帧 `showContent()` → `ShowWindow(SW_SHOW)`
- 无内容：`hideContent()` → `ShowWindow(SW_HIDE)`
- **先 resize 后 show** — 避免 debug 红色边框闪烁
- **宽度**：屏幕宽度 × 10%（固定）
- **高度**：`总条目数 × (itemH + gap)`，动态随条目增减

### 定位

- 距离屏幕顶部和右侧各留 5% 边距
- 统一右上角对齐（`Column + CrossAxisAlignment.end`）
- Status 面板（锁定键/IME/Insert）固定在 Hotkey 面板（按键回显）上方

### 条目大小

| 参数 | 公式 | 说明 |
|------|------|------|
| itemH | 屏幕高度 × 3% | 单条标签高度 |
| gap | itemH × 0.15 | 条目间距 |
| fontSize | itemH × 0.6 | 为下角字母(g/j/y/p/q)留空间 |
| 圆角 | itemH × 0.35 | 标签背景圆角 |
| 水平内边距 | itemH × 0.5 | 标签左右 padding |
| 垂直内边距 | itemH × 0.15 | 标签上下 padding |

## 窗口属性

```
WS_POPUP + WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
(无 WS_EX_TRANSPARENT — 不需要穿透)
```

- `SetQuitOnClose(true)` — 关闭时自动 `PostQuitMessage`
- 通过 `WM_MOUSEACTIVATE → MA_NOACTIVATE` + `WM_ACTIVATE → 0` 阻止焦点获取
- 启动时在 `main.cpp` 做单实例保护：`FindWindowW(nullptr, L"xmate_notify")`

## 主题与颜色

- 背景：`XMateColors.panelBg(context)` — 跟随用户设置的主题（dark/light）和透明度
- 文字：`XMateColors.textPrimary(context)` — 跟随主题的黑/白
- 不再使用 `.withAlpha(200)` 硬编码透明度，完全遵从 `app.theme.backgroundOpacity` 设置

## 键盘钩子

### WH_KEYBOARD_LL 回调

- 仅处理 `WM_KEYDOWN` / `WM_SYSKEYDOWN`
- **极速路径**：非功能键且无修饰键 → 立即 `return CallNextHookEx`（95%+ 击键在此退出）
- 纯修饰键按下（Ctrl/Alt/Shift/Win 单独）→ 丢弃
- IME 检测：每次击键通过 `GetForegroundWindow()` → `GetWindowThreadProcessId()` → `GetKeyboardLayout(tid)` 获取前台线程键盘布局，对比缓存
- 编码：`wParam=vkCode, lParam=(lockStates<<24)|(scanCode<<16)|modifierMask`

### IsFunctionalKey 白名单

| 类别 | 键 |
|------|-----|
| F 键 | F1-F24 |
| 导航 | Escape, Tab, CapsLock, Enter, Backspace, Delete, Insert |
| 方向 | Home, End, PageUp, PageDown, Arrow keys |
| 特殊 | PrintScreen, ScrollLock, Pause |
| 数字键盘 | NumLock, 0-9, +-*/. |
| 媒体 | Vol Up/Down/Mute, Play/Pause, Prev/Next, Stop |
| 浏览器 | Back, Forward, Refresh, Search, Favorites, Home |
| 启动 | Mail, Media, App1, App2 |
| IME | Kana, Kanji, Convert, NonConvert, ModeChange |

**不显示**：A-Z, 0-9（主键盘）, Space, OEM 标点（仅在无修饰键时过滤）

### Hotkey 面板排除规则 (Dart 侧)

以下按键组合**不显示**在 Hotkey 面板中：

- 锁定键：Caps Lock, Num Lock, Scroll Lock, Insert（这些在 Status 面板显示）
- 单独按：Backspace, Enter, Tab, Escape, Delete, 方向键, 小键盘数字
- Shift + 主键盘数字（Shift+1=!, 这是输入而非快捷键）
- 不带修饰符的字母/数字

显示的内容：
- F 键、媒体键、浏览器键（无论有无修饰符）
- 修饰符 + 字母 → 显示大写字母（如 `Ctrl+S`, `Alt+F4`）
- Space / Menu / Print Screen / Pause 等高阶键（需带修饰符）

### IME 语言映射

```
0x0804 (zh-CN) / 0x0404 (zh-TW) / 0x0C04 (zh-HK) → "中"
其他 → "EN"
```

## 设置

| 键 | 默认 | 说明 |
|----|------|------|
| `notification.keyEcho.hotkey` | `true` | Hotkey 面板（按键回显组合键） |
| `notification.keyEcho.status` | `true` | Status 面板（锁定键/IME/Insert） |

- 设置页位于 General 标签页，命令面板快捷键下方
- Dart 每 2s 轮询 settings.json 读取开关状态
- C++ 不读设置——无条件捕获并投递所有事件，Dart 根据开关和排除规则决定是否渲染

## 数据流

```
WH_KEYBOARD_LL 钩子回调
  → PostMessage(hwnd, WM_XMATE_KEY_ECHO, vkCode, modifiers+lockStates)
  → FlutterWindow::MessageHandler
  → keyecho_channel_->InvokeMethod("onKeyEvent", args)
  → Dart NotificationApp._onMethodCall
  → KeyClassifier.toDisplayLabel(vkCode, modifiers)  (排除规则过滤)
  → KeyEchoHotkeyPanelState.addKey(label)    (Hotkey 面板, 1s 独立倒计时消失)
  → KeyEchoStatusPanelState.updateLockStates(...)  (Status 面板, 常显)
  → _applyWindowSize()
     → resizeContent() (position + size, still hidden)
     → addPostFrameCallback → showContent() (SW_SHOW after Flutter renders)

IME 变化:
  WH_KEYBOARD_LL → GetForegroundWindow 线程 → GetKeyboardLayout(tid) 对比缓存
  → PostMessage(hwnd, WM_XMATE_IME_CHANGE, langId)
  → keyecho_channel_->InvokeMethod("onImeChange", {label})
  → Dart → KeyEchoStatusPanelState.showIme(label)  (5s 自动消失)
```

## 显示规格

- **标签高度** = 屏幕高度 × 3%
- **字体大小** = 标签高度 × 0.6
- **背景** = `XMateColors.panelBg(context)`（跟随主题和透明度设置）
- **文字** = `XMateColors.textPrimary(context)`（跟随主题）
- **圆角** = 标签高度 × 0.35

## Status 面板显示规则

| 状态 | 显示条件 | 标签 |
|------|----------|------|
| Caps Lock | 激活时显示 | Caps Lock |
| Num Lock | **未激活**时显示 | Num Lock OFF |
| Scroll Lock | 激活时显示 | Scroll Lock |
| Insert | 激活（覆盖模式）时显示 | Insert |
| IME | 切换到中文时显示 | 中（5s） |

## 文件清单

| 文件 | 用途 |
|------|------|
| `windows/runner/native/keyboard_hook.h` | C++ 钩子声明 |
| `windows/runner/native/keyboard_hook.cpp` | C++ WH_KEYBOARD_LL 实现 + IsFunctionalKey + IME |
| `windows/runner/main.cpp` | `--notification` 模式入口 + 单实例防护 |
| `windows/runner/flutter_window.h/.cpp` | keyecho channel 注册 + resizeContent/showContent/hideContent |
| `windows/runner/CMakeLists.txt` | 添加 keyboard_hook.cpp |
| `lib/main.dart` | 启动分支 + spawn + onExit 清理 |
| `lib/plugins/key_echo/notification_app.dart` | 通知进程独立 MaterialApp |
| `lib/plugins/key_echo/key_echo_widget.dart` | Hotkey/Status 面板 UI 组件 |
| `lib/plugins/key_echo/key_classifier.dart` | Win32 VK 码 → 可读标签 + 排除规则 |
| `lib/ui/settings/settings_page.dart` | Key Echo Hotkey/Status 开关 |
