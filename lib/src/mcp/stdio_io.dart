import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/cancel.dart';
import '../core/errors.dart';
import 'mcp.dart';

/// Local MCP server over stdin/stdout (newline-delimited JSON-RPC).
class StdioMcpSession extends McpJsonRpcSession {
  StdioMcpSession(this.server);

  final McpServer server;
  Process? _process;
  int _id = 0;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  StreamSubscription<String>? _sub;
  bool _started = false;

  Future<void> _ensure() async {
    if (_started) return;
    _started = true;
    final command = server.command;
    if (command == null || command.isEmpty) throw const McpException('This MCP server has no command.');
    _process = await Process.start(
      command,
      server.args,
      environment: {...Platform.environment, ...server.env},
      runInShell: Platform.isWindows,
    );
    _sub = _process!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine, onError: (_) {});
    _process!.stderr.transform(utf8.decoder).listen((_) {}, onError: (_) {});
    _process!.exitCode.then((code) {
      for (final c in _pending.values) {
        if (!c.isCompleted) c.completeError(McpException('MCP process exited ($code).'));
      }
      _pending.clear();
    });
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    Map j;
    try {
      j = jsonDecode(line) as Map;
    } catch (_) {
      return;
    }
    if (j['id'] == null) return;
    final id = j['id'] is int ? j['id'] as int : int.tryParse('${j['id']}');
    final c = id == null ? null : _pending.remove(id);
    if (c == null || c.isCompleted) return;
    if (j['error'] != null) {
      final e = j['error'];
      c.completeError(McpException(
        e is Map ? '${e['message'] ?? e}' : '$e',
        code: e is Map ? (e['code'] as num?)?.toInt() : null,
        body: jsonEncode(e),
      ));
    } else {
      final result = j['result'];
      c.complete(result is Map ? Map<String, dynamic>.from(result) : {'value': result});
    }
  }

  @override
  Future<Map<String, dynamic>> rpc(String method, [Map<String, dynamic>? params, CancelToken? cancelToken]) async {
    await _ensure();
    if (cancelToken?.isCancelled ?? false) throw const AiCancelledException();
    final id = ++_id;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    final payload = jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': requestParams(params)});
    _process!.stdin.writeln(payload);
    final remove = cancelToken?.onCancel(() {
      if (!c.isCompleted) {
        _pending.remove(id);
        c.completeError(const AiCancelledException());
      }
    });
    try {
      return await c.future.timeout(const Duration(seconds: 45));
    } finally {
      remove?.call();
      _pending.remove(id);
    }
  }

  @override
  Future<void> notify(String method, [Map<String, dynamic>? params]) async {
    await _ensure();
    _process!.stdin.writeln(jsonEncode({'jsonrpc': '2.0', 'method': method, if (params != null) 'params': params}));
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(const McpException('MCP client closed.'));
    }
    _pending.clear();
    _process?.kill();
    _process = null;
  }
}
