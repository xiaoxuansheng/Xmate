/// Translate plugin settings — LibreTranslate server config, lifecycle, and model management.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'server_manager.dart';
import 'model_manager.dart';
import 'python_service.dart';
import '../dictionary/dictionary_settings.dart';
import '../../core/theme/theme_colors.dart';

class TranslateSettings extends StatefulWidget {
  final void Function(String key, dynamic value) onSettingChanged;
  final dynamic Function(String key) getSetting;

  const TranslateSettings({
    super.key,
    required this.onSettingChanged,
    required this.getSetting,
  });

  @override
  State<TranslateSettings> createState() => _TranslateSettingsState();
}

class _TranslateSettingsState extends State<TranslateSettings> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _apiKeyCtrl;

  final _server = ServerManager();
  final _models = ModelManager();

  bool _ready = false;
  ServerState _serverState = ServerState.unknown;
  bool _busy = false;
  String _busyLabel = '';
  PythonInfo? _pythonInfo;
  bool _serverInstalled = false;

  List<PairedModel> _installed = [];
  List<PairedAvailable> _available = [];

  bool _installing = false;
  final _installLog = <String>[];

  StreamSubscription<ServerState>? _stateSub;

  static const _green = Color(0xFF40C057);
  static const _red = Color(0xFFE84040);
  static const _orange = Color(0xFFE8A440);

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(
      text: widget.getSetting('serverUrl') as String? ?? 'http://localhost:5000',
    );
    _apiKeyCtrl = TextEditingController(
      text: widget.getSetting('apiKey') as String? ?? '',
    );
    _serverState = _server.state;
    _stateSub = _server.onStateChanged.listen((s) {
      if (mounted) setState(() => _serverState = s);
    });
    _init();
  }

  Future<void> _init() async {
    _pythonInfo = await PythonService.detect();
    // Use ServerManager.isInstalled() as the primary check — it runs
    // "libretranslate --help" which is more reliable than the Python
    // import check (model_manager's checkInstalled).  The latter can
    // fail when the Python script path can't be resolved or when there
    // are venv / site-packages mismatches.
    var installed = await _server.isInstalled();
    if (!installed) {
      installed = await _models.checkInstalled();
    }
    await _server.adoptIfRunning();
    await _refreshModels();
    if (!mounted) return;
    setState(() {
      _serverInstalled = installed;
      _serverState = _server.state;
      _ready = true;
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _stateSub?.cancel();
    super.dispose();
  }

  void _save() {
    widget.onSettingChanged('serverUrl', _urlCtrl.text.trim());
    widget.onSettingChanged('apiKey', _apiKeyCtrl.text);
  }

  Future<void> _refreshModels() async {
    setState(() { _busy = true; _busyLabel = 'Loading models...'; });
    final installed = await _models.listInstalledPairs();
    if (!mounted) return;
    setState(() { _installed = installed; _busy = false; _busyLabel = ''; });
  }

  Future<void> _loadAvailable() async {
    setState(() { _busy = true; _busyLabel = 'Fetching available...'; });
    final available = await _models.listAvailablePairs();
    if (!mounted) return;
    final installedKeys = _installed.map((m) => m.pairKey).toSet();
    setState(() {
      _available = available.where((a) => !installedKeys.contains(a.pairKey)).toList();
      _busy = false; _busyLabel = '';
    });
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = cs.primary;
    if (!_ready) {
      return Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: accent)));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ═══════════════════════════════════════════════════════
          // Translate section
          // ═══════════════════════════════════════════════════════
          _buildSectionCard(
            title: 'Translate',
            icon: Icons.translate,
            children: [
              // ── 1. Install ───────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                child: _sectionHeader('Install', Icons.build),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
                child: _buildInstallRow(),
              ),
              if (_installLog.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
                  child: _buildLogArea(),
                ),
              ],
              const _Divider(),

              // ── 2. Server ────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                child: _sectionHeader('Server', Icons.dns),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
                child: _buildServerRow(),
              ),
              const _Divider(),

              // ── 3. Models ─────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                child: _sectionHeader('Models', Icons.model_training),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
                child: _buildInstalledModels(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                child: Row(children: [
                  Text('Available',
                      style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(138), fontWeight: FontWeight.w600)),
                  const Spacer(),
                  _miniBtn('Refresh', _loadAvailable, loading: _busy),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
                child: _buildAvailableModels(),
              ),
              if (_busy && _busyLabel.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
                  child: Row(children: [
                    SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: accent)),
                    const SizedBox(width: 8),
                    Text(_busyLabel, style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(138))),
                  ]),
                ),
              const _Divider(),
              _buildCopyright('LibreTranslate — open-source machine translation (libretranslate.com)'),
            ],
          ),

          const SizedBox(height: 20),
          // ═══════════════════════════════════════════════════════
          // Dictionary section
          // ═══════════════════════════════════════════════════════
          const DictionarySettings(),
        ],
      ),
    );
  }

  // ── 1. Install row ───────────────────────────────────────────────

  Widget _buildInstallRow() {
    final cs = Theme.of(context).colorScheme;
    final accent = cs.primary;
    final pythonOK = _pythonInfo != null && _pythonInfo!.found;
    final statusText = _serverInstalled ? 'Installed' : 'Not installed';
    final statusColor = _serverInstalled ? _green : cs.onSurface.withAlpha(97);
    final pythonText = pythonOK ? 'Python ${_pythonInfo!.version}' : 'Python not detected';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: XMateColors.cardFill(context), borderRadius: BorderRadius.circular(6),
        border: Border.all(color: XMateColors.highlight(context)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Row 1: Status + action
        Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: statusColor)),
          const SizedBox(width: 8),
          Expanded(child: Text(statusText, style: TextStyle(fontSize: 12, color: cs.onSurface))),
          if (_installing)
            SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: accent))
          else if (!pythonOK)
            _actionBtn('Install Python', Icons.install_desktop, _orange, () => _doInstallPython())
          else if (!_serverInstalled)
            _actionBtn('Install', Icons.download, _green, () => _doInstallServer())
          else
            _actionBtn('Uninstall', Icons.delete_outline, _red, () => _doUninstallServer()),
        ]),
        // Row 2: Python version hint
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 16),
          child: Text(pythonText, style: TextStyle(fontSize: 10, color: pythonOK ? cs.onSurface.withAlpha(97) : _red)),
        ),
      ]),
    );
  }

  Widget _buildLogArea() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 100),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: cs.onSurface.withAlpha(15), borderRadius: BorderRadius.circular(4),
      ),
      child: SingleChildScrollView(
        reverse: true,
        child: Text(
          _installLog.join('\n'),
          style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurface.withAlpha(138), fontFamily: 'monospace'),
        ),
      ),
    );
  }

  Future<void> _doInstallPython() async {
    setState(() { _installing = true; _installLog.clear(); });
    try {
      final ok = await PythonService.install(onLog: (line) {
        if (mounted) setState(() => _installLog.add(line));
      });
      if (!mounted) return;
      if (ok) {
        _pythonInfo = await PythonService.detect();
        setState(() {
          _installing = false;
          // Refresh _pythonInfo so the UI flips from "Install Python"
          // to "Install" (LibreTranslate) without needing a tab switch.
        });
        _showSnack('Python installed');
      } else {
        setState(() => _installing = false);
        _showSnack('Python install failed — see log');
      }
    } catch (e) {
      if (mounted) { setState(() => _installing = false); _showSnack('Error: $e'); }
    }
  }

  Future<void> _doInstallServer() async {
    setState(() { _installing = true; _installLog.clear(); });
    try {
      final ok = await _models.installServer(onLog: (line) {
        if (mounted) setState(() => _installLog.add(line));
      });
      if (!mounted) return;
      setState(() {
        _installing = false;
        if (ok) {
          _serverInstalled = true;
          _serverState = ServerState.stopped;
        }
      });
      if (ok) {
        _showSnack('Install complete');
      } else {
        _showSnack('Install failed — see log');
      }
    } catch (e) {
      if (mounted) {
        setState(() { _installing = false; _serverState = ServerState.error; });
        _showSnack('Error: $e');
      }
    }
  }

  Future<void> _doUninstallServer() async {
    if (_serverState == ServerState.running) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => _confirmDialog(
          'Uninstall LibreTranslate',
          'Server is running. It will be stopped first.\nContinue?',
        ),
      );
      if (confirm != true) return;
      await _server.stop();
    }

    setState(() { _installing = true; _installLog.clear(); });
    try {
      final ok = await _models.uninstallServer(onLog: (line) {
        if (mounted) setState(() => _installLog.add(line));
      });
      if (!mounted) return;
      setState(() => _installing = false);
      if (ok) {
        _serverInstalled = false;
        _installed.clear();
        _available.clear();
        _serverState = ServerState.notInstalled;
        _showSnack('Uninstall complete');
      } else {
        _showSnack('Uninstall failed — see log');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _installing = false);
        _showSnack('Error: $e');
      }
    }
  }

  // ── 2. Server row ────────────────────────────────────────────────

  Widget _buildServerRow() {
    final cs = Theme.of(context).colorScheme;
    final running = _serverState == ServerState.running;
    final starting = _serverState == ServerState.starting;
    final stopping = _serverState == ServerState.stopping;

    Color dotColor;
    String label;
    switch (_serverState) {
      case ServerState.running:
        dotColor = _green; label = 'Running — $_urlText';
      case ServerState.starting:
        dotColor = _orange; label = 'Starting...';
      case ServerState.stopping:
        dotColor = _orange; label = 'Stopping...';
      case ServerState.error:
        dotColor = _red; label = _server.lastError;
      case ServerState.stopped:
        dotColor = cs.onSurface.withAlpha(97); label = 'Stopped';
      case ServerState.notInstalled:
        dotColor = cs.onSurface.withAlpha(97); label = 'Not installed';
      case ServerState.unknown:
        dotColor = cs.onSurface.withAlpha(24); label = 'Unknown';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: XMateColors.cardFill(context), borderRadius: BorderRadius.circular(8),
        border: Border.all(color: XMateColors.highlight(context)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // URL + API key row
        Row(children: [
          Expanded(
            flex: 3,
            child: _urlField(),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 1,
            child: _apiKeyField(),
          ),
          const SizedBox(width: 6),
          _miniBtn('Save', _save),
        ]),
        const SizedBox(height: 8),
        // Status + buttons row
        Row(children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor)),
          const SizedBox(width: 6),
          Expanded(child: Text(label, style: TextStyle(fontSize: 11, color: cs.onSurface), maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (!running && _serverInstalled)
            _actionBtn('Start', Icons.play_arrow, _green, starting ? null : () => _doStart()),
          if (running || stopping)
            _actionBtn('Stop', Icons.stop, _red, stopping ? null : () => _doStop()),
          const SizedBox(width: 6),
          _iconBtn(Icons.refresh, _busy ? null : _refreshModels),
        ]),
      ]),
    );
  }

  Widget _urlField() {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 30,
      child: TextField(
        controller: _urlCtrl,
        style: TextStyle(fontSize: 12, color: cs.onSurface),
        decoration: InputDecoration(
          hintText: 'http://localhost:5000',
          hintStyle: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(77)),
          filled: true, fillColor: XMateColors.highlight(context),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          isDense: true,
        ),
      ),
    );
  }

  Widget _apiKeyField() {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 30,
      child: TextField(
        controller: _apiKeyCtrl,
        obscureText: true,
        style: TextStyle(fontSize: 12, color: cs.onSurface),
        decoration: InputDecoration(
          hintText: 'API key',
          hintStyle: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(77)),
          filled: true, fillColor: XMateColors.highlight(context),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          isDense: true,
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback? onTap) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Icon(icon, size: 16, color: onTap != null ? cs.onSurface.withAlpha(138) : cs.onSurface.withAlpha(24)),
    );
  }

  String get _urlText {
    final t = _urlCtrl.text.trim();
    return t.isEmpty ? 'http://localhost:5000' : t;
  }

  Future<void> _doStart() async {
    final codes = <String>{'en'};
    for (final m in _installed) {
      codes.add(m.code1);
      codes.add(m.code2);
    }
    await _server.start(loadOnly: codes.join(','));
  }

  Future<void> _doStop() async => _server.stop();

  // ── 3. Models ────────────────────────────────────────────────────

  Widget _buildInstalledModels() {
    if (_installed.isEmpty && !_busy) {
      return Padding(
        padding: const EdgeInsets.only(left: 4, top: 2),
        child: Text('No models installed', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withAlpha(97))),
      );
    }
    return Column(children: _installed.map((m) => _pairedModelRow(m)).toList());
  }

  Widget _pairedModelRow(PairedModel m) {
    final cs = Theme.of(context).colorScheme;
    final dir = m.isComplete ? '↔' : '→';
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: XMateColors.cardFill(context), borderRadius: BorderRadius.circular(6),
          border: Border.all(color: XMateColors.inputBorder(context)),
        ),
        child: Row(children: [
          Icon(Icons.translate, size: 14, color: cs.onSurface.withAlpha(97)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${m.name1} $dir ${m.name2}', style: TextStyle(fontSize: 12, color: cs.onSurface)),
              Text(m.sizeLabel, style: TextStyle(fontSize: 10, color: cs.onSurface.withAlpha(97))),
            ]),
          ),
          _miniBtn('Remove', () => _doUninstall(m)),
        ]),
      ),
    );
  }

  Future<void> _doUninstall(PairedModel m) async {
    final running = _serverState == ServerState.running;
    if (running) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => _confirmDialog(
          'Remove ${m.label}',
          'Server will be restarted after removal.\nContinue?',
        ),
      );
      if (confirm != true) return;
    }

    setState(() { _busy = true; _busyLabel = 'Removing ${m.label}...'; });
    try {
      final r = await _models.uninstallPair(m.code1, m.code2);
      if (r['ok'] == true) {
        if (running) await _server.stop();
        await _refreshModels();
        if (mounted && _serverState == ServerState.stopped) {
          await _server.start(loadOnly: _installedLoadOnly());
        }
      } else {
        if (mounted) _showSnack(r['error'] as String? ?? 'Remove failed');
      }
    } finally {
      if (mounted) setState(() { _busy = false; _busyLabel = ''; });
    }
  }

  // ── Available models ─────────────────────────────────────────────

  Widget _buildAvailableModels() {
    if (_available.isEmpty) {
      if (!_busy && _installed.isEmpty) {
        return Padding(
          padding: const EdgeInsets.only(left: 4, top: 2),
          child: Text('Click Refresh to fetch available models.',
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurface.withAlpha(97))),
        );
      }
      return const SizedBox.shrink();
    }

    return Column(children: _available.map((a) => _availableRow(a)).toList());
  }

  Widget _availableRow(PairedAvailable a) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: XMateColors.cardFill(context), borderRadius: BorderRadius.circular(6),
          border: Border.all(color: XMateColors.inputBorder(context)),
        ),
        child: Row(children: [
          Text('${a.name1} ↔ ${a.name2}',
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withAlpha(138),
              fontWeight: (a.code1 == 'zh' && a.code2 == 'en') ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          const Spacer(),
          _miniBtn('Install', () => _doInstall(a)),
        ]),
      ),
    );
  }

  Future<void> _doInstall(PairedAvailable a) async {
    final running = _serverState == ServerState.running;
    setState(() { _busy = true; _busyLabel = 'Installing ${a.name1} ↔ ${a.name2}...'; });
    try {
      final r = await _models.installPair(a.code1, a.code2);
      if (!mounted) return;
      if (r['ok'] == true) {
        await _refreshModels();
        if (mounted) {
          final installedKeys = _installed.map((m) => m.pairKey).toSet();
          setState(() {
            _available.removeWhere((x) => installedKeys.contains(x.pairKey));
          });
        }
        if (running) {
          await _server.stop();
          await _server.start(loadOnly: _installedLoadOnly());
        }
      } else {
        _showSnack(r['error'] as String? ?? 'Install failed');
      }
    } finally {
      if (mounted) setState(() { _busy = false; _busyLabel = ''; });
    }
  }

  String _installedLoadOnly() {
    final codes = <String>{'en'};
    for (final m in _installed) {
      codes.add(m.code1);
      codes.add(m.code2);
    }
    return codes.join(',');
  }

  // ── Shared helpers ───────────────────────────────────────────────

  Widget _actionBtn(String label, IconData icon, Color color, VoidCallback? onTap) {
    final cs = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 14, color: onTap != null ? color : cs.onSurface.withAlpha(24)),
      label: Text(label, style: TextStyle(fontSize: 11, color: onTap != null ? cs.onSurface : cs.onSurface.withAlpha(24))),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: (onTap != null ? color : cs.onSurface.withAlpha(24)).withAlpha(60)),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: Size.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
    );
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 12)),
      backgroundColor: XMateColors.pageBg(context),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ));
  }

  Widget _confirmDialog(String title, String body) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: XMateColors.dialogBg(context),
      title: Text(title, style: TextStyle(fontSize: 14, color: cs.onSurface)),
      content: Text(body, style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(179))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel', style: TextStyle(color: cs.onSurface.withAlpha(97)))),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue', style: TextStyle(color: _red))),
      ],
    );
  }

  Widget _sectionHeader(String title, IconData icon) {
    final cs = Theme.of(context).colorScheme;
    return Row(children: [
      Icon(icon, size: 15, color: cs.primary), const SizedBox(width: 6),
      Text(title, style: TextStyle(fontSize: 13, color: cs.primary, fontWeight: FontWeight.w600)),
    ]);
  }

  Widget _miniBtn(String label, VoidCallback? onTap, {bool loading = false}) {
    final cs = Theme.of(context).colorScheme;
    final accent = cs.primary;
    return GestureDetector(
      onTap: (onTap != null && !loading) ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          color: (onTap != null && !loading)
              ? XMateColors.inputFill(context)
              : cs.onSurface.withAlpha(15),
        ),
        child: loading
            ? SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: accent))
            : Text(label, style: TextStyle(fontSize: 10, color: onTap != null ? accent : cs.onSurface.withAlpha(24))),
      ),
    );
  }

  Widget _buildCopyright(String text) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10,
            color: cs.onSurface.withAlpha(70),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
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

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: 14,
      endIndent: 14,
      color: Theme.of(context).dividerColor,
    );
  }
}
