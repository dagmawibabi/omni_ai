import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../agents/toolkit.dart';
import '../core/tools.dart';
import 'device_sandbox.dart' show webViewSupported;

/// A real browser the AI drives: one web view that runs pages' JavaScript,
/// so it can use sites that are apps (search boxes, forms, logins). Put
/// [BrowserView] on screen to watch it live or take over (sign in, solve a
/// check), then hand back. The way teleai's browser works.
///
/// Elements are numbered by [read]; clicks and typing use those numbers
/// until the next read.
class BrowserSession extends ChangeNotifier {
  BrowserSession({this.userAgent = defaultUserAgent});

  static const defaultUserAgent = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/130.0.0.0 Mobile Safari/537.36';

  final String userAgent;
  WebViewController? _controller;
  Completer<void>? _loading;
  String? _lastError;
  String? _url;
  String? _title;
  Map<int, String> _labels = {};

  /// What the AI is doing right now ("Opening example.com"), for the view.
  String? activity;

  /// The page shown in [BrowserView]; null until a page is opened.
  WebViewController? get controller => _controller;
  bool get isOpen => _controller != null;
  String? get url => _url;
  String? get title => _title;

  /// The open page's site, e.g. `example.com`.
  String? get host {
    final u = _url == null ? null : Uri.tryParse(_url!);
    return u == null || u.host.isEmpty ? null : u.host;
  }

  /// What element [i] said at the last read, for approval dialogs.
  String? elementLabel(int i) => _labels[i];

  WebViewController _ensure() {
    if (!webViewSupported) throw UnsupportedError('The browser works on Android, iOS and macOS. Use fetch_url instead.');
    final existing = _controller;
    if (existing != null) return existing;
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(userAgent)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (u) {
          _lastError = null;
          _url = u;
          if (_loading == null || _loading!.isCompleted) _loading = Completer<void>();
          notifyListeners();
        },
        onPageFinished: (u) async {
          _url = u;
          if (_loading?.isCompleted == false) _loading!.complete();
          try {
            _title = await _controller?.getTitle();
          } catch (_) {}
          notifyListeners();
        },
        onWebResourceError: (e) {
          if (e.isForMainFrame ?? true) _lastError = '${e.errorCode} ${e.description}';
        },
      ));
    _controller = c;
    notifyListeners();
    return c;
  }

  WebViewController _require() => _controller ?? (throw StateError('No page is open. Call browser_open first.'));

  void _doing(String? what) {
    activity = what;
    notifyListeners();
  }

  /// Waits for a load, then a moment more for scripts to render.
  Future<void> _settle({Duration extra = const Duration(milliseconds: 1500)}) async {
    final loading = _loading;
    if (loading != null && !loading.isCompleted) await loading.future.timeout(const Duration(seconds: 25), onTimeout: () {});
    await Future<void>.delayed(extra);
    for (var i = 0; i < 10; i++) {
      if (await _eval('return document.readyState;') == 'complete') break;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  /// Runs a function body in the page and returns its value, through JSON
  /// because platforms hand strings back differently.
  Future<Object?> _eval(String body) async {
    Object? v = await _require()
        .runJavaScriptReturningResult('JSON.stringify((function(){ try { $body } catch (e) { return {error: String(e)}; } })())');
    for (var i = 0; i < 2 && v is String; i++) {
      try {
        v = jsonDecode(v);
      } catch (_) {
        break;
      }
    }
    return v;
  }

  Future<Map<String, dynamic>> open(String url, {int maxChars = 6000}) async {
    var u = url.trim();
    if (!u.contains('://')) u = 'https://$u';
    _doing('Opening ${Uri.tryParse(u)?.host ?? u}');
    try {
      final c = _ensure();
      _loading = Completer<void>();
      await c.loadRequest(Uri.parse(u));
      await _settle();
      return await read(maxChars: maxChars);
    } finally {
      _doing(null);
    }
  }

  Future<Map<String, dynamic>> back() async {
    final c = _require();
    _doing('Going back');
    try {
      if (await c.canGoBack()) {
        await c.goBack();
        await _settle();
      }
      return await read();
    } finally {
      _doing(null);
    }
  }

  /// The page as the AI sees it: address, title, readable text (from
  /// [offset], or snippets around [find]) and the usable elements, numbered.
  Future<Map<String, dynamic>> read({int offset = 0, int maxChars = 6000, String? find}) async {
    final r = await _eval(_snapshotJs);
    if (r is! Map || r['error'] != null) throw StateError('Could not read the page${r is Map ? ': ${r['error']}' : ''}.');
    final text = '${r['text'] ?? ''}';
    final out = <String, dynamic>{'url': r['url'], 'title': r['title'], if (_lastError != null) 'error': _lastError};
    if (find != null && find.trim().isNotEmpty) {
      out['matches'] = findSnippets(text, find);
    } else {
      final end = (offset + maxChars).clamp(0, text.length);
      out['text'] = offset >= text.length ? '' : text.substring(offset, end);
      if (end < text.length) out['more_text'] = 'Page text continues; pass offset=$end.';
    }
    out['elements'] = r['elements'];
    _labels = {
      for (final e in (r['elements'] as List? ?? const []).whereType<Map>())
        if (e['i'] is num) (e['i'] as num).toInt(): '${e['text'] ?? e['name'] ?? e['tag'] ?? ''}',
    };
    if (r['dialog'] != null) out['dialog'] = r['dialog'];
    return out;
  }

  Future<Map<String, dynamic>> click(int index) async {
    _doing('Clicking ${_labels[index] ?? '#$index'}');
    try {
      final r = await _eval('''
        var el = document.querySelector('[data-omni-id="$index"]');
        if (!el) return {error: 'No element $index; read the page again with browser_read.'};
        el.scrollIntoView({block: 'center'});
        var opts = {bubbles: true, cancelable: true, view: window};
        ['pointerdown', 'mousedown', 'pointerup', 'mouseup'].forEach(function (t) { el.dispatchEvent(new MouseEvent(t, opts)); });
        el.click();
        return {clicked: (el.innerText || el.value || el.getAttribute('aria-label') || el.tagName).toString().slice(0, 80)};
      ''');
      if (r is Map && r['error'] != null) return Map<String, dynamic>.from(r);
      await _settle();
      return {...?(r as Map?)?.cast<String, dynamic>(), 'page': await read(maxChars: 3000)};
    } finally {
      _doing(null);
    }
  }

  Future<Map<String, dynamic>> type(int index, String text, {bool clear = true, bool pressEnter = false}) async {
    _doing('Typing into ${_labels[index] ?? '#$index'}');
    try {
      final r = await _eval('''
        var el = document.querySelector('[data-omni-id="$index"]');
        if (!el) return {error: 'No element $index; read the page again with browser_read.'};
        el.focus();
        var value = ${jsonEncode(text)};
        if (el.isContentEditable) {
          if ($clear) el.textContent = '';
          document.execCommand('insertText', false, value);
        } else if (el.tagName === 'SELECT') {
          var opt = Array.from(el.options).find(function (o) { return o.value === value || o.text.trim() === value; });
          if (!opt) return {error: 'No option "' + value + '". Options: ' + Array.from(el.options).map(function (o) { return o.text.trim(); }).join(', ')};
          el.value = opt.value;
        } else {
          var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
          setter.call(el, ($clear ? '' : el.value) + value);
        }
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
        if ($pressEnter) {
          ['keydown', 'keypress', 'keyup'].forEach(function (t) {
            el.dispatchEvent(new KeyboardEvent(t, {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true}));
          });
          if (el.form) { if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit(); }
        }
        return {typed: true, value: (el.value || el.textContent || '').toString().slice(0, 200)};
      ''');
      if (r is Map && r['error'] != null) return Map<String, dynamic>.from(r);
      await _settle(extra: Duration(milliseconds: pressEnter ? 1500 : 400));
      return {...?(r as Map?)?.cast<String, dynamic>(), if (pressEnter) 'page': await read(maxChars: 3000)};
    } finally {
      _doing(null);
    }
  }

  /// Runs the AI's own script; the value of its last expression comes back.
  Future<Object?> evaluate(String js) async {
    _doing('Running a script');
    try {
      final v = await _eval('return eval(${jsonEncode(js)});');
      await _settle(extra: const Duration(milliseconds: 600));
      return v;
    } finally {
      _doing(null);
    }
  }

  Future<void> reload() async => _controller?.reload();

  /// Stops a page that is still loading, and any wait for one: for a stop
  /// button while the AI browses.
  Future<void> stop() async {
    if (_loading?.isCompleted == false) _loading!.complete();
    try {
      await _controller?.runJavaScript('window.stop()');
    } catch (_) {}
    _doing(null);
  }

  /// Closes the page; the view shows nothing until the next open.
  Future<void> close() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.loadRequest(Uri.parse('about:blank'));
    } catch (_) {}
    _controller = null;
    _url = null;
    _title = null;
    activity = null;
    notifyListeners();
  }

  /// Text around each place [needle] appears.
  static List<String> findSnippets(String text, String needle, {int max = 12, int context = 160}) {
    final lower = text.toLowerCase(), want = needle.toLowerCase();
    final out = <String>[];
    var at = lower.indexOf(want);
    while (at >= 0 && out.length < max) {
      final s = (at - context).clamp(0, text.length), e = (at + want.length + context).clamp(0, text.length);
      out.add('${s > 0 ? '…' : ''}${text.substring(s, e)}${e < text.length ? '…' : ''}');
      at = lower.indexOf(want, at + want.length);
    }
    return out;
  }

  /// Numbers the usable elements (links, buttons, fields) and reads the
  /// page's text, leaving out hidden elements.
  static const _snapshotJs = r'''
    var sel = 'a[href], button, input:not([type=hidden]), textarea, select, [role=button], [role=link], [role=tab], [role=menuitem], [role=checkbox], [onclick], [contenteditable=""], [contenteditable=true], summary';
    var els = Array.from(document.querySelectorAll(sel));
    var shown = function (el) {
      if (el.hidden || el.closest('[hidden],[aria-hidden=true]')) return false;
      var s = getComputedStyle(el);
      return s.display !== 'none' && s.visibility !== 'hidden';
    };
    var label = function (el) {
      var t = (el.innerText || '').trim();
      if (!t && el.labels && el.labels.length) t = el.labels[0].innerText;
      t = t || el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('title') || el.value || el.getAttribute('alt') || '';
      if (!t) { var img = el.querySelector && el.querySelector('img[alt]'); if (img) t = img.alt; }
      return String(t).replace(/\s+/g, ' ').trim().slice(0, 90);
    };
    var out = [], n = 0;
    document.querySelectorAll('[data-omni-id]').forEach(function (el) { el.removeAttribute('data-omni-id'); });
    for (var i = 0; i < els.length && out.length < 120; i++) {
      var el = els[i];
      if (!shown(el)) continue;
      el.setAttribute('data-omni-id', String(n));
      var o = {i: n, tag: el.tagName.toLowerCase()};
      var t = label(el); if (t) o.text = t;
      if (el.type && el.tagName !== 'BUTTON' && el.tagName !== 'A') o.type = el.type;
      if (el.name) o.name = el.name;
      if (el.tagName === 'A') o.href = el.href;
      if (el.tagName === 'SELECT') o.options = Array.from(el.options).slice(0, 20).map(function (x) { return x.text.trim(); });
      if ((el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') && el.value) o.value = String(el.value).slice(0, 80);
      if (el.type === 'checkbox' || el.type === 'radio') o.checked = el.checked;
      if (el.disabled || el.getAttribute('aria-disabled') === 'true') o.disabled = true;
      out.push(o); n++;
    }
    var root = document.querySelector('main, article, [role=main]') || document.body;
    var text = (root ? root.innerText : '').replace(/\n{3,}/g, '\n\n').trim();
    if (root !== document.body && text.length < 200 && document.body) text = document.body.innerText.trim();
    var dialog = document.querySelector('[role=dialog], [role=alertdialog], dialog[open]');
    return {url: location.href, title: document.title, text: text, elements: out, dialog: dialog ? dialog.innerText.trim().slice(0, 500) : null};
  ''';
}

/// Browser tools for the AI: open, read, click, type, back, run a script,
/// close. Clicking, submitting and scripts ask first by default (as in
/// teleai). Android, iOS and macOS.
class BrowserToolkit extends Toolkit {
  BrowserToolkit({BrowserSession? session, this.actionApproval = ApprovalPolicy.always}) : session = session ?? BrowserSession();

  /// The page the tools drive; show it with `BrowserView(session: …)`.
  final BrowserSession session;

  /// Approval for clicks, form submits and scripts.
  final ApprovalPolicy actionApproval;

  @override
  String get id => 'browser';
  @override
  String get name => 'Browser';
  @override
  bool get needsApiKey => false;
  @override
  bool get isConfigured => webViewSupported;
  @override
  Future<String?> verify() async => webViewSupported ? null : 'Needs Android, iOS or macOS.';

  @override
  String get instructions => 'You have a real browser (browser_open, browser_read, browser_click, browser_type…) for sites '
      'that need JavaScript, searching sites, or filling forms. The user can watch it and take over, e.g. to sign in.';

  @override
  Future<void> dispose() => session.close();

  @override
  Future<List<Tool>> tools() async => [
        Tool(
          name: 'browser_open',
          label: 'Opening a page',
          description: 'Opens a URL in the browser (scripts run, like a real phone browser) and returns its text and numbered '
              'elements (links, buttons, fields). The user can watch it live.',
          parametersJson: const {
            'type': 'object',
            'properties': {
              'url': {'type': 'string'},
              'max_chars': {'type': 'integer', 'description': 'Default 6000.'},
            },
            'required': ['url'],
          },
          execute: (i) => session.open('${i['url']}', maxChars: (i['max_chars'] as num?)?.toInt() ?? 6000),
        ),
        Tool(
          name: 'browser_read',
          label: 'Reading the page',
          description: 'Reads the open page again: more text from offset, snippets around find, and fresh element numbers.',
          parametersJson: const {
            'type': 'object',
            'properties': {
              'offset': {'type': 'integer'},
              'find': {'type': 'string', 'description': 'Words to look for on the page.'},
            },
          },
          execute: (i) => session.read(offset: (i['offset'] as num?)?.toInt() ?? 0, find: i['find'] as String?),
        ),
        Tool(
          name: 'browser_type',
          label: 'Typing',
          description: 'Types into a field by its element number (or picks a select option by its text). press_enter submits '
              'the form, e.g. a search box.',
          approval: ApprovalPolicy.when((i) => i['press_enter'] == true && actionApproval.requires(i)),
          parametersJson: const {
            'type': 'object',
            'properties': {
              'element': {'type': 'integer'},
              'text': {'type': 'string'},
              'clear': {'type': 'boolean', 'description': 'Replace what is there (default true).'},
              'press_enter': {'type': 'boolean'},
            },
            'required': ['element', 'text'],
          },
          execute: (i) =>
              session.type((i['element'] as num).toInt(), '${i['text']}', clear: i['clear'] != false, pressEnter: i['press_enter'] == true),
        ),
        Tool(
          name: 'browser_click',
          label: 'Clicking',
          approval: actionApproval,
          description: 'Clicks a link or button by its element number and returns the page after.',
          parametersJson: const {
            'type': 'object',
            'properties': {
              'element': {'type': 'integer'},
              'what': {'type': 'string', 'description': 'What it is, for the approval dialog.'},
            },
            'required': ['element'],
          },
          execute: (i) => session.click((i['element'] as num).toInt()),
        ),
        Tool(
          name: 'browser_back',
          label: 'Going back',
          description: 'Goes back to the previous page and reads it.',
          execute: (_) => session.back(),
        ),
        Tool(
          name: 'browser_run_js',
          label: 'Running a script',
          approval: actionApproval,
          description: 'Runs JavaScript in the open page and returns the value of its last expression, for what the other '
              'tools can\'t do (reading a table, scrolling, extracting data).',
          parametersJson: const {
            'type': 'object',
            'properties': {
              'code': {'type': 'string'},
            },
            'required': ['code'],
          },
          execute: (i) async => {'result': await session.evaluate('${i['code']}')},
        ),
        Tool(
          name: 'browser_close',
          label: 'Closing the browser',
          description: 'Closes the page when you are done.',
          execute: (_) async {
            await session.close();
            return {'closed': true};
          },
        ),
      ];
}
