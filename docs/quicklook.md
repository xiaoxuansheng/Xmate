# QuickLook 快速预览模块

> 独立进程预览窗口。用户资源管理器选中文件 → Alt+Q → 新 `xmate.exe --quicklook <path>` 进程。
> 详细架构见 `docs/architecture.md`。

## 目录结构

```
lib/
├── core/quicklook/
│   ├── quicklook_palette_state.dart    ← 主进程↔子进程 IPC（JSON 文件）
│   └── quicklook_utils.dart            ← 公共工具（V2.5.10 新增）
│       ├── fileSizeStr / fileTimeStr   ← 文件大小/时间格式化（统一 5 处重复）
│       ├── formatHotkey                ← 快捷键格式化（统一 4 处重复）
│       └── getSelectedFilePath()       ← 统一文件选中查询（palette → COM）
│
└── plugins/quicklook/
    ├── quicklook_plugin.dart           ← 插件元数据 + hotkey 默认值
    ├── quicklook_page.dart             ← 总控：_PreviewType 枚举路由 + 文件分类 + 轮询 + 标题栏
    ├── quicklook_settings.dart         ← 设置页（快捷键采集 + 格式列表）
    ├── quicklook_image_annotator.dart  ← 图片标注（编辑/裁剪/OCR/格式检测）
    ├── quicklook_eml_view.dart         ← EML 邮件预览（parser 已拆出）
    ├── quicklook_epub_view.dart        ← EPUB 电子书预览（ZIP reader 已拆出）
    │
    ├── parsers/                        ← 纯解析器（零 UI 依赖）
    │   ├── archive_parser.dart         ← ZIP/TAR/GZ 解析（u16le/u32le 公开）
    │   ├── eml_parser.dart             ← MIME 解析（RFC 2047/2045，从 eml_view 拆出）
    │   ├── epub_zip_reader.dart        ← EPUB ZIP reader（复用 archive_parser）
    │   └── image_utils.dart            ← computeBpp + detectImageFormat（从 annotator 拆出）
    │
    └── views/                          ← 所有 viewer + 共享控件
        ├── quicklook_office_view.dart  ← Word/PPT/Excel 三合一（IPreviewHandler，V2.5.10 合并）
        ├── quicklook_media_controls.dart ← 音频/视频共享（overlay + transport + keyboard，V2.5.10 新增）
        ├── quicklook_pdf_view.dart     ← PDF（缩略图 + 全页渲染 + 标注 + 搜索）
        ├── pdf_page_cache.dart         ← PDF 页面 LRU 缓存
        ├── quicklook_audio_view.dart   ← 音频播放器
        ├── quicklook_video_view.dart   ← 视频播放器
        ├── quicklook_text_view.dart    ← 纯文本查看器
        ├── quicklook_rich_view.dart    ← 代码/MD 高亮（WebView2）
        ├── quicklook_folder_view.dart  ← 文件夹列表
        ├── quicklook_fallback_view.dart ← 回退属性页
        ├── quicklook_hex_view.dart     ← 十六进制查看器
        └── quicklook_archive_view.dart ← 压缩包内容列表
```

## 架构

```
主进程（Alt+Q 热键触发）
  → COM getExplorerSelection (获取选中文件)
  → closeQuickLookWindows (关闭旧预览，保证单实例)
  → getSelectedFilePath() (palette state → COM，V2.5.10 统一)
  → Process.start("xmate.exe", ["--quicklook", path], detached)
                                         ↓
                        独立进程: main.cpp 检测 --quicklook
                          → 跳过 Mutex/托盘/服务
                          → FlutterWindow("quicklook", path)
                          → main.dart getStartupMode == "quicklook"
                          → QuickLookApp → QuickLookPage
                          → onReady → showNoActivate (SWP_NOACTIVATE)
                          → 400ms 轮询 Explorer 选中变化
```

## 原生文件清单（C++）

| 文件 | 职责 |
|------|------|
| `windows/runner/native/quicklook_helper.h/cpp` | COM Explorer 选中查询 + CloseQuickLookWindows |
| `windows/runner/native/office_preview_handler.h/cpp` | Office IPreviewHandler 子窗口嵌入（Word/PPT/Excel 通用） |
| `windows/runner/native/file_operations.h/cpp` | 文件操作 + `GetAudioProperties`(Media Foundation) |
| `windows/runner/main.cpp` | --quicklook 参数解析 + 新 FlutterWindow |
| `windows/runner/flutter_window.h/cpp` | `com.xmate/app` channel (getStartupMode) + `com.xmate/quicklook` channel + WM_ACTIVATE focus guard |
| `lib/main.dart` | QuickLookApp 类 + --quicklook 启动分支 + 子进程 spawn |

## 关键设计决策

1. **独立进程**：用 `io.Process.start(exe, args, mode: detached)` 启动独立 `xmate.exe --quicklook <path>`。每个预览完全独立于主进程，互不干扰。窗口类名 `"xmate_ql"`（CreateWindow 标题），用于 `CloseQuickLookWindows()` 关闭旧实例。
2. **不抢焦点**：
   - C++ `WM_ACTIVATE` handler：非 `WA_CLICKACTIVE` → `return 0` 静默吃掉
   - `WM_MOUSEACTIVATE` → `MA_ACTIVATE`（点窗口才激活）
   - Dart：`showNoActivate`（`SetWindowPos SWP_NOACTIVATE`）+ 不调 `setAlwaysOnTop`
3. **window_manager 可见性状态**：`waitUntilReadyToShow` 回调不调 `hide()`——否则 `_isWindowVisible=false` → 所有 API 短路。`_onReady` 先 `showNoActivate` 再 `windowManager.show()` 同步状态。
4. **单实例**：每次 Alt+Q 先 `CloseQuickLookWindows`（`EnumWindows` + `SendMessage(WM_CLOSE)` 同步关闭旧窗口），再 spawn 新进程。
5. **退出清理**：主进程 `onExit` 调 `closeQuickLookWindows` 清理子进程。
6. **GPU swapchain 重建**（V2.5.9）：QL 窗口初始化为 1×1，`showNoActivate` resize 到目标尺寸后 GPU swapchain 仍为 1×1 → 首次渲染空白（仅 Release 版本出现）。修复：`_onReady` 中 `showNoActivate()` 后立即 `forceChildRefresh()` 强制重建（同坑点 #19）。
7. **文件选中查询统一**（V2.5.10）：`getSelectedFilePath()` 合并了主进程和 QL 子进程中重复的 Palette state → Explorer COM 查询链，两处调用点均改为调用此函数。
8. **EML size tier 特殊处理**：`quicklook_eml_view.dart` 的 `_fmtSize` 仅支持 B/KB/MB 三档（无 GB），**不要**合并到通用 `fileSizeStr`。

---

## 音频预览（V2.5.4）

> 8 种音频格式播放预览，含完整快捷键控制、Media Foundation 元数据读取。

### 格式：mp3 / wav / flac / ogg / aac / m4a / wma / opus

### 窗口：440 × 200，固定大小

### UI 布局

```
┌─────────────────────────────────────────────────┐
│ 🎵  you.mp3                                      │  ← 文件名
│                                                  │
│  00:00 ───●────────────────────────── 03:45      │  ← 进度条 + 时间
│                                                  │
│  [🔁]   [1×]   [  ▶  ]   [🔊]   [ℹ️]           │  ← 按钮栏
│                                                   │
└─────────────────────────────────────────────────┘
```

| 按钮 | 图标 | 大小 | 功能 |
|------|------|------|------|
| 循环 | `Icons.repeat` | 32×32 | 切换 `ReleaseMode.loop`/`stop`，激活态蓝色边框 |
| 倍速 | 文字 1× | 32×32 | PopupMenu 向上弹出 6 选项 (0.5×~2×)，当前项蓝色 ✓ |
| 播放/暂停 | `Icons.play_arrow`/`pause` | 48×48 圆形 | 加载中显示 hourglass_empty |
| 音量 | `Icons.volume_up`/`down`/`off` | 32×32 | Overlay 弹出滑块，含静音切换 |
| 信息 | `Icons.info_outline` | 32×32 | Overlay 弹出 Codec / SR / Ch / Bitrate / Bit depth |

### 快捷键

| 键 | 操作 | 长按 |
|----|------|------|
| Space | 播放/暂停 | 否 |
| ← | 快退 1s | 是（KeyRepeatEvent 逐秒 seek） |
| → | 快进 1s | 是 |
| ↑ | 增大倍速（沿预设档位） | 是 |
| ↓ | 减小倍速 | 是 |
| Enter | 打开文件（`cmd /c start`） | 否 |

- `Focus(autofocus: true)` 包裹音频区，`KeyDownEvent` + `KeyRepeatEvent` 双通道
- Space/Enter 仅 `KeyDownEvent` 触发（防重复 toggle/多开）
- Enter 通过 `onOpenFile` 回调到父页面 `_openFile()`；父页面 `_onEnter()` 有 `_PreviewType.audio` guard

### 元数据读取（C++ Media Foundation）

```
Dart → com.xmate/fileops.getAudioProperties(path)
  → C++ GetAudioProperties()
    → MFStartup → MFCreateSourceReaderFromURL(file://…)
      → GetPresentationAttribute(MF_PD_DURATION)
      → GetCurrentMediaType(audio stream)
        → MF_MT_SUBTYPE → 20 种 GUID → 友好名
        → MF_MT_AUDIO_SAMPLES_PER_SECOND → sampleRate
        → MF_MT_AUDIO_NUM_CHANNELS → channels
        → MF_MT_AUDIO_BITS_PER_SAMPLE → bitsPerSample
        → MF_MT_AUDIO_AVG_BYTES_PER_SECOND → bitrate (×8)
    ↓ MF 失败
    → IShellItem2::GetPropertyStore (回退 Shell)
```

### 依赖：`audioplayers: 6.8.1` + `mfuuid.lib` / `mfplat.lib` / `mfreadwrite.lib`

---

## 视频预览（V2.5.4）

> 16 种视频格式播放预览，复用音频预览的全部快捷键和 UI 模式。

### 格式：mp4 / mkv / webm / avi / mov / wmv / flv / m4v / mpg / mpeg / 3gp / ts / vob / ogv

### 后端：**fvp**（mdk-sdk），注册为标准 video_player 平台实现，D3D11 硬件加速。

### 窗口：动态自适应 — 优先视频原始宽度，不足缩放到屏幕 98%，可超出 1/4 限制

### UI（与音频一致）

```
┌─────────────────────────────────────────┐
│ 🎬  video.mp4                            │
├─────────────────────────────────────────┤
│        ┌─────────────────────┐          │
│        │    VideoPlayer      │          │  ← AspectRatio 自适应
│        │   ▶ overlay on idle │          │     点击 = 播放/暂停
│        └─────────────────────┘          │
├─────────────────────────────────────────┤
│  00:00 ─●───────────── 05:30           │
│  [🔁]  [1×]  [  ▶  ]  [🔊]  [⛶]      │  ← 全屏替代信息按钮
└─────────────────────────────────────────┘
```

**与音频的差异**：
- ℹ️ 信息按钮 → ⛶ 全屏按钮（`Icons.fullscreen`/`fullscreen_exit`）
- 文件名在视频上方，无独立标题栏
- 视频区点击 = 播放/暂停

### 窗口尺寸逻辑

```
_init → 480×360 (default)
  → VideoPlayerController.initialize()
    → onVideoSizeReady(naturalSize) → resize to video w + 130px bar
全屏: onFullscreenToggle(true) → onVideoSizeReady(null) → 屏幕 98%
退出: onFullscreenToggle(false) → onVideoSizeReady(_videoNaturalSize) → 恢复
```

- `_onVideoSizeReady` 在 `quicklook_page.dart` 中，通过 `widget.onReady(size)` 调 C++ `showNoActivate` resize
- `_videoNaturalSize` 保存恢复尺寸

### 快捷键（与音频一致）

| 键 | 操作 | 长按 |
|----|------|------|
| Space | 播放/暂停 | 否 |
| ← → | 快退/快进 1s | 是 |
| ↑ ↓ | 增减倍速 | 是 |
| Enter | 打开文件 | 否 |
| Esc | 退出全屏 | 否 |

### 依赖：`fvp: 0.37.2` + `video_player: 2.11.1`（mdk-sdk 解码）

---

## 共享控件（V2.5.10）

音频和视频的 Overlay / Transport / Keyboard 已提取到 `views/quicklook_media_controls.dart`：
- `QuickLookMediaOverlay` mixin — showOverlay / refreshOverlay / removeOverlay / popupScaffold / infoRow
- `QuickLookMediaTransportBar` — 无状态按钮行 Widget（loop / speed / play / volume / info），通过回调注入差异
- `mediaHandleKey()` — 键盘快捷键处理函数（Space/←→/↑↓/Enter）
- `mediaTimeStr()` — Duration → MM:SS 格式化
- `nextSpeed()` / `prevSpeed()` / `seekRelative()` — 速度步进 / 相对 seek

音频和视频各自的播放器对象（AudioPlayer / VideoPlayerController）和具体 _togglePlayPause / _seek / _buildVolumeOverlay / _buildInfoOverlay 仍保留在各自的 view 里。

---

## Office 预览（V2.5.10 三合一）

> Word/PPT/Excel 三种格式，通过原生子窗口嵌入 Windows `IPreviewHandler`。
> V2.5.10 将原先独立的 `QuickLookWordView`/`QuickLookPptView`/`QuickLookExcelView`
> 合并为 `views/quicklook_office_view.dart` 中的 `QuickLookOfficeView`。
> C++ `office_preview_handler` 通过 `AssocQueryString` 按扩展名动态解析 CLSID，
> Dart 端零差异化逻辑。

### 格式：doc/docx/docm + ppt/pptx/pptm + xls/xlsx/xlsm

### 架构

```
Dart QuickLookOfficeView（状态机: creating→ready→error）
  → MethodChannel('com.xmate/officepreview')
    create(...) → C++ CreateWordPreview
      → AssocQueryString → CLSID → CoCreateInstance(IPreviewHandler)
      → IInitializeWithFile → Initialize
      → CreateWindowEx(WS_CHILD) → SetWindow → SetRect → DoPreview
      → CoMarshalInterface(handler) → wl_marshal.bin
      → WM_COPYDATA → 主进程 KeepWordHandlerAlive
        → CoUnmarshalInterface → proxy → g_pool (120s)
    setRect(...)→ C++ MoveWindow + handler->SetRect
    destroy(...)→ C++ Unload + DestroyWindow (不 Release — 主进程代理保活)
```

### 窗口层级

```
Top-level HWND (WS_POPUP, "xmate_ql")
  ├── FLUTTERVIEW (子窗口, Flutter 渲染 title bar)
  └── XMateWordPreview (子窗口, WS_CHILD, 覆盖内容区)
       承载 IPreviewHandler 渲染
```

### 关键设计决策

1. **原生子窗口嵌入** — `CreateWindowEx(WS_CHILD)` 创建兄弟窗口覆盖 Flutter 内容区。可滚动/选文字/Ctrl+C（取决于系统 handler）。
2. **COM marshal 跨进程 keep-alive** — `CoMarshalInterface` 序列化 handler → `WM_COPYDATA` 传主进程 → `CoUnmarshalInterface` 反序列化（<1ms，指向同一 Word server）。主进程代理保持 120s → QL 进程退出后 server 不关机 → 下次 Alt+Q 秒出预览。`DestroyWordPreview` 不 Release COM 引用。
3. **实例 pool** — `std::unordered_map<int64_t, WordPreviewInstance>` + 单调递增 handle。
4. **回退策略** — `check` 返回 false 或 `create` 返回 0 → `_toFallback()` → `QuickLookFallbackView`。
5. **rect 同步** — Flutter 主动在 `postFrameCallback` 中计算坐标，仅变化 ≥1 物理像素才调 `setRect`。
6. **启动优化** — `_doLoad` 已做 registry check，Widget 直接创建。
7. **打开文件** — 标题栏 Open 按钮调用 `_openFile()`（`cmd /c start`）。

### 文件清单

| 文件 | 职责 |
|------|------|
| `lib/plugins/quicklook/views/quicklook_office_view.dart` | Word/PPT/Excel 三合一预览组件（V2.5.10 合并） |
| `lib/plugins/quicklook/quicklook_page.dart` | 分发：3 case fall-through → `QuickLookOfficeView` |
| `windows/runner/native/office_preview_handler.h` | 接口：`IsWordPreviewAvailable` / `CreateWordPreview` / `SetWordPreviewRect` / `DestroyWordPreview` |
| `windows/runner/native/office_preview_handler.cpp` | 实现：COM `IPreviewHandler` 生命周期 + child HWND + instance pool |
| `windows/runner/flutter_window.cpp` | channel 注册：`com.xmate/officepreview`（4 method） |

### 依赖：无新增（复用 `shell32.lib` / `ole32.lib`）
