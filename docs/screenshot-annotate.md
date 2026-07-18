# 截图标注模块设计规范（annotate/）

> 以下为 V1.5.0 开发中沉淀的通用设计，后续为标注模块添加功能时必须遵循。

## 标注数据模型（`models/screenshot_data.dart`）

```
AnnotationShape (abstract)
├── RectAnnotation    x/y/w/h + shapeKind/lineStyle/fillStyle/fillColor/cornerRadius
├── ArrowAnnotation   fromX/fromY/toX/toY + startHead/endHead + lineStyle
├── TextAnnotation    x/y/text + fontSize/bold/italic/outline/fontFamily
├── FreehandAnnotation  points[] + lineStyle
├── NumberTagAnnotation x/y/number + style
└── MosaicAnnotation  mode/rect/points/cellSize

共享字段（基类）: id (自增唯一), rotation (radians, 2D 平面旋转角)
```

**关键约束**：
- `rotation` 字段只做纯增量，**不要**在 rotateAnn 中修改 x/y/w/h/from/to/points——位置坐标始终是未旋转的值
- 渲染时由 `drawAnnotation()` 做 `canvas.save→translate→rotate→draw→restore`
- 外形/线条/填充/字体等外观字段从 `ToolOptions` 映射写入，形状（shapeKind/cornerRadius）也属于外观

## 编辑状态机（`annotate_page.dart`）

```
三态区分（_ps / _pu / _pe 事件分支）:
┌───────────┬──────────────────────────────────────┐
│ creating  │ _tl != mouse 且 _ds != null           │
│           │ → 拖拽创建新标注                      │
├───────────┼──────────────────────────────────────┤
│ idle      │ _tl == mouse 且 _edDrag == null       │
│           │ → 点击空白取消 _selAnnId              │
├───────────┼──────────────────────────────────────┤
│ editing   │ _selAnnId != null 且 _edDrag != null  │
│           │ → 拖拽手柄：move/resize/rotate        │
└───────────┴──────────────────────────────────────┘
```

**关键字段**：
- `_selAnnId` (String?) — 当前选中标注 id
- `_edDrag` (AnnHandle?) — 拖拽中的手柄类型（move/tl/tr/bl/br/rotate）
- `_edBase` (Rect?) — 拖拽开始时的外接矩形基准（resize/rotate 的参考）
- `_edBaseObj` (AnnotationShape?) — 拖拽开始时的标注不可变副本

**编辑引用规则（避免静默失败）**：
- **move**：每帧从 `_ann` 列表 fetch 当前对象 → `translateAnn` → `_replaceAnn` → 重置 `_dBs`
- **resize/rotate**：始终基于**不可变** `_edBaseObj` 做变换，apply 后通过 `_findById(id)` 找当前列表引用做 replace
- **永远不要**用 `_replaceAnn(_edBaseObj!, newObj)` —— 帧 1 后 `_edBaseObj` 已从 `_ann` 移除，`indexOf` 返回 -1

**交互规则**：
- 每次 `_ad()` 创建后自动 `_selAnnId = a.id`（默认选中直到下一轮绘制开始）
- 非 mouse 工具开始绘制前先清除 `_selAnnId/_edDrag/_edBase/_edBaseObj`
- 非 mouse 工具时，handle 命中优先于创建（`_ps()` 中先检测 handles）

## 手柄几何：绘制与命中统一链（`annotate_canvas.dart`）

```
核心原则：_drawAnnHandles 和 hitTestAnnHandle 必须使用完全相同 geometry 链，
严禁依赖 canvas.save/translate/rotate 画手柄。

统一链:
  _getUnrotatedRect(a)           → raw Rect (未旋转轴对齐)
  _handlesGeometry(raw, rotation) → (corners, topMid, rotH)

  _drawAnnHandles:
    corners → canvas.drawPath(polygon) 画旋转 bbox
    corners[i] → 角点方块
    topMid→rotH → 旋转线 + 圆点（手柄直接在屏幕坐标绘制）

  hitTestAnnHandle:
    _pointInPolygon(p, corners) → move 命中
    (p - corners[i]).distance   → resize 角点命中
    (p - rotH).distance         → rotate 命中
```

**关键 helper**：
- `_rotRectCorners(Rect r, double angle)` → `List<Offset>` [tl, tr, br, bl]
- `_pointInPolygon(Offset p, List<Offset> poly)` → bool（射线法）
- `_rotRectBounds(Rect r, double angle)` → Rect（旋转后 AABB，用于 getAnnBounds）

## 2D 平面旋转

- `rotateAnn(a, da)`：**只增量 `rotation` 字段**，不修改坐标（返回新对象 `..rotation = a.rotation + da`）
- 渲染：`drawAnnotation()` 检测 `shape.rotation != 0` → `canvas.save() → translate(cx,cy) → rotate(rot) → translate(-cx,-cy) → 绘制 → restore()`
- 旋转中心：RectAnnotation 用 `x+w/2, y+h/2`（raw center），其他类型用 `getAnnBounds.center`
- 旋转后 bbox：`_rotRectBounds` 计算 4 角点旋转后的 AABB（用于 getAnnBounds / resize 基准）

## 命中测试规则

**RectAnnotation**：`_hitTestRectAnn(a, p)` — 旋转感知 + 填充/描边区分
- fillEnabled = `a.fillStyle == FillStyle.solid`
- 有填充：点在外扩半宽矩形/椭圆内 → 命中
- 无填充：点在外扩矩形/椭圆内 **且** 不在内缩矩形/椭圆内 → 只命中描边环（annular 判定）
- 先反向旋转 click point 到局部轴对齐空间再做判定

**Arrow/Freehand**：线段距离法（`_distToSeg`）

**Text/NumberTag/Mosaic**：bounds 判定（inflate 防抖）

## 缩放与 Shift 固定长宽比

- `resizeAnn(a, handle, delta, baseBounds, {keepAspect})`
- keepAspect=true 时：
  - 基准比例 = baseBounds.width / baseBounds.height（来自 `_edBase`，拖拽起点捕获）
  - dominant axis uniform scale: `s = max(|sW-1|, |sH-1|)` → sx=sy=s + dx/dy 补偿
  - 对所有类型统一生效（RectAnnotation 自有分支 + 通用 `_scaleAnn` 分支均已支持）
- `_shiftHeld`：`RawKeyboard.instance.keysPressed` 检测 ShiftLeft/Right
- `_pu()` 传 `keepAspect: _shiftHeld`

## 标注写入链路

```
ToolOptions (annotate_toolbar.dart)
  → onOptionsChanged → _opts = v
  → annotation_page._cd() / _ct() / _applyOptsToAnnotation()
  → AnnotationShape 构造函数（各项字段映射到模型）
  → annotate_canvas.dart drawAnnotation() 渲染
```

**新建标注时**：`_cd()` 把 `_opts` 各字段写入构造函数
**选中标注修改时**：`_applyOptsToAnnotation()` 保留位置/几何，仅替换外观字段

## Toolbar 规范

### 图标规范
- **所有图标统一使用 Material Icons（`Icons.xxx`）**，不引入自定义 SVG/PNG
- 工具按钮统一用 `_toolBtn(icon, toolEnum)`
- 分隔符 `_sep()` = 1px 宽 22px 高 Container
- 子选项按钮 `_optBtn(label, active, onTap)` — 文字标签式切换
- 下拉组件用 `PopupMenuButton`（如 lineStyle dropdown、fontFamily dropdown）
- 颜色预设为 7 色圆形 swatches
- 自定义颜色选择器：showDialog → RGB 滑块 + HEX 输入 + 20 色预设色板

### 布局约束
- 两级菜单结构：
  - Row 1：工具按钮 | undo/redo | copy/save/pin/close（三段式，`_sep()` 分隔）
  - Row 2：颜色行 + 粗细行 + 工具专属子选项（条件显示）
- **严禁使用 `Spacer()` 在 unbounded 宽度上下文中**——会静默导致 toolbar 不渲染
- 间隔用固定 `SizedBox(width: 6)` 替代 Spacer
- showColorRow 排除 mosaic（马赛克不需颜色），mosaic 用独立 `_buildMosaicRow()`

## 坐标系统

- 所有标注坐标 = **逻辑像素**（与 `MediaQuery.size` / `GestureDetector.localPosition` 一致）
- 导出时 `_exp()` 做 `sx=imgWidth/widgetWidth` 缩放到物理像素
- 不要混用 devicePixelRatio 和逻辑坐标

## 橡皮擦 Mask 顺序机制（V1.5.5）

- `_sharedOrderCounter` — 全局单调计数器，标注和 EraserMask 共享
- `_getOrAssignAnnOrder(a)` — 标注首次 paint 时从共享计数器分配 order-id（`putIfAbsent`）
- `EraserMask.orderId` — 创建时从同一计数器取值
- `paint()` 中按 order-id 排序后在同一 `saveLayer` 内绘制，保证：
  - M(A) → A(B) → B：B 覆盖 M，M 不擦 B
  - A → B → M：M 在 A/B 之后绘制，可擦除二者
- EraserMask 用 `BlendMode.clear` 打穿标注层，露出底图

## 标号工具（NumberTag）设计规范（V1.5.5）

**数据模型**：`NumberTagAnnotation` — x, y, number, color, style, fontSize

**样式枚举**（`NumberTagStyle`）：
- `circleOutline` — 颜色描边空心圆 + 颜色数字
- `solidCircle` — 颜色填充圆 + 白色数字
- `filledWhiteBorder` — 颜色填充 + 白色描边 + 白色数字

**渲染公式**（`_drawNumberTag`）：
- 圈半径 = `fontSize`（即 `numberTagSize`）
- 字体大小 = `fontSize`（数字贴在圈内饱满显示）
- 命中测试容差 = `fontSize + 6`（额外 6px 防抖）

**交互**：
- 点击即放置（无拖拽），自动选中
- 数字递增：`max+1` 策略（扫描 `_ann` 中所有 NumberTag 取最大 number+1）
- Clear All 后重置为 1；被擦除的 number 不回收
- Undo/Redo 恢复原数字

**ToolOptions 字段**：
- `numberTagStyle` — 样式
- `numberTagSize` — 圈/字大小（默认 16），小/中/大 三个圆环按钮 + 自定义 px 输入
- 颜色复用 `color` 字段；颜色行自动显示（numberTag 不在排除列表）
