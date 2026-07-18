# LibreTranslate 模块

> 离线翻译引擎，基于 LibreTranslate HTTP API + ArgosTranslate 模型。

## 文件清单（`lib/plugins/translate/`）

| 文件 | 职责 |
|------|------|
| `translate_service.dart` | LibreTranslate HTTP 客户端：`TranslateResult` + `translateWithDetail()` (类型化错误) + `translate()` (向后兼容) + `fetchLanguages()` + `kLangNamesZh`/`langNameZh()` |
| `translate_page.dart` | 翻译窗口 UI：文本翻译 + 多文件队列翻译 + 拖拽接收 + Open/Save/As 按钮 |
| `translate_settings.dart` | 设置页：安装/卸载 + 服务器管理 (Start/Stop) + 模型管理 (配对互译组) |
| `translate_plugin.dart` | 插件注册 + 命令 `translate.open` |
| `server_manager.dart` | 子进程生命周期：`Process.start` libretranslate → PID 文件 → 健康轮询 → `taskkill` |
| `model_manager.dart` | Dart ↔ Python 脚本通信：`listInstalledPairs()`/`listAvailablePairs()`/`installPair()`/`uninstallPair()` + pip install/uninstall |

## 外部文件

| 文件 | 职责 |
|------|------|
| `scripts/translate_model_manager.py` | JSON-line 脚本：模型安装/卸载/列表/SBD 预加载 + 正则降级 |
| `scripts/download_minisbd.py` | 一次性下载全部 MiniSBD ONNX 模型 (~7.7MB) |
| `scripts/start_translate_server.bat` | 手动启动 LibreTranslate 服务器 |

## 架构

```
Dart UI
  ├─ TranslateService (HTTP POST /translate)
  ├─ ServerManager (Process.start libretranslate)
  └─ ModelManager (Process.run translate_model_manager.py)
       └─ argostranslate.package API
```

## 关键设计

- **URL 统一**：`ServerManager.host/port/baseUrl` 从 `translate.serverUrl` 解析（`Uri.parse`）
- **互译组配对**：`PairedModel`/`PairedAvailable` — en↔zh 合并为一条，英语始终放后面
- **语言中文名**：`kLangNamesZh` (49 种) + `langNameZh()` 函数
- **MiniSBD 降级**：三层策略 — ① 正则降级注入 ② 内嵌目录复制 ③ GitHub 下载
- **拖拽集成**：`com.xmate/dragdrop` channel → 文本填入 / 文件批量入队
- **文件子菜单**：`FileActionKind.translateFile` — 仅支持扩展名可见

## OCR 翻译接入（V2.2.0）

- `screenshot/integration/translate_service.dart` 重写为 HTTP API 调用
- 翻译面板标题栏增加源/目标语言下拉（源含 auto，目标默认中文）
- 切换语言自动重译，无需二次确认
- 原位 OCR 文字在翻译模式下替换为译后文本
- 旧 Marian ONNX 方案封存：C++ 代码保留，Dart 不再调用 `com.xmate/translate`
