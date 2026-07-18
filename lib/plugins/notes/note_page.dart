/// 便签窗口 UI（独立进程内的唯一页面）
///
/// 结构：偏深标题栏（拖动移动 + 正中图钉 + 左侧提醒文本）
///     + 偏浅内容区（块编辑器，滚动）
///     + 右下角折角（点击撕掉关闭）
///     + 四边/四角缩放热区
///
/// 窗口几何调用一律走 WindowService.showNoActivate（SWP_NOZORDER，
/// 不改变 z-order）；setBounds 会 HWND_TOPMOST 强制置顶，禁用。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/window/window_manager.dart';
import 'note_blocks.dart';
import 'note_crypto.dart';
import 'note_editor.dart';
import 'note_model.dart';
import 'note_reminder.dart';
import 'note_store.dart';

const kNoteMinW = 240.0, kNoteMinH = 140.0;
const kNoteMaxW = 520.0, kNoteMaxH = 680.0;
const kNoteTitleH = 28.0;

class NotePage extends StatefulWidget {
  final NoteData note;
  const NotePage({super.key, required this.note});
  @override
  State<NotePage> createState() => NotePageState();
}

class NotePageState extends State<NotePage> with TickerProviderStateMixin {
  NoteData get note => widget.note;

  final _editorKey = GlobalKey<NoteEditorState>();
  final _contentKey = GlobalKey();
  final _scrollCtrl = ScrollController();

  // ── 动画 ──
  late final AnimationController _tearCtrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
  late final AnimationController _shakeCtrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
  late final AnimationController _flashCtrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  // 长按折角 1s → 折角变到最大并维持；松手时已达最大 = 删除
  late final AnimationController _holdCtrl =
      AnimationController(vsync: this, duration: const Duration(seconds: 1));
  // 底部平折（加密）动画
  late final AnimationController _lockFoldCtrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
  // 删除动画：四周向中心折拢收起 + 渐隐
  late final AnimationController _deleteCtrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
  // 左上角撕角换色
  late final AnimationController _peelCtrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 170));
  bool _tearing = false;
  bool _deleting = false;
  bool _deleted = false;         // 已删除 → 禁止后续保存复活文件
  bool _dogEarHover = false;
  bool _pinBounce = false;
  int _peelColorIndex = -1;      // 按下左上角时预览的随机色（-1 = 未按下）
  int? _mergePreviewColor;       // 拖动合并悬停时的目标颜色预览
  bool _alarmTextHidden = false; // 倒计时文本隐藏（只留闹钟图标）
  // ── 加密（折叠）──
  int _lockUiMode = 0;           // 0=正常 1=设置code 2=输入code解锁
  bool _lockError = false;       // 解锁输错抖动提示
  Offset? _lockDown;             // 底部按下位置（区分缩放拖动）
  Timer? _lockoutTimer;          // 错码锁定倒计时刷新
  bool _holdCancelled = false;   // 折角长按中指针移出 → 已取消

  // ── 提醒 ──
  Timer? _reminderTimer;
  String? _reminderText;

  // ── 保存 / 自适应 ──
  Timer? _saveTimer;
  int _fitGen = 0;
  bool _resizing = false;
  bool _windowReady = false; // NoteApp 初始定位完成前禁止自适应测量

  // ── 缩放手势（屏幕坐标系，避免左/上边拖拽时窗口移动引发反馈抖动）──
  Rect? _dragStartBounds;  // pan 开始时的窗口 bounds（逻辑像素）
  Rect? _curBounds;        // 最近一次应用的 bounds
  Offset? _startScreen;    // pan 开始时指针的屏幕坐标（逻辑）
  bool _heightTouched = false;

  @override
  void initState() {
    super.initState();
    _updateReminder();
    // 重启后仍在错码锁定期 → 恢复倒计时刷新（须首帧后，setState in
    // initState 无已渲染帧可重建 → 倒计时不更新）
    if (note.lockUntil > DateTime.now().millisecondsSinceEpoch) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureLockoutTicker();
      });
    }
    // 高度自适应不在此触发：须等 NoteApp 完成初始定位（onWindowPositioned）。
    // 否则测量发生在 1×1 引擎初始化尺寸下，内容按 1px 宽度折行出巨大高度
    // → clamp 到 kNoteMaxH → 新便签随机出现超大窗口（与定位异步链竞态）
  }

  @override
  void dispose() {
    _reminderTimer?.cancel();
    _saveTimer?.cancel();
    _flushSave();
    _tearCtrl.dispose();
    _shakeCtrl.dispose();
    _flashCtrl.dispose();
    _holdCtrl.dispose();
    _deleteCtrl.dispose();
    _peelCtrl.dispose();
    _lockFoldCtrl.dispose();
    _lockoutTimer?.cancel();
    for (final f in _lockBoxes) { f.dispose(); }
    for (final c in _lockBoxCtrl) { c.dispose(); }
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ── 对外（NoteApp 调用）──

  /// 命令面板追加 / 便签合并：追加 markdown 并反馈
  void externalAppend(String text) {
    _editorKey.currentState?.appendMarkdown(text);
    _afterExternalAppend();
  }

  /// 拖入的图片/文件块追加
  void externalAppendBlocks(List<NoteBlock> blocks) {
    _editorKey.currentState?.appendBlocks(blocks);
    _afterExternalAppend();
  }

  void _afterExternalAppend() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
    // 轻微抖动反馈
    _shakeCtrl.forward(from: 0);
  }

  void externalReload() {
    final fresh = NoteStore.load(note.id);
    if (fresh == null) return;
    note.content = fresh.content;
    _editorKey.currentState?.reload(fresh.content);
    _updateReminder();
  }

  /// 立即保存（窗口关闭 / 失焦时由 NoteApp flush）
  void flushSave() => _flushSave();

  // ── 内容变化 ──

  void _onContentChanged(String md) {
    note.content = md;
    NoteReminder.recompute(note);
    _scheduleSave();
    _updateReminder();
    _scheduleAutoFit();
  }

  void _scheduleSave() {
    if (_deleted) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _flushSave);
  }

  void _flushSave() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_deleted) return; // 长按删除后禁止复活文件
    NoteStore.save(note);
  }

  // ── 高度自适应 ──

  /// NoteApp 初始定位（showNoActivate 真实尺寸）完成后调用；
  /// 在此之前窗口仍是 1×1，一切测量无效。
  void onWindowPositioned() {
    if (_windowReady) return;
    _windowReady = true;
    _scheduleAutoFit();
  }

  void _scheduleAutoFit() {
    if (!_windowReady || !note.autoFit || _tearing || _deleting) return;
    final gen = ++_fitGen;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || gen != _fitGen || _resizing || !note.autoFit) return;
      final ctx = _contentKey.currentContext;
      final rb = ctx?.findRenderObject() as RenderBox?;
      if (rb == null || !rb.hasSize) return;
      // 兜底：布局宽度仍是初始化残留（远小于最小窗宽）→ 测量无效
      if (rb.size.width < kNoteMinW - 40) return;
      final contentH = rb.size.height;
      final target =
          (kNoteTitleH + contentH + 2).clamp(kNoteMinH, kNoteMaxH).ceilToDouble();
      Rect bounds;
      try {
        bounds = await windowManager.getBounds();
      } catch (_) {
        return;
      }
      if (!mounted || gen != _fitGen || _resizing) return;
      if ((bounds.height - target).abs() < 4) return;
      await WindowService().showNoActivate(
        x: bounds.left, y: bounds.top, width: bounds.width, height: target,
      );
      note.h = target;
      _scheduleSave();
    });
    // postFrameCallback 依赖下一帧触发；确保有帧被调度（如定位后无重绘）
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  // ── 提醒 ──

  void _updateReminder() {
    _reminderTimer?.cancel();
    _reminderTimer = null;
    final now = DateTime.now();

    // 已到期未触发 → 全部标记 fired，只触发一次提醒效果；
    // 触发后自动显示下一个最近的提醒（"一个到时间后显示下一个"）
    final overdue = note.reminders
        .where((r) => !r.fired && r.at <= now.millisecondsSinceEpoch)
        .toList();
    if (overdue.isNotEmpty) {
      for (final r in overdue) {
        r.fired = true;
      }
      _flushSave();
      _fireAlarmEffects();
    }

    final next = note.nextReminder;
    if (next == null) {
      if (_reminderText != null) setState(() => _reminderText = null);
      return;
    }
    final target = DateTime.fromMillisecondsSinceEpoch(next.at);
    setState(() => _reminderText = NoteReminder.formatRemaining(target, now));
    final remaining = target.difference(now);
    final tick = remaining.inSeconds <= 3660
        ? const Duration(seconds: 1)
        : const Duration(seconds: 30);
    _reminderTimer = Timer(tick, _updateReminder);
  }

  /// 到期效果：置顶前置 + 抖动 + 标题闪烁 + 提示音响 3 下
  void _fireAlarmEffects() {
    final wasPinned = note.pinned;
    () async {
      try {
        await windowManager.setAlwaysOnTop(true);
        await windowManager.show();
      } catch (_) {}
    }();
    _shakeCtrl.forward(from: 0);
    _flashCtrl.forward(from: 0);
    for (int i = 0; i < 3; i++) {
      Timer(Duration(milliseconds: 80 + i * 450), NoteLauncher.beep);
    }
    // 提醒展示 2.6s 后恢复原置顶状态
    Timer(const Duration(milliseconds: 2600), () async {
      if (!mounted) return;
      if (!wasPinned) {
        try { await windowManager.setAlwaysOnTop(false); } catch (_) {}
      }
    });
  }

  // ── 图钉 ──

  Future<void> _togglePin() async {
    setState(() {
      note.pinned = !note.pinned;
      _pinBounce = true;
    });
    Timer(const Duration(milliseconds: 190), () {
      if (mounted) setState(() => _pinBounce = false);
    });
    try {
      await windowManager.setAlwaysOnTop(note.pinned);
    } catch (_) {}
    _scheduleSave();
  }

  // ── 撕掉关闭 / 长按删除 ──

  /// 撕掉关闭（锁定便签也可用——仅关窗不删文件，下次打开仍锁定）
  Future<void> _tearOff() async {
    if (_tearing || _deleting) return;
    _tearing = true;
    note.closed = true;
    _flushSave();
    setState(() {});
    await _tearCtrl.forward();
    try {
      await windowManager.close();
    } catch (_) {}
  }

  /// 长按折角触发：删除便签文件（非撕掉），四周折拢收起后关闭窗口
  Future<void> _deleteNote() async {
    if (_deleting || _tearing || note.locked) return;
    _deleting = true;
    _deleted = true;
    _reminderTimer?.cancel();
    _saveTimer?.cancel();
    NoteStore.delete(note.id);
    setState(() {});
    await _deleteCtrl.forward();
    try {
      await windowManager.close();
    } catch (_) {}
  }

  /// 合并成功后由 NoteApp 调用：文件已删除，禁止 dispose/失焦兜底保存复活
  /// （此前合并后窗口关闭时 dispose→_flushSave 会把已删除的文件重新写回）
  void markDeleted() {
    _deleted = true;
    _saveTimer?.cancel();
    _reminderTimer?.cancel();
  }

  bool get isDeleted => _deleted;

  // ── 加密（折叠）──

  /// 底部平折触发热区：按下 → 对折动画；小位移松开 → 进入设置 code；
  /// 位移超过阈值 = 用户在拖底边缩放 → 取消折叠让位。
  Widget _buildLockFoldZone() {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        _lockDown = e.position;
        _lockFoldCtrl.forward(from: 0);
      },
      onPointerMove: (e) {
        if (_lockDown != null && (e.position - _lockDown!).distance > 8) {
          _cancelLockFold();
        }
      },
      onPointerUp: (_) {
        if (_lockDown == null) return;
        _lockDown = null;
        if (_lockFoldCtrl.value > 0.2) {
          // 松开触发加密：立即收起平折（不遮挡密码输入），进入设置 code
          setState(() {
            _lockUiMode = 1;
            _lockError = false;
          });
          _lockFoldCtrl.reverse();
        } else {
          _cancelLockFold();
        }
      },
      onPointerCancel: (_) => _cancelLockFold(),
      child: const MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SizedBox.expand(),
      ),
    );
  }

  void _cancelLockFold() {
    _lockDown = null;
    _lockFoldCtrl.reverse();
  }

  /// 6 位密码输入方框（单行 6 个 TextField，自动跳格）
  final List<FocusNode> _lockBoxes = List.generate(6, (_) => FocusNode());
  List<TextEditingController> _lockBoxCtrl = [];

  List<TextEditingController> _boxControllers() {
    if (_lockBoxCtrl.length != 6) {
      for (final c in _lockBoxCtrl) { c.dispose(); }
      _lockBoxCtrl = List.generate(6, (_) => TextEditingController());
    }
    return _lockBoxCtrl;
  }

  /// 锁定/设置/解锁面板 — 两行居中 UI：
  ///   第一行：锁图标 + 6 个密码方框
  ///   第二行：Set 6-digit code / Cancel / Wrong code / Locked+倒计时
  Widget _buildLockPane(Brightness brightness) {
    final dim = NoteColorSpec.textDim(brightness);
    final accent = Theme.of(context).colorScheme.primary;
    final err = Theme.of(context).colorScheme.error;
    final now = DateTime.now().millisecondsSinceEpoch;
    final lockedOut = note.lockUntil > now;

    // 已锁 + 未输码 → 锁图标（点击进入输码）
    if (note.locked && _lockUiMode == 0) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (lockedOut) {
            _ensureLockoutTicker();
            return;
          }
          setState(() {
            _lockUiMode = 2;
            _lockError = false;
          });
        },
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(
            Icons.lock_rounded,
            size: 34,
            color: lockedOut ? err.withAlpha(160) : dim,
          ),
          const SizedBox(height: 7),
          Text(
            lockedOut
                ? 'Locked · ${_lockoutRemaining(note.lockUntil, now)}'
                : 'Locked',
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: lockedOut ? FontWeight.w600 : FontWeight.normal,
                color: lockedOut ? err : dim),
          ),
        ]),
      );
    }

    final setup = _lockUiMode == 1;
    final boxes = _boxControllers();

    // 第二行状态文字
    String status;
    Color statusColor;
    if (lockedOut && !setup) {
      status = 'Locked · ${_lockoutRemaining(note.lockUntil, now)}';
      statusColor = err;
    } else if (_lockError) {
      status = 'Wrong code';
      statusColor = err;
    } else {
      status = setup ? 'Set 6-digit code' : 'Enter code to unlock';
      statusColor = dim;
    }

    return Column(mainAxisSize: MainAxisSize.min, children: [
      // 第一行：锁图标 + 6 方框
      Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            setup ? Icons.lock_outline_rounded : Icons.lock_rounded,
            size: 20,
            color: _lockError ? err : dim,
          ),
          const SizedBox(width: 10),
          for (int i = 0; i < 6; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            SizedBox(
              width: 26,
              height: 32,
              child: TextField(
                controller: boxes[i],
                focusNode: _lockBoxes[i],
                autofocus: i == 0,
                enabled: setup || !lockedOut,
                maxLength: 1,
                obscureText: true,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                cursorColor: accent,
                style: TextStyle(
                  fontSize: 17,
                  color: _lockError ? err : accent,
                  fontWeight: FontWeight.w700,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  counterText: '',
                  filled: true,
                  fillColor: _lockError
                      ? err.withAlpha(18)
                      : accent.withAlpha(12),
                  contentPadding: EdgeInsets.zero,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(
                        color: _lockError
                            ? err.withAlpha(180)
                            : accent.withAlpha(100)),
                  ),
                  disabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: dim.withAlpha(70)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(
                        color: _lockError ? err : accent, width: 2),
                  ),
                ),
                onChanged: (v) {
                  if (_lockError) setState(() => _lockError = false);
                  if (v.isNotEmpty) {
                    boxes[i].text = v[v.length - 1];
                    if (i < 5) _lockBoxes[i + 1].requestFocus();
                  }
                  if (_allDigits(boxes).length == 6) _submitCode(boxes);
                },
              ),
            ),
          ],
        ],
      ),
      const SizedBox(height: 10),
      // 第二行：状态文字 + Cancel
      Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(status,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight:
                      statusColor == err ? FontWeight.w600 : FontWeight.normal,
                  color: statusColor)),
          const SizedBox(width: 16),
          _SmallCancelBtn(
            dim: dim,
            onTap: () {
              for (final b in boxes) { b.clear(); }
              setState(() {
                _lockUiMode = 0;
                _lockError = false;
              });
              if (!note.locked) _lockFoldCtrl.reverse();
            },
          ),
        ],
      ),
    ]);
  }

  String _allDigits(List<TextEditingController> boxes) {
    final sb = StringBuffer();
    for (final b in boxes) { sb.write(b.text); }
    return sb.toString();
  }

  String _lockoutRemaining(int until, int now) {
    if (until <= now) return '';
    final sec = ((until - now) / 1000).ceil();
    if (sec <= 0) return '';
    if (sec < 60) return '${sec}s';
    if (sec < 3600) return '${sec ~/ 60}m ${sec % 60}s';
    return '${sec ~/ 3600}h ${(sec % 3600) ~/ 60}m';
  }

  void _submitCode(List<TextEditingController> boxes) {
    final code = _allDigits(boxes);
    if (code.length != 6) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (note.lockUntil > now) return; // 锁定期间拒绝尝试

    if (_lockUiMode == 1) {
      // 设置 code → 加密内容 + 存储验证子
      note.lockSalt = NoteCrypto.newSalt();
      note.lockHash = NoteCrypto.verifier(code, note.lockSalt);
      note.lockEnc = NoteCrypto.encrypt(note.content, code, note.lockSalt);
      note.content = '';
      note.lockFails = 0;
      note.lockUntil = 0;
      _flushSave();
      setState(() {
        _lockUiMode = 0;
        _lockError = false;
      });
      for (final b in boxes) { b.clear(); }
      _lockFoldCtrl.reverse();
    } else if (_lockUiMode == 2) {
      // 解锁验证
      if (NoteCrypto.verifier(code, note.lockSalt) == note.lockHash) {
        final dec = NoteCrypto.decrypt(note.lockEnc, code, note.lockSalt);
        if (dec != null) {
          note.content = dec;
          note.lockHash = '';
          note.lockSalt = '';
          note.lockEnc = '';
          note.lockFails = 0;
          note.lockUntil = 0;
          _flushSave();
          setState(() {
            _lockUiMode = 0;
            _lockError = false;
          });
          for (final b in boxes) { b.clear(); }
          _shakeCtrl.forward(from: 0);
          _scheduleAutoFit();
          _lockoutTimer?.cancel();
          return;
        }
      }
      // 错码：计数 + 递增锁定
      note.lockFails++;
      final fails = note.lockFails;
      if (fails >= 3) {
        // 第 3 次起递增锁定：5min * 2^(fails-3)，上限 1h
        final lockSec = (300 * (1 << (fails - 3)).clamp(0, 4096)).clamp(0, 3600);
        note.lockUntil = now + lockSec * 1000;
      }
      _flushSave();
      for (final b in boxes) { b.clear(); }
      FocusScope.of(context).requestFocus(_lockBoxes[0]);
      setState(() => _lockError = true);
      _shakeCtrl.forward(from: 0);
      if (note.lockUntil > now) _ensureLockoutTicker();
    }
  }

  /// 错码锁定倒计时刷新（每秒 setState；到期自停）
  void _ensureLockoutTicker() {
    if (_lockoutTimer?.isActive == true) return;
    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (note.lockUntil <= DateTime.now().millisecondsSinceEpoch) {
        _lockoutTimer?.cancel();
        _lockoutTimer = null;
      }
      setState(() {});
    });
  }

  /// 拖动合并预览：悬停到目标便签 → 整体变目标色；null = 还原自身色
  void setMergePreview(int? colorIndex) {
    if (_tearing || _deleting) return;
    setState(() => _mergePreviewColor = colorIndex);
  }

  // ── 缩放 ──
  // V3.2.7：指针位置换算到屏幕坐标系再计算增量。左/上边拖拽会移动窗口
  // 原点，视图内 delta 会被原点位移污染（反复触发重新定位）；
  // 屏幕坐标 = 当前窗口原点 + 视图内坐标，两者位移互相抵消，保持稳定。

  Future<void> _resizeStart(DragStartDetails d) async {
    _resizing = true;
    _heightTouched = false;
    _dragStartBounds = null;
    _startScreen = null;
    final local = d.globalPosition; // Flutter "global" = 窗口视图内坐标
    try {
      final b = await windowManager.getBounds();
      _dragStartBounds = b;
      _curBounds = b;
      _startScreen = b.topLeft + local;
    } catch (_) {}
  }

  void _resizeUpdate(DragUpdateDetails d,
      {bool left = false, bool right = false, bool top = false, bool bottom = false}) {
    final start = _dragStartBounds;
    final cur = _curBounds;
    final startScreen = _startScreen;
    if (start == null || cur == null || startScreen == null) return;

    final screen = cur.topLeft + d.globalPosition;
    final dx = screen.dx - startScreen.dx;
    final dy = screen.dy - startScreen.dy;

    double x = start.left, y = start.top, w = start.width, h = start.height;
    if (right) w = (start.width + dx).clamp(kNoteMinW, kNoteMaxW);
    if (bottom) h = (start.height + dy).clamp(kNoteMinH, kNoteMaxH);
    if (left) {
      w = (start.width - dx).clamp(kNoteMinW, kNoteMaxW);
      x = start.right - w;
    }
    if (top) {
      h = (start.height - dy).clamp(kNoteMinH, kNoteMaxH);
      y = start.bottom - h;
    }
    if (top || bottom) _heightTouched = true;
    // 与原生取整保持一致，避免屏幕坐标换算累积漂移
    x = x.roundToDouble();
    y = y.roundToDouble();
    w = w.roundToDouble();
    h = h.roundToDouble();
    _curBounds = Rect.fromLTWH(x, y, w, h);
    WindowService().showNoActivate(x: x, y: y, width: w, height: h);
  }

  Future<void> _resizeEnd() async {
    _resizing = false;
    _dragStartBounds = null;
    _startScreen = null;
    try {
      final b = await windowManager.getBounds();
      note.x = b.left;
      note.y = b.top;
      note.w = b.width;
      note.h = b.height;
    } catch (_) {}
    if (_heightTouched && note.autoFit) {
      note.autoFit = false; // 手动改高度 → 关闭自适应
    }
    _scheduleSave();
    if (!_heightTouched) _scheduleAutoFit(); // 只改宽度 → 重新按内容适配高度
  }

  // ── 构建 ──

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    // 拖动合并预览中 → 整体显示目标便签的颜色
    final spec = _mergePreviewColor != null
        ? kNoteColors[_mergePreviewColor!.clamp(0, kNoteColors.length - 1)]
        : note.color;
    final titleColor = spec.title(brightness);
    final bodyColor = spec.body(brightness);
    final accent = Theme.of(context).colorScheme.primary;

    final card = Column(children: [
      _buildTitleBar(titleColor, accent, brightness),
      Expanded(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          color: bodyColor,
          width: double.infinity,
          // 锁相关界面：不进 ScrollView，整页上下左右居中显示
          child: (note.locked || _lockUiMode != 0)
              ? Center(child: _buildLockPane(brightness))
              : SingleChildScrollView(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Column(
                    key: _contentKey,
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      NoteEditor(
                        key: _editorKey,
                        initialContent: note.content,
                        brightness: brightness,
                        onChanged: _onContentChanged,
                        isTokenFired: (token) {
                          for (final r in note.reminders) {
                            if (r.token == token && r.fired) return true;
                          }
                          return false;
                        },
                      ),
                    ],
                  ),
                ),
        ),
      ),
    ]);

    // 底部平折颜色（比 body 深一档，同折角）
    final hsl = HSLColor.fromColor(bodyColor);
    final foldColor = brightness == Brightness.dark
        ? hsl.withLightness((hsl.lightness + 0.10).clamp(0.0, 1.0)).toColor()
        : hsl.withLightness((hsl.lightness - 0.10).clamp(0.0, 1.0)).toColor();

    // 卡片 + 折角（一起参与撕掉动画）；亮/暗模式均无外层描边
    final cardWithEar = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(children: [
        Positioned.fill(child: card),
        if (_lockUiMode == 0) ...[
          Positioned(
            right: 0,
            bottom: 0,
            child: _buildDogEar(bodyColor, brightness, locked: note.locked),
          ),
          if (!note.locked) ...[
            // 左上角撕角换色热区
            Positioned(
              left: 0,
              top: 0,
              child: _buildColorPeel(spec, brightness),
            ),
            // 底部按下 → 折角转为整个底部平折（加密触发热区）
            Positioned(
              left: 14,
              right: 92,
              bottom: 0,
              height: 9,
              child: _buildLockFoldZone(),
            ),
          ],
        ],
        // 底部平折动画覆盖层（对折上升）
        AnimatedBuilder(
          animation: _lockFoldCtrl,
          builder: (ctx, _) {
            final t = Curves.easeOut.transform(_lockFoldCtrl.value);
            if (t <= 0.005) return const SizedBox.shrink();
            return Positioned.fill(
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: (0.42 * t).clamp(0.0, 1.0),
                    widthFactor: 1,
                    child: Container(
                      decoration: BoxDecoration(
                        color: foldColor,
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: 6,
                            offset: Offset(0, -3),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ]),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(children: [
        Positioned.fill(
          child: AnimatedBuilder(
            animation: Listenable.merge([_tearCtrl, _shakeCtrl, _deleteCtrl]),
            builder: (ctx, child) {
              final t = Curves.easeIn.transform(_tearCtrl.value);
              final del = Curves.easeIn.transform(_deleteCtrl.value);
              final shake = _shakeCtrl.isAnimating
                  ? math.sin(_shakeCtrl.value * math.pi * 6) *
                      4 * (1 - _shakeCtrl.value)
                  : 0.0;
              // 撕掉：从右下角折角撕起 → 绕左下角逆时针翻转 + 向上飞出 + 渐隐
              // 删除：四周向中心折拢收起（缩放）+ 轻微旋转 + 渐隐
              return Opacity(
                opacity: ((1 - t) * (1 - del)).clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(shake, -t * t * 110),
                  child: Transform.scale(
                    scale: 1 - del * 0.96,
                    child: Transform.rotate(
                      angle: -t * 0.13 + del * 0.06,
                      alignment:
                          t > 0 ? Alignment.bottomLeft : Alignment.center,
                      child: child,
                    ),
                  ),
                ),
              );
            },
            child: cardWithEar,
          ),
        ),
        ..._buildResizeZones(),
      ]),
    );
  }

  Widget _buildTitleBar(Color titleColor, Color accent, Brightness brightness) {
    final pinColor = note.pinned
        ? NoteColorSpec.text(brightness)
        : NoteColorSpec.text(brightness).withAlpha(80);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => windowManager.startDragging(),
      // TweenAnimationBuilder：换色（合并预览/撕角换色）时标题栏平滑过渡
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: titleColor),
        duration: const Duration(milliseconds: 180),
        builder: (ctx, animTitle, child) => AnimatedBuilder(
          animation: _flashCtrl,
          builder: (ctx2, child2) {
            // 到期闪烁：accent 两次脉冲叠加在标题栏上
            final v = _flashCtrl.isAnimating
                ? math.pow(math.sin(_flashCtrl.value * math.pi * 2), 2)
                    .toDouble()
                : 0.0;
            return Container(
              height: kNoteTitleH,
              color: Color.lerp(animTitle ?? titleColor, accent, v * 0.55),
              child: child2,
            );
          },
          child: child,
        ),
        child: Stack(children: [
          // 右上：闹钟 + 提醒剩余时间（点击图标切换倒计时显示/隐藏）
          if (_reminderText != null)
            Positioned(
              right: 10,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () =>
                    setState(() => _alarmTextHidden = !_alarmTextHidden),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.alarm, size: 13, color: accent),
                  if (!_alarmTextHidden) ...[
                    const SizedBox(width: 3),
                    Text(
                      _reminderText!,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: accent,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ]),
              ),
            ),
          // 正中：图钉
          Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _togglePin,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: AnimatedScale(
                  scale: _pinBounce ? 1.3 : 1.0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutBack,
                  child: AnimatedRotation(
                    turns: note.pinned ? 0 : -0.075,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutBack,
                    child: Icon(
                      note.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                      size: 22,
                      color: pinColor,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  /// 右下角折角：hover 翻起变大；短按撕掉；长按 1s 折角渐大至最大并维持，
  /// 达最大后折角内显示白色垃圾桶图标，松手即删除；未到最大松手回缩取消。
  ///
  /// 用 Listener 而非 GestureDetector：tap 手势按住约 500ms 会被竞技场判负
  /// 触发 onTapCancel（导致折角回缩、且永远收不到 onTapUp → 松手无法删除）；
  /// 原始指针事件不参与竞技场，down/up 必达。
  Widget _buildDogEar(Color bodyColor, Brightness brightness,
      {bool locked = false}) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _holdCtrl,
      builder: (ctx, _) {
        final hold = _holdCtrl.value; // completed 后停在 1.0 → 维持最大
        final base = _dogEarHover ? 45.0 : 33.0;
        final size = base + hold * 52; // 锁定便签无长按：保持 base
        final atMax = !locked && hold >= 0.98; // 锁定模式下不显示垃圾桶
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _dogEarHover = true),
          onExit: (_) => setState(() => _dogEarHover = false),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) {
              if (locked) { _tearOff(); return; }       // 锁定仅撕掉
              if (_deleting || _tearing) return;
              _holdCancelled = false;
              _holdCtrl.stop();
              _holdCtrl.forward(from: 0);
            },
            onPointerMove: (e) {
              if (locked) return;
              // 与其他手势一致：指针移出折角区域 → 取消删除回缩
              if (_holdCancelled || _deleting || _tearing) return;
              final p = e.localPosition;
              if (p.dx < -6 || p.dy < -6 || p.dx > size + 6 || p.dy > size + 6) {
                _holdCancelled = true;
                _holdCtrl.reverse();
              }
            },
            onPointerUp: (_) {
              if (locked) return; // 锁定仅撕掉（已在 onPointerDown 触发）
              if (_deleting || _tearing) return;
              if (_holdCancelled) {
                _holdCancelled = false;
                return; // 已移出取消 → 松手不删除
              }
              if (_holdCtrl.value >= 0.98) {
                _deleteNote();          // 已达最大 → 松手删除
              } else if (_holdCtrl.value < 0.12) {
                _holdCtrl.stop();
                _holdCtrl.value = 0;
                _tearOff();             // 短按 = 撕掉关闭
              } else {
                _holdCtrl.reverse();    // 未到最大 = 取消回缩
              }
            },
            onPointerCancel: (_) {
              _holdCancelled = false;
              if (!_deleting) _holdCtrl.reverse();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              width: size,
              height: size,
              child: CustomPaint(
                painter: _DogEarPainter(
                  bodyColor: bodyColor,
                  brightness: brightness,
                  lift: _dogEarHover || hold > 0,
                  danger: hold,
                  dangerColor: cs.error,
                ),
                child: atMax
                    ? Align(
                        // 折角三角占盒子左上半 → 图标放三角形重心处
                        alignment: const Alignment(-0.4, -0.4),
                        child: Icon(Icons.delete,
                            size: (size * 0.30).clamp(14.0, 26.0),
                            color: Colors.white),
                      )
                    : null,
              ),
            ),
          ),
        );
      },
    );
  }

  /// 左上角撕角换色：按下撕开露出随机新色，松开应用；移出取消
  Widget _buildColorPeel(NoteColorSpec spec, Brightness brightness) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          var idx = math.Random().nextInt(kNoteColors.length);
          if (idx == note.colorIndex) idx = (idx + 1) % kNoteColors.length;
          setState(() => _peelColorIndex = idx);
          _peelCtrl.forward(from: 0);
        },
        onTapUp: (_) {
          if (_peelColorIndex >= 0) {
            setState(() {
              note.colorIndex = _peelColorIndex;
              _peelColorIndex = -1;
            });
            _scheduleSave();
          }
          _peelCtrl.reverse();
        },
        onTapCancel: () {
          setState(() => _peelColorIndex = -1);
          _peelCtrl.reverse();
        },
        child: AnimatedBuilder(
          animation: _peelCtrl,
          builder: (ctx, _) {
            final t = Curves.easeOut.transform(_peelCtrl.value);
            final size = 20 + t * 22; // 按下逐渐撕大
            final idx = _peelColorIndex;
            return SizedBox(
              width: size,
              height: size,
              child: idx >= 0 && t > 0.01
                  ? CustomPaint(
                      painter: _CornerPeelPainter(
                        reveal: kNoteColors[idx].title(brightness),
                        flapColor: spec.title(brightness),
                        brightness: brightness,
                      ),
                    )
                  : null,
            );
          },
        ),
      ),
    );
  }

  List<Widget> _buildResizeZones() {
    const t = 6.0; // 热区厚度
    const c = 12.0; // 角热区
    Widget zone({
      double? l, double? r, double? tp, double? b,
      double? w, double? h,
      required MouseCursor cursor,
      bool eL = false, bool eR = false, bool eT = false, bool eB = false,
    }) {
      return Positioned(
        left: l, right: r, top: tp, bottom: b, width: w, height: h,
        child: MouseRegion(
          cursor: cursor,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: _resizeStart,
            onPanUpdate: (d) =>
                _resizeUpdate(d, left: eL, right: eR, top: eT, bottom: eB),
            onPanEnd: (_) => _resizeEnd(),
          ),
        ),
      );
    }

    return [
      // 边
      zone(l: c, r: c, tp: 0, h: 4, cursor: SystemMouseCursors.resizeUpDown, eT: true),
      zone(l: c, r: c, b: 0, h: t, cursor: SystemMouseCursors.resizeUpDown, eB: true),
      zone(tp: c, b: c, l: 0, w: t, cursor: SystemMouseCursors.resizeLeftRight, eL: true),
      zone(tp: c, b: c, r: 0, w: t, cursor: SystemMouseCursors.resizeLeftRight, eR: true),
      // 角（右下角让位给折角，只留细边）
      zone(l: 0, tp: 0, w: c, h: 4, cursor: SystemMouseCursors.resizeUpLeftDownRight, eL: true, eT: true),
      zone(r: 0, tp: 0, w: c, h: 4, cursor: SystemMouseCursors.resizeUpRightDownLeft, eR: true, eT: true),
      zone(l: 0, b: 0, w: c, h: t, cursor: SystemMouseCursors.resizeUpRightDownLeft, eL: true, eB: true),
    ];
  }
}

/// 小号 Cancel 按钮（锁屏 UI 右侧）
class _SmallCancelBtn extends StatelessWidget {
  final Color dim;
  final VoidCallback onTap;
  const _SmallCancelBtn({required this.dim, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Text('Cancel',
          style: TextStyle(fontSize: 10.5, color: dim)),
    );
  }
}

/// 折角画笔：便签右下角翻起的三角
class _DogEarPainter extends CustomPainter {
  final Color bodyColor;
  final Brightness brightness;
  final bool lift;
  final double danger;       // 0..1 长按进度（接近 1 = 删除倒计时）
  final Color dangerColor;
  _DogEarPainter({
    required this.bodyColor,
    required this.brightness,
    required this.lift,
    this.danger = 0,
    this.dangerColor = const Color(0xFFE53935),
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // 底下露出的"背面"阴影区（撕开的缝隙）
    final under = Path()
      ..moveTo(0, h)
      ..lineTo(w, 0)
      ..lineTo(w, h)
      ..close();
    canvas.drawPath(
      under,
      Paint()
        ..color = brightness == Brightness.dark
            ? Colors.black.withAlpha(150)
            : Colors.black.withAlpha(45),
    );
    // 翻起的折角三角（比 body 亮/暗一点）；长按接近阈值 → 变红警示
    final hsl = HSLColor.fromColor(bodyColor);
    final baseEar = brightness == Brightness.dark
        ? hsl.withLightness((hsl.lightness + 0.10).clamp(0.0, 1.0)).toColor()
        : hsl.withLightness((hsl.lightness - 0.10).clamp(0.0, 1.0)).toColor();
    final earColor = Color.lerp(baseEar, dangerColor, danger) ?? baseEar;
    final ear = Path()
      ..moveTo(0, h)
      ..lineTo(w, 0)
      ..lineTo(0, 0)
      ..close();
    canvas.drawShadow(ear, Colors.black, lift ? 3.5 : 2.0, false);
    canvas.drawPath(ear, Paint()..color = earColor);
  }

  @override
  bool shouldRepaint(_DogEarPainter old) =>
      old.bodyColor != bodyColor || old.lift != lift ||
      old.brightness != brightness || old.danger != danger ||
      old.dangerColor != dangerColor;
}

/// 左上角撕角换色画笔：撕开的夹层露出新色一角
class _CornerPeelPainter extends CustomPainter {
  final Color reveal;       // 露出层颜色（新便签色）
  final Color flapColor;    // 上层（当前色）折角
  final Brightness brightness;
  _CornerPeelPainter({
    required this.reveal,
    required this.flapColor,
    required this.brightness,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // 露出层（新颜色三角）
    final revealPath = Path()
      ..moveTo(0, 0)
      ..lineTo(w, 0)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(revealPath, Paint()..color = reveal);
    // 上层折角（当前颜色，沿对角线向内翻折 —— 与右下折角镜像）
    final hsl = HSLColor.fromColor(flapColor);
    final flap = brightness == Brightness.dark
        ? hsl.withLightness((hsl.lightness + 0.08).clamp(0.0, 1.0)).toColor()
        : hsl.withLightness((hsl.lightness - 0.08).clamp(0.0, 1.0)).toColor();
    final flapPath = Path()
      ..moveTo(w, 0)
      ..lineTo(0, h)
      ..lineTo(w, h)
      ..close();
    canvas.drawShadow(flapPath, Colors.black, 2.5, false);
    canvas.drawPath(flapPath, Paint()..color = flap);
  }

  @override
  bool shouldRepaint(_CornerPeelPainter old) =>
      old.reveal != reveal || old.flapColor != flapColor ||
      old.brightness != brightness;
}
