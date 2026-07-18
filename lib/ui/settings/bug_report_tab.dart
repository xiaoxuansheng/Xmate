/// Bug report tab — Settings → Debug tab.
///
/// Embeds a 1x1 pixel InAppWebView directly in the widget tree for
/// real WebView2 rendering (needed for MS Forms React app to fully
/// initialize DOM). On submit, loads the form URL → fills via JS →
/// clicks Submit → disposes. The 1x1 WebView is invisible in practice.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class BugReportTab extends StatefulWidget {
  const BugReportTab({super.key});

  @override
  State<BugReportTab> createState() => _BugReportTabState();
}

enum _FbState { idle, loading, submitted, failed }

class _BugReportTabState extends State<BugReportTab> {
  final _descCtrl = TextEditingController();
  _FbState _fb = _FbState.idle;

  // ── 1×1 invisible WebView fields ──
  InAppWebViewController? _wvCtrl;
  Completer<void>? _wvReady;
  bool _wvCreated = false;

  static const _formUrl =
      'https://forms.cloud.microsoft/Pages/ResponsePage.aspx'
      '?id=DQSIkWdsW0yxEjajBLZtrQAAAAAAAAAAAANAAdE-9WJUMEZPQUVKSFpLSERDR0hHRkhNRlVDRkJPUS4u';

  bool get _canSubmit => _descCtrl.text.trim().isNotEmpty && _fb != _FbState.loading;

  @override
  void initState() {
    super.initState();
    _descCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _descCtrl.removeListener(() {});
    _descCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_canSubmit || !_wvCreated || _wvCtrl == null) return;
    _startFillSequence();
  }

  Future<void> _startFillSequence() async {
    if (_fb == _FbState.loading) return;
    setState(() => _fb = _FbState.loading);

    final desc = _descCtrl.text.trim();
    _wvReady = Completer<void>();

    // Navigate to the form
    _wvCtrl!.loadUrl(urlRequest: URLRequest(url: WebUri(_formUrl)));

    // Wait for loadStop callback to signal ready
    try {
      await _wvReady!.future.timeout(const Duration(seconds: 15));
      // loaded → run fill sequence
      final ok = await _fillSequence(desc);
      if (mounted) setState(() => _fb = ok ? _FbState.submitted : _FbState.failed);
    } on TimeoutException {
      if (mounted) setState(() => _fb = _FbState.failed);
    } catch (_) {
      if (mounted) setState(() => _fb = _FbState.failed);
    }
  }

  /// onLoadStop callback: fires when the form page finishes loading.
  void _onLoadStop() {
    _wvReady?.complete();
  }

  Future<bool> _fillSequence(String description) async {
    final c = _wvCtrl!;
    // Wait for React to render
    await Future.delayed(const Duration(seconds: 3));

    // Stage 1: click → fill → submit (up to 4 rounds)
    for (int i = 0; i < 4; i++) {
      await c.evaluateJavascript(source: _clickQuestionJs());
      await Future.delayed(const Duration(milliseconds: 1500));

      final fr = await c.evaluateJavascript(source: _findAndFillJs(description));
      if (fr != null && fr.contains('"filled:')) {
        await Future.delayed(const Duration(milliseconds: 500));
        final sr = await c.evaluateJavascript(source: _clickSubmitJs());
        if (sr != null && sr.contains('"clicked:')) return true;
      }
    }

    // Stage 2: keyboard fallback (up to 3 rounds)
    for (int i = 0; i < 3; i++) {
      final kr = await c.evaluateJavascript(source: _keyboardFillJs(description));
      if (kr != null && (kr.contains('"typed:') || kr.contains('"textarea:'))) {
        await Future.delayed(const Duration(milliseconds: 500));
        final sr = await c.evaluateJavascript(source: _clickSubmitJs());
        if (sr != null && sr.contains('"clicked:')) return true;
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    return false;
  }

  // ── JS snippets ──────────────────────────────────────────────

  static String _clickQuestionJs() => '''
(function(){
  var ss=['[class*="question"]','[class*="Question"]','[class*="response"]','[class*="Response"]','[class*="container"]','[class*="Container"]','[class*="row"]','[class*="Row"]','[class*="textbox"]','[class*="TextBox"]','[role="textbox"]','[role="group"]'];
  var n=0;
  for(var s=0;s<ss.length&&n<5;s++){
    var es=document.querySelectorAll(ss[s]);
    for(var i=0;i<es.length&&n<5;i++){if(es[i].offsetParent!==null){es[i].click();n++;}}
  }
  document.body.click();
  return JSON.stringify('c:'+n);
})();
''';

  static String _findAndFillJs(String description) {
    final b64 = base64Encode(utf8.encode(description));
    return '''
(function(){
  try{var b64='$b64',raw=atob(b64),bytes=new Uint8Array(raw.length);
  for(var i=0;i<raw.length;i++)bytes[i]=raw.charCodeAt(i);
  var t=new TextDecoder('utf-8').decode(bytes);
  function S(e,v){e.focus();var p=e instanceof HTMLTextAreaElement?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;var d=Object.getOwnPropertyDescriptor(p,'value');if(d&&d.set)d.set.call(e,v);else e.value=v;try{e.dispatchEvent(new InputEvent('input',{bubbles:!0,composed:!0,cancelable:!0,inputType:'insertText',data:v}))}catch(_){e.dispatchEvent(new Event('input',{bubbles:!0,composed:!0}))}e.dispatchEvent(new Event('change',{bubbles:!0,composed:!0}));e.dispatchEvent(new FocusEvent('blur',{bubbles:!0}))}
  function R(e,v){e.focus();e.innerText='';e.innerText=v;try{e.dispatchEvent(new InputEvent('input',{bubbles:!0,composed:!0,inputType:'insertText',data:v}))}catch(_){e.dispatchEvent(new Event('input',{bubbles:!0,composed:!0}))}e.dispatchEvent(new Event('change',{bubbles:!0,composed:!0}));e.blur()}
  var fs=[];
  document.querySelectorAll('input[type="text"]:not([readonly]):not([disabled]), textarea:not([readonly]):not([disabled])').forEach(function(e){fs.push({e:e,t:'i'})});
  document.querySelectorAll('div[contenteditable="true"]:not([aria-readonly="true"])').forEach(function(e){fs.push({e:e,t:'r'})});
  var ifs=document.querySelectorAll('iframe');
  for(var fi=0;fi<ifs.length&&fs.length===0;fi++){try{var doc=ifs[fi].contentDocument||ifs[fi].contentWindow.document;if(doc){doc.querySelectorAll('input[type="text"]:not([readonly]):not([disabled]), textarea:not([readonly]):not([disabled])').forEach(function(e){fs.push({e:e,t:'i'})});doc.querySelectorAll('div[contenteditable="true"]:not([aria-readonly="true"])').forEach(function(e){fs.push({e:e,t:'r'})})}}catch(_){}}
  if(fs.length===0)return JSON.stringify('nf');
  var f=fs[0];if(f.t==='r')R(f.e,t);else S(f.e,t);
  var v=f.t==='r'?f.e.innerText:f.e.value;return JSON.stringify('filled:'+(v?v.length:0));}
  catch(e){return JSON.stringify('err:'+e.message)}
})();
''';
  }

  static String _clickSubmitJs() => '''
(function(){
  try{var ss=['button[aria-label*="Submit" i]','button[aria-label*="提交" i]','button.__submitButton__','button[data-automation-id="submitButton"]','.office-form-submit button','button.ms-Button--primary'];
  var btn=null;
  for(var s=0;s<ss.length;s++){var b=document.querySelector(ss[s]);if(b&&b.offsetParent!==null){btn=b;break;}}
  if(!btn){var all=document.querySelectorAll('button');for(var i=0;i<all.length;i++){if(all[i].offsetParent!==null&&(all[i].innerText||'').toLowerCase().indexOf('submit')>=0){btn=all[i];break;}}}
  if(!btn){var all=document.querySelectorAll('button');for(var i=all.length-1;i>=0;i--){if(all[i].offsetParent!==null){btn=all[i];break;}}}
  if(btn){btn.scrollIntoView({block:'center'});btn.click();return JSON.stringify('clicked:'+((btn.innerText||'').substring(0,40)))}
  return JSON.stringify('no-btn');}
  catch(e){return JSON.stringify('err:'+e.message)}
})();
''';

  static String _keyboardFillJs(String description) {
    final b64 = base64Encode(utf8.encode(description));
    return '''
(function(){
  try{var b64='$b64',raw=atob(b64),bytes=new Uint8Array(raw.length);
  for(var i=0;i<raw.length;i++)bytes[i]=raw.charCodeAt(i);
  var t=new TextDecoder('utf-8').decode(bytes);
  document.body.focus();document.body.click();
  for(var k=0;k<15;k++){document.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',code:'Tab',keyCode:9,which:9,bubbles:!0,cancelable:!0,composed:!0}));var ae=document.activeElement;if(ae&&ae!==document.body&&ae!==document.documentElement&&(ae.tagName==='INPUT'||ae.tagName==='TEXTAREA'||ae.contentEditable==='true'))break}
  var ae=document.activeElement;
  if(ae&&(ae.tagName==='INPUT'||ae.tagName==='TEXTAREA'||ae.contentEditable==='true')){ae.focus();if(ae.contentEditable==='true'){ae.innerText=t}else{var p=ae instanceof HTMLTextAreaElement?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;var d=Object.getOwnPropertyDescriptor(p,'value');if(d&&d.set)d.set.call(ae,t);else ae.value=t}try{ae.dispatchEvent(new InputEvent('input',{bubbles:!0,composed:!0,cancelable:!0,inputType:'insertText',data:t}))}catch(_){ae.dispatchEvent(new Event('input',{bubbles:!0,composed:!0}))}ae.dispatchEvent(new Event('change',{bubbles:!0,composed:!0}));ae.dispatchEvent(new FocusEvent('blur',{bubbles:!0}));var v=ae.value||ae.innerText||'';if(v.length>0)return JSON.stringify('typed:'+v.length)}
  var ta=document.querySelector('textarea');if(ta&&ta.offsetParent!==null){ta.focus();ta.value=t;ta.dispatchEvent(new Event('input',{bubbles:!0,composed:!0}));ta.dispatchEvent(new Event('change',{bubbles:!0,composed:!0}));return JSON.stringify('textarea:'+(ta.value?ta.value.length:0))}
  return JSON.stringify('no-input');}
  catch(e){return JSON.stringify('err:'+e.message)}
})();
''';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final loading = _fb == _FbState.loading;

    return Container(
      decoration: BoxDecoration(
        color: cs.onSurface.withAlpha(8),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 1×1 invisible WebView (always in tree, real rendering) ──
          SizedBox(
            width: 1,
            height: 1,
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topLeft,
                maxWidth: 1,
                maxHeight: 1,
                child: InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri('about:blank')),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    domStorageEnabled: true,
                    supportZoom: false,
                    useWideViewPort: true,
                  ),
                  onWebViewCreated: (ctrl) {
                    _wvCtrl = ctrl;
                    _wvCreated = true;
                  },
                  onLoadStop: (ctrl, url) {
                    if (url != null && !url.toString().startsWith('about:')) {
                      _onLoadStop();
                    }
                  },
                ),
              ),
            ),
          ),
          // ── Visible UI ──
          Row(
            children: [
              Icon(Icons.bug_report, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              Text('Bug Report',
                  style: TextStyle(fontSize: 13, color: cs.primary, fontWeight: FontWeight.w500)),
              const Spacer(),
              if (_fb == _FbState.submitted)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle, size: 14, color: Color(0xFF4CAF50)),
                    const SizedBox(width: 4),
                    Text('Submitted', style: TextStyle(fontSize: 11, color: cs.primary)),
                  ],
                ),
              if (_fb == _FbState.failed)
                Text('Failed — retry?', style: TextStyle(fontSize: 11, color: Colors.redAccent.withAlpha(200))),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _descCtrl,
            enabled: !loading,
            maxLines: 5,
            style: TextStyle(fontSize: 13, color: cs.onSurface),
            decoration: InputDecoration(
              hintText: 'Describe the bug...',
              hintStyle: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(80)),
              filled: true,
              fillColor: cs.onSurface.withAlpha(10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: cs.onSurface.withAlpha(30))),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: cs.onSurface.withAlpha(30))),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: cs.primary, width: 1.5)),
              contentPadding: const EdgeInsets.all(10), isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 32,
            child: ElevatedButton(
              onPressed: _canSubmit ? _submit : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF5AAAC2),
                foregroundColor: Colors.white,
                disabledBackgroundColor: cs.onSurface.withAlpha(30),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
              child: loading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(
                      _fb == _FbState.submitted ? 'Submitted' : 'Submit Feedback',
                      style: const TextStyle(fontSize: 12),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
