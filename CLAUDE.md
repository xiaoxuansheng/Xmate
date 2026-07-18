# CLAUDE.md — XMate 项目 AI 助手指引

> 本文件为 AI 助手提供项目上下文和**必须遵守**的关键约束。模块开发细节见 `docs/` 目录。

## 项目概要

**XMate** = Windows 私人助理工具合集 App。Flutter 框架，插件化架构，命令面板 + 快捷键驱动。当前版本 **V3.4.0**（双引擎 OCR：PP-OCRv6 中文 + WinRT 英文，GitHub 在线更新）。

## 环境说明

协作工具为 **Claude Code**，实际模型为 **DeepSeek V4 Pro**。

## 工作规范

### 修改前
1. **备份 `lib/`** → `lib_bak_v{N}_YYYYMMDD_HHMMSS`（`cp -r lib lib_bak_v{N}`）
2. 专注于当前问题，只在必要时读取 devlog / test list / 相关 docs
3. 制定 todo 清单，只改当前问题
4. **禁止用 Agent 做问题分析/原因定位** — Agent 分析效果极差，直接自己读代码分析。Agent 仅用于简单代码查找（如搜索某个关键字出现在哪些文件）
5. **禁止用 Workflow** — 当前模型为 DeepSeek V4 Pro，不支持 Workflow 所需的语法

### 修改后
1. **更新 `test list.md`**：一句话总结本轮改动 + 改动文件列表 + 核心测试项 3-5 条（只写本轮差异，已验证的不重复），删除之前版本内容，只保留当前版本list
2. **开发日志和模块文档只在稳定版本统一整理**，不每轮更新
3. 变更技术依赖时同步 `docs/tech-stack.md`

### 版本号规范
- **前两位（X.Y）由用户决定**，AI 不得擅自变更
- **第三位（补丁号）每轮修复后自动递增**
- 备份目录、test list 中的版本号必须一致

### 每周 Bug 更新阶段

- **逐条处理**：用户逐条给出 bug/优化项，每次只处理当前一条
- **最小改动**：只动相关代码，不读取无关文件；遇到底层问题要彻底解决根因，不采用补丁式修补
- **修改前备份**：`cp -r lib lib_bak_v{N}_YYYYMMDD_HHMMSS`
- **修改后更新 test list**：一句话总结本轮改动 + 改动文件列表 + 核心测试项 3-5 条
- **版本号**：每条 bug 修复后补丁号自动递增（如 3.2.0 → 3.2.1 → 3.2.2 ...）
- **禁止 Agent/Workflow**：同样适用

### 遇到不确定时
- 停下来问用户，不要猜测
- 涉及架构变更，先更新方案文档再执行

## 文档路径指引

| 类型 | 路径 |
|------|------|
| 📋 需求 / 🏗️ 架构 / 🔧 技术栈 | `docs/requirements.md` / `architecture.md` / `tech-stack.md` |
| 📇 功能文件索引（快速定位） | `docs/file-index.md` |
| 📝 代码规范（含主题规范） / 📁 目录结构 / 🔌 插件协议 | `docs/code-standards.md` / `project-structure.md` / `plugin-protocol.md` |
| 🔄 开发流程 / 🛠️ 环境搭建 | `docs/development-workflow.md` / `environment-setup.md` |
| 🪟 QuickLook 预览 | `docs/quicklook.md` |
| 🔍 File Search | `docs/file-search.md` |
| ✏️ 截图标注 | `docs/screenshot-annotate.md` |
| 🌐 LibreTranslate | `docs/libretranslate.md` |
| 🧩 插件独立窗口 | `docs/plugin-independent-window.md` |
| 🖱️ OLE 拖出 | `docs/ole-drag-out.md` |
| ⚠️ 坑点详解 | `docs/pitfalls.md`（完整 27 条） |

## 关键约束

- **平台**：Windows 11，目标 Win10+，后续 iOS/Android
- **框架**：Flutter 3.44.1，Dart 3.12.1（SDK 约束 `^3.12.1`）
- **状态管理**：Riverpod
- **架构模式**：插件化（核心与业务分离）
- **UI 风格**：极简，命令面板模式
- **颜色方案**：`ThemeService`（单例 ChangeNotifier）+ Material 3 `ColorScheme.fromSeed()` + `XMateColors` token 体系
  - **禁止硬编码颜色** — 所有颜色通过 `Theme.of(context).colorScheme` 或 `XMateColors.*` 获取
  - 主题模式：Dark / Light / Follow Windows（设置键 `app.theme.mode`）
  - 自定义主题色：6 预设 + 自定义 HEX（设置键 `app.theme.accentColor`，默认 `0xFF5AAAC2`）
  - 面板透明度：用户可调 20-100%（设置键 `app.theme.backgroundOpacity`，默认 87）
  - Scaffold 始终 `Colors.transparent`
  - 完整规范见 `docs/code-standards.md` 主题与颜色规范章节
- **性能**：空闲内存 < 50MB，冷启动 < 2s

## 窗口状态机（重要！不要破坏！）

```
┌──────────┬──────────┬──────────────────────────────────┐
│   状态    │   大小    │              操作                │
├──────────┼──────────┼──────────────────────────────────┤
│ 初始化    │   1×1    │ C++ SetNextFrameCallback         │
│          │          │ → SetWindowPos 1×1               │
│          │          │ → SWP_SHOWWINDOW                 │
│          │          │ → Dart waitUntilReady            │
│          │          │ → setAlwaysOnTop + hide          │
├──────────┼──────────┼──────────────────────────────────┤
│ 隐藏     │  (任意)   │ hide()                           │
├──────────┼──────────┼──────────────────────────────────┤
│ 命令面板  │ 540×420  │ showFloating() → 居中偏上浮窗    │
├──────────┼──────────┼──────────────────────────────────┤
│ 截图标注  │   全屏    │ setFullScreen + show()           │
├──────────┼──────────┼──────────────────────────────────┤
│ 设置页   │   全屏    │ showOverlay() → 全屏（同截图标注）│
├──────────┼──────────┼──────────────────────────────────┤
│ QuickLook│ 自适应    │ 独立进程 xmate.exe --quicklook    │
│(独立进程) │          │ showNoActivate + poll 400ms      │
└──────────┴──────────┴──────────────────────────────────┘
```

### 四条铁律
1. **窗口样式 `WS_POPUP`** — C++ 创建即无边框，永不恢复 `WS_OVERLAPPEDWINDOW`
2. **命令面板浮窗化** — 用 `showFloating()`，不阻塞桌面交互
3. **关闭只 `hide()`** — 不 pop 路由，不切换状态
4. **独立窗口不 hide() + 不 setAlwaysOnTop** — waitUntilReadyToShow 回调保持显示

## 核心架构要点

- **app.dart**：窗口内容完全由 `XMateAppState._overlay` 控制，`setState` 切换（不是 Navigator push/pop）
- **window_manager.dart**：`WindowService` 只暴露 `showFloating` / `showFullscreen` / `hideWindow` / `dispose`
- **main.dart**：入口，初始化顺序 = 设置 → 窗口 → 注册插件 → 热键(从 settings 加载) → 托盘 → runApp
- **快捷键**：由 `main.dart` 统一注册后分发，**禁止插件自行注册快捷键**
- **管理员权限**：XMate 始终普通权限运行。需要提权时 `ShellExecuteExW(runas)` 启动新进程（见 `docs/pitfalls.md` #13）

## 关键坑点（共 11 条核心约束，完整 27 条见 `docs/pitfalls.md`）

| # | 规则 | 违反后果 |
|---|------|----------|
| 1 | **禁止插件自行注册快捷键**，由 main.dart 统一注册 | 崩溃 |
| 2 | **含中文的 C++ 文件必须 UTF-8 BOM 编码** | MSVC C4819 编译错误 |
| 3 | **Enter 必须走 `TextField.onSubmitted`**，禁止 `_handleEarlyKey` 直接 `_exec()` | IME 状态残留，`onSubmitted` 永不触发 |
| 4 | **窗口样式 WS_POPUP，永不恢复 WS_OVERLAPPEDWINDOW** | 外围边框回来 |
| 5 | **Dart→C++ 路径必须 `/` → `\` 归一化**；C++→Dart 转回 `/` | Windows API 静默失败 |
| 6 | **overlay 切换：先 `onClose()` 关闭当前，下一帧 `addPostFrameCallback` 打开新** | 新窗口闪一下后消失 |
| 7 | `showOverlay(AnnotatePage)` + 首帧后调用 `forceChildRefresh()` | GPU swapchain 停留在旧尺寸 |
| 8 | `refitWindow` 每个 `await` 后检查 `_windowGeneration` 令牌 | 截图后窗口被缩回 540×48 |
| 9 | C++ 必须 `Show()` 一次窗口让 Flutter 引擎初始化 | 命令面板渲染为空 |
| 10 | 剪贴板图片用 `CF_DIB`（非 `CF_BITMAP`）+ PNG 双通道 | 跨进程粘贴失败 |
| 11 | 管理员操作走 `ShellExecuteExW(runas)` 启动新进程 | 无法临时提权 |

## 模块文档索引

需要开发或修改对应模块时，先读取对应文档：

| 模块 | 文档 |
|------|------|
| 主题系统 & 颜色规范 | `docs/code-standards.md`（主题与颜色规范章节） |
| QuickLook 预览 | `docs/quicklook.md` |
| File Search | `docs/file-search.md` |
| 截图标注 | `docs/screenshot-annotate.md` |
| LibreTranslate | `docs/libretranslate.md` |
| 插件独立窗口 | `docs/plugin-independent-window.md` |
| OLE 拖出 | `docs/ole-drag-out.md` |

## 启动检查

```bash
cd /path/to/XMate
flutter build windows --debug        # 编译
./build/windows/x64/runner/Debug/xmate.exe  # 启动
```
