import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../agents/toolkit.dart';
import '../core/errors.dart';
import '../core/http.dart';
import '../core/media.dart';
import '../core/tools.dart';

/// A running E2B sandbox.
class E2BSandbox {
  const E2BSandbox({required this.id, required this.domain, this.envdToken, this.trafficToken, required this.template, this.startedAt});
  final String id;
  final String domain;
  final String? envdToken;
  final String? trafficToken;
  final String template;

  /// When [E2BClient.create] made it.
  final DateTime? startedAt;
}

/// A sandbox from the account's list ([E2BClient.sandboxes]).
class E2BSandboxInfo {
  const E2BSandboxInfo({required this.id, required this.template, required this.state, this.startedAt, this.endAt, this.cpus, this.memoryMb});

  factory E2BSandboxInfo.fromJson(Map s) => E2BSandboxInfo(
        id: '${s['sandboxID']}',
        template: '${s['alias'] ?? s['templateID'] ?? ''}',
        state: '${s['state'] ?? ''}',
        startedAt: DateTime.tryParse('${s['startedAt']}'),
        endAt: DateTime.tryParse('${s['endAt']}'),
        cpus: (s['cpuCount'] as num?)?.toInt(),
        memoryMb: (s['memoryMB'] as num?)?.toInt(),
      );

  final String id;
  final String template;

  /// `running` or `paused`.
  final String state;
  final DateTime? startedAt;

  /// When E2B will stop it.
  final DateTime? endAt;
  final int? cpus;
  final int? memoryMb;

  Map<String, dynamic> toJson() => {
        'id': id,
        'template': template,
        'state': state,
        if (startedAt != null) 'started': startedAt!.toIso8601String(),
        if (endAt != null) 'ends': endAt!.toIso8601String(),
        if (cpus != null) 'cpus': cpus,
        if (memoryMb != null) 'memory_mb': memoryMb,
      };
}

/// What running code produced: printed output, results (text, images,
/// HTML…) and the error, if any.
class E2BExecution {
  final stdout = StringBuffer();
  final stderr = StringBuffer();
  /// Each output (`text`, `png`, `html`, `json`…); the cell's value has
  /// `main: true`.
  final results = <Map<String, dynamic>>[];
  Map<String, dynamic>? error;

  /// The interpreter's execution number, like Jupyter's `[3]`.
  int? count;

  /// The cell's value as text, like the last line of a notebook cell.
  String? get text => results.where((r) => r['main'] == true).firstOrNull?['text'] as String?;

  /// Images the code drew (charts), decoded.
  List<GeneratedFile> get images => [
        for (final r in results)
          if (r['png'] is String)
            GeneratedFile.fromBase64(r['png'] as String, mediaType: 'image/png')
          else if (r['jpeg'] is String)
            GeneratedFile.fromBase64(r['jpeg'] as String, mediaType: 'image/jpeg'),
      ];

  /// For the model: output clipped, images replaced by a note.
  Map<String, dynamic> toJson() {
    String clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}… [${s.length - n} more characters]';
    final out = stdout.toString(), err = stderr.toString();
    final textResults = [
      for (final r in results)
        {
          for (final e in r.entries)
            if (!const {'png', 'jpeg', 'svg', 'pdf', 'main'}.contains(e.key)) e.key: e.value is String ? clip(e.value as String, 4000) : e.value
        },
    ]..removeWhere((r) => r.isEmpty);
    final pictures = images.length;
    return {
      if (out.isNotEmpty) 'stdout': clip(out, 12000),
      if (err.isNotEmpty) 'stderr': clip(err, 6000),
      if (textResults.isNotEmpty) 'results': textResults,
      if (pictures > 0) 'images': '$pictures image${pictures == 1 ? '' : 's'} shown to the user.',
      if (error != null) 'error': error,
    };
  }
}

/// E2B cloud sandboxes: Linux VMs that run Python, JavaScript, bash, R and
/// Java, through E2B's REST API and the sandbox's code-interpreter server.
/// Get a key at https://e2b.dev/dashboard?tab=keys.
class E2BClient {
  E2BClient({this.apiKey, http.Client? httpClient})
      : _net = AiHttp(provider: 'E2B', client: httpClient);

  static const api = 'https://api.e2b.app';
  static const defaultTemplate = 'code-interpreter-v1';
  static const languages = ['python', 'javascript', 'bash', 'r', 'java'];
  static const _port = 49999;

  String? apiKey;
  final AiHttp _net;

  Map<String, String> get _headers => {'X-API-KEY': apiKey?.trim() ?? ''};

  Future<E2BSandbox> create(
      {String template = defaultTemplate, Duration timeout = const Duration(minutes: 10), bool internet = true}) async {
    final j = _net.json(await _net.post(Uri.parse('$api/v2/sandboxes'), headers: _headers, json: {
      'templateID': template.trim().isEmpty ? defaultTemplate : template.trim(),
      'timeout': timeout.inSeconds.clamp(30, 3600),
      'allow_internet_access': internet,
      'metadata': {'app': 'omni_ai'},
    }));
    if (j is! Map || j['sandboxID'] == null) throw const AiException('E2B did not return a sandbox.', provider: 'e2b');
    final domain = '${j['domain'] ?? ''}';
    return E2BSandbox(
      id: '${j['sandboxID']}',
      domain: domain.isEmpty || domain == 'null' ? 'e2b.app' : domain,
      envdToken: j['envdAccessToken'] as String?,
      trafficToken: j['trafficAccessToken'] as String?,
      template: '${j['templateID'] ?? template}',
      startedAt: DateTime.now(),
    );
  }

  Future<void> keepAlive(String sandboxId, Duration timeout) async => _net.ensureOk(await _net
      .post(Uri.parse('$api/sandboxes/$sandboxId/timeout'), headers: _headers, json: {'timeout': timeout.inSeconds.clamp(30, 3600)}));

  /// Stops a sandbox. One that is already gone counts as stopped.
  Future<void> kill(String sandboxId) async {
    final r = await _net.delete(Uri.parse('$api/sandboxes/$sandboxId'), headers: _headers, timeout: const Duration(seconds: 20));
    if (r.statusCode != 404) _net.ensureOk(r);
  }

  /// Sandboxes running on the account, as E2B lists them.
  Future<List<Map<String, dynamic>>> list() async {
    final j = _net.json(await _net.get(Uri.parse('$api/v2/sandboxes?limit=50'), headers: _headers));
    return [for (final s in (j is List ? j : const []).whereType<Map>()) Map<String, dynamic>.from(s)];
  }

  /// Sandboxes running on the account.
  Future<List<E2BSandboxInfo>> sandboxes() async => [for (final s in await list()) E2BSandboxInfo.fromJson(s)];

  /// Runs [code]; [onOutput] sees printed lines as they come.
  Future<E2BExecution> run(
    E2BSandbox s,
    String code, {
    String language = 'python',
    Duration timeout = const Duration(minutes: 2),
    void Function(String text, {required bool error})? onOutput,
  }) async {
    final req = http.Request('POST', Uri.parse('https://$_port-${s.id}.${s.domain}/execute'))
      ..headers.addAll({
        'Content-Type': 'application/json',
        'E2b-Sandbox-Id': s.id,
        'E2b-Sandbox-Port': '$_port',
        if (s.trafficToken != null) 'E2B-Traffic-Access-Token': s.trafficToken!,
        if (s.envdToken != null) 'X-Access-Token': s.envdToken!,
      })
      ..body = jsonEncode({'code': code, if (language != 'python') 'language': language});
    final ex = E2BExecution();
    try {
      await for (final line in _net.lines(req, idleTimeout: timeout)) {
        if (line.trim().isEmpty) continue;
        final Map msg;
        try {
          msg = jsonDecode(line) as Map;
        } catch (_) {
          continue;
        }
        switch (msg['type']) {
          case 'stdout':
            ex.stdout.write('${msg['text'] ?? ''}');
            onOutput?.call('${msg['text'] ?? ''}', error: false);
          case 'stderr':
            ex.stderr.write('${msg['text'] ?? ''}');
            onOutput?.call('${msg['text'] ?? ''}', error: true);
          case 'result':
            ex.results.add({
              for (final e in msg.entries)
                if (e.key != 'type' && e.key != 'is_main_result') '${e.key}': e.value,
              if (msg['is_main_result'] == true) 'main': true,
            });
          case 'error':
            ex.error = {'name': msg['name'], 'value': msg['value'], 'traceback': msg['traceback']};
          case 'number_of_executions':
            ex.count = (msg['execution_count'] as num?)?.toInt();
        }
      }
    } on AiException catch (e) {
      if (e.statusCode == 502 || e.statusCode == 404) throw const SandboxGoneException();
      if (e.message.contains('stopped answering')) {
        ex.error = {'name': 'TimeoutError', 'value': 'Took longer than ${timeout.inSeconds} s and was cut off.'};
      } else {
        rethrow;
      }
    }
    return ex;
  }

  static const _mark = '__OMNI__';

  Future<Map<String, dynamic>> _py(E2BSandbox s, String body) async {
    final ex = await run(s, 'import json, base64, os\n$body');
    if (ex.error != null) throw AiException('${ex.error!['name']}: ${ex.error!['value']}', provider: 'e2b');
    final out = ex.stdout.toString();
    final i = out.indexOf(_mark);
    if (i < 0) throw const AiException('The sandbox gave no answer.', provider: 'e2b');
    return Map<String, dynamic>.from(jsonDecode(out.substring(i + _mark.length).trim()) as Map);
  }

  Future<void> writeFile(E2BSandbox s, String path, Uint8List bytes) => _py(s, '''
p = ${jsonEncode(path)}
os.makedirs(os.path.dirname(os.path.abspath(p)), exist_ok=True)
with open(p, "wb") as f: f.write(base64.b64decode(${jsonEncode(base64Encode(bytes))}))
print("$_mark" + json.dumps({"ok": True}))
''');

  Future<Uint8List> readFile(E2BSandbox s, String path, {int maxBytes = 15 << 20}) async {
    final j = await _py(s, '''
p = ${jsonEncode(path)}
n = os.path.getsize(p)
if n > $maxBytes: raise ValueError(f"{p} is {n} bytes; the limit is $maxBytes")
print("$_mark" + json.dumps({"b64": base64.b64encode(open(p, "rb").read()).decode()}))
''');
    return base64Decode('${j['b64']}');
  }

  Future<List<Map<String, dynamic>>> listFiles(E2BSandbox s, String path) async {
    final j = await _py(s, '''
p = ${jsonEncode(path)}
import time
out = [{"name": e.name, "path": os.path.join(p, e.name), "dir": e.is_dir(), "size": e.stat().st_size, "modified": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(e.stat().st_mtime))} for e in sorted(os.scandir(p), key=lambda e: (not e.is_dir(), e.name))[:300]]
print("$_mark" + json.dumps({"files": out}))
''');
    return [for (final f in (j['files'] as List? ?? const [])) Map<String, dynamic>.from(f as Map)];
  }

  /// Runs a shell command and returns its exit code and output.
  Future<Map<String, dynamic>> command(E2BSandbox s, String cmd,
          {String cwd = '/home/user', Duration timeout = const Duration(minutes: 2)}) =>
      _py(s, '''
import subprocess
p = subprocess.run(${jsonEncode(cmd)}, shell=True, capture_output=True, text=True, cwd=${jsonEncode(cwd)}, timeout=${timeout.inSeconds})
print("$_mark" + json.dumps({"exit_code": p.returncode, "stdout": p.stdout[-12000:], "stderr": p.stderr[-6000:]}))
''');
}

/// The sandbox stopped (timed out or was killed).
class SandboxGoneException extends AiException {
  const SandboxGoneException() : super('The sandbox has stopped.', provider: 'e2b');
}

/// A cloud computer for agents: run code, shell commands, and work with
/// files in an E2B sandbox that keeps its state between calls.
class E2BToolkit extends Toolkit {
  E2BToolkit(
      {String? apiKey,
      this.template = E2BClient.defaultTemplate,
      this.sandboxTimeout = const Duration(minutes: 15),
      this.approval = ApprovalPolicy.never,
      http.Client? httpClient})
      : client = E2BClient(apiKey: apiKey, httpClient: httpClient);

  final E2BClient client;

  /// The sandbox image; `code-interpreter-v1` has Python with pandas,
  /// numpy, matplotlib and more, plus JS, bash, R and Java kernels.
  final String template;

  /// How long an idle sandbox lives.
  final Duration sandboxTimeout;

  /// Whether running code needs a person's yes. Sandboxes are isolated from
  /// the device, so the default is not to ask.
  final ApprovalPolicy approval;

  E2BSandbox? _sandbox;
  Future<E2BSandbox>? _starting;

  String? get apiKey => client.apiKey;
  set apiKey(String? v) => client.apiKey = v;

  /// The current sandbox, if one is running.
  E2BSandbox? get sandbox => _sandbox;

  @override
  String get id => 'e2b';
  @override
  String get name => 'E2B sandbox';
  @override
  String get apiKeyUrl => 'https://e2b.dev/dashboard?tab=keys';
  @override
  bool get isConfigured => apiKey?.trim().isNotEmpty ?? false;

  @override
  String get instructions =>
      'You have a Linux sandbox (run_code, run_command, sandbox files). Use it to compute, analyze data, make charts '
      '(matplotlib plt.show()), and test code instead of guessing. State persists between calls.';

  @override
  Future<String?> verify() async {
    try {
      requireKey(this, apiKey);
      await client.list();
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// The sandbox, started on first use and restarted if it stopped.
  Future<E2BSandbox> open() async {
    requireKey(this, apiKey);
    if (_sandbox != null) return _sandbox!;
    return _starting ??= client.create(template: template, timeout: sandboxTimeout).then((s) {
      _sandbox = s;
      _starting = null;
      return s;
    }, onError: (Object e) {
      _starting = null;
      throw e;
    });
  }

  /// Runs [f] in the sandbox, starting a fresh one once if it had stopped.
  Future<T> withSandbox<T>(Future<T> Function(E2BSandbox s) f) async {
    try {
      return await f(await open());
    } on SandboxGoneException {
      _sandbox = null;
      return f(await open());
    }
  }

  @override
  Future<void> dispose() async {
    final s = _sandbox;
    _sandbox = null;
    if (s != null) await client.kill(s.id).catchError((_) {});
  }

  @override
  Future<List<Tool>> tools() async => [
        Tool(
          name: 'run_code',
          label: 'Running code',
          approval: approval,
          description: 'Runs code in a cloud Linux sandbox and returns printed output, the last expression\'s value and '
              'errors. Python (default) has numpy, pandas, matplotlib, scipy, requests; `!pip install x` works. Charts '
              '(plt.show()) are shown to the user. Variables and files persist between calls.',
          parameters: Schema.object({
            'code': Schema.string(),
            'language': Schema.enumOf(E2BClient.languages),
          }, required: [
            'code'
          ]),
          execute: (i) async {
            final language = E2BClient.languages.contains(i['language']) ? i['language'] as String : 'python';
            final ex = await withSandbox((s) => client.run(s, '${i['code']}', language: language));
            return ToolOutput(ex.toJson(), files: ex.images);
          },
        ),
        Tool(
          name: 'run_command',
          label: 'Running a command',
          approval: approval,
          description: 'Runs a shell command in the sandbox (bash) and returns exit code, stdout and stderr.',
          parameters: Schema.object({
            'command': Schema.string(),
            'cwd': Schema.string(description: 'Working directory. Default /home/user.'),
          }, required: [
            'command'
          ]),
          execute: (i) => withSandbox((s) => client.command(s, '${i['command']}', cwd: '${i['cwd'] ?? '/home/user'}')),
        ),
        Tool(
          name: 'sandbox_write_file',
          label: 'Writing a file',
          description: 'Writes a text file in the sandbox.',
          parameters: Schema.object({'path': Schema.string(), 'content': Schema.string()}),
          execute: (i) async {
            await withSandbox((s) => client.writeFile(s, '${i['path']}', Uint8List.fromList(utf8.encode('${i['content']}'))));
            return {'written': i['path']};
          },
        ),
        Tool(
          name: 'sandbox_read_file',
          label: 'Reading a file',
          description: 'Reads a file from the sandbox. Text comes back as text; images are shown to the user.',
          parameters: Schema.object({'path': Schema.string()}),
          execute: (i) async {
            final bytes = await withSandbox((s) => client.readFile(s, '${i['path']}'));
            final type = sniffMediaType(bytes, fallback: 'text/plain');
            if (type.startsWith('image/')) {
              return ToolOutput({'path': i['path'], 'image': 'shown to the user', 'bytes': bytes.length},
                  files: [GeneratedFile(bytes, mediaType: type)]);
            }
            if (type != 'text/plain') return {'path': i['path'], 'media_type': type, 'bytes': bytes.length};
            final text = utf8.decode(bytes, allowMalformed: true);
            return {'path': i['path'], 'text': text.length > 20000 ? '${text.substring(0, 20000)}…' : text};
          },
        ),
        Tool(
          name: 'sandbox_list_files',
          label: 'Listing files',
          description: 'Lists a folder in the sandbox.',
          parameters: Schema.object({'path': Schema.string(description: 'Default /home/user.')}, required: []),
          execute: (i) async => {
            'files': await withSandbox((s) => client.listFiles(s, '${i['path'] ?? '/home/user'}')),
          },
        ),
      ];
}
