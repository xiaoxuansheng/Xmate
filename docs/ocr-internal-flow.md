# XMate OCR 内部流程（含坐标变换链）

> V1.8.2 | 2026-06-19

---

## 一、整体管道

```
用户触发 OCR（工具栏按钮 / 键盘 T）
  │
  ├── Step A: Dart 端 crop PNG
  │
  ├── Step B: MethodChannel → C++ 引擎
  │
  ├── Step C: C++ PP-OCRv6 检测+识别
  │
  ├── Step D: C++ 结构分析（PP-StructureV3 ONNX 或几何兜底）
  │
  ├── Step E: C++ BuildFullText（Markdown 生成）
  │
  └── Step F: Dart 接收 JSON → 渲染浮动面板
```

---

## 二、坐标变换链（关键！）

### 坐标空间一览

| 空间 | 来源 | 范围 | 说明 |
|------|------|------|------|
| **物理截图像素** | C++ `captureFullScreen` | `monW×monH` (含 DPR) | `captureDpr=1.5` → 2880×1620 |
| **Flutter 逻辑像素** | `MediaQuery.size` | `monW/dpr × monH/dpr` | widget 坐标系，GestureDetector 返回此坐标 |
| **选区 `_sel`** | 用户拖拽/自动吸附 | 逻辑像素 | 对用户可见的蓝色选框 |
| **C++ 引擎输入像素** | `_encodePngCrop` 裁切后 | `cropW×cropH` | **OCR 内部所有坐标以此为准** |
| **V3 模型输入** | `bilinearResize → 800×800` | 固定 800×800 | 预缩放后送 ONNX |
| **V3 模型输出** | `fetch_name_0 [N,7]` | 800×800 归一化 | 需 *scaleX/scaleY 回原图 |

### 变换链

```
┌──────────────────────────────────────────────────────────────────────────┐
│ (A) 全屏截取                                                             │
│                                                                          │
│  C++ BitBlt → PNG (monW×monH 物理像素) + dpr + monitor rect              │
│  例: monitor=2560×1440, dpr=1.5 → PNG=3840×2160 px                       │
│                                                                          │
│  Flutter 解码: _img (3840×2160 ui.Image)                                 │
│  Widget 尺寸:  ws = MediaQuery.size = 2560×1440 (逻辑像素)               │
│  缩放比:       sx = _img.width  / ws.width  = 3840/2560 = 1.5 = dpr      │
│                sy = _img.height / ws.height = 2160/1440 = 1.5             │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ (B) 选区 → 图像像素 crop                                                 │
│                                                                          │
│  _sel = Rect(L,T,R,B)   ← 逻辑坐标                                       │
│  cropR = Rect(                                                           │
│    L * sx,    T * sy,                                                    │
│    W * sx,    H * sy,                                                    │
│  )  ← 物理像素（crop 图像内坐标）                                        │
│                                                                          │
│  _encodePngCrop: PictureRecorder draw + toImage → PNG bytes              │
│  cropW = cropR.width.round()                                             │
│  cropH = cropR.height.round()                                            │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼  MethodChannel("com.xmate/ocr").recognize(pngBytes)
┌──────────────────────────────────────────────────────────────────────────┐
│ (C) C++: stbi_load → rgb[cropW × cropH × 3]                             │
│                                                                          │
│  **从此开始，所有坐标都以 cropW×cropH 为基准**                            │
│                                                                          │
│  检测:                                                                   │
│    PreprocessDet:                                                        │
│      max(cropW,cropH) > 960 ? scale = 960/maxDim : scale=1.0            │
│      bilinear resize → {newW,newH}                                       │
│      32 倍填充 → {paddedW, paddedH}                                      │
│      → [1,3,paddedH,paddedW] → det.onnx                                  │
│    PostprocessDet:                                                       │
│      invScale = (paddedW/outW) / scale  ← 这个公式把坐标映回 cropW×cropH │
│      box.x = minX * invScale, box.y = minY * invScale                    │
│                                                                          │
│  识别:                                                                   │
│    PreprocessRec: per-box crop + perspective warp → 48×N                 │
│    → rec.onnx CTCDecode → text                                           │
│                                                                          │
│  文本框坐标 = crop 图像像素，原点在 crop 左上角                            │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ (D) 结构分析（V3 模型路径）                                              │
│                                                                          │
│  AnalyzeStructureV3:                                                     │
│    预处理: bilinear resize(cropW×cropH → 800×800)                        │
│    推理:   image[1,3,800,800] + im_shape[cropH,cropW] + scale_factor     │
│           → fetch_name_0[N,7]                                            │
│    坐标映射 (V1.8.2 修复):                                               │
│      pixelX = reg.x * (cropW / 800)     ← 消除长宽比失真                 │
│      pixelY = reg.y * (cropH / 800)                                      │
│                                                                          │
│  **修复前 BUG**: 把 800×800 坐标当作 "pixel space" 不缩放                │
│    → region bbox (0-800) vs textBox bbox (0-cropW/H)                    │
│    → 不匹配 → boxes 落 catch-all → 阅读顺序错乱                           │
│                                                                          │
│  **修复后**: 仅固定 ×(cropW/800, cropH/800) 缩放                         │
│                                                                          │
│  框归属 3 阶段:                                                           │
│    Phase A: 中心点落入 region bbox (含 5% margin)                         │
│    Phase B: IOU > 0.05 最近邻匹配                                        │
│    Phase C: 中心距离 < 30% 对角线                                        │
│    catch-all: 合并到最近已有 paragraph → 最后才建独立 unit                │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ (E) BuildFullText                                                        │
│                                                                          │
│  按 readingOrder 遍历 StructureUnit:                                     │
│    段落: textBoxIndices 已排序(cy→cx) → y-overlap 检测同行/换行          │
│           → 同行空格, 换行 \n, 段间 \n\n                                 │
│    表格: cellTexts[row][col] → Markdown | col | + | --- |                │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼  JSON { fullText, blocks[], diag }
┌──────────────────────────────────────────────────────────────────────────┐
│ (F) Dart: OcrResult.fromJson → _buildOcrOverlay                         │
│                                                                          │
│  success 分支:                                                            │
│    Material(Container(Column(                                             │
│      Row(title + diag badge)           // 可拖拽标题栏                    │
│      if extra2 → Text(diag line2)      // 第二行 diag                    │
│      Expanded(SelectableText(fullText)) // 可选中/可滚动正文              │
│    )))                                                                   │
│                                                                          │
│  面板自动定位: _ocrPanelAutoRect(ws)                                     │
│    优先: right → below → left → above → center                          │
│    尺寸: pw = _sel.width, ph = _sel.height (逻辑像素)                    │
│                                                                          │
│  快捷键 (面板可见时):                                                     │
│    Ctrl+A → 全选文本                                                      │
│    Ctrl+C → 复制 fullText                                                │
│    Ctrl+S → 保存 .txt                                                    │
│    Esc    → 关闭面板, 切回鼠标工具                                        │
│    滚轮   → 滚动文本 (指针在面板内时)                                     │
└──────────────────────────────────────────────────────────────────────────┘
```

### 坐标转换速查表

| 转换 | 公式 | 常量 |
|------|------|------|
| 物理像素 → 逻辑像素 | `logical = physical / dpr` | dpr = 截图的 devicePixelRatio |
| 逻辑像素 → crop 像素 | `crop = (logical - sel.topLeft) * (imgSize / widgetSize)` | imgSize/widgetSize ≈ dpr |
| det 输出 → crop 像素 | `crop = det * (paddedW/outW) / scale` | paddedW=paddedH=32n, scale=960/maxDim |
| V3 800×800 → crop 像素 | `cropX = v3X * cropW / 800, cropY = v3Y * cropH / 800` | cropW, cropH = PNG 输入尺寸 |
| crop 像素 → JSON block | 直接输出 (crop 空间) | 与 input PNG 对应 |
| crop 像素 → 原图逻辑像素 | `logical = (crop + cropOffset) / dpr` | 不做 OCR UI, 仅 fullText |

---

## 三、C++ 引擎内部步骤

### Step 1: 解码 PNG

```cpp
uint8_t* raw = stbi_load_from_memory(pngBytes, &w, &h, &comp, 3);
// w, h = crop 图像尺寸（cropW, cropH）
// rgb = [w*h*3] uint8 buffer
```

### Step 2: 文本检测 (det.onnx)

```
PreprocessDet:
  maxDim = max(w,h), scale = 960/maxDim (if >960)
  newW = w*scale, newH = h*scale
  bilinear resize → pad to 32× multiple → paddedW×paddedH
  normalize: mean=[0.485,0.456,0.406], std=[0.229,0.224,0.225]
  → [1,3,paddedH,paddedW] float32

det.onnx inference → probability map [1, oh, ow]

PostprocessDet:
  threshold=0.3 → binary mask
  连通组件 (minArea=15)
  invScale = (paddedW/ow) / scale  ← key: maps back to crop space
  box.x = minX * invScale, box.y = minY * invScale
```

### Step 3: 文本框排序

```cpp
SortBoxes: y-center → x-center, with y-threshold = avgH * 0.5
```

### Step 4: 方向分类 (cls.onnx, optional)

```cpp
ApplyCls:
  提取 box axis-aligned crop → bilinear resize 48×192
  normalize: mean=0.5, std=0.5
  → [1,3,48,192] → cls.onnx → softmax 2-class
  prob180 > 0.9 → swap box corners (0↔2, 1↔3)
```

### Step 5: 文本识别 (rec.onnx)

```cpp
RecognizeBox:
  orderBoxCorners → perspective rectification (or axis-aligned fallback)
  bilinear resize → 48 × N  (N ∈ [8, 480], aspect-ratio-preserving)
  pad width to 8× multiple
  normalize: mean=0.5, std=0.5
  → [1,3,48,finalW] → rec.onnx → CTC greedy decode
```

### Step 6: 结构分析

```
if (structureSession_ 已加载):
  AnalyzeStructureV3:
    bilinear resize → 800×800
    normalize → [1,3,800,800] + im_shape + scale_factor
    → PP-DocLayoutV3 → fetch_name_0 [N,7]
    scale 坐标: x*cropW/800, y*cropH/800
    3 阶段匹配 boxes → regions → StructureUnit
else:
  AnalyzeStructure (几何):
    y-overlap 行聚类 → x-center 列检测 → paragraph/table 划分
```

### Step 7: 生成 Markdown

```cpp
BuildFullText: 遍历 StructureUnit → 段落换行+空行+表格 Markdown
```

---

## 四、C++ 输出 JSON 协议

```json
{
  "ok": true,
  "fullText": "…markdown text…",
  "language": "ch",
  "blocks": [
    {"text": "检测到的文本", "x": 12.5, "y": 34.1, "w": 156.3, "h": 22.5},
    ...
  ],
  "diag": {
    "stage": "success",
    "engine_src": "ppocrv6_onnx",
    "model_dir": "…",
    "dict": "ppocrv6_dict",
    "keys_size": 18384,
    "box_count": 15,
    "png_len": 123456,
    "img_size": "800x600",

    "cls_enabled": true,
    "cls_applied": 1,

    "structure_enabled": true,
    "structure_fallback": "v3",
    "num_structure_units": 2,
    "num_assigned_text_blocks": 15,
    "table_detected": 0,
    "table_cell_stats": "none",

    "rec_output_shape": "[1,25,18384]",
    "rec_decode_mode": "shape=…_candidateC=18384_…",
    "rec_T": 25,
    "rec_C": 18384,
    "rec_best_text_len": 12,
    "rec_best_score": -15.3,
    "rec_input_w": 320,
    "det_stride": 4,
    "det_in_hw": "448x672",
    "det_out_hw": "112x168"
  }
}
```

**坐标说明**: `blocks[].x/y/w/h` 是 crop 图像像素坐标，原点在 crop 图像左上角。
JS            on 解码 PNG 为 cropW×cropH RGB 平面
- 所有检测/识别/结构分析的坐标以 crop 图像为基准

---

## 五、翻译管道（附加）

```
Dart: TranslateService.translateBatch(texts)
  → MethodChannel("com.xmate/translate").translate({"texts": [...]})
    → C++ TranslateBatch:
      SP tokenizer (Unigram, Viterbi)
      → encoder.onnx →  hidden states
      → decoder.onnx →  autoregressive argmax (全范围 0-65000)
      → SP detokenizer
  ← JSON { ok: true, translations: ["翻译结果1", …] }
```

---

## 六、文件清单

| 文件 | 职责 |
|------|------|
| `lib/plugins/screenshot/annotate/annotate_page.dart` | UI: 选区 → crop → 发送 OCR → 面板渲染 |
| `lib/plugins/screenshot/annotate/ocr_service.dart` | MethodChannel 封装 + JSON 解析 |
| `lib/plugins/screenshot/integration/translate_service.dart` | 翻译 MethodChannel 封装 |
| `lib/plugins/screenshot/capture/capture_win32.dart` | 全屏截取 MethodChannel 封装 |
| `windows/runner/native/onnx_ocr_engine.cpp` | C++ OCR 引擎 (det/cls/rec + structure + fullText) |
| `windows/runner/native/onnx_ocr_engine.h` | `OcrFromPNG(pngBytes) → JSON` 接口 |
| `windows/runner/native/translate_engine.cpp` | C++ 翻译引擎 |
| `windows/runner/native/screenshot_capture.cpp` | C++ 全屏截取 |
| `windows/runner/native/models/` | ONNX 模型 + 字典 + config |

---

## 七、当前模型状态

| 模型 | 文件 | 大小 | 状态 |
|------|------|------|:----:|
| PP-OCRv6 det | `det.onnx` | 4.7MB | ✅ |
| PP-OCRv6 rec | `rec.onnx` | 16.5MB | ✅ |
| PP-OCR cls | `cls.onnx` | 583KB | ✅ 加载+参与推理 |
| PP-DocLayoutV3 | `structure.onnx` | 130MB | ✅ V3 推理 |
| OPUS-MT encoder | `translate_encoder.onnx` | 210MB | ✅ |
| OPUS-MT decoder | `translate_decoder.onnx` | 369MB | ✅ |
| 字典 | `ppocrv6_dict.txt` | ~200KB | ✅ |
| 共享词表 | `vocab.json` / `shared_vocab.txt` | ~3.4MB | ✅ |
