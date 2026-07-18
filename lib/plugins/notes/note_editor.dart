/// 便签块式编辑器（Notion 式，自研，无第三方依赖）
///
/// 渲染策略：未聚焦块渲染为样式化 Text.rich（链接可点、todo 可勾选、
/// @时间主题色高亮）；点击块 → 切换为 TextField 编辑（全局同时只有一个
/// TextField，焦点切换时提交回块模型）。
///
/// 标记+空格转换：`# ` `## ` `### ` `[] ` `[ ] ` `* ` `- ` `1. ` `--- `
/// Enter 分裂块 / 列表延续；空列表项 Enter 退回段落；行首 Backspace
/// 降级 / 并入上一块（经 controller 文本检测，IME 安全 —— Enter 不在
/// 按键层拦截，见 CLAUDE.md 坑点 #3）。
library;

import 'dart:io' as io;

import 'package:flutter/gestures.dart' show kPrimaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/drag/drag_out_helper.dart';
import 'note_blocks.dart';
import 'note_model.dart';
import 'note_reminder.dart';

// ── 共享文本工具 ──────────────────────────────────────────────

final _reUrl = RegExp(r'https?://[^\s　]+');

/// 内联样式：**加粗** / *斜体* / <u>下划线</u>，支持嵌套
/// （如 `**粗 *粗斜* 粗**`）。递归配对解析，不用单遍正则。
/// 渲染态隐藏标记字符（WYSIWYG）；编辑态（聚焦块）标记以暗淡小字显示，
/// 保证 TextField 文本偏移 1:1（Obsidian live-preview 模式）。

/// 在 [seg] 中从 [from] 起找 [open]...[close] 的最近非空配对。
/// 返回 (openIndex, closeIndex)；无可闭合配对返回 null。
(int, int)? _findPair(String seg, int from, String open, String close) {
  var p = seg.indexOf(open, from);
  while (p >= 0) {
    final q = seg.indexOf(close, p + open.length);
    if (q < 0) return null;
    if (q > p + open.length) return (p, q); // 内容非空
    p = q; // 空内容（如 ****）：闭合标记转为新的起始候选
  }
  return null;
}

/// 渲染 span 结果：附带 渲染偏移 → 源偏移 映射（隐藏标记后点击定位用）
class RenderedSpans {
  final List<InlineSpan> spans;
  final List<(int, int, int)> segments; // (renderedStart, sourceStart, len) 递增
  const RenderedSpans(this.spans, this.segments);

  int sourceOffset(int renderedOffset, int sourceLength) {
    if (segments.isEmpty) return renderedOffset.clamp(0, sourceLength);
    for (final (rs, ss, len) in segments) {
      if (renderedOffset < rs) return ss;
      if (renderedOffset < rs + len) return ss + (renderedOffset - rs);
    }
    return sourceLength;
  }
}

/// 高亮 span 构建：内联样式 + URL/@时间 accent 着色。
/// [hideMarkers] 渲染态隐藏 **/*/<u> 标记；
/// [isFired] 已触发的 @token → 暗淡 + 删除线。
RenderedSpans buildNoteSpans(
  String text,
  TextStyle base,
  Color accent, {
  bool hideMarkers = false,
  bool Function(String token)? isFired,
}) {
  final spans = <InlineSpan>[];
  final segs = <(int, int, int)>[];
  int rPos = 0;

  void emit(String s, TextStyle st, int sStart) {
    if (s.isEmpty) return;
    spans.add(TextSpan(text: s, style: st));
    segs.add((rPos, sStart, s.length));
    rPos += s.length;
  }

  // URL / @token 高亮（已触发 token → 删除线）
  void emitPlain(String seg, int sStart, TextStyle st) {
    if (seg.isEmpty) return;
    final ranges = <(int, int, bool)>[]; // (start, end, isUrl)
    for (final m in _reUrl.allMatches(seg)) {
      ranges.add((m.start, m.end, true));
    }
    for (final r in NoteReminder.findAll(seg)) {
      ranges.add((r.start, r.end, false));
    }
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    int pos = 0;
    for (final (start, end, isUrl) in ranges) {
      if (start < pos) continue; // 重叠跳过
      if (start > pos) emit(seg.substring(pos, start), st, sStart + pos);
      final tokenText = seg.substring(start, end);
      TextStyle ts;
      if (isUrl) {
        ts = st.copyWith(
          color: accent,
          fontWeight: FontWeight.w600,
          decoration: TextDecoration.underline,
          decorationColor: accent,
        );
      } else if (isFired?.call(tokenText) ?? false) {
        final dim = (st.color ?? accent).withAlpha(110);
        ts = st.copyWith(
          color: dim,
          decoration: TextDecoration.lineThrough,
          decorationColor: dim,
        );
      } else {
        ts = st.copyWith(color: accent, fontWeight: FontWeight.w600);
      }
      emit(tokenText, ts, sStart + start);
      pos = end;
    }
    if (pos < seg.length) emit(seg.substring(pos), st, sStart + pos);
  }

  final markStyle = base.copyWith(
    color: (base.color ?? const Color(0xFF888888)).withAlpha(70),
    fontSize: (base.fontSize ?? 13.5) * 0.82,
  );
  void marker(String s, int sStart) {
    if (hideMarkers) return; // 渲染态：标记不输出（映射跳过该源区间）
    emit(s, markStyle, sStart);
  }

  // ── 递归内联解析（嵌套支持）──
  // 每层找起始最早的可闭合标记；同起点时 ** 优先于 *（避免拆散 **）；
  // 内层继承外层合成样式。标记配对不跨行（块内 \n 逐行解析）。
  void parseInline(String seg, int sStart, TextStyle st) {
    var pos = 0;
    while (pos < seg.length) {
      final bold = _findPair(seg, pos, '**', '**');
      final ul = _findPair(seg, pos, '<u>', '</u>');
      final it = _findPair(seg, pos, '*', '*');

      (int, int)? best;
      var bOpen = '', bClose = '';
      TextStyle Function(TextStyle)? merge;
      void consider((int, int)? cand, String open, String close,
          TextStyle Function(TextStyle) m) {
        if (cand == null) return;
        if (best == null || cand.$1 < best!.$1) {
          best = cand;
          bOpen = open;
          bClose = close;
          merge = m;
        }
      }

      consider(bold, '**', '**',
          (s) => s.copyWith(fontWeight: FontWeight.w700));
      consider(
          ul,
          '<u>',
          '</u>',
          (s) => s.copyWith(
              decoration: TextDecoration.underline, decorationColor: s.color));
      consider(it, '*', '*', (s) => s.copyWith(fontStyle: FontStyle.italic));

      if (best == null) {
        emitPlain(seg.substring(pos), sStart + pos, st);
        return;
      }
      final (p, q) = best!;
      if (p > pos) emitPlain(seg.substring(pos, p), sStart + pos, st);
      marker(bOpen, sStart + p);
      parseInline(seg.substring(p + bOpen.length, q),
          sStart + p + bOpen.length, merge!(st));
      marker(bClose, sStart + q);
      pos = q + bClose.length;
    }
  }

  // 按行解析（标记不跨块内换行），行间补回 \n 的映射
  var lineStart = 0;
  while (true) {
    final nl = text.indexOf('\n', lineStart);
    final end = nl < 0 ? text.length : nl;
    parseInline(text.substring(lineStart, end), lineStart, base);
    if (nl < 0) break;
    emit('\n', base, nl);
    lineStart = nl + 1;
  }
  if (spans.isEmpty) spans.add(TextSpan(text: '', style: base));
  return RenderedSpans(spans, segs);
}

/// 打开外部链接 / 文件
void openExternal(String target) {
  if (target.isEmpty) return;
  io.Process.run('cmd', ['/c', 'start', '', target]);
}

/// 编辑态 controller — live-preview：TextField 显示原始源文本（标记可见、
/// 偏移 1:1），但通过 [buildTextSpan] 套用 buildNoteSpans 的样式
/// （粗/斜/下划线即时渲染，标记暗淡小字）。IME 组词期间回退纯文本，
/// 保留系统组词下划线。
class _HighlightController extends TextEditingController {
  _HighlightController({super.text});

  /// 由 NoteEditor 注入（依赖块类型样式与主题色）
  RenderedSpans Function(String text)? spanBuilder;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final sb = spanBuilder;
    final composing = value.composing;
    if (sb == null ||
        (withComposing && composing.isValid && !composing.isCollapsed)) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }
    return TextSpan(style: style, children: sb(text).spans);
  }
}

// ── 编辑器 ───────────────────────────────────────────────────

class NoteEditor extends StatefulWidget {
  final String initialContent;
  final Brightness brightness;
  final ValueChanged<String> onChanged; // 每次内容变化回调序列化后的 markdown
  final bool Function(String)? isTokenFired; // 来自 note.reminders 的 fired 状态
  const NoteEditor({
    super.key,
    required this.initialContent,
    required this.brightness,
    required this.onChanged,
    this.isTokenFired,
  });
  @override
  State<NoteEditor> createState() => NoteEditorState();
}

class NoteEditorState extends State<NoteEditor> {
  late List<NoteBlock> _blocks;

  int _focused = -1;            // TextField 编辑中的块
  int _selected = -1;           // 选中的非文本块（divider/image/file）
  _HighlightController? _ctrl;
  FocusNode? _fieldFocus;
  final _nonTextFocus = FocusNode(); // 非文本块选中时接收 Backspace
  String _committedText = '';   // _ctrl 上一次已处理文本（区分 Enter/粘贴）

  // 图片/文件块拖出状态机（8px 阈值，与 command_palette 一致）
  int? _dragPtrId;
  Offset? _dragOrigin;
  bool _dragFired = false;

  // 块排序拖拽（右侧手柄 Draggable + 块 DragTarget 指示线插入）
  int? _dragFrom;              // 正在拖拽的块下标
  int _dropIndex = -1;         // 插入落点（0.._blocks.length）
  Offset _dragAnchor = Offset.zero; // feedback 锚点偏移（还原指针位置用）
  double _editorWidth = 280;   // LayoutBuilder 捕获的编辑器宽度

  @override
  void initState() {
    super.initState();
    _blocks = parseMarkdownBlocks(widget.initialContent);
  }

  @override
  void dispose() {
    _disposeField();
    _nonTextFocus.dispose();
    super.dispose();
  }

  void _disposeField() {
    _ctrl?.dispose();
    _ctrl = null;
    _fieldFocus?.dispose();
    _fieldFocus = null;
  }

  // ── 对外 API ──

  String get markdown => blocksToMarkdown(_blocks);

  /// 外部追加内容（命令面板 append / 便签合并 / 拖入）
  void appendBlocks(List<NoteBlock> newBlocks) {
    if (newBlocks.isEmpty) return;
    setState(() {
      // 仅剩一个空段落时直接替换
      if (_blocks.length == 1 &&
          _blocks[0].type == NoteBlockType.paragraph &&
          _blocks[0].text.isEmpty) {
        _blocks.clear();
      }
      _blocks.addAll(newBlocks);
    });
    _notify();
  }

  void appendMarkdown(String md) => appendBlocks(parseMarkdownBlocks(md));

  /// 重新加载内容（外部文件变化）
  void reload(String content) {
    setState(() {
      _commitField();
      _focused = -1;
      _selected = -1;
      _disposeField();
      _blocks = parseMarkdownBlocks(content);
    });
  }

  void _notify() => widget.onChanged(blocksToMarkdown(_blocks));

  // ── 焦点管理 ──

  void _commitField() {
    if (_focused >= 0 && _focused < _blocks.length && _ctrl != null) {
      _blocks[_focused].text = _ctrl!.text;
    }
  }

  void _focusBlock(int i, {int caret = -1}) {
    if (i < 0 || i >= _blocks.length || !_blocks[i].isTextual) return;
    _commitField();
    _disposeField();
    final b = _blocks[i];
    _ctrl = _HighlightController(text: b.text);
    // 编辑态 live-preview：标记可见（偏移 1:1）+ 样式即时渲染
    _ctrl!.spanBuilder = (t) => buildNoteSpans(
          t,
          _styleFor(b),
          Theme.of(context).colorScheme.primary,
          isFired: widget.isTokenFired,
        );
    final off = caret < 0 || caret > b.text.length ? b.text.length : caret;
    _ctrl!.selection = TextSelection.collapsed(offset: off);
    _committedText = b.text;
    _fieldFocus = FocusNode();
    setState(() {
      _focused = i;
      _selected = -1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fieldFocus?.requestFocus();
    });
  }

  void _unfocus() {
    _commitField();
    setState(() {
      _focused = -1;
      _selected = -1;
    });
    _disposeField();
    _notify();
  }

  void _selectNonText(int i) {
    _commitField();
    _disposeField();
    setState(() {
      _focused = -1;
      _selected = i;
    });
    _nonTextFocus.requestFocus();
  }

  // ── 文本变化：Enter 分裂 / 粘贴多行 / 标记转换 ──

  void _onTextChanged(int i) {
    if (_ctrl == null || i != _focused || i >= _blocks.length) return;
    final c = _ctrl!;
    // IME 组词中不处理（组词结束后会再次回调）
    final composing = c.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;

    final oldText = _committedText;
    final t = c.text;

    // ── 换行处理 ──
    // Enter → 分裂进入下一块；Shift+Enter → 块内换行；粘贴多行 → 逐行解析。
    final oldNl = '\n'.allMatches(oldText).length;
    final newNl = '\n'.allMatches(t).length;
    if (newNl > oldNl) {
      final isSingleEnter = t.length == oldText.length + 1 && newNl == oldNl + 1;
      final b = _blocks[i];

      // Shift+Enter → 保留 \n，留在本块
      if (isSingleEnter && HardwareKeyboard.instance.isShiftPressed) {
        b.text = t;
        _committedText = t;
        _notify();
        return;
      }

      // 空列表项 Enter → 退回段落
      if (isSingleEnter &&
          oldText.isEmpty &&
          (b.type == NoteBlockType.todo ||
              b.type == NoteBlockType.bullet ||
              b.type == NoteBlockType.numbered)) {
        b.type = NoteBlockType.paragraph;
        b.checked = false;
        _setFieldText('', 0);
        setState(() {});
        _notify();
        return;
      }

      if (isSingleEnter) {
        // 在插入点分裂为两块：列表延续同类型，标题/段落 → 段落
        final caret = c.selection.baseOffset.clamp(1, t.length);
        final before = t.substring(0, caret - 1);
        final after = t.substring(caret);
        b.text = before;
        final contType = switch (b.type) {
          NoteBlockType.todo => NoteBlockType.todo,
          NoteBlockType.bullet => NoteBlockType.bullet,
          NoteBlockType.numbered => NoteBlockType.numbered,
          _ => NoteBlockType.paragraph,
        };
        _blocks.insert(i + 1, NoteBlock(type: contType, text: after));
        // 先废弃旧 controller，防止 _focusBlock 的 commit 把含 \n 的旧文本
        // 写回当前块（V3.2.6 bug：回车后本块多出一行）
        _focused = -1;
        _disposeField();
        setState(() {});
        _notify();
        _focusBlock(i + 1, caret: 0);
        return;
      }

      // 粘贴多行 → 首行入当前块，其余逐行解析 markdown
      final lines = t.split('\n');
      b.text = lines[0];
      final inserted = parseMarkdownBlocks(lines.sublist(1).join('\n'));
      _blocks.insertAll(i + 1, inserted);
      _focused = -1;
      _disposeField();
      setState(() {});
      _notify();
      int focusTo = i + inserted.length;
      while (focusTo > i && !_blocks[focusTo].isTextual) {
        focusTo--;
      }
      if (_blocks[focusTo].isTextual) {
        _focusBlock(focusTo);
      }
      return;
    }

    // ── 标记+空格转换（光标须刚好在标记之后）──
    final sel = c.selection;
    if (sel.isCollapsed && sel.baseOffset > 0) {
      final transformed = _tryMarkerTransform(i, t, sel.baseOffset);
      if (transformed) return;
    }

    _blocks[i].text = t;
    _committedText = t;
    _notify();
  }

  /// 检测行首标记 → 转换块类型。返回 true 表示已处理。
  bool _tryMarkerTransform(int i, String t, int caret) {
    final b = _blocks[i];

    NoteBlockType? target;
    int markerLen = 0;

    if (t.startsWith('--- ') && caret == 4) {
      // 分割线：当前块变 divider，剩余文本进入新段落
      final remainder = t.substring(4);
      b.type = NoteBlockType.divider;
      b.text = '';
      _blocks.insert(
          i + 1, NoteBlock(type: NoteBlockType.paragraph, text: remainder));
      setState(() {});
      _notify();
      _focusBlock(i + 1, caret: 0);
      return true;
    } else if (t.startsWith('# ') && caret == 2) {
      target = NoteBlockType.h1; markerLen = 2;
    } else if (t.startsWith('## ') && caret == 3) {
      target = NoteBlockType.h2; markerLen = 3;
    } else if (t.startsWith('### ') && caret == 4) {
      target = NoteBlockType.h3; markerLen = 4;
    } else if (t.startsWith('[] ') && caret == 3) {
      target = NoteBlockType.todo; markerLen = 3;
    } else if (t.startsWith('[ ] ') && caret == 4) {
      target = NoteBlockType.todo; markerLen = 4;
    } else if (t.startsWith('【】 ') && caret == 3) {
      target = NoteBlockType.todo; markerLen = 3;
    } else if (t.startsWith('【 】 ') && caret == 4) {
      target = NoteBlockType.todo; markerLen = 4;
    } else if ((t.startsWith('* ') || t.startsWith('- ')) && caret == 2) {
      target = NoteBlockType.bullet; markerLen = 2;
    } else {
      final m = RegExp(r'^(\d+)\. ').firstMatch(t);
      if (m != null && caret == m.end) {
        target = NoteBlockType.numbered;
        markerLen = m.end;
      }
    }

    if (target == null || target == b.type) return false;
    b.type = target;
    if (target == NoteBlockType.todo) b.checked = false;
    _setFieldText(t.substring(markerLen), 0);
    b.text = _ctrl!.text;
    setState(() {});
    _notify();
    return true;
  }

  /// 静默更新 controller 文本 + 光标（不触发 onChanged 循环）
  void _setFieldText(String text, int caret) {
    _committedText = text;
    _ctrl!.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret),
    );
  }

  // ── 行首 Backspace / 跨块方向键 / Enter / Ctrl+B/U/I ──

  KeyEventResult _onFieldKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final c = _ctrl;
    if (c == null || _focused < 0) return KeyEventResult.ignored;
    // IME 组词中一律放行
    final composing = c.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    final sel = c.selection;

    // ── Enter / Shift+Enter ──
    if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter) {
      _committedText = c.text;
      if (HardwareKeyboard.instance.isShiftPressed) {
        // Shift+Enter → insert \n at caret, stay in this block
        final t = c.text;
        final caret = sel.isValid ? sel.start.clamp(0, t.length) : t.length;
        final nt = t.substring(0, caret) + '\n' + t.substring(caret);
        _blocks[_focused].text = nt;
        _setFieldText(nt, caret + 1);
        _notify();
        return KeyEventResult.handled;
      }
      // Normal Enter → let framework insert \n, _onTextChanged splits block
      return KeyEventResult.ignored;
    }

    if (k == LogicalKeyboardKey.backspace &&
        sel.isCollapsed &&
        sel.baseOffset == 0) {
      return _handleBackspaceAtStart()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.arrowUp &&
        sel.isCollapsed &&
        sel.baseOffset == 0) {
      final prev = _prevTextual(_focused);
      if (prev >= 0) {
        _focusBlock(prev);
        return KeyEventResult.handled;
      }
    }
    if (k == LogicalKeyboardKey.arrowDown &&
        sel.isCollapsed &&
        sel.baseOffset == c.text.length) {
      final next = _nextTextual(_focused);
      if (next >= 0) {
        _focusBlock(next, caret: 0);
        return KeyEventResult.handled;
      }
    }
    if (k == LogicalKeyboardKey.escape) {
      _unfocus();
      return KeyEventResult.handled;
    }

    // ── Ctrl+B / U / I → 加粗 / 下划线 / 斜体 ──
    if (HardwareKeyboard.instance.isControlPressed) {
      String? prefix, suffix;
      if (k == LogicalKeyboardKey.keyB) {
        prefix = '**'; suffix = '**';
      } else if (k == LogicalKeyboardKey.keyU) {
        prefix = '<u>'; suffix = '</u>';
      } else if (k == LogicalKeyboardKey.keyI) {
        prefix = '*'; suffix = '*';
      }
      if (prefix != null) {
        _toggleInlineStyle(prefix, suffix!);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// 选区包裹/去包裹内联样式标记；无选区则插入标记对并把光标置于中间。
  void _toggleInlineStyle(String prefix, String suffix) {
    final c = _ctrl;
    if (c == null || _focused < 0) return;
    final sel = c.selection;
    if (!sel.isValid) return;
    final t = c.text;
    final start = sel.start, end = sel.end;

    String newText;
    TextSelection newSel;
    if (sel.isCollapsed) {
      newText = t.substring(0, start) + prefix + suffix + t.substring(start);
      newSel = TextSelection.collapsed(offset: start + prefix.length);
    } else {
      final selText = t.substring(start, end);
      if (selText.startsWith(prefix) &&
          selText.endsWith(suffix) &&
          selText.length >= prefix.length + suffix.length) {
        // 选区内含标记 → 去除
        final inner =
            selText.substring(prefix.length, selText.length - suffix.length);
        newText = t.replaceRange(start, end, inner);
        newSel = TextSelection(
            baseOffset: start, extentOffset: start + inner.length);
      } else if (start >= prefix.length &&
          end + suffix.length <= t.length &&
          t.substring(start - prefix.length, start) == prefix &&
          t.substring(end, end + suffix.length) == suffix) {
        // 标记在选区外侧 → 去除
        newText = t.substring(0, start - prefix.length) +
            selText +
            t.substring(end + suffix.length);
        newSel = TextSelection(
            baseOffset: start - prefix.length,
            extentOffset: end - prefix.length);
      } else {
        // 包裹
        newText = t.replaceRange(start, end, '$prefix$selText$suffix');
        newSel = TextSelection(
            baseOffset: start + prefix.length,
            extentOffset: end + prefix.length);
      }
    }
    _committedText = newText;
    c.value = TextEditingValue(text: newText, selection: newSel);
    _blocks[_focused].text = newText;
    _notify();
  }

  bool _handleBackspaceAtStart() {
    final i = _focused;
    final b = _blocks[i];
    b.text = _ctrl!.text; // 先提交本块当前编辑内容
    // 非段落 → 先降级为段落
    if (b.type != NoteBlockType.paragraph) {
      setState(() {
        b.type = NoteBlockType.paragraph;
        b.checked = false;
      });
      _notify();
      return true;
    }
    if (i == 0) return false;
    final prev = _blocks[i - 1];
    if (prev.isTextual) {
      // 并入上一块
      final joinAt = prev.text.length;
      prev.text = prev.text + b.text;
      _blocks.removeAt(i);
      // 先废弃旧 controller，避免 _focusBlock 的 commit 把旧文本写入
      // 位移后的错误块（V3.2.6 bug 同源）
      _focused = -1;
      _disposeField();
      setState(() {});
      _notify();
      _focusBlock(i - 1, caret: joinAt);
    } else {
      // 上一块是 divider/image/file → 删除它（本块下标前移 1）
      _blocks.removeAt(i - 1);
      _focused = -1;
      _disposeField();
      setState(() {});
      _notify();
      _focusBlock(i - 1, caret: 0);
    }
    return true;
  }

  int _prevTextual(int from) {
    for (int i = from - 1; i >= 0; i--) {
      if (_blocks[i].isTextual) return i;
    }
    return -1;
  }

  int _nextTextual(int from) {
    for (int i = from + 1; i < _blocks.length; i++) {
      if (_blocks[i].isTextual) return i;
    }
    return -1;
  }

  // ── 非文本块删除 ──

  KeyEventResult _onNonTextKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_selected < 0 || _selected >= _blocks.length) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.backspace || k == LogicalKeyboardKey.delete) {
      setState(() {
        _blocks.removeAt(_selected);
        if (_blocks.isEmpty) _blocks.add(NoteBlock());
        _selected = -1;
      });
      _notify();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      setState(() => _selected = -1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ── 拖出（图片/文件块）──

  void _onBlockPointerDown(PointerDownEvent e) {
    if (_dragPtrId != null && _dragPtrId != e.pointer) return;
    _dragPtrId = e.pointer;
    _dragOrigin = e.position;
    _dragFired = false;
  }

  void _onBlockPointerMove(PointerMoveEvent e, NoteBlock b) {
    if (e.pointer != _dragPtrId || _dragOrigin == null || _dragFired) return;
    if ((e.buttons & kPrimaryMouseButton) == 0) return;
    if ((e.position - _dragOrigin!).distance < 8.0) return;
    _dragFired = true;
    final path = b.path;
    if (path.isEmpty) return;
    if (b.type == NoteBlockType.image) {
      const MethodChannel('com.xmate/dragout')
          .invokeMethod('start', {'mode': 'image', 'path': path})
          .whenComplete(_resetBlockDrag);
    } else {
      DragOutChannel.dragFile([path]).whenComplete(_resetBlockDrag);
    }
  }

  void _onBlockPointerEnd(PointerEvent e) {
    if (e.pointer == _dragPtrId) _resetBlockDrag();
  }

  void _resetBlockDrag() {
    _dragPtrId = null;
    _dragOrigin = null;
    _dragFired = false;
  }

  // ── 样式 ──

  /// 便签 body 色上的 pill 填充色（白色半透，暗/浅通用）
  Color _blockPillBg() {
    return widget.brightness == Brightness.dark
        ? Colors.white.withAlpha(20)
        : Colors.black.withAlpha(12);
  }

  TextStyle _styleFor(NoteBlock b) {
    final color = NoteColorSpec.text(widget.brightness);
    switch (b.type) {
      case NoteBlockType.h1:
        return TextStyle(
            fontSize: 19, fontWeight: FontWeight.w700, color: color, height: 1.4);
      case NoteBlockType.h2:
        return TextStyle(
            fontSize: 16.5, fontWeight: FontWeight.w700, color: color, height: 1.4);
      case NoteBlockType.h3:
        return TextStyle(
            fontSize: 14.5, fontWeight: FontWeight.w600, color: color, height: 1.4);
      case NoteBlockType.todo:
        return TextStyle(
          fontSize: 13.5,
          color: b.checked ? NoteColorSpec.textDim(widget.brightness) : color,
          decoration: b.checked ? TextDecoration.lineThrough : null,
          decorationColor: NoteColorSpec.textDim(widget.brightness),
          height: 1.45,
        );
      default:
        return TextStyle(fontSize: 13.5, color: color, height: 1.45);
    }
  }

  // ── 构建 ──

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, constraints) {
      if (constraints.maxWidth.isFinite) _editorWidth = constraints.maxWidth;
      final children = <Widget>[];
      int numIndex = 0;
      for (int i = 0; i < _blocks.length; i++) {
        final b = _blocks[i];
        if (b.type == NoteBlockType.numbered) {
          numIndex++;
        } else {
          numIndex = 0;
        }
        final block = _buildBlock(i, b, numIndex);
        children.add(keyedBlock(i, block));
      }
      // 尾部空白区：点击 → 聚焦/新建末尾段落；拖拽悬停 → 落点为末尾
      children.add(DragTarget<int>(
        onWillAcceptWithDetails: (_) => true,
        onMove: (_) => _setDropIndex(_blocks.length),
        onAcceptWithDetails: _acceptDrop,
        builder: (tailCtx, cand, rej) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _focusTail,
          child: const SizedBox(height: 28, width: double.infinity),
        ),
      ));
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      );
    });
  }

  /// 块行包装：DragTarget（落点检测 + 指示线）+ 右侧拖拽手柄（仅选中块显示）
  Widget keyedBlock(int i, Widget block) {
    final accent = Theme.of(context).colorScheme.primary;
    final canReorder = _blocks.length >= 2;
    final showHandle = canReorder && (i == _focused || i == _selected);
    final dragging = _dragFrom != null;
    // 落点等于拖拽源原位时不显示指示线（放下也不会移动）
    final noop = dragging &&
        (_dropIndex == _dragFrom || _dropIndex == _dragFrom! + 1);
    final showTop = dragging && !noop && _dropIndex == i;
    final showBottom = dragging && !noop &&
        i == _blocks.length - 1 && _dropIndex == _blocks.length;

    Widget row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: block),
        if (canReorder)
          // TextFieldTapRegion：按住手柄不触发 TextField.onTapOutside，
          // 否则拖拽开始前编辑态就被提交、手柄随之消失
          TextFieldTapRegion(
            child: IgnorePointer(
              ignoring: !showHandle,
              child: AnimatedOpacity(
                opacity: showHandle ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                child: _buildDragHandle(i),
              ),
            ),
          ),
      ],
    );
    if (_dragFrom == i) row = Opacity(opacity: 0.35, child: row);

    BuildContext? targetCtx;
    return DragTarget<int>(
      key: ValueKey('blk_$i'),
      onWillAcceptWithDetails: (_) => true,
      onMove: (d) {
        final rb = targetCtx?.findRenderObject() as RenderBox?;
        if (rb == null || !rb.hasSize) return;
        // d.offset 是 feedback 锚点位置 → 加回锚点偏移得到指针位置
        final local = rb.globalToLocal(d.offset + _dragAnchor);
        _setDropIndex(local.dy < rb.size.height / 2 ? i : i + 1);
      },
      onAcceptWithDetails: _acceptDrop,
      builder: (ctx, cand, rej) {
        targetCtx = ctx;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            row,
            if (showTop)
              Positioned(
                  left: 0, right: 20, top: -1.5, child: _dropLine(accent)),
            if (showBottom)
              Positioned(
                  left: 0, right: 20, bottom: -1.5, child: _dropLine(accent)),
          ],
        );
      },
    );
  }

  Widget _dropLine(Color accent) => Container(
        height: 3,
        decoration: BoxDecoration(
          color: accent,
          borderRadius: BorderRadius.circular(1.5),
        ),
      );

  Widget _buildDragHandle(int i) {
    final icon = Padding(
      padding: const EdgeInsets.only(left: 4, top: 1),
      child: Icon(Icons.drag_indicator,
          size: 16, color: NoteColorSpec.textDim(widget.brightness)),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: Draggable<int>(
        data: i,
        dragAnchorStrategy: _feedbackAnchor,
        feedback: Builder(builder: (_) => _buildDragFeedback(i)),
        childWhenDragging: Opacity(opacity: 0.3, child: icon),
        onDragStarted: () => setState(() {
          _dragFrom = i;
          _dropIndex = -1;
        }),
        onDragEnd: (_) => _endDrag(),
        child: icon,
      ),
    );
  }

  double get _ghostWidth => (_editorWidth - 20).clamp(140.0, 480.0);

  /// feedback 锚点：指针握在幽灵块右上（对应手柄位置）
  Offset _feedbackAnchor(
      Draggable<Object> draggable, BuildContext context, Offset position) {
    _dragAnchor = Offset(_ghostWidth - 12, 14);
    return _dragAnchor;
  }

  /// 拖拽跟随的幽灵块（简化渲染，文本最多两行）
  Widget _buildDragFeedback(int i) {
    if (i < 0 || i >= _blocks.length) return const SizedBox.shrink();
    final b = _blocks[i];
    final accent = Theme.of(context).colorScheme.primary;
    final dim = NoteColorSpec.textDim(widget.brightness);

    Widget inner;
    switch (b.type) {
      case NoteBlockType.divider:
        inner = Container(height: 2, color: dim.withAlpha(120));
      case NoteBlockType.image:
        final f = io.File(b.path);
        inner = f.existsSync()
            ? Align(
                alignment: Alignment.centerLeft,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.file(f, height: 48, fit: BoxFit.contain),
                ),
              )
            : Icon(Icons.broken_image_outlined, size: 18, color: dim);
      case NoteBlockType.file:
        inner = Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.insert_drive_file_outlined,
              size: 15, color: accent.withAlpha(200)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              b.text,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5,
                  color: NoteColorSpec.text(widget.brightness)),
            ),
          ),
        ]);
      default:
        final rendered = buildNoteSpans(
          b.text, _styleFor(b), accent,
          hideMarkers: true,
          isFired: widget.isTokenFired,
        );
        inner = Text.rich(
          TextSpan(children: rendered.spans),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        );
    }

    return Material(
      elevation: 5,
      borderRadius: BorderRadius.circular(6),
      color: widget.brightness == Brightness.dark
          ? const Color(0xFF3A3A3A)
          : Colors.white,
      child: Container(
        width: _ghostWidth,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: accent.withAlpha(140), width: 1),
        ),
        child: inner,
      ),
    );
  }

  void _setDropIndex(int v) {
    if (_dropIndex != v) setState(() => _dropIndex = v);
  }

  void _endDrag() {
    if (_dragFrom == null && _dropIndex < 0) return;
    setState(() {
      _dragFrom = null;
      _dropIndex = -1;
    });
  }

  /// 释放：把 from 块移到 _dropIndex 插入位（可跨任意距离）
  void _acceptDrop(DragTargetDetails<int> d) {
    final from = d.data;
    final to = _dropIndex;
    if (to < 0 ||
        from < 0 ||
        from >= _blocks.length ||
        to == from ||
        to == from + 1) {
      _endDrag();
      return;
    }
    _commitField();
    final wasFocused = _focused == from;
    final wasSelected = _selected == from;
    _focused = -1;
    _selected = -1;
    _disposeField();
    final moved = _blocks.removeAt(from);
    final insertAt = to > from ? to - 1 : to;
    _blocks.insert(insertAt, moved);
    _dragFrom = null;
    _dropIndex = -1;
    setState(() {});
    _notify();
    // 保持拖拽前的选中/编辑态（落到新位置）
    if (wasFocused && moved.isTextual) {
      _focusBlock(insertAt);
    } else if (wasSelected) {
      setState(() => _selected = insertAt);
      _nonTextFocus.requestFocus();
    }
  }

  void _focusTail() {
    final last = _blocks.length - 1;
    if (_blocks[last].isTextual) {
      _focusBlock(last);
    } else {
      setState(() => _blocks.add(NoteBlock()));
      _notify();
      _focusBlock(_blocks.length - 1);
    }
  }

  Widget _buildBlock(int i, NoteBlock b, int numIndex) {
    switch (b.type) {
      case NoteBlockType.divider:
        return _buildDivider(i);
      case NoteBlockType.image:
        return _buildImage(i, b);
      case NoteBlockType.file:
        return _buildFile(i, b);
      default:
        return _buildTextual(i, b, numIndex);
    }
  }

  Widget _buildTextual(int i, NoteBlock b, int numIndex) {
    final style = _styleFor(b);
    final prefix = _buildPrefix(i, b, numIndex, style);
    final isEditing = i == _focused && _ctrl != null;
    final accent = Theme.of(context).colorScheme.primary;

    Widget content;
    if (isEditing) {
      content = Focus(
        onKeyEvent: _onFieldKey,
        child: TextField(
          controller: _ctrl,
          focusNode: _fieldFocus,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          style: style,
          cursorColor: accent,
          cursorHeight: style.fontSize! * 1.25,
          // 全部显式置空：亮色主题的 inputDecorationTheme 带 focusedBorder/filled，
          // 会给聚焦块叠加主题的边框和底色（暗色主题没有 → 两模式表现不一致），
          // 选中外框统一由下方 Container 绘制
          decoration: const InputDecoration(
            isDense: true,
            isCollapsed: true,
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
          onChanged: (_) => _onTextChanged(i),
          onTapOutside: (_) {
            // 点击窗口内其他位置：由目标块自己接管焦点；点击非交互区则提交
            if (_focused == i) _unfocus();
          },
        ),
      );
    } else {
      final hint = _blocks.length == 1 && b.text.isEmpty && i == 0;
      content = LayoutBuilder(builder: (ctx, constraints) {
        final cs = Theme.of(ctx).colorScheme;
        final rendered = hint
            ? RenderedSpans(
                [TextSpan(
                    text: 'Write your thoughts now...',
                    style: style.copyWith(
                        color: NoteColorSpec.textDim(widget.brightness)))],
                const [])
            : buildNoteSpans(
                b.text, style, cs.primary,
                hideMarkers: true,
                isFired: widget.isTokenFired,
              );
        final span = TextSpan(children: rendered.spans);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _handleRenderedTap(i, b, span, rendered, constraints.maxWidth, d),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text.rich(span),
            ),
          ),
        );
      });
    }

    // 选中（编辑中）块：主题色外框，亮/暗模式一致（自绘，不依赖 InputDecoration）；
    // 非编辑态保留同宽透明边框，避免进出编辑态时文本位移
    return Padding(
      padding: EdgeInsets.only(
        top: b.type == NoteBlockType.h1 || b.type == NoteBlockType.h2 ? 4 : 1,
        bottom: 1,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: isEditing ? accent.withAlpha(180) : Colors.transparent,
            width: 1.3,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ?prefix,
            Expanded(child: content),
          ],
        ),
      ),
    );
  }

  /// 未聚焦块点击：命中 URL → 打开；否则用 RenderedSpans 映射点击位置。
  void _handleRenderedTap(int i, NoteBlock b, TextSpan span,
      RenderedSpans rendered, double width, TapUpDetails d) {
    final painter = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    final pos = painter.getPositionForOffset(d.localPosition);
    painter.dispose();
    final sourceOff = rendered.sourceOffset(pos.offset, b.text.length);
    final offset = sourceOff.clamp(0, b.text.length);
    for (final m in _reUrl.allMatches(b.text)) {
      if (offset >= m.start && offset < m.end) {
        openExternal(m.group(0)!);
        return;
      }
    }
    _focusBlock(i, caret: offset);
  }

  Widget? _buildPrefix(int i, NoteBlock b, int numIndex, TextStyle style) {
    final dim = NoteColorSpec.textDim(widget.brightness);
    switch (b.type) {
      case NoteBlockType.todo:
        final accent = Theme.of(context).colorScheme.primary;
        return Padding(
          padding: const EdgeInsets.only(right: 6, top: 2),
          child: GestureDetector(
            onTap: () {
              setState(() => b.checked = !b.checked);
              _notify();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 15,
              height: 15,
              decoration: BoxDecoration(
                color: b.checked ? accent : Colors.transparent,
                borderRadius: BorderRadius.circular(3.5),
                border: Border.all(
                    color: b.checked ? accent : dim, width: 1.4),
              ),
              child: b.checked
                  ? const Icon(Icons.check, size: 11, color: Colors.white)
                  : null,
            ),
          ),
        );
      case NoteBlockType.bullet:
        return Padding(
          padding: const EdgeInsets.only(left: 2, right: 8),
          child: Text('•', style: style.copyWith(fontWeight: FontWeight.w700)),
        );
      case NoteBlockType.numbered:
        return Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Text('$numIndex.',
              style: style.copyWith(color: dim)),
        );
      default:
        return null;
    }
  }

  Widget _buildDivider(int i) {
    final selected = i == _selected;
    final dim = NoteColorSpec.textDim(widget.brightness);
    final accent = Theme.of(context).colorScheme.primary;
    Widget w = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _selectNonText(i),
      child: Container(
        height: 14,
        alignment: Alignment.center,
        decoration: selected
            ? BoxDecoration(
                border: Border.all(color: accent.withAlpha(120)),
                borderRadius: BorderRadius.circular(3))
            : null,
        child: Container(height: 1.2, color: dim.withAlpha(90)),
      ),
    );
    if (selected) {
      w = Focus(focusNode: _nonTextFocus, onKeyEvent: _onNonTextKey, child: w);
    }
    return Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: w);
  }

  Widget _buildImage(int i, NoteBlock b) {
    final selected = i == _selected;
    final accent = Theme.of(context).colorScheme.primary;
    final file = io.File(b.path);
    Widget img = file.existsSync()
        ? ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: Image.file(file, fit: BoxFit.contain, gaplessPlayback: true),
          )
        : Container(
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _blockPillBg(),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(Icons.broken_image_outlined,
                size: 20, color: NoteColorSpec.textDim(widget.brightness)),
          );

    Widget w = Listener(
      onPointerDown: _onBlockPointerDown,
      onPointerMove: (e) => _onBlockPointerMove(e, b),
      onPointerUp: _onBlockPointerEnd,
      onPointerCancel: _onBlockPointerEnd,
      child: GestureDetector(
        onTap: () => _selectNonText(i),
        onDoubleTap: () => openExternal(b.path),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: Container(
            decoration: selected
                ? BoxDecoration(
                    border: Border.all(color: accent.withAlpha(160), width: 1.5),
                    borderRadius: BorderRadius.circular(6))
                : null,
            padding: const EdgeInsets.all(1),
            child: img,
          ),
        ),
      ),
    );
    if (selected) {
      w = Focus(focusNode: _nonTextFocus, onKeyEvent: _onNonTextKey, child: w);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Align(alignment: Alignment.centerLeft, child: w),
    );
  }

  Widget _buildFile(int i, NoteBlock b) {
    final selected = i == _selected;
    final accent = Theme.of(context).colorScheme.primary;
    final textColor = NoteColorSpec.text(widget.brightness);
    Widget w = Listener(
      onPointerDown: _onBlockPointerDown,
      onPointerMove: (e) => _onBlockPointerMove(e, b),
      onPointerUp: _onBlockPointerEnd,
      onPointerCancel: _onBlockPointerEnd,
      child: GestureDetector(
        onTap: () => _selectNonText(i),
        onDoubleTap: () => openExternal(b.path),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: _blockPillBg(),
            borderRadius: BorderRadius.circular(6),
            border: selected
                ? Border.all(color: accent.withAlpha(160), width: 1.2)
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.insert_drive_file_outlined,
                  size: 15, color: accent.withAlpha(200)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  b.text,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: textColor),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected) {
      w = Focus(focusNode: _nonTextFocus, onKeyEvent: _onNonTextKey, child: w);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Align(alignment: Alignment.centerLeft, child: w),
    );
  }
}
