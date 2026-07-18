# XMate 架构设计

> 版本：v2.0 | 更新：2026-07-03

## 设计理念

XMate 是**插件宿主平台**。核心框架提供基础设施，业务功能以插件形式独立存在。

**核心原则**：核心与业务分离 / 插件自治 / 协议驱动 / 渐进增强

## 架构分层

```
┌─────────────────────────────────────────────┐
│                  XMate 核心                   │
│  系统托盘 │ 命令面板 │ 快捷键管理器 │ 插件注册  │
│  设置管理 │ 窗口管理器 │ 文件搜索   │ 事件总线   │
│  主题服务 │ 色彩令牌                             │
│                                             │
│  ┌──────────┐ ┌──────────┐ ┌────────────┐  │
│  │截图插件   │ │翻译插件   │ │QuickLook   │  │
│  │(标注+录制) │ │(LibreTranslate)│(文件预览)│  │
│  └──────────┘ └──────────┘ └────────────┘  │
└─────────────────────────────────────────────┘
```

## 核心模块职责

| 模块 | 职责 | 关键文件 |
|------|------|----------|
| 系统托盘 | 后台常驻、托盘菜单 | `core/tray/`, `native/tray_icon.cpp` |
| 命令面板 | 浮动输入框、模糊搜索、命令执行 | `core/command/command_palette.dart` |
| 快捷键 | 全局注册/分发，**插件禁止自行注册** | `core/hotkey/` |
| 插件注册 | 发现、加载、生命周期管理 | `core/plugin/` |
| 设置服务 | JSON 持久化，插件隔离 | `core/settings/` |
| 窗口管理 | WS_POPUP 窗口、showFloating/showFullscreen | `core/window/` |
| 主题服务 | 深色/浅色/跟随系统，自定义主题色+透明度 | `core/theme/` |
| 色彩令牌 | XMateColors + BuildContext 扩展，统一颜色入口 | `core/theme/theme_colors.dart` |
| 文件搜索 | trigram 索引、USN 增量更新 | `core/search/` |
| 事件总线 | 插件间松耦合通信 | `core/event/` |

## 数据流

```
用户操作 → 快捷键/命令面板 → 插件路由 → 插件处理 → UI窗口 / 文件操作 / 事件广播
```

## 当前状态

4 个已安装插件：Screenshot（含 Screen Recording）、Translate、QuickLook、File Search

详见各模块开发文档：`docs/quicklook.md`、`docs/file-search.md`、`docs/screenshot-annotate.md`、`docs/libretranslate.md`
