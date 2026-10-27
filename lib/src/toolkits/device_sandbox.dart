import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../agents/toolkit.dart';
import '../core/media.dart';
import '../core/tools.dart';

/// Whether this platform has the system web view the on-device sandbox and
/// browser use (Android, iOS, macOS).
bool get webViewSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// What a run printed, returned and made.
class SandboxRun {
  const SandboxRun({required this.output, this.result, this.error, this.files = const []});
  final String output;
  final Object? result;
  final String? error;
  final List<({String name, GeneratedFile file})> files;

  Map<String, dynamic> toJson() {
    String clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}… [${s.length - n} more characters]';
    return {
      if (output.isNotEmpty) 'output': clip(output, 12000),
      if (result != null) 'result': result is String ? clip(result as String, 8000) : result,
      if (error != null) 'error': clip(error!, 4000),
      if (files.isNotEmpty) 'files': [for (final f in files) '${f.name} (${f.file.bytes.length} bytes, shown to the user)'],
    };
  }
}

/// Runs Python (Pyodide: Python compiled to WebAssembly, downloaded once,
/// with numpy, pandas, matplotlib and more loaded from imports) or
/// JavaScript in a hidden page on the device: free, no key, cut off from
/// the app. The way teleai's `run_code` works.
///
/// Files: input files are in the working directory (Python) or `files[name]`
/// as a Uint8Array (JavaScript). Python writes outputs to `out/`;
/// JavaScript sets `outFiles[name]` to a string or Uint8Array.
class DeviceSandbox {
  WebViewController? _c;
  Completer<void>? _ready;
  bool _python = false;
  final _pending = <int, Completer<Object?>>{};
  var _next = 0;

  /// Where Pyodide is downloaded from.
  static const pyodideUrl = 'https://cdn.jsdelivr.net/pyodide/v0.26.4/full/';

  bool get running => _pending.isNotEmpty;

  Future<WebViewController> _page() async {
    if (!webViewSupported) throw UnsupportedError('The on-device sandbox works on Android, iOS and macOS. Use E2B elsewhere.');
    final ready = _ready;
    if (ready != null) {
      await ready.future;
      return _c!;
    }
    final done = _ready = Completer<void>();
    final c = _c = WebViewController();
    await c.setJavaScriptMode(JavaScriptMode.unrestricted);
    await c.addJavaScriptChannel('OmniSandbox', onMessageReceived: (m) {
      try {
        final j = jsonDecode(m.message) as Map<String, dynamic>;
        final waiter = _pending.remove(j['id']);
        if (j['ok'] == true) {
          waiter?.complete(j['value']);
        } else {
          waiter?.completeError(StateError('${j['error']}'));
        }
      } catch (_) {}
    });
    await c.setNavigationDelegate(NavigationDelegate(onPageFinished: (_) {
      if (!done.isCompleted) done.complete();
    }));
    // An https origin, so the CDN serves Pyodide and its packages.
    await c.loadHtmlString('<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>',
        baseUrl: 'https://sandbox.omni-ai.app/');
    await done.future.timeout(const Duration(seconds: 15), onTimeout: () {});
    return c;
  }

  Future<Object?> _call(String body, Map<String, Object?> args, Duration timeout) async {
    final c = await _page();
    final id = ++_next;
    final waiter = _pending[id] = Completer<Object?>();
    final names = args.keys.join(', ');
    final values = args.values.map(jsonEncode).join(', ');
    await c.runJavaScript('''
      (async function ($names) { $body })($values)
        .then(function (v) { OmniSandbox.postMessage(JSON.stringify({id: $id, ok: true, value: v === undefined ? null : v})); })
        .catch(function (e) { OmniSandbox.postMessage(JSON.stringify({id: $id, ok: false, error: String(e && e.stack || e)})); });
    ''');
    try {
      return await waiter.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      await cancel();
      throw StateError('The code ran longer than ${timeout.inSeconds} s and was stopped.');
    }
  }

  /// Runs [code] (`python` or `javascript`) with [inputs] as input files.
  Future<SandboxRun> run({
    required String language,
    required String code,
    Map<String, Uint8List> inputs = const {},
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final files = {for (final e in inputs.entries) e.key: base64Encode(e.value)};
    final Object? raw;
    if (language == 'python') {
      if (!_python) {
        await _call('''
          if (!window.loadPyodide) {
            await new Promise(function (ok, fail) {
              var s = document.createElement('script');
              s.src = '${pyodideUrl}pyodide.js'; s.onload = ok;
              s.onerror = function () { fail(new Error('Could not download Python (Pyodide). Is there an internet connection?')); };
              document.head.appendChild(s);
            });
          }
          if (!window.__py) window.__py = await loadPyodide({indexURL: '$pyodideUrl'});
          return true;
        ''', const {}, const Duration(minutes: 3));
        _python = true;
      }
      raw = await _call(_pythonRunner, {'__code': code, '__files': files}, timeout);
    } else {
      raw = await _call(_jsRunner, {'__code': code, '__files': files}, timeout);
    }
    final r = raw is Map ? raw : <String, dynamic>{'result': raw};
    final made = <({String name, GeneratedFile file})>[];
    for (final f in (r['files'] as List? ?? const []).whereType<Map>()) {
      final name = '${f['name']}'.split(RegExp(r'[\\/]')).last;
      final bytes = base64Decode('${f['data']}');
      made.add((name: name, file: GeneratedFile(bytes, mediaType: _typeOf(name, bytes))));
    }
    return SandboxRun(output: '${r['stdout'] ?? ''}', result: r['result'], error: r['error'] as String?, files: made);
  }

  static String _typeOf(String name, Uint8List bytes) {
    final sniffed = sniffMediaType(bytes, fallback: '');
    if (sniffed.isNotEmpty) return sniffed;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'csv' => 'text/csv',
      'json' => 'application/json',
      'html' || 'htm' => 'text/html',
      'svg' => 'image/svg+xml',
      'md' => 'text/markdown',
      'txt' || 'log' || 'py' || 'js' => 'text/plain',
      _ => 'application/octet-stream',
    };
  }

  /// Stops whatever is running by throwing the page away. The next run
  /// starts a fresh one.
  Future<void> cancel() async {
    for (final w in _pending.values) {
      if (!w.isCompleted) w.completeError(StateError('Stopped.'));
    }
    _pending.clear();
    final c = _c;
    _c = null;
    _ready = null;
    _python = false;
    try {
      await c?.loadRequest(Uri.parse('about:blank'));
    } catch (_) {}
  }

  static const _jsRunner = r'''
    var out = [];
    var log = function () { out.push(Array.prototype.map.call(arguments, function (a) { return typeof a === 'string' ? a : JSON.stringify(a); }).join(' ')); };
    var input = {};
    for (var name in __files) { var b = atob(__files[name]); var u = new Uint8Array(b.length); for (var i = 0; i < b.length; i++) u[i] = b.charCodeAt(i); input[name] = u; }
    var outFiles = {};
    var con = {log: log, info: log, warn: log, error: log};
    var result, error;
    try {
      var AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
      result = await new AsyncFunction('files', 'outFiles', 'console', __code)(input, outFiles, con);
    } catch (e) { error = String(e && e.stack || e); }
    var made = [];
    for (var n in outFiles) {
      var v = outFiles[n];
      var bytes = typeof v === 'string' ? new TextEncoder().encode(v) : new Uint8Array(v);
      var s = ''; for (var j = 0; j < bytes.length; j++) s += String.fromCharCode(bytes[j]);
      made.push({name: n, data: btoa(s)});
    }
    try { JSON.stringify(result); } catch (e) { result = String(result); }
    return {stdout: out.join('\n'), result: result === undefined ? null : result, error: error || null, files: made};
  ''';

  static const _pythonRunner = r'''
    var py = window.__py, out = [];
    py.setStdout({batched: function (s) { out.push(s); }});
    py.setStderr({batched: function (s) { out.push(s); }});
    var home = '/home/pyodide/run_' + Date.now();
    py.FS.mkdirTree(home + '/out');
    py.FS.chdir(home);
    for (var name in __files) {
      var b = atob(__files[name]); var u = new Uint8Array(b.length); for (var i = 0; i < b.length; i++) u[i] = b.charCodeAt(i);
      py.FS.writeFile(home + '/' + name, u);
    }
    var result = null, error = null;
    try {
      await py.loadPackagesFromImports(__code);
      var v = await py.runPythonAsync(__code);
      if (v !== undefined && v !== null) result = v.toJs ? JSON.parse(JSON.stringify(v.toJs({dict_converter: Object.fromEntries}))) : (typeof v === 'object' ? String(v) : v);
    } catch (e) { error = String(e); }
    var made = [];
    var walk = function (dir, prefix) {
      py.FS.readdir(dir).forEach(function (n) {
        if (n === '.' || n === '..') return;
        var p = dir + '/' + n, st = py.FS.stat(p);
        if (py.FS.isDir(st.mode)) return walk(p, prefix + n + '_');
        var bytes = py.FS.readFile(p), s = '';
        for (var j = 0; j < bytes.length; j++) s += String.fromCharCode(bytes[j]);
        made.push({name: prefix + n, data: btoa(s)});
      });
    };
    walk(home + '/out', '');
    return {stdout: out.join('\n'), result: result, error: error, files: made};
  ''';
}

/// Runs code on the device for the AI: Python or JavaScript, free and
/// private, no key. Charts and files the code writes come back as
/// `FileOutput`. Android, iOS and macOS.
///
/// Hand the code files with [addFile] (e.g. what the user attached); the
/// model refers to them by name.
class DeviceSandboxToolkit extends Toolkit {
  DeviceSandboxToolkit({DeviceSandbox? sandbox, this.approval = ApprovalPolicy.never, this.timeout = const Duration(seconds: 90)})
      : sandbox = sandbox ?? DeviceSandbox();

  final DeviceSandbox sandbox;

  /// The code can't reach the app or its files, so it runs without asking
  /// by default.
  final ApprovalPolicy approval;
  final Duration timeout;
  final _files = <String, Uint8List>{};

  /// Makes a file available to the code by [name].
  void addFile(String name, Uint8List bytes) => _files[name] = bytes;
  void removeFile(String name) => _files.remove(name);
  Map<String, Uint8List> get files => Map.unmodifiable(_files);

  @override
  String get id => 'device_sandbox';
  @override
  String get name => 'On-device sandbox';
  @override
  bool get needsApiKey => false;
  @override
  bool get isConfigured => webViewSupported;
  @override
  Future<String?> verify() async => webViewSupported ? null : 'Needs Android, iOS or macOS.';

  @override
  String get instructions => 'run_code_on_device runs Python or JavaScript on this device: use it to calculate, analyse data, '
      'convert files and make charts instead of guessing.';

  @override
  Future<void> dispose() => sandbox.cancel();

  @override
  Future<List<Tool>> tools() async => [
        Tool(
          name: 'run_code_on_device',
          label: 'Running code',
          approval: approval,
          description: 'Runs code in a sandbox on this device, cut off from the app: Python (Pyodide: the standard library plus '
              'numpy, pandas, matplotlib, pillow and other packages loaded from imports; the first run downloads Python) or '
              'JavaScript (an async function body; return a value). Printed output and the value of the last expression '
              '(Python) or of return (JavaScript) come back. Input files: Python finds them in the working directory; '
              'JavaScript gets files["name"] as a Uint8Array. To make files, Python writes into out/ (e.g. '
              'plt.savefig("out/chart.png")) and JavaScript sets outFiles["name"]; they are shown to the user.'
              '${_files.isEmpty ? '' : ' Files available: ${_files.keys.join(', ')}.'}',
          parametersJson: const {
            'type': 'object',
            'properties': {
              'language': {
                'type': 'string',
                'enum': ['python', 'javascript'],
              },
              'code': {'type': 'string'},
              'files': {
                'type': 'array',
                'items': {'type': 'string'},
                'description': 'Names of available files to give the code.',
              },
              'text_files': {
                'type': 'object',
                'description': 'Extra input files to create: name → text content.',
              },
            },
            'required': ['code'],
          },
          execute: (i) async {
            final inputs = <String, Uint8List>{
              for (final n in (i['files'] as List? ?? const []))
                if (_files.containsKey('$n')) '$n': _files['$n']!,
              if (i['text_files'] is Map)
                for (final e in (i['text_files'] as Map).entries) '${e.key}': Uint8List.fromList(utf8.encode('${e.value}')),
            };
            final missing = [
              for (final n in (i['files'] as List? ?? const []))
                if (!_files.containsKey('$n')) '$n'
            ];
            final run = await sandbox.run(
              language: i['language'] == 'javascript' ? 'javascript' : 'python',
              code: '${i['code']}',
              inputs: inputs,
              timeout: timeout,
            );
            return ToolOutput(
              {...run.toJson(), if (missing.isNotEmpty) 'missing_files': missing},
              files: [for (final f in run.files) f.file],
            );
          },
        ),
      ];
}
