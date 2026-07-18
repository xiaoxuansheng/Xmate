/// 便签数据模型与配色
///
/// 8 种经典便签色，每种含 light/dark 两套（标题偏深 + 内容偏浅）。
/// 便签记录持久化为 %APPDATA%\XMate\notes\<id>.json（见 note_store.dart）。
library;

import 'package:flutter/material.dart';

/// 一种便签配色（标题栏 / 内容区 × light / dark）
class NoteColorSpec {
  final Color lightTitle;
  final Color lightBody;
  final Color darkTitle;
  final Color darkBody;
  const NoteColorSpec({
    required this.lightTitle,
    required this.lightBody,
    required this.darkTitle,
    required this.darkBody,
  });

  Color title(Brightness b) => b == Brightness.dark ? darkTitle : lightTitle;
  Color body(Brightness b) => b == Brightness.dark ? darkBody : lightBody;

  /// 正文文字色（保证在 body 上可读）
  static Color text(Brightness b) =>
      b == Brightness.dark ? const Color(0xFFECECE4) : const Color(0xFF3A3A30);

  /// 次要文字色
  static Color textDim(Brightness b) =>
      b == Brightness.dark ? const Color(0x99ECECE4) : const Color(0x883A3A30);
}

/// 8 种预设便签色（黄/粉/蓝/绿/橙/紫/薄荷/灰）
const kNoteColors = <NoteColorSpec>[
  NoteColorSpec( // 0 经典黄
    lightTitle: Color(0xFFEFDC82), lightBody: Color(0xFFFDF6B8),
    darkTitle: Color(0xFF3A361E), darkBody: Color(0xFF4A452C)),
  NoteColorSpec( // 1 粉
    lightTitle: Color(0xFFF2B3C6), lightBody: Color(0xFFFDDCE6),
    darkTitle: Color(0xFF3A2229), darkBody: Color(0xFF4A3038)),
  NoteColorSpec( // 2 蓝
    lightTitle: Color(0xFFA9CCEC), lightBody: Color(0xFFD8EAFA),
    darkTitle: Color(0xFF202B3A), darkBody: Color(0xFF2D3A4A)),
  NoteColorSpec( // 3 绿
    lightTitle: Color(0xFFAEDCA4), lightBody: Color(0xFFDCF2D5),
    darkTitle: Color(0xFF213321), darkBody: Color(0xFF2F4230)),
  NoteColorSpec( // 4 橙
    lightTitle: Color(0xFFF5C08D), lightBody: Color(0xFFFEE7C8),
    darkTitle: Color(0xFF3A2C1B), darkBody: Color(0xFF4A3A28)),
  NoteColorSpec( // 5 紫
    lightTitle: Color(0xFFC9B2E8), lightBody: Color(0xFFEBE0F8),
    darkTitle: Color(0xFF2D2239), darkBody: Color(0xFF3C3049)),
  NoteColorSpec( // 6 薄荷
    lightTitle: Color(0xFFA3DDD0), lightBody: Color(0xFFD8F2EC),
    darkTitle: Color(0xFF1C332F), darkBody: Color(0xFF29423D)),
  NoteColorSpec( // 7 灰
    lightTitle: Color(0xFFCFCFCB), lightBody: Color(0xFFEDEDE9),
    darkTitle: Color(0xFF2A2A2A), darkBody: Color(0xFF383838)),
];

/// 一条 @时间 提醒（一个便签可有多个，显示最近的未触发项）
class NoteReminderEntry {
  final String token;  // @token 原文（内容匹配的稳定锚点）
  final int at;        // 触发时刻 epoch ms（相对时间按 token 创建时锚定）
  bool fired;          // 已触发
  NoteReminderEntry({required this.token, required this.at, this.fired = false});

  Map<String, dynamic> toJson() => {'token': token, 'at': at, 'fired': fired};

  static NoteReminderEntry fromJson(Map<String, dynamic> m) => NoteReminderEntry(
        token: m['token'] as String? ?? '',
        at: m['at'] as int? ?? 0,
        fired: m['fired'] as bool? ?? false,
      );
}

/// 一条便签记录
class NoteData {
  final String id;
  String content;          // markdown 源文本
  int colorIndex;          // kNoteColors 下标
  bool pinned;             // 置顶
  bool closed;             // 已撕掉（仅设置页可见）
  final int createdAt;     // epoch ms
  int updatedAt;           // epoch ms
  double? x, y, w, h;      // 窗口位置/大小（逻辑像素）
  bool autoFit;            // 高度自适应内容
  // ── 锁（加密折叠）：口令不落盘，只存 KDF 验证子；内容流加密 ──
  String lockHash;         // 口令验证子（空 = 未上锁）
  String lockSalt;         // 每便签随机盐
  String lockEnc;          // 加密后的内容（base64；上锁期间 content 为空）
  int lockFails;           // 连续错码次数（3 次起递增锁定）
  int lockUntil;           // 锁定截止 epoch ms（0 = 未锁定）
  List<NoteReminderEntry> reminders; // @时间提醒列表

  NoteData({
    required this.id,
    this.content = '',
    this.colorIndex = 0,
    this.pinned = false,
    this.closed = false,
    required this.createdAt,
    required this.updatedAt,
    this.x, this.y, this.w, this.h,
    this.autoFit = true,
    this.lockHash = '',
    this.lockSalt = '',
    this.lockEnc = '',
    this.lockFails = 0,
    this.lockUntil = 0,
    List<NoteReminderEntry>? reminders,
  }) : reminders = reminders ?? [];

  /// 已上锁（折叠）：内容隐藏，clear/合并/删除均不生效
  bool get locked => lockHash.isNotEmpty;

  /// 最近的未触发提醒（无则 null）
  NoteReminderEntry? get nextReminder {
    NoteReminderEntry? best;
    for (final r in reminders) {
      if (r.fired) continue;
      if (best == null || r.at < best.at) best = r;
    }
    return best;
  }

  NoteColorSpec get color =>
      kNoteColors[colorIndex.clamp(0, kNoteColors.length - 1)];

  /// 首行纯文本预览（去除 markdown 标记）
  String get preview {
    for (final raw in content.split('\n')) {
      var line = raw.trim();
      if (line.isEmpty) continue;
      line = line
          .replaceFirst(RegExp(r'^#{1,3}\s+'), '')
          .replaceFirst(RegExp(r'^- \[[ xX]\]\s+'), '')
          .replaceFirst(RegExp(r'^[-*]\s+'), '')
          .replaceFirst(RegExp(r'^\d+\.\s+'), '');
      if (line == '---') continue;
      // 图片/文件块显示为标记
      final img = RegExp(r'^!\[[^\]]*\]\(([^)]+)\)$').firstMatch(line);
      if (img != null) return '[Image]';
      final file = RegExp(r'^\[([^\]]+)\]\([^)]+\)$').firstMatch(line);
      if (file != null) return '[File] ${file.group(1)}';
      if (line.isNotEmpty) return line;
    }
    return '(Empty note)';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'content': content,
        'colorIndex': colorIndex,
        'pinned': pinned,
        'closed': closed,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'x': x, 'y': y, 'w': w, 'h': h,
        'autoFit': autoFit,
        'lockHash': lockHash,
        'lockSalt': lockSalt,
        'lockEnc': lockEnc,
        'lockFails': lockFails,
        'lockUntil': lockUntil,
        'reminders': reminders.map((r) => r.toJson()).toList(),
      };

  static NoteData fromJson(Map<String, dynamic> m) {
    var reminders = <NoteReminderEntry>[];
    final rawList = m['reminders'];
    if (rawList is List) {
      reminders = rawList
          .whereType<Map<String, dynamic>>()
          .map(NoteReminderEntry.fromJson)
          .where((r) => r.token.isNotEmpty && r.at > 0)
          .toList();
    }
    return NoteData(
      id: m['id'] as String? ?? '',
      content: m['content'] as String? ?? '',
      colorIndex: m['colorIndex'] as int? ?? 0,
      pinned: m['pinned'] as bool? ?? false,
      closed: m['closed'] as bool? ?? false,
      createdAt: m['createdAt'] as int? ?? 0,
      updatedAt: m['updatedAt'] as int? ?? 0,
      x: (m['x'] as num?)?.toDouble(),
      y: (m['y'] as num?)?.toDouble(),
      w: (m['w'] as num?)?.toDouble(),
      h: (m['h'] as num?)?.toDouble(),
      autoFit: m['autoFit'] as bool? ?? true,
      lockHash: m['lockHash'] as String? ?? '',
      lockSalt: m['lockSalt'] as String? ?? '',
      lockEnc: m['lockEnc'] as String? ?? '',
      lockFails: m['lockFails'] as int? ?? 0,
      lockUntil: m['lockUntil'] as int? ?? 0,
      reminders: reminders,
    );
  }
}
