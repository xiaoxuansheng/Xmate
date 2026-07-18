library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/command/user_command_service.dart';
import '../../core/plugin/plugin_registry.dart';
import '../../core/services/update_service.dart';
import '../../core/search/search_engine_service.dart';
import '../../core/search/file_search_service.dart';
import '../../core/settings/settings_service.dart';
import '../../core/theme/theme_service.dart';
import '../../core/theme/theme_colors.dart';
import '../../core/tray/tray_manager.dart';
import '../../plugins/quicklook/quicklook_plugin.dart';

import 'commands_tab.dart';
import 'file_search_tab.dart';
import 'bug_report_tab.dart';
import 'setup_checker_tab.dart';
import 'usage_stats_tab.dart';
import '../help/help_page.dart';

/// Callback when hotkey is changed: (modsMask, keyId, keyLabel).
/// The caller (main.dart) should re-register the system hotkey.
typedef HotkeyChangedCallback = Future<void> Function(int modsMask, int keyId, String keyLabel);

/// Callback when a hotkey capture session starts/ends.
/// [source] identifies which capture row (e.g. "settings.palette"),
/// [active] = true on entering capture, false on leaving.
typedef CaptureStateCallback = void Function(String source, bool active);

class SettingsPage extends StatefulWidget {
  final PluginRegistry registry;
  final GlobalKey contentKey;
  final VoidCallback onClose;
  final HotkeyChangedCallback? onHotkeyChanged;
  final CaptureStateCallback? onCaptureStateChanged;
  final VoidCallback? onCommandsChanged;
  const SettingsPage({
    super.key,
    required this.registry,
    required this.contentKey,
    required this.onClose,
    this.onHotkeyChanged,
    this.onCaptureStateChanged,
    this.onCommandsChanged,
  });
  @override State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _kHotkey = 'app.hotkey.palette';
  static const _captureSource = 'settings.palette';
  static const _debugChannel = MethodChannel('com.xmate/debug');

  final _settings = SettingsService();
  final _searchService = SearchEngineService();
  final _userCommandService = UserCommandService();
  bool _autoStart = false;

  // Debug tab -- search results (hidden behind toggle)
  bool _showDebug = false;

  final _debugSearchCtrl = TextEditingController();
  List<Map<String, dynamic>> _debugSearchResults = [];
  bool _debugSearchRunning = false;

  // Hotkey state
  String _hotkeyLabel = 'Alt+Space';
  bool _capturing = false;
  final _captureFocus = FocusNode();

  // Search engine state
  List<SearchEngine> _allEngines = [];

  // User command state
  List<UserCommand> _commands = [];

  @override void initState() {
    super.initState();
    _load();
    _captureFocus.addListener(_onCaptureFocusChange);
    ThemeService.onChanged = _notifyThemeChanged;
  }

  @override void dispose() {
    if (_capturing) {
      widget.onCaptureStateChanged?.call(_captureSource, false);
    }
    _captureFocus.dispose();
    _debugSearchCtrl.dispose();
    if (ThemeService.onChanged == _notifyThemeChanged) {
      ThemeService.onChanged = null;
    }
    super.dispose();
  }

  void _onCaptureFocusChange() {
    if (!_captureFocus.hasFocus && _capturing) {
      setState(() => _capturing = false);
      widget.onCaptureStateChanged?.call(_captureSource, false);
    }
  }

  Future<void> _load() async {
    final autoStart = await TrayService().isAutoStart();
    final hk = _settings.get(_kHotkey);
    final engines = _searchService.loadEngines();
    final commands = _userCommandService.loadCommands();
    setState(() {
      _autoStart = autoStart;
      if (hk is Map) {
        _hotkeyLabel = _formatHotkey(hk['modifiers'] ?? 0, hk['key'] ?? 0);
      }
      _allEngines = engines;
      _commands = commands;
    });
  }

  // ─── Auto-start ───

  Future<void> _toggleAutoStart(bool v) async {
    final newState = await TrayService().toggleAutoStart();
    setState(() => _autoStart = newState);
  }

  /// Push current key echo settings to the notification process via Windows message.
  void _notifyKeyEchoSettings() {
    final hotkey = _settings.getWithDefault<bool>('notification.keyEcho.hotkey', true);
    final status = _settings.getWithDefault<bool>('notification.keyEcho.status', true);
    _debugChannel.invokeMethod('sendKeyEchoSettings', {
      'hotkey': hotkey,
      'status': status,
    });
  }

  /// Push current theme to the notification process via Windows message.
  void _notifyThemeChanged() {
    final ts = ThemeService();
    int mode;
    switch (ts.themeMode) {
      case ThemeMode.light:  mode = 1; break;
      case ThemeMode.system: mode = 2; break;
      default:               mode = 0; break; // dark
    }
    _debugChannel.invokeMethod('sendThemeChanged', {
      'mode': mode,
      'accent': ts.accentColor.toARGB32(),
    });
  }

  // ─── Hotkey display / capture ───

  String _formatHotkey(int mods, int key) {
    final parts = <String>[];
    if (mods & 1 != 0) parts.add('Alt');
    if (mods & 2 != 0) parts.add('Ctrl');
    if (mods & 4 != 0) parts.add('Shift');
    if (mods & 8 != 0) parts.add('Win');
    final k = LogicalKeyboardKey.findKeyByKeyId(key);
    if (k != null) parts.add(_keyName(k));
    return parts.isEmpty ? 'Unset' : parts.join('+');
  }

  String _keyName(LogicalKeyboardKey key) {
    final n = key.keyLabel;
    if (n.length == 1 && n.codeUnitAt(0) >= 0x41 && n.codeUnitAt(0) <= 0x5A) return n;
    if (n == ' ') return 'Space';
    return n;
  }

  void _startCapture() {
    setState(() => _capturing = true);
    widget.onCaptureStateChanged?.call(_captureSource, true);
    _captureFocus.requestFocus();
  }

  void _onCaptureKey(KeyEvent event) {
    if (!_capturing || event is! KeyDownEvent) return;

    final key = event.logicalKey;
    // Ignore modifier-only presses
    if (key == LogicalKeyboardKey.altLeft || key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.controlLeft || key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.shiftLeft || key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.metaLeft || key == LogicalKeyboardKey.metaRight) {
      return;
    }

    final mods = HardwareKeyboard.instance.logicalKeysPressed;
    int mask = 0;
    if (mods.contains(LogicalKeyboardKey.altLeft) || mods.contains(LogicalKeyboardKey.altRight)) mask |= 1;
    if (mods.contains(LogicalKeyboardKey.controlLeft) || mods.contains(LogicalKeyboardKey.controlRight)) mask |= 2;
    if (mods.contains(LogicalKeyboardKey.shiftLeft) || mods.contains(LogicalKeyboardKey.shiftRight)) mask |= 4;
    if (mods.contains(LogicalKeyboardKey.metaLeft) || mods.contains(LogicalKeyboardKey.metaRight)) mask |= 8;

    if (mask == 0) {
      setState(() => _capturing = false);
      widget.onCaptureStateChanged?.call(_captureSource, false);
      _captureFocus.unfocus();
      return;
    }

    final newLabel = _formatHotkey(mask, key.keyId);
    _saveHotkey(mask, key.keyId, newLabel);
    setState(() {
      _capturing = false;
      _hotkeyLabel = newLabel;
    });
    widget.onCaptureStateChanged?.call(_captureSource, false);
    _captureFocus.unfocus();
  }

  Future<void> _saveHotkey(int mods, int keyId, String label) async {
    // Save config to settings
    _settings.set(_kHotkey, {'modifiers': mods, 'key': keyId});
    // Let main.dart handle actual registration
    await widget.onHotkeyChanged?.call(mods, keyId, label);
  }

  // ─── Build ───

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tabCount = _showDebug ? 7 : 5;
    return KeyboardListener(
      focusNode: _captureFocus,
      onKeyEvent: _onCaptureKey,
      child: DefaultTabController(
        length: tabCount,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Center(
            child: Container(
              key: widget.contentKey,
              width: 572,
              height: 620,
              padding: const EdgeInsets.all(16),
              child: Container(
                width: 540,
                height: 550,
                decoration: BoxDecoration(
                  color: XMateColors.panelBg(context),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Theme.of(context).colorScheme.primary.withAlpha(60), width: 1.5),
                ),
                child: Column(children: [
                  _buildHeader(),
                  TabBar(
                    indicatorColor: cs.primary,
                    labelColor: cs.primary,
                    unselectedLabelColor: cs.onSurface.withAlpha(138),
                    labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    unselectedLabelStyle: const TextStyle(fontSize: 13),
                    tabs: [
                      const Tab(text: 'General'),
                      const Tab(text: 'File Search'),
                      const Tab(text: 'Engine'),
                      const Tab(text: 'Commands'),
                      const Tab(text: 'Plugins'),
                      if (_showDebug) ...[
                        const Tab(text: 'Help'),
                        const Tab(text: 'Debug'),
                      ],
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildGeneralTab(),
                        const FileSearchTab(),
                        _buildEngineTab(),
                        CommandsTab(
                          service: _userCommandService,
                          commands: _commands,
                          onChanged: () => widget.onCommandsChanged?.call(),
                        ),
                        _buildPluginsTab(),
                        if (_showDebug) ...[
                          HelpPage(onClose: () {}),
                          _buildDebugTab(),
                        ],
                      ],
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
        child: Row(children: [
          Icon(Icons.settings, color: cs.primary, size: 18),
          const SizedBox(width: 8),
          Text('Settings',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: cs.onSurface)),
          const Expanded(child: SizedBox()),
          IconButton(
            icon: Icon(Icons.close, color: cs.onSurface.withAlpha(179), size: 20),
            onPressed: widget.onClose,
            tooltip: 'Close',
          ),
        ]),
      ),
    );
  }

  Widget _buildGeneralTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(children: [
        _SectionCard(
          children: [
            _SwitchRow(
              label: 'Launch at startup',
              value: _autoStart,
              onChanged: _toggleAutoStart,
            ),
            const _Divider(),
            _HotkeyRow(
              label: 'Command palette hotkey',
              hotkey: _hotkeyLabel,
              capturing: _capturing,
              onTap: _startCapture,
            ),
          ],
        ),
        const SizedBox(height: 20),
        // ─── Appearance Settings ───
        _SectionCard(
          title: 'Appearance',
          children: [
            _ThemeModeRow(
              label: 'Theme',
              value: ThemeService().themeMode,
              onChanged: (mode) => ThemeService().setThemeMode(mode),
            ),
            const _Divider(),
            _AccentColorRow(),
            const _Divider(),
            _OpacitySliderRow(),
          ],
        ),
        const SizedBox(height: 20),
        _VersionRow(
          onTap: () {
            setState(() {
              _showDebug = !_showDebug;
            });
          },
        ),
      ]),
    );
  }

  Widget _buildPluginsTab() {
    final cs = Theme.of(context).colorScheme;
    // Dynamically collect all plugins that have a settings page.
    final plugins = widget.registry.plugins
        .where((p) => p.settingsPage != null)
        .toList();

    if (plugins.isEmpty) return const SizedBox.shrink();

    return DefaultTabController(
      length: plugins.length,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TabBar(
            indicatorColor: cs.primary,
            labelColor: cs.primary,
            unselectedLabelColor: cs.onSurface.withAlpha(138),
            labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 12),
            tabs: plugins.map((p) => Tab(text: p.name)).toList(),
          ),
          SizedBox(
            height: 380,
            child: TabBarView(
              children: plugins.map((p) {
                return _buildPluginSettings(p.id, p.icon, p.name);
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPluginSettings(String pluginId, IconData defaultIcon, String defaultName) {
    final plugin = widget.registry.findById(pluginId);
    if (plugin == null) return const SizedBox.shrink();

    // Wire QuickLook plugin with key echo settings
    if (plugin is QuickLookPlugin) {
      plugin.keyEchoHotkey = _settings.getWithDefault<bool>('notification.keyEcho.hotkey', true);
      plugin.keyEchoStatus = _settings.getWithDefault<bool>('notification.keyEcho.status', true);
      plugin.onKeyEchoHotkeyChanged = (v) {
        _settings.set('notification.keyEcho.hotkey', v);
        _notifyKeyEchoSettings();
      };
      plugin.onKeyEchoStatusChanged = (v) {
        _settings.set('notification.keyEcho.status', v);
        _notifyKeyEchoSettings();
      };
    }

    final sp = plugin.settingsPage;
    if (sp == null) return const SizedBox.shrink();

    // Screenshot, QuickLook, and Translate&Dict plugins build their own inner section
    // headers — skip the outer _SectionCard wrapper.
    if (pluginId == 'screenshot' || pluginId == 'quicklook' || pluginId == 'translate' || pluginId == 'notes') {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: KeyedSubtree(
          key: ValueKey('settings_content_$pluginId'),
          child: sp,
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: _SectionCard(
        title: plugin.name,
        icon: plugin.icon,
        children: [
          KeyedSubtree(
            key: ValueKey('settings_content_$pluginId'),
            child: sp,
          ),
        ],
      ),
    );
  }

  // -- Debug tab (dev-only) --

  static const _accent = Color(0xFF5AAAC2);

  Widget _buildDebugTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        children: [
            // ── Environment Setup Check (top) ──
            const SetupCheckerTab(),
            const SizedBox(height: 16),
            // ── Bug Report ──
            const BugReportTab(),
            const SizedBox(height: 16),
            // ── Usage Statistics ──
            const UsageStatsTab(),
            const SizedBox(height: 16),
            // ── File Search section ────────────────────────────────
            _SectionCard(
            title: 'Debug -- File Search',
            icon: Icons.bug_report,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                child: TextField(
                  controller: _debugSearchCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Enter search query...',
                    hintStyle: const TextStyle(color: Colors.white30, fontSize: 13),
                    filled: true,
                    fillColor: const Color(0x20FFFFFF),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    isDense: true,
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.search, color: _accent, size: 20),
                      tooltip: 'Search',
                      onPressed: _debugSearchRunning ? null : _debugFileSearch,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                  ),
                  onSubmitted: (_) => _debugFileSearch(),
                ),
              ),
              if (_debugSearchResults.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
                  child: Text(
                    '${_debugSearchResults.length} results',
                    style: const TextStyle(fontSize: 11, color: Colors.white38),
                  ),
                ),
              if (_debugSearchResults.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 340),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _debugSearchResults.length,
                    itemBuilder: (_, i) {
                      final r = _debugSearchResults[i];
                      final name = '${r['name']}${(r['ext'] as String?)?.isNotEmpty == true ? '.${r['ext']}' : ''}';
                      final path = r['path'] as String? ?? '';
                      final score = (r['score'] as num?)?.toStringAsFixed(3) ?? '0.000';
                      final isDir = r['isDir'] == true;
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          isDir ? Icons.folder : Icons.insert_drive_file,
                          size: 16, color: isDir ? const Color(0xFFDBB440) : Colors.white54,
                        ),
                        title: Text(name, style: const TextStyle(fontSize: 13, color: Colors.white)),
                        subtitle: Text(
                          path,
                          style: const TextStyle(fontSize: 10, color: Colors.white30),
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(
                          score,
                          style: TextStyle(
                            fontSize: 11,
                            color: score.startsWith('0.0') ? Colors.white30 : const Color(0xFF5AAAC2),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _debugFileSearch() async {
    final q = _debugSearchCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() => _debugSearchRunning = true);
    try {
      final results = FileSearchService().search(q);
      setState(() {
        _debugSearchResults = results
            .map((r) => {
                  'name': r.name,
                  'ext': r.ext,
                  'path': r.fullPath,
                  'score': r.score,
                  'isDir': r.isDir,
                })
            .toList();
        _debugSearchRunning = false;
      });
    } catch (e) {
      setState(() => _debugSearchRunning = false);
    }
  }

  // ── Engine tab ─────────────────────────────────────────────

  late Map<SearchEngineCategory, List<SearchEngine>> _engineGrouped = {};

  void _rebuildEngineGrouped() {
    _engineGrouped = {};
    for (final cat in SearchEngineCategory.values) {
      _engineGrouped[cat] = _allEngines
          .where((e) => e.category == cat)
          .toList();
    }
  }

  Future<void> _engineDelete(SearchEngineCategory cat, int i) async {
    final engine = _engineGrouped[cat]![i];
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          backgroundColor: XMateColors.dialogBg(ctx),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: cs.primary.withAlpha(40))),
          title: Text('Delete engine', style: TextStyle(color: cs.onSurface)),
          content: Text('Remove "${engine.name}"?',
              style: TextStyle(color: cs.onSurface.withAlpha(179))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete',
                    style: TextStyle(color: Colors.redAccent))),
          ],
        );
      },
    );
    if (ok == true) {
      _engineGrouped[cat]!.removeAt(i);
      _engineSave();
    }
  }

  Future<void> _engineEdit(SearchEngineCategory cat, int? index) async {
    final isImage = cat == SearchEngineCategory.image;
    final engine = index != null
        ? _engineGrouped[cat]![index]
        : SearchEngine(
            name: '',
            url: '',
            copyMode: isImage,
            category: cat,
          );
    final result = await showDialog<SearchEngine>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => _EngineEditorDialog(
        engine: engine,
        category: cat,
        hideCopyMode: isImage,
      ),
    );
    if (result != null) {
      if (index != null) {
        _engineGrouped[cat]![index] = result;
      } else {
        _engineGrouped[cat]!.add(result);
      }
      _engineSave();
    }
  }

  Future<void> _engineSave() async {
    final all = <SearchEngine>[];
    for (final cat in SearchEngineCategory.values) {
      all.addAll(_engineGrouped[cat] ?? []);
    }
    await _searchService.saveEngines(all);
    setState(() => _allEngines = all);
  }

  void _engineReorder(SearchEngineCategory cat, int oldIdx, int newIdx) {
    final item = _engineGrouped[cat]!.removeAt(oldIdx);
    _engineGrouped[cat]!.insert(newIdx, item);
    _engineSave();
  }

  Widget _buildEngineTab() {
    if (_allEngines.isNotEmpty && _engineGrouped.isEmpty) {
      _rebuildEngineGrouped();
    }

    return DefaultTabController(
      length: SearchEngineCategory.values.length,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TabBar(
            indicatorColor: Theme.of(context).colorScheme.primary,
            labelColor: Theme.of(context).colorScheme.primary,
            unselectedLabelColor: Theme.of(context).colorScheme.onSurface.withAlpha(138),
            labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 12),
            tabs: SearchEngineCategory.values
                .map((cat) => Tab(text: _kCategoryLabels[cat]!.split(' ').first))
                .toList(),
          ),
          SizedBox(
            height: 420,
            child: TabBarView(
              children: SearchEngineCategory.values.map((cat) {
                return _CategoryEngineList(
                  category: cat,
                  engines: _engineGrouped[cat] ?? [],
                  onDelete: (i) => _engineDelete(cat, i),
                  onEdit: (i) => _engineEdit(cat, i),
                  onAdd: () => _engineEdit(cat, null),
                  onReorder: (oldIdx, newIdx) => _engineReorder(cat, oldIdx, newIdx),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

}

// ─── Section Card ───

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;
  const _SectionCard({this.title = '', this.icon = Icons.settings, required this.children});

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (title.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            Icon(icon, size: 16, color: cs.primary),
            const SizedBox(width: 6),
            Text(title, style: TextStyle(fontSize: 13, color: cs.primary, fontWeight: FontWeight.w500)),
          ]),
        ),
      Container(
        decoration: BoxDecoration(
          color: cs.onSurface.withAlpha(8),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    ]);
  }
}

// ─── Switch Row ───

class _SwitchRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SwitchRow({required this.label, required this.value, required this.onChanged});

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(children: [
        Text(label, style: TextStyle(fontSize: 14, color: cs.onSurface)),
        const Spacer(),
        SizedBox(
          height: 28,
          child: Transform.scale(
            scale: 0.7,
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeTrackColor: cs.primary,
            ),
          ),
        ),
      ]),
    );
  }
}

// ─── Hotkey Row ───

class _HotkeyRow extends StatelessWidget {
  final String label;
  final String hotkey;
  final bool capturing;
  final VoidCallback onTap;
  const _HotkeyRow({required this.label, required this.hotkey, required this.capturing, required this.onTap});

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(children: [
        Text(label, style: TextStyle(fontSize: 14, color: cs.onSurface)),
        const Spacer(),
        GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: capturing ? cs.primary.withAlpha(60) : cs.onSurface.withAlpha(15),
              borderRadius: BorderRadius.circular(6),
              border: capturing ? Border.all(color: cs.primary, width: 1.5) : null,
            ),
            child: Text(
              capturing ? 'Press new hotkey...' : hotkey,
              style: TextStyle(
                fontSize: 13,
                color: capturing ? cs.primary : cs.onSurface.withAlpha(179),
                fontWeight: capturing ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

// ─── Key Echo Toggle Row ───

// ─── Thin Divider ───

class _Divider extends StatelessWidget {
  const _Divider();
  @override Widget build(BuildContext context) {
    return Divider(height: 1, thickness: 1, indent: 14, endIndent: 14, color: Theme.of(context).dividerColor);
  }
}

// ─── Category labels (shared by engine tab / editor) ───

const _kCategoryLabels = {
  SearchEngineCategory.text: 'Text Search',
  SearchEngineCategory.image: 'Image Search',
  SearchEngineCategory.map: 'Map Search',
  SearchEngineCategory.translate: 'Translate',
  SearchEngineCategory.dictionary: 'Dictionary',
};

// ─── Theme Mode Row ───

class _ThemeModeRow extends StatefulWidget {
  final String label;
  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;
  const _ThemeModeRow({required this.label, required this.value, required this.onChanged});
  @override State<_ThemeModeRow> createState() => _ThemeModeRowState();
}

class _ThemeModeRowState extends State<_ThemeModeRow> {
  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Row(children: [
        Text(widget.label, style: TextStyle(fontSize: 14, color: cs.onSurface)),
        const Spacer(),
        SizedBox(
          height: 34,
          child: DropdownButton<ThemeMode>(
            value: widget.value,
            dropdownColor: XMateColors.dialogBg(context),
            style: TextStyle(fontSize: 13, color: cs.primary),
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
              DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
              DropdownMenuItem(value: ThemeMode.system, child: Text('Follow Windows')),
            ],
            onChanged: (v) {
              if (v != null) widget.onChanged(v);
            },
          ),
        ),
      ]),
    );
  }
}

// ─── Accent Color Row ───

class _AccentColorRow extends StatefulWidget {
  const _AccentColorRow();
  @override State<_AccentColorRow> createState() => _AccentColorRowState();
}

class _AccentColorRowState extends State<_AccentColorRow> {
  @override Widget build(BuildContext context) {
    final ts = ThemeService();
    final current = ts.accentColor;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          ...kAccentPresets.map((color) {
            final selected = current.toARGB32() == color.toARGB32();
            return GestureDetector(
              onTap: () => ts.setAccentColor(color),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: selected
                      ? Border.all(color: cs.onSurface, width: 2)
                      : Border.all(color: Colors.transparent, width: 2),
                ),
                child: selected
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : null,
              ),
            );
          }),
          // Custom color picker button
          GestureDetector(
            onTap: () => _showCustomColorDialog(context),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: cs.onSurface.withAlpha(80), width: 1.5),
              ),
              child: Icon(Icons.add, size: 16, color: cs.onSurface.withAlpha(138)),
            ),
          ),
        ],
      ),
    );
  }

  void _showCustomColorDialog(BuildContext context) {
    final ts = ThemeService();
    final cs = Theme.of(context).colorScheme;
    final hexCtrl = TextEditingController(text: ts.accentColor.toARGB32().toRadixString(16).padLeft(8, '0').substring(2));

    showDialog(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, sbSetState) {
        // Parse current hex to preview color, fallback to current accent.
        Color previewColor;
        final raw = hexCtrl.text.replaceAll('#', '');
        final intVal = int.tryParse(raw, radix: 16);
        if (intVal != null && raw.length == 6) {
          previewColor = Color(0xFF000000 | intVal);
        } else {
          previewColor = ts.accentColor;
        }

        return AlertDialog(
          backgroundColor: XMateColors.dialogBg(context),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: cs.primary.withAlpha(60))),
          title: Text('Custom accent color', style: TextStyle(fontSize: 16, color: cs.onSurface)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            // Color preview circle
            Center(
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: previewColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: cs.onSurface.withAlpha(60), width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: hexCtrl,
              style: TextStyle(color: cs.onSurface),
              onChanged: (_) => sbSetState(() {}), // refresh preview
              decoration: InputDecoration(
                hintText: '5AAAC2',
                hintStyle: TextStyle(color: cs.onSurface.withAlpha(97)),
                prefixText: '#',
                prefixStyle: TextStyle(color: cs.onSurface),
                filled: true,
                fillColor: cs.onSurface.withAlpha(10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: cs.onSurface.withAlpha(40)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: cs.onSurface.withAlpha(40)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: cs.primary, width: 1.5),
                ),
              ),
            ),
          ]),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: cs.onSurface.withAlpha(138))),
            ),
            TextButton(
              onPressed: () {
                final hex = hexCtrl.text.replaceAll('#', '').trim();
                final val = int.tryParse(hex, radix: 16);
                if (val != null && hex.length == 6) {
                  ts.setAccentColor(Color(0xFF000000 | val));
                  Navigator.pop(ctx);
                }
              },
              child: Text('Apply', style: TextStyle(color: cs.primary)),
            ),
          ],
        );
      }),
    );
  }
}

// ─── Opacity Slider Row ───

class _OpacitySliderRow extends StatefulWidget {
  const _OpacitySliderRow();
  @override State<_OpacitySliderRow> createState() => _OpacitySliderRowState();
}

class _OpacitySliderRowState extends State<_OpacitySliderRow> {
  @override Widget build(BuildContext context) {
    final ts = ThemeService();
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Background opacity', style: TextStyle(fontSize: 14, color: cs.onSurface)),
          const Spacer(),
          Text('${ts.backgroundOpacity}%',
              style: TextStyle(fontSize: 13, color: cs.primary)),
        ]),
        Slider(
          value: ts.backgroundOpacity.toDouble(),
          min: 75,
          max: 100,
          divisions: 25,
          label: '${ts.backgroundOpacity}%',
          onChanged: (v) => ts.setBackgroundOpacity(v.round()),
        ),
      ]),
    );
  }
}

// ─── Version Row ───

/// Read version from pubspec.yaml bundled as a Flutter asset so it
/// works after installation — File I/O against the CWD won't find it.
///
/// Returns the version string or '?.?.?' on failure.
Future<String> _readVersion() async {
  try {
    final content = await rootBundle.loadString('pubspec.yaml');
    final m = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(content);
    if (m != null) return m.group(1)!;
  } catch (_) {}
  return '?.?.?';
}

class _VersionRow extends StatefulWidget {
  final VoidCallback onTap;
  const _VersionRow({required this.onTap});

  @override
  State<_VersionRow> createState() => _VersionRowState();
}

class _VersionRowState extends State<_VersionRow> {
  String _version = '';
  final _updateService = UpdateService();
  UpdateCheckResult? _updateResult;
  bool _downloading = false;
  double _downloadProgress = 0;

  @override
  void initState() {
    super.initState();
    _loadVersion().then((_) => _checkForUpdate());
  }

  Future<void> _loadVersion() async {
    _version = await _readVersion();
    if (mounted) setState(() {});
  }

  Future<void> _checkForUpdate() async {
    if (_version.isEmpty || _version == '?.?.?') return;
    final result = await _updateService.checkForUpdate(_version);
    if (mounted) setState(() => _updateResult = result);
  }

  Future<void> _downloadAndInstall() async {
    final url = _updateResult?.downloadUrl;
    if (url == null || url.isEmpty) return;

    setState(() => _downloading = true);

    final path = await _updateService.downloadInstaller(
      url,
      onProgress: (p) {
        if (mounted) setState(() => _downloadProgress = p);
      },
    );

    if (!mounted) return;

    setState(() => _downloading = false);

    if (path != null) {
      // Launch installer — XMate exits so it can be overwritten
      Process.start(path, [], runInShell: true);
    } else {
      if (mounted) {
        _showErrorSnackBar('Download failed. Please try again later.');
      }
    }
  }

  void _showErrorSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(color: Colors.white)),
        backgroundColor: Colors.redAccent,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final showUpdate = _updateResult != null &&
        _updateResult!.status == UpdateStatus.updateAvailable;
    final showDownloading = _downloading;

    return GestureDetector(
      onTap: widget.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
          const SizedBox(width: double.infinity),
          Container(
            width: 70, height: 70,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: ThemeService().effectiveBrightness == Brightness.dark
                    ? Color.from(alpha: cs.primary.a, red: 1.0 - cs.primary.r, green: 1.0 - cs.primary.g, blue: 1.0 - cs.primary.b)
                    : cs.primary,
                width: 2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(35),
              child: Image.asset(
                ThemeService().effectiveBrightness == Brightness.dark
                    ? 'assets/logo_dark.png'
                    : 'assets/logo.png',
                width: 70, height: 70, fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(height: 6),
          // ── Version row with optional update button ──
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('XMate V$_version', style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(80))),
              if (showUpdate) ... [
                const SizedBox(width: 8),
                _updateButton(),
              ],
            ],
          ),
          // ── Download progress ──
          if (showDownloading) ...[
            const SizedBox(height: 6),
            SizedBox(
              width: 200,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _downloadProgress,
                  minHeight: 4,
                  backgroundColor: cs.onSurface.withAlpha(20),
                  valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Downloading... ${(_downloadProgress * 100).toStringAsFixed(0)}%',
              style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(60)),
            ),
          ],
          const SizedBox(height: 2),
          Text('萧  Gabriel',
              style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(60))),
          const SizedBox(height: 2),
          Text('Built with Claude Code (DeepSeek V4 Pro)',
              style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(50))),
        ]),
      ),
    );
  }

  Widget _updateButton() {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => _confirmUpdate(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: cs.primary.withAlpha(30),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: cs.primary, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.system_update, size: 11, color: cs.primary),
            const SizedBox(width: 4),
            Text(
              'Update',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: cs.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmUpdate() async {
    final latest = _updateResult?.latestVersion ?? '';

    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          backgroundColor: XMateColors.dialogBg(ctx),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: cs.primary.withAlpha(60)),
          ),
          title: Text('Update Available', style: TextStyle(color: cs.onSurface)),
          content: Text(
            'XMate $latest is available.\nYour version: $_version\n\nDownload and install now?',
            style: TextStyle(color: cs.onSurface.withAlpha(179), fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Later',
                  style: TextStyle(color: cs.onSurface.withAlpha(138))),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Download',
                  style: TextStyle(color: cs.primary)),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      await _downloadAndInstall();
    }
  }
}

// ─── Per-Category Engine List ───

class _CategoryEngineList extends StatelessWidget {
  final SearchEngineCategory category;
  final List<SearchEngine> engines;
  final void Function(int) onDelete;
  final void Function(int) onEdit;
  final VoidCallback onAdd;
  final void Function(int, int) onReorder;

  const _CategoryEngineList({
    required this.category,
    required this.engines,
    required this.onDelete,
    required this.onEdit,
    required this.onAdd,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (engines.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('No engines configured',
              style: TextStyle(color: cs.onSurface.withAlpha(138))),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: onAdd,
            icon: Icon(Icons.add, size: 16, color: cs.primary),
            label: Text('Add engine',
                style: TextStyle(fontSize: 13, color: cs.primary)),
          ),
        ]),
      );
    }

    final isImage = category == SearchEngineCategory.image;

    return Column(children: [
      // Add button row
      Padding(
        padding: const EdgeInsets.fromLTRB(0, 4, 4, 2),
        child: Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: onAdd,
            icon: Icon(Icons.add, size: 16, color: cs.primary),
            label: Text('Add',
                style: TextStyle(fontSize: 12, color: cs.primary)),
            style: TextButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
      ),
      // Reorderable list
      Expanded(
        child: ReorderableListView.builder(
          itemCount: engines.length,
          buildDefaultDragHandles: false,
          onReorderItem: onReorder,
          padding: EdgeInsets.zero,
          itemBuilder: (_, i) {
            final e = engines[i];
            final isDefault = i == 0;
            return Padding(
              key: ValueKey('${category.name}_${e.name}_$i'),
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Container(
                decoration: BoxDecoration(
                  color: cs.onSurface.withAlpha(8),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.only(
                    left: 8, right: 4, top: 10, bottom: 10),
                child: Row(children: [
                  ReorderableDragStartListener(
                    index: i,
                    child: Icon(Icons.drag_indicator,
                        size: 16, color: cs.onSurface.withAlpha(77)),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Text(e.name,
                                style: TextStyle(
                                    color: cs.onSurface,
                                    fontSize: 14,
                                    fontWeight: isDefault
                                        ? FontWeight.w600
                                        : FontWeight.w500)),
                            if (isDefault) ...[
                              const SizedBox(width: 6),
                              Text('(default)',
                                  style: TextStyle(
                                      fontSize: 10,
                                      color:
                                          cs.onSurface.withAlpha(97))),
                            ],
                          ]),
                          const SizedBox(height: 2),
                          Text(e.url,
                              style: TextStyle(
                                  color: cs.onSurface.withAlpha(138),
                                  fontSize: 11),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ]),
                  ),
                  if (!isImage && e.copyMode)
                    Container(
                      margin: const EdgeInsets.only(right: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: cs.primary.withAlpha(40),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('copy',
                          style: TextStyle(
                              color: cs.primary, fontSize: 10)),
                    ),
                  if (isImage)
                    Container(
                      margin: const EdgeInsets.only(right: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: cs.primary.withAlpha(40),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('copy',
                          style: TextStyle(
                              color: cs.primary, fontSize: 10)),
                    ),
                  IconButton(
                    icon: Icon(Icons.edit,
                        size: 16,
                        color: cs.onSurface.withAlpha(138)),
                    tooltip: 'Edit',
                    onPressed: () => onEdit(i),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                        minWidth: 32, minHeight: 32),
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_outline,
                        size: 16,
                        color: cs.onSurface.withAlpha(97)),
                    tooltip: 'Delete',
                    onPressed: () => onDelete(i),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                        minWidth: 32, minHeight: 32),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

// ─── Engine Editor Dialog ───

class _EngineEditorDialog extends StatefulWidget {
  final SearchEngine engine;
  final SearchEngineCategory category;
  final bool hideCopyMode;
  const _EngineEditorDialog({
    required this.engine,
    required this.category,
    this.hideCopyMode = false,
  });

  @override
  State<_EngineEditorDialog> createState() => _EngineEditorDialogState();
}

class _EngineEditorDialogState extends State<_EngineEditorDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _urlCtrl;
  late bool _copyMode;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.engine.name);
    _urlCtrl = TextEditingController(text: widget.engine.url);
    _copyMode = widget.engine.copyMode;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  String get _urlHint {
    switch (widget.category) {
      case SearchEngineCategory.image:
        return 'URL (no placeholder)';
      case SearchEngineCategory.text:
      case SearchEngineCategory.map:
      case SearchEngineCategory.dictionary:
        return 'URL ({query} placeholder)';
      case SearchEngineCategory.translate:
        return 'URL ({query} placeholder)';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final catLabel =
        _kCategoryLabels[widget.category] ?? widget.category.name;
    return AlertDialog(
      backgroundColor: XMateColors.dialogBg(context),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: cs.primary.withAlpha(40))),
      title: Text(
        widget.engine.name.isEmpty ? 'Add Engine' : 'Edit Engine',
        style: TextStyle(color: cs.onSurface, fontSize: 18),
      ),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Category label (read-only)
          Row(children: [
            Text('Category: ',
                style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withAlpha(138))),
            Text(catLabel,
                style: TextStyle(
                    fontSize: 12, color: cs.onSurface)),
          ]),
          const SizedBox(height: 14),
          TextField(
            controller: _nameCtrl,
            style: TextStyle(color: cs.onSurface, fontSize: 14),
            decoration: InputDecoration(
              labelText: 'Name',
              labelStyle:
                  TextStyle(color: cs.onSurface.withAlpha(138)),
              filled: true,
              fillColor: cs.onSurface.withAlpha(12),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _urlCtrl,
            style: TextStyle(color: cs.onSurface, fontSize: 14),
            decoration: InputDecoration(
              labelText: _urlHint,
              labelStyle:
                  TextStyle(color: cs.onSurface.withAlpha(138)),
              filled: true,
              fillColor: cs.onSurface.withAlpha(12),
              border: const OutlineInputBorder(),
            ),
          ),
          if (!widget.hideCopyMode) ...[
            const SizedBox(height: 14),
            Row(children: [
              Text('Copy mode',
                  style:
                      TextStyle(color: cs.onSurface, fontSize: 14)),
              const Spacer(),
              SizedBox(
                height: 28,
                child: Transform.scale(
                  scale: 0.7,
                  child: Switch(
                    value: _copyMode,
                    onChanged: (v) =>
                        setState(() => _copyMode = v),
                    activeTrackColor: cs.primary,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 4),
            Text(
              _copyMode
                  ? 'Copy query to clipboard, then open URL'
                  : 'Substitute {query} into URL and open',
              style: TextStyle(
                  color: cs.onSurface.withAlpha(97),
                  fontSize: 11),
            ),
          ],
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            final url = _urlCtrl.text.trim();
            if (name.isEmpty || url.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Name and URL are required'),
                    backgroundColor: Colors.redAccent),
              );
              return;
            }
            Navigator.pop(
                context,
                SearchEngine(
                  name: name,
                  url: url,
                  copyMode: widget.hideCopyMode ? true : _copyMode,
                  category: widget.category,
                ));
          },
          child: Text('OK', style: TextStyle(color: cs.primary)),
        ),
      ],
    );
  }
}
