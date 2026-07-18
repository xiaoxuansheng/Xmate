import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Plain-text preview with line numbers (Dart fallback when WebView2 unavailable).
///
/// Uses [ListView.builder] for correct line-to-line alignment.
/// Click a line number to toggle select; Shift+click for range select;
/// Ctrl+C copies selected lines.
class QuickLookTextView extends StatefulWidget {
  final String filePath;
  const QuickLookTextView({super.key, required this.filePath});

  @override
  State<QuickLookTextView> createState() => _QuickLookTextViewState();
}

class _QuickLookTextViewState extends State<QuickLookTextView> {
  String? _content;
  String? _errorMsg;
  bool _truncated = false;
  static const _maxBytes = 1 * 1024 * 1024;
  final Set<int> _selLines = {};
  int _lastLine = -1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant QuickLookTextView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filePath != oldWidget.filePath) {
      _content = null;
      _errorMsg = null;
      _truncated = false;
      _selLines.clear();
      _lastLine = -1;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final file = File(widget.filePath);
      if (!await file.exists()) {
        if (!mounted) return;
        setState(() => _errorMsg = 'Failed to read text');
        return;
      }
      final length = await file.length();
      final readLen = length > _maxBytes ? _maxBytes : length;
      final truncated = length > _maxBytes;
      final bytes =
          await file.readAsBytes().then((b) => b.sublist(0, readLen));
      String content;
      try {
        content = String.fromCharCodes(bytes);
      } catch (_) {
        content = String.fromCharCodes(bytes.cast<int>());
      }
      if (!mounted) return;
      setState(() {
        _content = content;
        _truncated = truncated;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMsg = 'Failed to read text');
    }
  }

  void _onLineTap(int n) {
    setState(() {
      if (_lastLine >= 0 &&
          (HardwareKeyboard.instance.isShiftPressed)) {
        final lo = math.min(_lastLine, n);
        final hi = math.max(_lastLine, n);
        for (var i = lo; i <= hi; i++) {
          _selLines.add(i);
        }
      } else {
        if (_selLines.contains(n)) {
          _selLines.remove(n);
        } else {
          _selLines.add(n);
        }
      }
      _lastLine = n;
    });
  }

  void _onTextTap() {
    if (_selLines.isNotEmpty) {
      setState(() {
        _selLines.clear();
        _lastLine = -1;
      });
    }
  }

  void _copySelected() {
    if (_selLines.isEmpty) return;
    final sorted = _selLines.toList()..sort();
    final text = sorted.map((i) => linesForCopy).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    setState(() {
      _selLines.clear();
      _lastLine = -1;
    });
  }

  List<String> get linesForCopy => _content?.split('\n') ?? [];

  @override
  Widget build(BuildContext context) {
    if (_errorMsg != null) {
      return Center(
        child: Text(_errorMsg!,
            style: const TextStyle(fontSize: 15, color: Colors.redAccent)),
      );
    }
    if (_content == null) {
      return const Center(
        child:
            CircularProgressIndicator(strokeWidth: 2, color: Colors.white38),
      );
    }

    final lines = _content!.split('\n');

    return Column(
      children: [
        if (_truncated)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: Colors.orange.withAlpha(40),
            child: const Text('File too large, showing first 1 MB',
                style: TextStyle(fontSize: 11, color: Colors.orangeAccent)),
          ),
        Expanded(
          child: Actions(
            actions: <Type, Action<Intent>>{
              CopySelectionTextIntent:
                  CallbackAction<CopySelectionTextIntent>(onInvoke: (intent) {
                _copySelected();
                return null;
              }),
              SelectAllTextIntent:
                  CallbackAction<SelectAllTextIntent>(onInvoke: (intent) {
                setState(() {
                  for (var i = 0; i < lines.length; i++) {
                    _selLines.add(i);
                  }
                  _lastLine = lines.length - 1;
                });
                return null;
              }),
            },
            child: ListView.builder(
              itemCount: lines.length,
              itemExtent: 19.5,
              itemBuilder: (context, i) {
                final sel = _selLines.contains(i);
                return GestureDetector(
                  onTap: () => _onTextTap(),
                  child: Container(
                    color: sel ? const Color(0x1E80D8FF) : Colors.transparent,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GestureDetector(
                          onTap: () => _onLineTap(i),
                          child: Container(
                            width: 52,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 8),
                            child: Text(
                              '${i + 1}',
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.0,
                                color: sel
                                    ? const Color(0xFF80D8FF)
                                    : Colors.white38,
                                fontFamily: 'Consolas',
                              ),
                            ),
                          ),
                        ),
                        Container(width: 1, color: Colors.white10, height: 19.5),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            lines[i],
                            style: const TextStyle(
                              fontSize: 13,
                              height: 1.5,
                              color: Colors.white,
                              fontFamily: 'Consolas',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
