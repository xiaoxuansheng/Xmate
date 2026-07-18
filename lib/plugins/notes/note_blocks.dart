/// 便签内容块模型 —— markdown 源文本 ↔ 块列表双向转换
///
/// 块类型与 markdown 对应：
///   h1/h2/h3     `# ` `## ` `### `
///   todo         `- [ ] ` / `- [x] `
///   bullet       `- ` 或 `* `
///   numbered     `1. `（序列化时自动重排序号）
///   divider      `---`（独占一行）
///   image        `![](path)`（独占一行）
///   file         `[name](path)`（独占一行且 path 非 http）
///   paragraph    其余
///
/// 块 vs 行：一个块可含多行（Shift+Enter 产生块内 \n）。序列化时块内
/// \n 写为「行尾 `\` + 换行」续行标记；解析时行尾 `\` 的下一行原样并入
/// 同一块（不做块类型解析）。保证 关闭→重开 块结构无损往返。
library;

enum NoteBlockType {
  paragraph, h1, h2, h3, todo, bullet, numbered, divider, image, file,
}

class NoteBlock {
  NoteBlockType type;
  String text;    // 文本类块的内容；file 块 = 显示名
  bool checked;   // todo 勾选状态
  String path;    // image/file 块的路径

  NoteBlock({
    this.type = NoteBlockType.paragraph,
    this.text = '',
    this.checked = false,
    this.path = '',
  });

  bool get isTextual =>
      type != NoteBlockType.divider &&
      type != NoteBlockType.image &&
      type != NoteBlockType.file;
}

final _reTodo = RegExp(r'^- \[([ xX])\]\s?(.*)$');
final _reCnTodo = RegExp(r'^- \【([ xX])\】\s?(.*)$');  // 【】 also todo
final _reBullet = RegExp(r'^[-*]\s(.*)$');
final _reNumbered = RegExp(r'^\d+\.\s(.*)$');
final _reHeading = RegExp(r'^(#{1,3})\s(.*)$');
final _reImage = RegExp(r'^!\[[^\]]*\]\(([^)]+)\)$');
final _reFile = RegExp(r'^\[([^\]]+)\]\(([^)]+)\)$');
final _reEscaped = RegExp(r'^\\(.)(.*)$'); // \# \* \- \[ \] \--- etc.

/// markdown → 块列表（空内容返回一个空段落，编辑器始终有块可聚焦）
List<NoteBlock> parseMarkdownBlocks(String markdown) {
  final blocks = <NoteBlock>[];
  final raw = markdown.split('\n');
  int idx = 0;
  while (idx < raw.length) {
    final rawLine = raw[idx];
    idx++;
    // 行尾 `\`（trim 前检查）= 块内换行续行标记
    var cont = rawLine.endsWith('\\');
    final line = cont
        ? rawLine.substring(0, rawLine.length - 1)
        : rawLine.trimRight();
    final b = _parseLine(line);
    if (cont && b.isTextual) {
      final sb = StringBuffer(b.text);
      while (cont && idx < raw.length) {
        final nraw = raw[idx];
        idx++;
        cont = nraw.endsWith('\\');
        sb.write('\n');
        sb.write(cont ? nraw.substring(0, nraw.length - 1) : nraw.trimRight());
      }
      b.text = sb.toString();
    }
    blocks.add(b);
  }
  if (blocks.isEmpty) blocks.add(NoteBlock());
  return blocks;
}

/// 单个逻辑行（块首行）→ 块类型检测
NoteBlock _parseLine(String trimmed) {
  if (trimmed == '---') {
    return NoteBlock(type: NoteBlockType.divider);
  }
  // Backslash escape: \# \* \- \[ \] etc. → strip \ and treat as paragraph
  final esc = _reEscaped.firstMatch(trimmed);
  if (esc != null) {
    return NoteBlock(
        type: NoteBlockType.paragraph, text: esc.group(1)! + esc.group(2)!);
  }
  var m = _reHeading.firstMatch(trimmed);
  if (m != null) {
    final level = m.group(1)!.length;
    return NoteBlock(
      type: level == 1
          ? NoteBlockType.h1
          : level == 2
              ? NoteBlockType.h2
              : NoteBlockType.h3,
      text: m.group(2)!,
    );
  }
  m = _reTodo.firstMatch(trimmed);
  if (m != null) {
    return NoteBlock(
      type: NoteBlockType.todo,
      checked: m.group(1)!.toLowerCase() == 'x',
      text: m.group(2)!,
    );
  }
  m = _reCnTodo.firstMatch(trimmed);
  if (m != null) {
    return NoteBlock(
      type: NoteBlockType.todo,
      checked: m.group(1)!.toLowerCase() == 'x',
      text: m.group(2)!,
    );
  }
  m = _reNumbered.firstMatch(trimmed);
  if (m != null) {
    return NoteBlock(type: NoteBlockType.numbered, text: m.group(1)!);
  }
  m = _reBullet.firstMatch(trimmed);
  if (m != null) {
    return NoteBlock(type: NoteBlockType.bullet, text: m.group(1)!);
  }
  m = _reImage.firstMatch(trimmed);
  if (m != null) {
    return NoteBlock(type: NoteBlockType.image, path: m.group(1)!);
  }
  m = _reFile.firstMatch(trimmed);
  if (m != null) {
    final path = m.group(2)!;
    // 网页链接保持为普通段落（编辑器内 URL 自动识别）
    if (!path.startsWith('http://') && !path.startsWith('https://')) {
      return NoteBlock(
          type: NoteBlockType.file, text: m.group(1)!, path: path);
    }
  }
  return NoteBlock(type: NoteBlockType.paragraph, text: trimmed);
}

/// 块列表 → markdown（numbered 连续段自动重排序号）
String blocksToMarkdown(List<NoteBlock> blocks) {
  final lines = <String>[];
  int num = 0;

  // 块内 \n → 行尾 `\` 续行；末行本身以 `\` 结尾时补一个空格防误判续行
  // （parse 侧 trimRight 会剥掉该空格，往返无损）
  String enc(String text) {
    var t = text.replaceAll('\n', '\\\n');
    if (t.endsWith('\\')) t = '$t ';
    return t;
  }

  for (final b in blocks) {
    if (b.type == NoteBlockType.numbered) {
      num++;
    } else {
      num = 0;
    }
    switch (b.type) {
      case NoteBlockType.h1:
        lines.add('# ${enc(b.text)}');
      case NoteBlockType.h2:
        lines.add('## ${enc(b.text)}');
      case NoteBlockType.h3:
        lines.add('### ${enc(b.text)}');
      case NoteBlockType.todo:
        lines.add('- [${b.checked ? 'x' : ' '}] ${enc(b.text)}');
      case NoteBlockType.bullet:
        lines.add('- ${enc(b.text)}');
      case NoteBlockType.numbered:
        lines.add('$num. ${enc(b.text)}');
      case NoteBlockType.divider:
        lines.add('---');
      case NoteBlockType.image:
        lines.add('![](${b.path})');
      case NoteBlockType.file:
        lines.add('[${b.text}](${b.path})');
      case NoteBlockType.paragraph:
        lines.add(enc(_escapeParagraph(b.text)));
    }
  }
  return lines.join('\n');
}

/// 段落首行若形似其他块标记（或以 `\` 开头）→ 前置 `\` 转义，
/// 防止 重开时被解析成标题/列表等（parse 的 _reEscaped 会剥离该 `\`）
String _escapeParagraph(String text) {
  final nl = text.indexOf('\n');
  final first = nl < 0 ? text : text.substring(0, nl);
  final needs = first.startsWith('\\') ||
      first == '---' ||
      _reHeading.hasMatch(first) ||
      _reTodo.hasMatch(first) ||
      _reCnTodo.hasMatch(first) ||
      _reBullet.hasMatch(first) ||
      _reNumbered.hasMatch(first) ||
      _reImage.hasMatch(first) ||
      _reFile.hasMatch(first);
  return needs ? '\\$text' : text;
}
