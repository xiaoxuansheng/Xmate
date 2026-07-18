/// 便签独立进程 App（`xmate.exe --note <id>`）
///
/// 职责：窗口初始定位（新建 = 级联+聚焦；恢复 = 原位置不抢焦点）、
/// WM_COPYDATA 命令接收（append/reload）、拖入分发、
/// 标题栏拖动结束后的便签合并检测。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/theme/theme_service.dart';
import '../../core/window/window_manager.dart';
import 'note_blocks.dart';
import 'note_model.dart';
import 'note_page.dart';
import 'note_store.dart';

class NoteApp extends StatefulWidget {
  final String noteId;
  const NoteApp({super.key, required this.noteId});
  @override
  State<NoteApp> createState() => _NoteAppState();
}

class _NoteAppState extends State<NoteApp> with WindowListener {
  static const _appChannel = MethodChannel('com.xmate/app');
  static const _dragChannel = MethodChannel('com.xmate/dragdrop');

  late final NoteData _note;
  final _pageKey = GlobalKey<NotePageState>();
  Timer? _moveDebounce;
  Timer? _previewThrottle;
  bool _merging = false;
  String? _previewTargetId;             // 当前悬停的合并目标
  final _peerColorCache = <String, int>{}; // 目标便签 id → colorIndex

  @override
  void initState() {
    super.initState();
    // 加载便签记录；文件缺失（异常情况）则以该 id 新建
    var loaded = NoteStore.load(widget.noteId);
    if (loaded == null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      loaded = NoteData(id: widget.noteId, createdAt: now, updatedAt: now);
      NoteStore.save(loaded);
    }
    // 打开即视为未关闭（从设置页重新打开已撕掉的便签）
    if (loaded.closed) {
      loaded.closed = false;
      NoteStore.save(loaded);
    }
    _note = loaded;

    windowManager.addListener(this);

    // WM_COPYDATA → noteDataRequest（append / reload 命令文件）
    _appChannel.setMethodCallHandler((call) async {
      if (call.method != 'noteDataRequest') return;
      final dataPath = call.arguments as String?;
      if (dataPath == null || dataPath.isEmpty) return;
      try {
        final file = io.File(dataPath);
        if (!await file.exists()) return;
        final json = jsonDecode(await file.readAsString());
        await file.delete();
        if (json is! Map<String, dynamic>) return;
        final cmd = json['cmd'] as String? ?? '';
        if (cmd == 'append') {
          if (_note.locked) return; // 锁定便签不接受外部追加
          final text = json['text'] as String? ?? '';
          if (text.isNotEmpty) {
            _pageKey.currentState?.externalAppend(text);
          }
        } else if (cmd == 'reload') {
          _pageKey.currentState?.externalReload();
        }
      } catch (_) {}
    });

    // 拖入：text → markdown 追加；files → 图片/文件块
    _dragChannel.setMethodCallHandler((call) async {
      if (call.method != 'onDrop' || !mounted) return;
      final args = call.arguments as Map<dynamic, dynamic>?;
      if (args == null) return;
      final type = args['type'] as String?;
      if (type == 'text') {
        final text = (args['text'] as String? ?? '').trim();
        if (text.isNotEmpty) _pageKey.currentState?.externalAppend(text);
      } else if (type == 'files') {
        final raw = args['files'] as List<dynamic>?;
        if (raw != null && raw.isNotEmpty) {
          _handleFileDrop(raw.cast<String>());
        }
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _positionWindow());
  }

  @override
  void dispose() {
    _moveDebounce?.cancel();
    _previewThrottle?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  // ── 初始定位 ──

  Future<void> _positionWindow() async {
    final display = ui.PlatformDispatcher.instance.displays.first;
    final ss = display.size / display.devicePixelRatio;

    final fresh = _note.x == null || _note.y == null;
    double w = (_note.w ?? 300).clamp(kNoteMinW, kNoteMaxW);
    // 新建便签 = 空便签自适应高度（kNoteMinH），避免首次自动缩小的跳变
    double h = (_note.h ?? kNoteMinH).clamp(kNoteMinH, kNoteMaxH);
    double x, y;
    if (fresh) {
      // 级联：按已开便签数偏移
      int openCount = 0;
      try {
        openCount = (await NoteLauncher.openNoteIds()).length;
      } catch (_) {}
      final offset = ((openCount - 1).clamp(0, 10)) * 26.0;
      x = ss.width * 0.58 + offset;
      y = ss.height * 0.22 + offset;
    } else {
      x = _note.x!;
      y = _note.y!;
    }
    // clamp 屏幕内
    final margin = 8.0;
    x = x.clamp(margin, (ss.width - w - margin).clamp(margin, ss.width));
    y = y.clamp(margin, (ss.height - h - margin).clamp(margin, ss.height));

    await WindowService().showNoActivate(x: x, y: y, width: w, height: h);
    // 1×1 → 实际尺寸后重建 swapchain
    await WindowService().forceChildRefresh();

    if (_note.pinned) {
      // 须在窗口可见后调用（window_manager 内部 _isWindowVisible 短路）
      try { await windowManager.setAlwaysOnTop(true); } catch (_) {}
    }
    if (fresh) {
      // 新建便签：聚焦以便立即输入
      try { await windowManager.focus(); } catch (_) {}
      _note.x = x;
      _note.y = y;
      _note.w = w;
      _note.h = h;
      NoteStore.save(_note);
    }
    // 定位/显示完成 → 此后 NotePage 的高度自适应测量才有意义
    _pageKey.currentState?.onWindowPositioned();
  }

  // ── 拖入文件 ──

  void _handleFileDrop(List<String> paths) {
    const imageExts = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp'};
    final blocks = <NoteBlock>[];
    for (final raw in paths) {
      final path = raw.replaceAll('/', '\\');
      if (path.isEmpty) continue;
      final dot = path.lastIndexOf('.');
      final ext = dot >= 0 ? path.substring(dot).toLowerCase() : '';
      final base = path.substring(path.lastIndexOf('\\') + 1);
      if (imageExts.contains(ext)) {
        // 复制到资产目录（便签内图片长期有效）
        try {
          final dest =
              '${NoteStore.assetsDir}\\${DateTime.now().millisecondsSinceEpoch}_$base';
          io.File(path).copySync(dest);
          blocks.add(NoteBlock(type: NoteBlockType.image, path: dest));
          continue;
        } catch (_) {}
      }
      blocks.add(NoteBlock(type: NoteBlockType.file, text: base, path: path));
    }
    if (blocks.isNotEmpty) {
      _pageKey.currentState?.externalAppendBlocks(blocks);
    }
  }

  // ── 窗口事件 ──

  @override
  void onWindowMoved() => _afterMoveEnd(merge: true);

  @override
  void onWindowMove() {
    // 兜底只保存位置：合并必须发生在鼠标松开（WM_EXITSIZEMOVE →
    // onWindowMoved）。此前 250ms 静默兜底会在拖动中停留时误触发合并。
    _moveDebounce?.cancel();
    _moveDebounce = Timer(
        const Duration(milliseconds: 250), () => _afterMoveEnd(merge: false));
    // 拖动中节流检测悬停目标 → 源便签实时变目标色预览
    if (_previewThrottle?.isActive != true) {
      _previewThrottle = Timer(const Duration(milliseconds: 130), () {});
      _updateMergePreview();
    }
  }

  /// 拖动中：悬停目标变化时通知 NotePage 变色（无目标 → 还原）
  Future<void> _updateMergePreview() async {
    if (_merging || !mounted || _note.locked) return;
    final targetId = await _hitTargetId();
    if (targetId == _previewTargetId) return;
    _previewTargetId = targetId;
    int? colorIdx;
    if (targetId != null) {
      colorIdx = _peerColorCache[targetId] ??=
          NoteStore.load(targetId)?.colorIndex ?? 0;
    }
    _pageKey.currentState?.setMergePreview(colorIdx);
  }

  @override
  void onWindowBlur() {
    _pageKey.currentState?.flushSave();
  }

  Future<void> _afterMoveEnd({required bool merge}) async {
    _moveDebounce?.cancel();
    if (_merging || !mounted) return;
    if (_pageKey.currentState?.isDeleted ?? false) return;
    // 保存新位置
    try {
      final b = await windowManager.getBounds();
      _note.x = b.left;
      _note.y = b.top;
      NoteStore.save(_note);
    } catch (_) {}
    if (!merge) return; // 拖动暂停兜底：只存位置，保留预览，不触发合并
    await _checkMerge();
    // 无论合并成功与否，还原颜色预览（ensure set —— 不走 == 短路）
    _resetMergePreview();
  }

  void _resetMergePreview() {
    _previewTargetId = null;
    _previewThrottle?.cancel();
    _pageKey.currentState?.setMergePreview(null);
  }

  /// 自身标题栏中心点落入的其他便签窗口 id（无 → null；锁定目标跳过）
  Future<String?> _hitTargetId() async {
    final rects = await NoteLauncher.openNoteRects();
    final own = rects[_note.id];
    if (own == null || rects.length < 2) return null;

    final dpr = ui.PlatformDispatcher.instance.displays.first.devicePixelRatio;
    final cx = (own[0] + own[2]) / 2;
    final cy = own[1] + kNoteTitleH * dpr / 2;

    String? targetId;
    double bestDist = double.infinity;
    for (final e in rects.entries) {
      if (e.key == _note.id) continue;
      final r = e.value;
      if (cx >= r[0] && cx <= r[2] && cy >= r[1] && cy <= r[3]) {
        final tx = (r[0] + r[2]) / 2, ty = (r[1] + r[3]) / 2;
        final d = (tx - cx) * (tx - cx) + (ty - cy) * (ty - cy);
        if (d < bestDist) {
          bestDist = d;
          targetId = e.key;
        }
      }
    }
    // 锁定（折叠）便签不能作为合并目标
    if (targetId != null && (NoteStore.load(targetId)?.locked ?? false)) {
      return null;
    }
    return targetId;
  }

  /// 标题栏中心点落入其他便签窗口 → 合并（自身内容追加到目标，自身删除）
  Future<void> _checkMerge() async {
    if (_merging || _note.locked) return; // 锁定便签不参与合并
    String? targetId;
    try {
      targetId = await _hitTargetId();
    } catch (_) {}
    if (targetId == null) return;

    _merging = true;
    try {
      // 提交编辑器最新内容后取 markdown
      _pageKey.currentState?.flushSave();
      final md = NoteStore.load(_note.id)?.content ?? _note.content;
      if (md.trim().isNotEmpty) {
        final delivered = await NoteLauncher.sendCommand(
            targetId, {'cmd': 'append', 'text': md});
        if (!delivered) {
          // 目标窗口不可达 → 回退：主进程直接写该便签文件追加内容
          final targetNote = NoteStore.load(targetId);
          if (targetNote != null) {
            targetNote.content =
                targetNote.content.isEmpty ? md : '${targetNote.content}\n$md';
            NoteStore.save(targetNote);
          }
        }
      }
      // 合并完成 → 先标记已删除（阻断 dispose→flushSave 复活文件），再删+关
      _pageKey.currentState?.markDeleted();
      NoteStore.delete(_note.id);
      try { await windowManager.close(); } catch (_) {}
    } catch (_) {
    } finally {
      _merging = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: ts.themeMode,
      theme: ts.lightTheme,
      darkTheme: ts.darkTheme,
      home: ExcludeSemantics(
        child: NotePage(key: _pageKey, note: _note),
      ),
    );
  }
}
