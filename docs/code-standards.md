# XMate 代码规范

> 版本：v2.0 | 更新：2026-07-03

## 命名规范

| 类型 | 规则 | 示例 |
|------|------|------|
| Dart 文件 | `snake_case.dart` | `command_palette.dart` |
| 类名 | `PascalCase` | `ScreenshotPlugin` |
| 公共成员 | `camelCase` | `onExecute` |
| 私有成员 | `_camelCase` | `_selectedIndex` |
| 常量 | `camelCase`（Dart 风格） | `kDefaultHotkey` |
| 布尔值 | `isXxx` / `hasXxx` / `canXxx` | `isEnabled` |

## 文件结构

```dart
// 1. 导入（按 dart: / package: / 相对 分组）
// 2. 类/函数定义
// 3. 扩展方法（如有）
```

类成员顺序（Effective Dart）：静态常量 → 实例变量 → 构造函数 → 公共方法 → 私有方法

## 注释规范

- **公共 API 必须有 `///` 文档注释**，说明用途和参数
- **复杂逻辑必须有行内 `//` 注释**，解释为什么这么做

## Provider 命名（Riverpod）

```dart
// 命名规则：{功能名}Provider
final screenshotStateProvider = StateNotifierProvider<...>((ref) {
  return ScreenshotNotifier();
});
```

插件级 provider 放插件文件夹根目录，全局 provider 放 `core/` 对应模块。

## 错误处理

- 不吞异常 — 至少 log 出来
- 用户可见错误用 SnackBar 或 toast
- 开发调试用 `core/utils/logger.dart` 统一输出

## 主题与颜色规范（V2.7.3+）

### 核心原则

**禁止硬编码颜色**。所有 UI 颜色必须通过主题系统获取，以支持深色/浅色/跟随系统三种模式。

### 架构

```
SettingsService (settings.json)
  └─ keys: app.theme.mode / app.theme.accentColor / app.theme.backgroundOpacity
       │
       ▼
ThemeService (singleton extends ChangeNotifier)        ← lib/core/theme/theme_service.dart
  ├─ themeMode (dark / light / system)
  ├─ accentColor (Color)
  ├─ backgroundOpacity (int 20-100)
  ├─ lightTheme / darkTheme getter                    ← lib/core/theme/app_theme.dart
  └─ effectiveBrightness → Brightness
       │
       ▼
XMateColors (static token helpers)                    ← lib/core/theme/theme_colors.dart
  └─ panelBg / dialogBg / toolbarBg / cardFill / divider / inputFill / inputBorder ...
       │
       ▼
context.xmColors (BuildContext extension)             ← 便捷访问器
```

### 获取颜色的正确方式

```dart
// 方式 1：从 ColorScheme 获取（推荐用于通用场景）
final cs = Theme.of(context).colorScheme;
cs.primary          // 主题色（用户自定义，默认 0xFF5AAAC2）
cs.onSurface        // 表面文字色（深色模式 = 白色，浅色模式 = 深色）
cs.onPrimary        // 主题色上的文字色

// 方式 2：XMateColors 语义化 token（推荐用于面板/容器）
XMateColors.panelBg(context)     // 面板背景（自动应用用户透明度设置）
XMateColors.dialogBg(context)    // 对话框背景（始终不透明）
XMateColors.toolbarBg(context)   // 工具栏背景
XMateColors.cardFill(context)    // 卡片内填充
XMateColors.inputFill(context)   // 输入框填充
XMateColors.divider(context)     // 分隔线

// 方式 3：BuildContext 扩展（最简洁）
context.xmColors.panelBg
context.xmColors.textSecondary
context.xmColors.dividerColor
```

### 颜色对照表

| 语义 | 深色模式值 | 浅色模式值 | 获取方式 |
|------|-----------|-----------|----------|
| 页面背景 | `0xFF1A1A2E` | `0xFFF0F2F5` | `XMateColors.pageBg(context)` |
| 面板背景 | `0x1A1A2E` + 用户 alpha | `0xFFFFFF` + 用户 alpha | `XMateColors.panelBg(context)` |
| 工具栏背景 | `0xCC1A1A2E` | `0xEEFFFFFF` | `XMateColors.toolbarBg(context)` |
| 对话框背景 | `0xFF1A1A2E` | `0xFFFFFFFF` | `XMateColors.dialogBg(context)` |
| 卡片填充 | `white.withAlpha(12)` | `black.withAlpha(8)` | `XMateColors.cardFill(context)` |
| 输入框填充 | `white.withAlpha(10)` | `black.withAlpha(6)` | `XMateColors.inputFill(context)` |
| 主文字 | `Colors.white` | `0xFF1A1A2E` | `cs.onSurface` |
| 次要文字 | `white.withAlpha(179)` | `black.withAlpha(179)` | `cs.onSurface.withAlpha(179)` |
| 暗淡文字 | `white.withAlpha(97)` | `black.withAlpha(97)` | `cs.onSurface.withAlpha(97)` |
| 禁用文字 | `white.withAlpha(61)` | `black.withAlpha(61)` | `cs.onSurface.withAlpha(61)` |
| 强调色 | 用户自定义（默认 `0xFF5AAAC2`） | 同深色 | `cs.primary` |

### 禁止的写法

```dart
// ❌ 禁止
Color(0xFF5AAAC2)            // 硬编码主题色
Color(0xFF80D8FF)            // 硬编码强调色
Color(0xDD1A1A2E)            // 硬编码面板背景
Colors.white                 // 硬编码文字色（假设深色背景）
Colors.white70               // 硬编码文字色
Colors.white24               // 硬编码禁用色
const Color(0x33FFFFFF)      // 硬编码分隔线

// ✅ 正确
cs.primary                   // 主题色
cs.onSurface                 // 自适应文字色
XMateColors.panelBg(context) // 自适应面板背景
cs.onSurface.withAlpha(179)  // 次要文字
cs.onSurface.withAlpha(61)   // 禁用态
cs.onSurface.withAlpha(51)   // 分隔线
```

### 例外（保持硬编码的颜色）

- **标注工具预设色**：`Colors.red/orange/green/blue/purple/white/black`（用户可选的颜色值，非 UI 主题色）
- **语义色**：`Colors.redAccent`（错误状态）、`Colors.red.withAlpha()`（擦除按钮）
- **调色板**：颜色选择器中的 20 种 Material 预设色
- **调试叠加层**：`Color(0xAA00FF00)`（绿色调试框）

### 三个入口的一致性

| 入口 | 文件 | 主题初始化 |
|------|------|-----------|
| 主应用 | `lib/app.dart` | `ThemeService().init()` in `initState` |
| QuickLook 子进程 | `lib/main.dart` | `SettingsService().init()` + `ThemeService().init()` before `runApp` |
| 屏幕录制子进程 | `lib/main.dart` | 同上 |

### WebView2 主题适配

需要 WebView2 渲染的内容（代码/Markdown/邮件/EPUB），通过 `ThemeService().effectiveBrightness` 判断当前明暗，向 HTML 注入对应的 CSS 变量：

```dart
final isLight = ThemeService().effectiveBrightness == Brightness.light;
// 传递给 _buildHtml(bodyHtml, isLight: isLight)
// CSS 中使用 ${isLight ? '#FFFFFF' : '#1A1A2E'} 双值插值
```

## 性能约束

- 避免在 `build()` 中执行耗时操作
- 大图片加载使用异步
- 空闲时内存占用 < 50MB
