# XMate 插件开发协议

> 版本：v1.1 | 更新：2026-07-03

## 插件基类

```dart
abstract class XMatePlugin {
  String get id;                    // 唯一标识，如 "screenshot"
  String get name;                  // 显示名称，如 "截图"
  String get description;
  IconData get icon;
  List<CommandItem> get commands;   // 命令面板匹配
  Map<String, HotKey> get defaultHotKeys; // 默认快捷键

  Future<void> onInit(PluginContext context);
  Future<void> onDispose();
  Widget? get settingsPage;         // 可选设置页
  bool get enabled => true;
}
```

## CommandItem

```dart
class CommandItem {
  final String id;           // 如 "screenshot.activate"
  final String text;         // 如 "截图"
  final List<String> aliases;
  final String description;
  final IconData icon;
  final VoidCallback onExecute;
}
```

## PluginContext

```dart
class PluginContext {
  SettingsService get settings;
  void registerHotKey(String action, HotKey key, VoidCallback callback);
  void emitEvent(String eventName, {Map<String, dynamic>? data});
  StreamSubscription listenEvent(String eventName, ...);
  Future<int> createWindow(WindowConfig config);
}
```

## 开发新插件步骤

1. 在 `lib/plugins/{id}/` 下创建文件夹
2. 创建 `{id}_plugin.dart` 实现 `XMatePlugin`
3. 在 `PluginRegistry` 中注册
4. 定义命令（至少一个 `activate` 命令）
5. 如需独立窗口，参考 `docs/plugin-independent-window.md`

## 隔离原则

- ✅ 可以：访问 PluginContext、创建窗口、读写自己的设置、收发事件
- ❌ 不可以：直接引用其他插件代码、修改核心框架、阻塞 UI 线程
- ⚠️ 插件间通过事件总线通信，不直接依赖

## 设置页 UI 规范

设置页使用 `_SectionCard`（在 `settings_page.dart` 中定义）作为外层容器。如需内部分组，自行构建嵌套 section（header + card），样式与外层一致：

- **Header**：`Icon(16px, Colors.white54)` + `Text(13px, Colors.white54)`
- **Body**：`Container(Colors.white.withAlpha(12), BorderRadius.circular(10))`
- **行布局**：`Padding(horizontal:14, vertical:6)` + `Row([label, Spacer(), widget])`
- **分隔线**：`Divider(color: 0x20FFFFFF)`

参考实现：`lib/plugins/screenshot/screenshot_settings.dart`
