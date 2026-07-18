/// XMate User Guide — accessible from Settings → Debug tab.
///
/// Chapters are bilingual (Chinese / English) with a toggle button.
library;

import 'package:flutter/material.dart';
import '../../core/theme/theme_colors.dart';

// ─── Bilingual data model ────────────────────────────────────────

class _SubSec {
  final String titleZh;
  final String titleEn;
  final List<String> bulletsZh;
  final List<String> bulletsEn;
  const _SubSec({
    required this.titleZh,
    required this.titleEn,
    required this.bulletsZh,
    required this.bulletsEn,
  });
}

class _ChapterData {
  final IconData icon;
  final String titleZh;
  final String titleEn;
  final String shortcutZh;
  final String shortcutEn;
  final List<String> bulletsZh;
  final List<String> bulletsEn;
  final List<_SubSec> subSections;

  const _ChapterData({
    required this.icon,
    required this.titleZh,
    required this.titleEn,
    required this.shortcutZh,
    required this.shortcutEn,
    this.bulletsZh = const [],
    this.bulletsEn = const [],
    this.subSections = const [],
  });
}

// ─── Chapter data ────────────────────────────────────────────────

const _kChapters = <_ChapterData>[
  _ChapterData(
    icon: Icons.space_bar,
    titleZh: '命令面板',
    titleEn: 'Command Palette',
    shortcutZh: 'Alt + Space',
    shortcutEn: 'Alt + Space',
    bulletsZh: [
      'XMate 的核心入口——输入关键词模糊搜索并执行所有功能命令。',
      'Alt+Shift+Space：抓取前台窗口选中的文本，预填入命令面板。',
    ],
    bulletsEn: [
      'Core entry point — type keywords to fuzzy-search and execute all commands.',
      'Alt+Shift+Space: grab selected text from the foreground app and pre-fill the palette.',
    ],
    subSections: [
      _SubSec(
        titleZh: '文件搜索',
        titleEn: 'File Search',
        bulletsZh: [
          '输入过滤器关键词 + 空格进入文件搜索模式（如 "documents 报告"）。',
          '基于三元组模糊匹配，支持中文拼音搜索。',
          '在设置 → File Search 中配置索引目录、排除规则和更新间隔。',
          '支持优先级规则：可设置优先/降权/排除的路径或文件名模式。',
        ],
        bulletsEn: [
          'Type a filter keyword + space to enter file search mode, then enter your query.',
          'Trigram-based fuzzy matching with pinyin support for Chinese filenames.',
          'Configure index directories, exclusion patterns, and update intervals in Settings → File Search.',
          'Priority rules: set prefer/demote/exclude patterns for paths or filenames.',
        ],
      ),
      _SubSec(
        titleZh: '文件搜索过滤器',
        titleEn: 'File Search Filters',
        bulletsZh: [
          '为常用搜索条件创建命名过滤器预设（如"文档"、"图片"、"视频"）。',
          '过滤器可按扩展名、文件夹范围、正则表达式限定结果。',
          '在命令面板中输入过滤器关键字即可套用，也可设为默认过滤器。',
          '在设置 → File Search 标签页中管理过滤器。',
        ],
        bulletsEn: [
          'Create named filter presets for common search criteria (e.g. "Documents", "Images", "Videos").',
          'Filters can limit results by extension, folder scope, or regex pattern.',
          'Type a filter keyword in the command palette to apply it, or set as default filter.',
          'Manage filters in Settings → File Search tab.',
        ],
      ),
      _SubSec(
        titleZh: '词典速查',
        titleEn: 'Dictionary Lookup',
        bulletsZh: [
          '直接输入英文单词（如 "hello"）或中文词语，自动识别并显示词典释义。',
          '回车打开独立词典窗口查看详细释义；支持 770,000+ 词条。',
        ],
        bulletsEn: [
          'Type an English word (e.g. "hello") or Chinese term — auto-detected and looked up instantly.',
          'Press Enter to open the full dictionary window; 770,000+ entries supported.',
        ],
      ),
      _SubSec(
        titleZh: '搜索引擎',
        titleEn: 'Search Engines',
        bulletsZh: [
          '在命令面板输入查询内容，用默认搜索引擎搜索；按右键可选择其他引擎。',
          '支持文本、图片、地图、翻译、词典五种引擎类别，可自定义 URL。',
          '地图搜索：输入 "map " + 地点名称，直接用地图引擎搜索。',
          '在设置 → Engine 标签页管理：添加、编辑、排序、设为默认、删除。',
        ],
        bulletsEn: [
          'Type a query to search with the default engine; press Right arrow to choose another engine.',
          'Five engine categories: text, image, map, translate, dictionary — all with customizable URLs.',
          'Map search: type "map " + place name to search directly with the map engine.',
          'Manage in Settings → Engine tab: add, edit, reorder, set default, delete.',
        ],
      ),
      _SubSec(
        titleZh: '用户命令',
        titleEn: 'User Commands',
        bulletsZh: [
          '定义自定义终端命令，从命令面板直接启动。',
          '每条命令可配置名称、关键词别名、快捷键、工作目录。',
          '在设置 → Commands 标签页管理：创建、编辑、启用/禁用、分配快捷键。',
        ],
        bulletsEn: [
          'Define custom shell commands and launch them from the command palette.',
          'Each command can have its own name, keyword alias, shortcut, and working directory.',
          'Manage in Settings → Commands tab: create, edit, enable/disable, assign hotkeys.',
        ],
      ),
      _SubSec(
        titleZh: '内置工具',
        titleEn: 'Built-in Tools',
        bulletsZh: [
          '计算器（= 开头）：输入 "=3*5+2" 自动求值，支持 +-*/%^() 运算；回车复制结果，点击打开 calc.exe。',
          '汇率换算（\$ / ￥ 开头）：输入 "\$ 100" 或 "￥ 100" 实时换算 12 种货币；点击货币标签切换币种，自动记忆。',
          '时区换算（UTC 开头）：输入 "UTC " 进入，自动填入当前时间；下拉菜单选择输入/输出时区，⇄ 互换，自动夏令时。',
        ],
        bulletsEn: [
          'Calculator (= prefix): type "=3*5+2" to evaluate, supports +-*/%^(); Enter to copy, click to open calc.exe.',
          'Currency Exchange (\$ / ￥ prefix): type "\$ 100" to convert across 12 currencies; switch via pills, auto-remembered.',
          'Timezone Converter (UTC prefix): type "UTC " to enter; auto-fills current time; dropdowns for source/target with ⇄ swap, auto DST.',
        ],
      ),
    ],
  ),
  _ChapterData(
    icon: Icons.swap_horiz,
    titleZh: '交互方式',
    titleEn: 'Interaction',
    shortcutZh: '跨功能联动',
    shortcutEn: 'Cross-feature links',
    bulletsZh: [
      '命令面板文本抓取：Alt+Shift+Space 获取前台应用选中文本，可继续搜索、翻译或查词。',
      '截图 → 录屏：标注工具栏点击视频图标，直接对同一区域开始录屏。',
      '截图 → 翻译：标注工具栏可将截图区域发送到翻译窗口做 OCR 翻译。',
      'QuickLook → 翻译：预览任意文件时，一键发送到翻译窗口处理。',
      'OLE 拖出：截图标注后可拖拽图片到其他应用（如微信、Word），无需保存文件。',
      '文件拖入：将文件拖入翻译窗口直接翻译内容；拖入格式转换窗口添加待转换文件。',
      '系统托盘：右键托盘图标可快速唤起命令面板、截图、打开设置。',
      '快捷键全局生效：所有快捷键在任何前台应用下均可触发 XMate 功能。',
    ],
    bulletsEn: [
      'Text grab: Alt+Shift+Space captures selected text from the foreground app for search, translate, or dictionary.',
      'Screenshot → Recording: click the videocam icon in the annotation toolbar to start recording the same region.',
      'Screenshot → Translate: send captured region from the annotation toolbar to the translation window for OCR.',
      'QuickLook → Translate: one-click send from file preview to the translation window.',
      'OLE drag-out: drag annotated screenshots directly into other apps (e.g. WeChat, Word) — no save needed.',
      'File drag-in: drop files into the Translate window to translate content; drop into File Converter to add conversion tasks.',
      'System tray: right-click the tray icon for quick access to command palette, screenshot, and settings.',
      'Global hotkeys: all shortcuts work from any foreground application to trigger XMate features instantly.',
    ],
  ),
  _ChapterData(
    icon: Icons.crop,
    titleZh: '截图与标注',
    titleEn: 'Screenshot & Annotation',
    shortcutZh: 'Alt + S（默认）',
    shortcutEn: 'Alt + S (default)',
    bulletsZh: [
      '选择屏幕区域截图——拖拽框选后进入标注工具栏。',
      '标注工具：矩形、椭圆、箭头、画笔、文字、马赛克（像素化）、步骤编号。',
      'OCR：一键提取截图区域的文字。',
      '钉图：将截图悬浮在屏幕上作为参考。',
      '跳转录屏：点击标注工具栏的视频图标即可对同一区域开始录屏。',
      '支持保存到文件、复制到剪贴板、OLE 拖出。',
    ],
    bulletsEn: [
      'Select a screen region to capture — drag to define the area, then use the annotation toolbar.',
      'Annotation tools: rectangle, ellipse, arrow, free-draw, text, mosaic (pixelate), and step-counter.',
      'OCR: extract text from the captured region with one click.',
      'Pin: keep the screenshot floating on-screen as a reference.',
      'Jump to Screen Recording: click the videocam icon in the annotation toolbar to start recording the same region.',
      'Save to file, copy to clipboard, or drag out as OLE.',
    ],
  ),
  _ChapterData(
    icon: Icons.videocam,
    titleZh: '屏幕录制',
    titleEn: 'Screen Recording',
    shortcutZh: 'Alt + R（默认）',
    shortcutEn: 'Alt + R (default)',
    bulletsZh: [
      '使用 FFmpeg 录制屏幕区域为 MP4。支持硬件加速（NVENC / AMF）。',
      '可配置 FPS、CRF 画质、音频源、鼠标光标显示、文件名模板。',
      '录制指示器悬浮窗显示时长并提供停止按钮。',
      '可从截图标注工具栏直接启动，精确选择录制区域。',
    ],
    bulletsEn: [
      'Record screen regions to MP4 using FFmpeg. Supports hardware acceleration (NVENC / AMF).',
      'Configurable FPS, CRF quality, audio source, mouse cursor visibility, and filename template.',
      'Recording indicator overlay shows duration and provides stop control.',
      'Can be started from the screenshot annotation toolbar for precise region selection.',
    ],
  ),
  _ChapterData(
    icon: Icons.preview,
    titleZh: '快速预览',
    titleEn: 'Quick Look',
    shortcutZh: 'Alt + Q（默认）',
    shortcutEn: 'Alt + Q (default)',
    bulletsZh: [
      '无需打开应用程序即可即时预览文件——类似 macOS Quick Look。',
      '支持格式：图片（PNG/JPG/GIF/WebP/SVG/PSD/RAW）、视频、音频、PDF、Office 文档、EPUB、EML、压缩包（ZIP/RAR/7z）、文本/代码、十六进制、文件夹。',
      '再次按快捷键关闭；先在资源管理器中选中文件可上下文预览。',
      '可钉住窗口保持置顶，可拖拽调整位置。',
    ],
    bulletsEn: [
      'Preview files instantly without opening native applications — like macOS Quick Look.',
      'Supported formats: images (PNG/JPG/GIF/WebP/SVG/PSD/RAW), videos, audio, PDF, Office docs, EPUB, EML, archives (ZIP/RAR/7z), text/code, hex view, and folders.',
      'Press the hotkey again to close; select a file in Explorer first for contextual preview.',
      'Pin window to keep it on top; drag to reposition.',
    ],
  ),
  _ChapterData(
    icon: Icons.translate,
    titleZh: '翻译',
    titleEn: 'Translate',
    shortcutZh: '命令面板 → "翻译"',
    shortcutEn: 'Command palette → "Translate"',
    bulletsZh: [
      '独立翻译窗口，基于 LibreTranslate（可本地服务或远程服务）。',
      '支持多语言对——通过设置 → 插件标签页安装模型。',
      '支持翻译选中文本、粘贴内容、拖放文本文件。',
      '自动检测源语言；可配置目标语言。',
    ],
    bulletsEn: [
      'Standalone translation window powered by LibreTranslate (local server or remote).',
      'Support for multiple language pairs — install models via Settings → Plugins tab.',
      'Translate selected text, paste content, or drag-and-drop text files.',
      'Auto-detects source language; configurable target language.',
    ],
  ),
  _ChapterData(
    icon: Icons.menu_book,
    titleZh: '词典',
    titleEn: 'Dictionary',
    shortcutZh: '命令面板 → "词典"',
    shortcutEn: 'Command palette → "Dictionary"',
    bulletsZh: [
      '基于 ECDICT 的英汉词典（770,000+ 词条）。',
      '两种查词模式：命令面板直接输入单词自动查词，或打开独立窗口。',
      '通过设置 → Debug 标签页导入自定义 SQLite 词典数据库。',
      '支持迷你模式，紧凑悬浮窗。',
    ],
    bulletsEn: [
      'English-Chinese dictionary based on ECDICT (770,000+ entries).',
      'Two lookup modes: type a word directly in the command palette (auto-detect), or use the standalone window.',
      'Import your own SQLite dictionary databases via the Settings → Debug tab.',
      'Supports mini-mode for a compact floating window.',
    ],
  ),
  _ChapterData(
    icon: Icons.swap_horiz,
    titleZh: '文件格式转换',
    titleEn: 'File Converter',
    shortcutZh: '命令面板 → "文件转换"',
    shortcutEn: 'Command palette → "File Converter"',
    bulletsZh: [
      '使用 FFmpeg 转换媒体文件格式：视频、音频、图片转码。',
      '通过 qpdf 进行 PDF 后处理：页面操作（提取/合并/旋转）、优化、加密、水印。',
      '批量转换，可配置并行数；支持硬件加速（CUDA / AMF）。',
      '可配置默认输出目录和转换预设。',
    ],
    bulletsEn: [
      'Convert media files between formats using FFmpeg: video, audio, and image transcoding.',
      'PDF post-processing via qpdf: page operations (extract/merge/rotate), optimization, encryption, and watermarking.',
      'Batch conversion with configurable parallelism; hardware acceleration support (CUDA / AMF).',
      'Configurable default output directory and conversion presets.',
    ],
  ),
  _ChapterData(
    icon: Icons.sticky_note_2_outlined,
    titleZh: '便签',
    titleEn: 'Sticky Notes',
    shortcutZh: '命令面板 → "@ "',
    shortcutEn: 'Command palette → "@ "',
    bulletsZh: [
      '在命令面板中输入 "@ " 快速记录便签——新建或追加到已有便签；在设置页查看管理所有便签。',
      '独立进程多开窗口，8 种经典便签色（light/dark 双主题），支持窗口缩放/拖拽/置顶。',
    ],
    bulletsEn: [
      'Type "@ " in the command palette to jot a note — create new or append to existing; manage all notes in Settings.',
      'Multi-instance independent windows, 8 preset colors (light/dark dual theme), with resize/drag/pin support.',
    ],
    subSections: [
      _SubSec(
        titleZh: '块式编辑',
        titleEn: 'Block Editing',
        bulletsZh: [
          'Notion 风格块编辑器：`# / ## / ### / [] / * / 1. / 【】 / ---` + 空格转换块类型。',
          '内联标记：Ctrl+B 加粗、Ctrl+I 斜体、Ctrl+U 下划线 —— 编辑态标记可见，渲染态 WYSIWYG。',
          'Enter 分裂 / Shift+Enter 块内换行；块拖拽排序（按手柄拖动，指示线定位落点）。',
          '反斜杠转义 `\#` `\*` 防止误转；支持拖入图片/文件，拖出到其他应用。',
        ],
        bulletsEn: [
          'Notion-style block editing: `# / ## / ### / [] / * / 1. / 【】 / ---` + space to convert block type.',
          'Inline styling: Ctrl+B bold, Ctrl+I italic, Ctrl+U underline — markers visible while typing, WYSIWYG when unfocused.',
          'Enter split / Shift+Enter newline; drag blocks to reorder (drag handle + insertion indicators).',
          'Backslash escape `\\#` `\\*` to prevent conversion; drag in images/files, drag out to other apps.',
        ],
      ),
      _SubSec(
        titleZh: '提醒与加密',
        titleEn: 'Reminders & Encryption',
        bulletsZh: [
          '@时间 提醒（任意文本位置）：相对 @5min @2h，绝对 @18:30 @明天9点，日期 @2026-07-20，星期 @周五。',
          '支持多提醒、秒级 @30s、UTC 后缀 @18:30 UTC+8；标题栏显示最近倒计时，到期置顶+抖动+提示音。',
          '加密折叠：按住便签底部折起上锁 → 设置 6 位数字码 → 内容流加密存储（口令不落盘）。',
          '点击锁图标输码解锁；错码 3 次递增锁定 5 分钟→最长 1 小时（重启不重置）。',
        ],
        bulletsEn: [
          '@time reminders (anywhere in text): relative @5min @2h, absolute @18:30 @tomorrow 9:00, dates, weekdays.',
          'Multiple reminders, seconds @30s, UTC suffix @18:30 UTC+8; nearest countdown in title bar; topmost+shake+beep on fire.',
          'Encryption fold: hold bottom edge → fold up → set 6-digit code → stream-encrypted storage (passcode never written to disk).',
          'Tap lock icon to unlock; 3 wrong attempts = progressive lockout: 5 min → up to 1 hour (persisted across restarts).',
        ],
      ),
      _SubSec(
        titleZh: '交互技巧',
        titleEn: 'Interaction Tips',
        bulletsZh: [
          '右下折角：短按撕掉关闭（飞起动画），长按 1s 折角变大出现垃圾桶图标松手删除（折拢动画），锁定便签仅可撕掉。',
          '左上角：按下撕开一角预览随机颜色，松手切换便签色。',
          '拖动便签到另一个便签上 → 变色预览 → 松手合并（内容追加到目标，源便签删除）。',
          '图钉按钮置顶；闹钟区域点击可隐藏/显示倒计时；锁定的便签受保护——不可合并/面板追加/删除。',
          '模板：在设置页 Input Rules 卡片中可查看完整块标记语法参考。',
        ],
        bulletsEn: [
          'Lower-right corner: short tap = tear off (fly-up animation); long press 1s to grow → trash icon appears → release to delete (fold-away animation). Locked notes can only be torn off.',
          'Upper-left corner: press to peel and preview a random new color, release to switch the note color.',
          'Drag one note onto another → color preview → release to merge (content appended to target, source deleted).',
          'Pin button to stay on top; click alarm area to toggle countdown visibility; locked notes are protected — no merge / palette append / delete.',
          'Reference: the Input Rules card in Settings lists all block marker syntax.',
        ],
      ),
    ],
  ),
  _ChapterData(
    icon: Icons.keyboard,
    titleZh: '按键回显',
    titleEn: 'Key Echo',
    shortcutZh: '设置 → 插件 → Quick Look 中切换',
    shortcutEn: 'Toggle in Settings → Plugins → Quick Look',
    bulletsZh: [
      '显示键盘快捷键覆盖层——用于演示和教程。',
      '同时显示 Caps Lock / Num Lock / Scroll Lock 状态变化。',
      '作为独立覆盖层进程运行；在 Quick Look 插件设置中配置。',
    ],
    bulletsEn: [
      'Displays an overlay showing keyboard shortcuts as you type — useful for presentations and tutorials.',
      'Also shows Caps Lock / Num Lock / Scroll Lock status changes.',
      'Runs as a separate overlay process; configure in the Quick Look plugin settings.',
    ],
  ),
  _ChapterData(
    icon: Icons.settings,
    titleZh: '设置与个性化',
    titleEn: 'Settings & Customization',
    shortcutZh: '命令面板 → "设置"',
    shortcutEn: 'Command palette → "Settings"',
    bulletsZh: [
      '主题：暗色、亮色或跟随 Windows。自定义主题色（6 种预设 + 自定义 HEX）。可调节背景透明度（20–100%）。',
      '快捷键：可自定义命令面板、截图、Quick Look、屏幕录制的快捷键——在设置中捕获新按键。',
      '开机自启：让 XMate 随 Windows 启动。系统托盘：右键快捷操作。',
      '点击设置页底部的版本号可显示 Debug 和 Help（本页面）标签页。',
    ],
    bulletsEn: [
      'Theme: Dark, Light, or Follow Windows. Custom accent color (6 presets + custom HEX). Adjustable background opacity (20–100%).',
      'Hotkeys: customizable shortcuts for command palette, screenshot, Quick Look, and screen recording — capture new keys in Settings.',
      'Auto-start: launch XMate when Windows starts. System tray: right-click for quick actions.',
      'Click the version number at the bottom of Settings to reveal the Debug and Help (this page) tabs.',
    ],
  ),
];

// ─── Help page ───────────────────────────────────────────────────

class HelpPage extends StatefulWidget {
  final VoidCallback onClose;

  const HelpPage({super.key, required this.onClose});

  @override
  State<HelpPage> createState() => _HelpPageState();
}

class _HelpPageState extends State<HelpPage> {
  String _lang = 'en';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: Container(
          width: 620,
          height: 640,
          padding: const EdgeInsets.all(16),
          child: Container(
            width: 588,
            height: 608,
            decoration: BoxDecoration(
              color: XMateColors.panelBg(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: cs.primary.withAlpha(60), width: 1.5),
            ),
            child: Column(
              children: [
                _buildHeader(context),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final ch in _kChapters) _buildChapter(context, ch),
                        const SizedBox(height: 8),
                        Center(
                          child: GestureDetector(
                            onTap: () => _showDonateDialog(context),
                            child: Text(
                              'XMate — Windows Private Assistant',
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.primary.withAlpha(150),
                                decoration: TextDecoration.underline,
                                decorationColor: cs.primary.withAlpha(80),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showDonateDialog(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => AlertDialog(
        backgroundColor: XMateColors.dialogBg(context),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.primary.withAlpha(60)),
        ),
        title: Row(
          children: [
            Icon(Icons.favorite, color: Colors.redAccent, size: 20),
            const SizedBox(width: 8),
            Text(_lang == 'en' ? 'Support XMate' : '支持 XMate',
                style: TextStyle(fontSize: 16, color: cs.onSurface)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset(
                'assets/donate_qr.png',
                width: 280, height: 280, fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Container(
                  width: 280, height: 200,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withAlpha(10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: cs.onSurface.withAlpha(30)),
                  ),
                  child: Center(
                    child: Text(_lang == 'en' ? 'QR code not found' : '收款码未找到',
                        style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(120))),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _lang == 'en' ? 'Thank you for your support!' : '感谢您的支持！',
              style: TextStyle(fontSize: 14, color: cs.onSurface.withAlpha(200)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(_lang == 'en' ? 'Close' : '关闭', style: TextStyle(color: cs.primary)),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) {},
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
        child: Row(
          children: [
            Icon(Icons.help_outline, color: cs.primary, size: 18),
            const SizedBox(width: 8),
            Text(
              _lang == 'en' ? 'User Guide' : '用户指南',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: cs.onSurface),
            ),
            const Expanded(child: SizedBox()),
            // Language toggle
            GestureDetector(
              onTap: () => setState(() => _lang = _lang == 'en' ? 'zh' : 'en'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: cs.primary.withAlpha(100)),
                  color: cs.primary.withAlpha(20),
                ),
                child: Text(
                  _lang == 'en' ? '中文' : 'EN',
                  style: TextStyle(fontSize: 12, color: cs.primary, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChapter(BuildContext context, _ChapterData ch) {
    final cs = Theme.of(context).colorScheme;
    final isZh = _lang == 'zh';
    final title = isZh ? ch.titleZh : ch.titleEn;
    final shortcut = isZh ? ch.shortcutZh : ch.shortcutEn;
    final bullets = isZh ? ch.bulletsZh : ch.bulletsEn;
    final hasSubs = ch.subSections.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(ch.icon, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: cs.onSurface)),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: cs.primary.withAlpha(30), borderRadius: BorderRadius.circular(4)),
                child: Text(shortcut, style: TextStyle(fontSize: 11, color: cs.primary, fontFamily: 'monospace')),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (!hasSubs)
            for (final b in bullets) _Bullet(b)
          else ...[
            for (final b in bullets) _Bullet(b),
            const SizedBox(height: 4),
            for (final ss in ch.subSections)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 6, bottom: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(isZh ? ss.titleZh : ss.titleEn,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.primary.withAlpha(200))),
                    const SizedBox(height: 2),
                    for (final b in (isZh ? ss.bulletsZh : ss.bulletsEn)) _Bullet(b),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ─── Bullet ──────────────────────────────────────────────────────

class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet(this.text);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('• ', style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(138))),
          Expanded(child: Text(text, style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(200), height: 1.4))),
        ],
      ),
    );
  }
}
