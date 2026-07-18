/// 便签存储与进程启动
///
/// 每条便签一个 JSON 文件：%APPDATA%\XMate\notes\<id>.json
/// 图片资产目录：%APPDATA%\XMate\notes\assets\
///
/// 写入规则（避免多进程竞争）：
///  - 便签进程只写自己的文件
///  - 主进程仅在目标便签窗口不存在时才直接写其文件
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/services.dart';

import 'note_model.dart';
import 'note_reminder.dart';

class NoteStore {
  static String get dir {
    final d = '${io.Platform.environment['APPDATA']}\\XMate\\notes';
    io.Directory(d).createSync(recursive: true);
    return d;
  }

  static String get assetsDir {
    final d = '$dir\\assets';
    io.Directory(d).createSync(recursive: true);
    return d;
  }

  static String _pathOf(String id) => '$dir\\$id.json';

  static String get _orderPath => '$dir\\_order.json';

  /// 用户自定义显示顺序（设置页拖拽排序），仅主进程写入。
  /// 独立文件存储 → 不与便签进程写各自 `<id>.json` 竞争。
  static List<String> loadOrder() {
    try {
      final f = io.File(_orderPath);
      if (!f.existsSync()) return [];
      final m = jsonDecode(f.readAsStringSync());
      if (m is List) return m.whereType<String>().toList();
    } catch (_) {}
    return [];
  }

  static void saveOrder(List<String> ids) {
    try {
      io.File(_orderPath).writeAsStringSync(jsonEncode(ids));
    } catch (_) {}
  }

  /// 列出所有便签。排序：未入自定义顺序的（新建）按 updatedAt 降序在前，
  /// 已排序的按用户顺序在后；从未排序过时 = 全部 updatedAt 降序（原行为）。
  static List<NoteData> list() {
    final result = <NoteData>[];
    try {
      for (final f in io.Directory(dir).listSync()) {
        if (f is! io.File || !f.path.endsWith('.json')) continue;
        try {
          final m = jsonDecode(f.readAsStringSync());
          if (m is Map<String, dynamic>) {
            final n = NoteData.fromJson(m);
            if (n.id.isNotEmpty) result.add(n);
          }
        } catch (_) {}
      }
    } catch (_) {}
    final order = loadOrder();
    result.sort((a, b) {
      final ia = order.indexOf(a.id), ib = order.indexOf(b.id);
      if (ia >= 0 && ib >= 0) return ia.compareTo(ib);
      if (ia != ib) return ia >= 0 ? 1 : -1; // 未排序的（新建）在前
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return result;
  }

  static NoteData? load(String id) {
    try {
      final f = io.File(_pathOf(id));
      if (!f.existsSync()) return null;
      final m = jsonDecode(f.readAsStringSync());
      if (m is Map<String, dynamic>) return NoteData.fromJson(m);
    } catch (_) {}
    return null;
  }

  static void save(NoteData note) {
    note.updatedAt = DateTime.now().millisecondsSinceEpoch;
    try {
      io.File(_pathOf(note.id))
          .writeAsStringSync(const JsonEncoder.withIndent('  ')
              .convert(note.toJson()));
    } catch (_) {}
  }

  static void delete(String id) {
    try {
      final f = io.File(_pathOf(id));
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// 删除全部便签（锁定的跳过；含资产目录与排序文件，有锁定便签时保留资产）
  static void deleteAll() {
    var lockedRemain = false;
    for (final n in list()) {
      if (n.locked) {
        lockedRemain = true;
        continue; // 锁定（折叠）便签不被 clear
      }
      delete(n.id);
    }
    try {
      final o = io.File(_orderPath);
      if (o.existsSync()) o.deleteSync();
    } catch (_) {}
    if (lockedRemain) return; // 锁定便签可能引用图片资产 → 保留
    try {
      final a = io.Directory(assetsDir);
      if (a.existsSync()) a.deleteSync(recursive: true);
    } catch (_) {}
  }

  static int _lastColorIndex = -1;

  /// 新建便签（随机取色，避开上一次的颜色）
  static NoteData create(String content) {
    final now = DateTime.now().millisecondsSinceEpoch;
    var color = now % kNoteColors.length;
    if (color == _lastColorIndex) color = (color + 1) % kNoteColors.length;
    _lastColorIndex = color;
    final note = NoteData(
      id: 'n$now',
      content: content,
      colorIndex: color,
      createdAt: now,
      updatedAt: now,
    );
    NoteReminder.recompute(note);
    save(note);
    return note;
  }
}

/// 便签进程启动与跨进程消息（com.xmate/notes channel 封装）
class NoteLauncher {
  static const _channel = MethodChannel('com.xmate/notes');

  /// 启动（或前置已存在的）便签窗口进程
  static Future<void> spawn(String id) async {
    try {
      await io.Process.start(
        io.Platform.resolvedExecutable,
        ['--note', id],
        mode: io.ProcessStartMode.detached,
      );
    } catch (_) {}
  }

  /// 新建便签并打开窗口
  static Future<NoteData> createAndOpen(String content) async {
    final note = NoteStore.create(content);
    await spawn(note.id);
    return note;
  }

  /// 当前打开中的便签窗口 id 集合
  static Future<Set<String>> openNoteIds() async {
    try {
      final json = await _channel.invokeMethod<String>('listNoteWindows');
      if (json == null || json.isEmpty) return {};
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map((e) => (e as Map<String, dynamic>)['id'] as String? ?? '')
          .where((s) => s.isNotEmpty)
          .toSet();
    } catch (_) {
      return {};
    }
  }

  /// 打开中的便签窗口矩形（物理像素）：id → [l, t, r, b]
  static Future<Map<String, List<int>>> openNoteRects() async {
    final result = <String, List<int>>{};
    try {
      final json = await _channel.invokeMethod<String>('listNoteWindows');
      if (json == null || json.isEmpty) return result;
      final list = jsonDecode(json) as List<dynamic>;
      for (final e in list) {
        final m = e as Map<String, dynamic>;
        final id = m['id'] as String? ?? '';
        if (id.isEmpty) continue;
        result[id] = [
          (m['l'] as num).toInt(), (m['t'] as num).toInt(),
          (m['r'] as num).toInt(), (m['b'] as num).toInt(),
        ];
      }
    } catch (_) {}
    return result;
  }

  /// 向打开中的便签窗口发送命令（临时 JSON 文件 + WM_COPYDATA）。
  /// 返回 false = 窗口不存在（调用方回退直接写文件）。
  static Future<bool> sendCommand(String id, Map<String, dynamic> cmd) async {
    try {
      final tmp = await io.Directory.systemTemp.createTemp('xmate_note_');
      final file = io.File('${tmp.path}\\note_cmd.json');
      await file.writeAsString(jsonEncode(cmd));
      final ok = await _channel.invokeMethod<bool>('sendNoteData', {
        'id': id,
        'dataPath': file.path,
      });
      if (ok != true) {
        try { await file.delete(); } catch (_) {}
      }
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  /// 追加文本到便签：窗口打开 → 发消息实时追加；否则直接写文件。
  /// 锁定（折叠）便签不接受追加（窗口侧同样有守卫）。
  static Future<void> appendText(String id, String text) async {
    if (text.trim().isEmpty) return;
    if (NoteStore.load(id)?.locked ?? false) return;
    final delivered = await sendCommand(id, {'cmd': 'append', 'text': text});
    if (delivered) return;
    final note = NoteStore.load(id);
    if (note == null || note.locked) return;
    note.content = note.content.isEmpty ? text : '${note.content}\n$text';
    NoteReminder.recompute(note);
    NoteStore.save(note);
  }

  static Future<bool> closeWindow(String id) async {
    try {
      return await _channel.invokeMethod<bool>(
              'closeNoteWindow', {'id': id}) ==
          true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> focusWindow(String id) async {
    try {
      return await _channel.invokeMethod<bool>(
              'focusNoteWindow', {'id': id}) ==
          true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> beep() async {
    try { await _channel.invokeMethod('beep'); } catch (_) {}
  }
}
