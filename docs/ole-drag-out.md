# OLE 拖出 (Drag Out) 模块

> Debug tab 最小验证模型已通过。以下为实测结论，后续拖拽交互设计以此为准。

## 已验证可行：三种数据类型

| 数据类型 | 说明 | C++ 格式 | 是否能拖到桌面/Explorer | 是否能拖到其他软件 |
|----------|------|----------|------------------------|-------------------|
| **File** | 文件路径 | `CF_HDROP` | ✅ 是 | ✅ 是 |
| **Image** | 图片文件 → 位图 | `CF_DIB` + `CF_HDROP` | ✅ 是 | ✅ 是 |
| **Text** | 纯文本字符串 | `CF_UNICODETEXT` | ❌ 否（桌面/Explorer 不接受纯文本 drop） | ✅ 是 |

## 不可行：路径字符串

- **路径作为文本（`C:\foo\bar.txt`）不能拖到桌面/Explorer** — Explorer 需要 `CF_HDROP` 格式（`DROPFILES` 结构体），不接受 `CF_UNICODETEXT` 格式的路径字符串
- 如果要让"路径文本"可拖到 Explorer，必须将其包装为 `CF_HDROP`（即 File 模式），不能当作文本

## 架构

```
Dart GestureDetector.onPanStart (鼠标按下+移动)
  → MethodChannel('com.xmate/dragout').invokeMethod('start', {mode, files/path/text})
    → C++ OleInitialize → MultiFormatDragData (IDataObject, 1-3 格式)
      → FileDragSource (IDropSource)
        → DoDragDrop(hwnd, data, src, COPY|MOVE|LINK, &effect)
          → 内部消息循环 → 用户释放 → DRAGDROP_S_DROP → result(true)
```

## 关键设计决策

1. **拖拽必须从 `onPanStart` 触发**，不能从 `onTap`/`onPressed`：`DoDragDrop()` 要求启动时左键处于按下状态，否则瞬间返回
2. **`OleInitialize(nullptr)`** 必须在调用线程执行（method channel handler 可能在不同线程，重复调用安全）
3. **必须传真实 HWND**（不能是 `nullptr`）— Explorer 通过它校验拖拽来源
4. **Image 模式同时提供 `CF_DIB` + `CF_HDROP`**：图片编辑器需要 `CF_DIB`（位图数据），Explorer/桌面需要 `CF_HDROP`（文件路径），双格式保证全目标兼容
5. **Text 模式只有 `CF_UNICODETEXT`**：桌面/Explorer 不是文本 drop target，文本只能拖到编辑器/聊天框等接受文本的应用

## 文件清单

| 文件 | 职责 |
|------|------|
| `windows/runner/native/drag_drop_handler.h` | `MultiFormatEnum` + `MultiFormatDragData` + `FileDragSource` + `StartDrag()` 声明 |
| `windows/runner/native/drag_drop_handler.cpp` | 完整实现（~370 行）：CF_HDROP 构建 / GDI+ → CF_DIB / CF_UNICODETEXT / DoDragDrop 入口 |
| `windows/runner/flutter_window.h` | `dragout_channel_` 成员 |
| `windows/runner/flutter_window.cpp` | `com.xmate/dragout` channel 注册（3 mode handler） |
| `lib/ui/settings/settings_page.dart` | Debug tab 测试 UI：File/Image/Text 三模式 + `_debugDragOut()` |

## 依赖

- `gdiplus.lib`（Image → CF_DIB 转换）
- 无 Dart 新增依赖
