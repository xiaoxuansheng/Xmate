# File Search 模块

> 文件搜索引擎，基于 trigram 索引 + 优先级规则评分。

## 索引格式 (.xmfi + .xmfs)
- `.xmfi` = header(14B) + entry table(16B/entry) + name trigram index + pinyin trigram index + CRC32(4B)
- `.xmfs` = raw null-terminated UTF-8 string pool (name\0ext\0path\0 per entry)
- 增量段 = `{hash}_N.xmfi` + `{hash}_N.xmfs` (N=1,2,3...)

## 搜索流程（V2.1.0）
- Phase A: trigram 搜索 (zero decode) → preScore → TopK 200
- Phase B: TopK decode + ext/path/regex filter + PriorityRule(13条) + 评分 + 前缀过滤 + 去重 + 补位到 20
- 已删除 denyExtensions/ignoreRegex/preferRegex/preferExtensions 检查，统一由 PriorityRule 管理

## 更新策略（V2.1.0）
- **Rebuild**: C++ `ScanDirectoryAsync`（`std::thread` 后台）→ Isolate 全量构建 → 覆盖 base
- **Update**: C++ `QueryUsnWithDirsAsync`（`std::thread` 后台）→ dirtyDirs/deletedDirs/renamedDirs → 增量段构建
- 目录重命名：旧名 → D| 前缀立即屏蔽；新名 → 空 segment 加速 compaction
- S|/D| 空前缀不再写入 del 文件（修复根目录直接子目录被误过滤）
- Compaction: 增量段 ≥ 5 → 全量重建
- 阈值: dirtyDirs > 10k → 回退到全量 Rebuild

## 前缀过滤规则
- `S|dir/` (Superseded): 仅过滤 base(priority=0) 中 dir/ 的**直接子文件**，子目录不过滤
- `D|dir/` (Deleted): 过滤所有 segment 中 dir/ 整棵子树
- 前缀存储在 `{hash}_del.txt`

## 过滤器（V2.1.0 重构）
- 进入：键入空格 + 第一词匹配已知 filter → 进入 filter 模式（唯一触发条件）
- 退出：Backspace + text == `keyword ` → KeyEvent 吞键 → 文本保持 `keyword ` → 退出
- 空格后无内容显示 placeholder + filter header，不触发搜索
- 已删除 `_scanWithFilter()` 全表扫描，filter 内搜索与普通模式相同（trigram + filter 检查）
- 5 个内置：`folder`/`doc`(55 exts)/`pic`(17)/`video`(61)/`audio`(36)
- 自定义过滤器：keyword/name/path/extensions/regex，持久化到 `app.filesearch.customFilters`
- 模型：`lib/core/search/file_search_filter.dart`
- 设置 UI：File Search → Filters 子标签

## 评分机制（V2.1.0）
- 公式：`score = pm*0.35 + nm*0.30 + depthTable[depth] + recent*0.20`，然后 `× prMultiplier + prBonus`
- Depth 查表：`[0.05, 0.029, 0.024, 0.021, 0.019, 0.018]`，6 层封顶
- 已移除：`denyExtensions` / `preferExtensions` / `ignoreRegex` / `preferRegex`（由 PriorityRule 替代）

## 优先级规则（V2.1.0）
- 三档：`prefer` (+0.50) / `uncommon` (×0.3) / `exclude` (continue)
- Prefer 和 Uncommon 可叠加：同时命中 = `×0.3 + 0.50`
- 13 条默认规则：Start Menu prefer ×1 + 系统目录 uncommon ×8 + 文件名 regex uncommon ×4
- `search()` decode 循环遍历全部规则，exclude 最高优先
- 持久化到 `app.filesearch.priorityRules`，无存储时种子默认
- 模型：`lib/core/search/file_search_priority.dart`
- 设置 UI：File Search → Priority 子标签（含 Rules 按钮展示公式和规则说明）

## 子菜单（V2.0.0）
- 方向右键 / 鼠标右键 on FileResultEntry → 进入子菜单（双缓冲模式，复用搜索子菜单架构）
- 9 个内置操作：打开所在文件夹/复制路径/复制(C++ CF_HDROP)/剪切/创建快捷方式/删除(回收站)/属性/固定到开始/以管理员打开
- 自定义 action：Title/Shortcut/Path(文件选择器)/Args({file})/Admin/Silent
- 快捷键采集 + 全局热键执行
- 原生 C++ 文件操作：`windows/runner/native/file_operations.cpp/h` — `com.xmate/fileops` channel
- 设置 UI：File Search → Submenu 子标签
- 模型/服务：`lib/core/command/file_submenu_item.dart` + `file_submenu_service.dart`

## 管理员权限与开机自启（V2.2.0）
- ❌ 已移除 `wWinMain` 自检 `TokenElevation` + `ShellExecuteEx(runas)` 重新启动 — 不再以管理员权限运行主进程
- 开机自启通过 Task Scheduler（`CLSID_TaskScheduler`）：`TASK_RUNLEVEL_LUA`（普通权限），`TASK_TRIGGER_LOGON`
- 所有管理员操作按需提权：`ShellExecuteExW(runas)` 启动新进程 → UAC → 执行 → 退出（见 `docs/pitfalls.md` #12）

## 打开历史优先（V2.0.0）
- `_openFile()` 和 `file_submenu_service.execute()` 调用 `markOpened()`
- `_recentOpenSet` 记录最近 256 条打开路径，搜索评分 +0.20

## 默认索引目录（V2.0.0）
- 首次运行种子：桌面/下载/文档/Start Menu（通过 env vars）+ 非 C: 盘符

## 依赖

> ✅ WinRT OCR 已卸载，PP-OCRv6 引擎在 `onnx_ocr_engine.cpp`。
> ONNX Runtime 依赖：`onnxruntime.dll` (~15MB) + 3 个 OCR `.onnx` 模型 (~21MB) + 2 个翻译 `.onnx` 模型 (~553MB) + `vocab.json` + `shared_vocab.txt` + `ppocrv6_dict.txt`。
> MarianMT 模型（`translate_encoder.onnx`/`translate_decoder.onnx`）**已封存**——代码保留不动，但 OCR 翻译已改用 LibreTranslate HTTP API。
