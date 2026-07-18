/// @时间提醒解析与格式化
///
/// 识别文本中任意位置的 @时间 token（中英文），解析为绝对时间：
///  - 相对：@30s @5min @30分钟 @2h @1小时 @1h30min @2天
///  - 时刻：@18:30 @18:30:15 @9点 @9点半（已过则顺延到明天）
///  - 日词：@今天9点 @明天 @后天18:00 @tomorrow 9:00
///  - 星期：@周五 @星期三 @Friday（下一个该星期，默认 09:00）
///  - 日期：@7月20日 10:00 @2026-07-20 18:30（M月D日已过顺延明年）
///  - UTC 校正：绝对时刻可带后缀，如 @18:30 UTC+8 / @2026-07-20 09:00 UTC
///
/// 一个便签可含多个 @token → [NoteData.reminders] 列表；recompute 按 token
/// 原文配对保留旧条目（相对时间按 token 首次输入时锚定，不因重解析重置），
/// 新 token 以当前时刻锚定。
library;

import 'note_model.dart';

/// 一次 @时间 匹配结果
class ReminderMatch {
  final String token;   // 含 @ 的完整原文
  final int start;      // 在源文本中的偏移
  final int end;
  final DateTime time;  // 解析出的绝对时间（本地）
  const ReminderMatch(this.token, this.start, this.end, this.time);
}

/// 时刻解析中间结果（h/mi/s + 可选 UTC 偏移分钟 + 消费长度）
class _ClockPart {
  final int h, mi, s;
  final int? utcMin; // null = 本地时间
  final int len;
  const _ClockPart(this.h, this.mi, this.s, this.utcMin, this.len);
}

class NoteReminder {
  // ── 正则（均从 '@' 之后开始匹配）──
  // 中文单位后不能用 \b（\b 只识别 ASCII 词字符），改用 (?![A-Za-z0-9])。
  static final _reDay = RegExp(r'^(\d+)\s*(天|days?|d)(?![A-Za-z0-9])');
  static final _reHourMin = RegExp(
      r'^(\d+)\s*(小时|时|hours?|hrs?|h)(?:\s*(\d+)\s*(分钟|分|minutes?|mins?|m))?(?![A-Za-z0-9])');
  static final _reMin =
      RegExp(r'^(\d+)\s*(分钟|分|minutes?|mins?|m)(?![A-Za-z0-9])');
  static final _reSec =
      RegExp(r'^(\d+)\s*(秒钟?|seconds?|secs?|s)(?![A-Za-z0-9])');
  static final _reClock = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2}))?');
  static final _reCnClock = RegExp(r'^(\d{1,2})点(半|(\d{1,2})分?)?');
  static final _reUtc =
      RegExp(r'^\s*(?:UTC|GMT)(?:([+-]\d{1,2})(?::?(\d{2}))?)?(?![A-Za-z0-9])');
  static final _reDayWord = RegExp(r'^(今天|明天|后天|today|tomorrow|tmr)');
  static final _reCnWeek = RegExp(r'^(?:周|星期|礼拜)([一二三四五六日天])');
  static final _reEnWeek = RegExp(
      r'^(monday|mon|tuesday|tue|wednesday|wed|thursday|thu|friday|fri|saturday|sat|sunday|sun)\b',
      caseSensitive: false);
  static final _reFullDate = RegExp(r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})');
  static final _reCnDate = RegExp(r'^(\d{1,2})月(\d{1,2})日?');

  /// 找出 [text] 中所有可解析的 @时间 token（任意位置，无需独立成块/词）。
  /// [anchor] 为相对时间的基准（默认 now）。
  static List<ReminderMatch> findAll(String text, {DateTime? anchor}) {
    final now = anchor ?? DateTime.now();
    final result = <ReminderMatch>[];
    for (int i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch != '@' && ch != '＠') continue;
      final rest = text.substring(i + 1);
      final parsed = _parseOne(rest, now);
      if (parsed == null) continue;
      final (time, len) = parsed;
      result.add(ReminderMatch(
          text.substring(i, i + 1 + len), i, i + 1 + len, time));
      i += len; // 跳过已消费部分
    }
    return result;
  }

  /// 解析 '@' 之后的文本，返回 (绝对时间, 消费长度)；无法解析返回 null。
  static (DateTime, int)? _parseOne(String s, DateTime now) {
    if (s.isEmpty) return null;

    // ── 相对：天 ──
    var m = _reDay.firstMatch(s);
    if (m != null) {
      final d = int.parse(m.group(1)!);
      if (d > 0 && d <= 3650) {
        return (now.add(Duration(days: d)), m.end);
      }
    }

    // ── 相对：小时（含 1h30min 组合）──
    m = _reHourMin.firstMatch(s);
    if (m != null) {
      final h = int.parse(m.group(1)!);
      final min = m.group(3) != null ? int.parse(m.group(3)!) : 0;
      if (h > 0 && h <= 8760 && min < 60) {
        return (now.add(Duration(hours: h, minutes: min)), m.end);
      }
    }

    // ── 相对：分钟 ──
    m = _reMin.firstMatch(s);
    if (m != null) {
      final min = int.parse(m.group(1)!);
      if (min > 0 && min <= 525600) {
        return (now.add(Duration(minutes: min)), m.end);
      }
    }

    // ── 相对：秒 ──
    m = _reSec.firstMatch(s);
    if (m != null) {
      final sec = int.parse(m.group(1)!);
      if (sec > 0 && sec <= 86400 * 7) {
        return (now.add(Duration(seconds: sec)), m.end);
      }
    }

    // ── 完整日期：2026-07-20 [18:30[:15]] [UTC+8] ──
    m = _reFullDate.firstMatch(s);
    if (m != null) {
      final y = int.parse(m.group(1)!);
      final mo = int.parse(m.group(2)!);
      final d = int.parse(m.group(3)!);
      if (y >= 2000 && y <= 2100 && mo >= 1 && mo <= 12 && d >= 1 && d <= 31) {
        final t = _parseTrailingTime(s.substring(m.end));
        final dt = _resolveWall(y, mo, d, t);
        return (dt, m.end + t.len);
      }
    }

    // ── 中文日期：7月20日 [10:00 / 10点] [UTC+8] ──
    m = _reCnDate.firstMatch(s);
    if (m != null) {
      final mo = int.parse(m.group(1)!);
      final d = int.parse(m.group(2)!);
      if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) {
        final t = _parseTrailingTime(s.substring(m.end));
        var dt = _resolveWall(now.year, mo, d, t);
        if (!dt.isAfter(now)) dt = _resolveWall(now.year + 1, mo, d, t);
        return (dt, m.end + t.len);
      }
    }

    // ── 日词：今天/明天/后天/today/tomorrow [时间] [UTC+8] ──
    m = _reDayWord.firstMatch(s);
    if (m != null) {
      final word = m.group(1)!.toLowerCase();
      final offset = (word == '明天' || word == 'tomorrow' || word == 'tmr')
          ? 1
          : (word == '后天' ? 2 : 0);
      final t = _parseTrailingTime(s.substring(m.end));
      final base = now.add(Duration(days: offset));
      final dt = _resolveWall(base.year, base.month, base.day, t);
      return (dt, m.end + t.len);
    }

    // ── 星期：周五 / Friday [时间] [UTC+8] ──
    int? weekday;
    int wLen = 0;
    m = _reCnWeek.firstMatch(s);
    if (m != null) {
      const map = {'一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 7, '天': 7};
      weekday = map[m.group(1)!];
      wLen = m.end;
    } else {
      m = _reEnWeek.firstMatch(s);
      if (m != null) {
        const map = {
          'mon': 1, 'tue': 2, 'wed': 3, 'thu': 4, 'fri': 5, 'sat': 6, 'sun': 7
        };
        weekday = map[m.group(1)!.toLowerCase().substring(0, 3)];
        wLen = m.end;
      }
    }
    if (weekday != null) {
      final t = _parseTrailingTime(s.substring(wLen));
      final delta = (weekday - now.weekday) % 7;
      var dt = _resolveWall(now.year, now.month, now.day + delta, t);
      if (!dt.isAfter(now)) dt = _resolveWall(now.year, now.month, now.day + delta + 7, t);
      return (dt, wLen + t.len);
    }

    // ── 时刻：18:30[:15] / 9点半 [UTC+8]（已过顺延明天）──
    final t = _parseClockAt(s);
    if (t != null) {
      DateTime dt;
      if (t.utcMin == null) {
        dt = DateTime(now.year, now.month, now.day, t.h, t.mi, t.s);
        if (!dt.isAfter(now)) dt = dt.add(const Duration(days: 1));
      } else {
        // 以该 UTC 偏移下的"今天"为基准
        final zoneNow = now.toUtc().add(Duration(minutes: t.utcMin!));
        dt = _wallAtOffset(
            zoneNow.year, zoneNow.month, zoneNow.day, t.h, t.mi, t.s, t.utcMin!);
        if (!dt.isAfter(now)) dt = dt.add(const Duration(days: 1));
      }
      return (dt, t.len);
    }

    return null;
  }

  /// 把 (y,mo,d) + 时刻部分解析为本地 DateTime（支持 UTC 偏移）。
  static DateTime _resolveWall(int y, int mo, int d, _ClockPart t) {
    if (t.utcMin == null) return DateTime(y, mo, d, t.h, t.mi, t.s);
    return _wallAtOffset(y, mo, d, t.h, t.mi, t.s, t.utcMin!);
  }

  /// wall 时间在 UTC+offsetMin 时区 → 本地 DateTime
  static DateTime _wallAtOffset(
      int y, int mo, int d, int h, int mi, int s, int offsetMin) {
    return DateTime.utc(y, mo, d, h, mi, s)
        .subtract(Duration(minutes: offsetMin))
        .toLocal();
  }

  /// 解析日期/日词/星期后紧跟的时间与 UTC 后缀（允许一个空格），
  /// 无时间时默认 09:00。
  static _ClockPart _parseTrailingTime(String s) {
    var offset = 0;
    var body = s;
    if (body.startsWith(' ') || body.startsWith('　')) {
      offset = 1;
      body = body.substring(1);
    }
    final t = _parseClockAt(body);
    if (t == null) {
      // 无时刻 → 仍尝试 UTC 后缀（如 "@明天 UTC+8" 默认 9:00）
      final u = _parseUtcSuffix(s);
      return _ClockPart(9, 0, 0, u?.$1, u?.$2 ?? 0);
    }
    return _ClockPart(t.h, t.mi, t.s, t.utcMin, offset + t.len);
  }

  /// 解析开头的时刻表达（18:30[:15] / 9点 / 9点半 / 9点15分 + 可选 UTC 后缀）。
  static _ClockPart? _parseClockAt(String s) {
    int h, mi, sec = 0, len;
    var m = _reClock.firstMatch(s);
    if (m != null) {
      h = int.parse(m.group(1)!);
      mi = int.parse(m.group(2)!);
      sec = m.group(3) != null ? int.parse(m.group(3)!) : 0;
      if (h > 23 || mi > 59 || sec > 59) return null;
      len = m.end;
    } else {
      m = _reCnClock.firstMatch(s);
      if (m == null) return null;
      h = int.parse(m.group(1)!);
      if (h > 23) return null;
      mi = 0;
      if (m.group(2) == '半') {
        mi = 30;
      } else if (m.group(3) != null) {
        mi = int.parse(m.group(3)!);
        if (mi > 59) return null;
      }
      len = m.end;
    }
    final u = _parseUtcSuffix(s.substring(len));
    if (u != null) {
      return _ClockPart(h, mi, sec, u.$1, len + u.$2);
    }
    return _ClockPart(h, mi, sec, null, len);
  }

  /// 解析 UTC 后缀：" UTC+8" / "UTC+8:30" / " GMT-5" / "UTC"（=UTC+0）。
  /// 返回 (偏移分钟, 消费长度)；无则 null。
  static (int, int)? _parseUtcSuffix(String s) {
    final m = _reUtc.firstMatch(s);
    if (m == null) return null;
    int offsetMin = 0;
    if (m.group(1) != null) {
      final hh = int.parse(m.group(1)!); // 含符号
      final mm = m.group(2) != null ? int.parse(m.group(2)!) : 0;
      if (hh.abs() > 14 || mm > 59) return null;
      offsetMin = hh * 60 + (hh < 0 ? -mm : mm);
    }
    return (offsetMin, m.end);
  }

  /// 内容变化后重算便签的提醒列表。
  /// 按 token 原文与旧条目逐一配对：token 未变 → 保留旧锚点与 fired 状态
  /// （相对时间不重置）；新 token → 以当前时刻解析入表；消失的 → 移除。
  static void recompute(NoteData note) {
    final matches = findAll(note.content);
    final old = note.reminders;
    final used = List<bool>.filled(old.length, false);
    final result = <NoteReminderEntry>[];
    for (final m in matches) {
      int found = -1;
      for (int i = 0; i < old.length; i++) {
        if (!used[i] && old[i].token == m.token) {
          found = i;
          break;
        }
      }
      if (found >= 0) {
        used[found] = true;
        result.add(old[found]);
      } else {
        result.add(NoteReminderEntry(
            token: m.token, at: m.time.millisecondsSinceEpoch));
      }
    }
    note.reminders = result;
  }

  /// 标题栏剩余时间显示：
  ///  ≤1h → 倒计时 "MM:SS"；>1h → "Xd Yh" / "Xh Ym"。
  static String formatRemaining(DateTime target, DateTime now) {
    var diff = target.difference(now);
    if (diff.isNegative) diff = Duration.zero;
    if (diff.inSeconds <= 3600) {
      final m = (diff.inSeconds ~/ 60).toString().padLeft(2, '0');
      final s = (diff.inSeconds % 60).toString().padLeft(2, '0');
      return '$m:$s';
    }
    final d = diff.inDays;
    final h = diff.inHours % 24;
    final mi = diff.inMinutes % 60;
    if (d > 0) return h > 0 ? '${d}d ${h}h' : '${d}d';
    return mi > 0 ? '${h}h ${mi}m' : '${h}h';
  }
}
