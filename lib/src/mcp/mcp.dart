import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../agents/toolkit.dart';
import '../core/cancel.dart';
import '../core/errors.dart';
import '../core/http.dart';
import '../core/tools.dart';
import '../keys/key_store.dart';
import 'stdio.dart';

/// How an MCP server is reached. HTTP is the portable default (AI SDK
/// `createMCPClient({ transport: { type: 'http' } })`). SSE is the older
/// HTTP transport. Stdio is local processes on desktop.
enum McpTransportKind { http, sse, stdio }

/// A saved MCP server: install it, then list and call its tools.
///
/// HTTP:
/// ```dart
/// McpServer.http('linear', url: 'https://mcp.linear.app/mcp', headers: {'Authorization': 'Bearer …'})
/// ```
///
/// Stdio (desktop):
/// ```dart
/// McpServer.stdio('github', command: 'npx', args: ['-y', '@modelcontextprotocol/server-github'])
/// ```
class McpServer {
  McpServer({
    required this.id,
    this.transport = McpTransportKind.http,
    this.url,
    this.headers = const {},
    this.command,
    this.args = const [],
    this.env = const {},
    this.approval = ApprovalPolicy.never,
    this.protocolVersionDiscovery = true,
  }) : assert(RegExp(r'^[A-Za-z0-9][A-Za-z0-9_\-]{0,47}$').hasMatch(id), 'MCP server ids use letters, digits, _ and -.');

  factory McpServer.http(String id,
          {required String url, Map<String, String> headers = const {}, ApprovalPolicy approval = ApprovalPolicy.never}) =>
      McpServer(id: id, transport: McpTransportKind.http, url: url, headers: headers, approval: approval);

  factory McpServer.sse(String id,
          {required String url, Map<String, String> headers = const {}, ApprovalPolicy approval = ApprovalPolicy.never}) =>
      McpServer(id: id, transport: McpTransportKind.sse, url: url, headers: headers, approval: approval);

  factory McpServer.stdio(String id,
          {required String command,
          List<String> args = const [],
          Map<String, String> env = const {},
          ApprovalPolicy approval = ApprovalPolicy.never}) =>
      McpServer(id: id, transport: McpTransportKind.stdio, command: command, args: args, env: env, approval: approval);

  factory McpServer.fromJson(Map j) => McpServer(
        id: '${j['id']}',
        transport: McpTransportKind.values.firstWhere(
          (k) => k.name == '${j['transport'] ?? 'http'}',
          orElse: () => McpTransportKind.http,
        ),
        url: j['url'] as String?,
        headers: {
          if (j['headers'] is Map)
            for (final e in (j['headers'] as Map).entries) '${e.key}': '${e.value}'
        },
        command: j['command'] as String?,
        args: [for (final a in (j['args'] as List? ?? const [])) '$a'],
        env: {
          if (j['env'] is Map)
            for (final e in (j['env'] as Map).entries) '${e.key}': '${e.value}'
        },
        approval: '${j['approval']}' == 'always' ? ApprovalPolicy.always : ApprovalPolicy.never,
        protocolVersionDiscovery: j['protocolVersionDiscovery'] != false,
      );

  /// Short id used as a toolkit id (`mcp_<id>`) and a tool-name prefix.
  final String id;
  final McpTransportKind transport;

  /// HTTP or SSE endpoint.
  final String? url;
  final Map<String, String> headers;

  /// Stdio process.
  final String? command;
  final List<String> args;
  final Map<String, String> env;

  /// Applied to every tool this server exposes.
  final ApprovalPolicy approval;

  /// Probe modern stateless MCP before falling back to the legacy handshake.
  /// Disable for endpoints that require `initialize` as their first request.
  final bool protocolVersionDiscovery;

  Map<String, dynamic> toJson() => {
        'id': id,
        'transport': transport.name,
        if (url != null) 'url': url,
        if (headers.isNotEmpty) 'headers': headers,
        if (command != null) 'command': command,
        if (args.isNotEmpty) 'args': args,
        if (env.isNotEmpty) 'env': env,
        if (approval.kind != 'never') 'approval': approval.kind,
        if (!protocolVersionDiscovery) 'protocolVersionDiscovery': false,
      };
}

/// A tool advertised by an MCP server.
class McpToolInfo {
  const McpToolInfo({required this.name, this.description = '', this.inputSchema = const {'type': 'object'}, this.raw = const {}});

  factory McpToolInfo.fromJson(Map j) => McpToolInfo(
        name: '${j['name']}',
        description: '${j['description'] ?? ''}',
        inputSchema: j['inputSchema'] is Map ? Map<String, dynamic>.from(j['inputSchema'] as Map) : const {'type': 'object'},
        raw: Map<String, dynamic>.from(j),
      );

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final Map<String, dynamic> raw;
}

/// A resource advertised by an MCP server.
class McpResource {
  const McpResource({required this.uri, this.name, this.description, this.mimeType});

  factory McpResource.fromJson(Map j) => McpResource(
        uri: '${j['uri']}',
        name: j['name'] as String?,
        description: j['description'] as String?,
        mimeType: j['mimeType'] as String?,
      );

  final String uri;
  final String? name;
  final String? description;
  final String? mimeType;
}

/// A prompt template advertised by an MCP server.
class McpPrompt {
  const McpPrompt({required this.name, this.description, this.arguments = const []});

  factory McpPrompt.fromJson(Map j) => McpPrompt(
        name: '${j['name']}',
        description: j['description'] as String?,
        arguments: [
          for (final a in (j['arguments'] as List? ?? const []))
            if (a is Map) Map<String, dynamic>.from(a)
        ],
      );

  final String name;
  final String? description;
  final List<Map<String, dynamic>> arguments;
}

class McpException extends AiException {
  const McpException(super.message, {this.code, super.body, super.statusCode}) : super(provider: 'mcp');
  final int? code;
}

/// Lightweight MCP client, modelled on Vercel AI SDK `createMCPClient`.
/// Connects, lists tools/resources/prompts, and turns tools into [Tool]s
/// for `generateText` / agents.
///
/// ```dart
/// final mcp = await createMcpClient(McpServer.http('docs', url: 'https://mcp.example.com/mcp'));
/// final tools = await mcp.tools();
/// await generateText(model: …, tools: tools, prompt: '…');
/// await mcp.close();
/// ```
class McpClient {
  McpClient._(this.server, this._session);

  final McpServer server;
  final McpJsonRpcSession _session;

  /// Server info from `initialize`.
  String get serverName => _session.serverName;
  String get protocolVersion => _session.protocolVersion;
  Map<String, dynamic> get capabilities => _session.capabilities;

  /// Lists tools (paginated under the hood).
  Future<List<McpToolInfo>> listTools({CancelToken? cancelToken}) => _session.listTools(cancelToken: cancelToken);

  /// Runs a tool. Returns JSON the model can read (text joined, or structured content).
  Future<Object?> callTool(String name, Map<String, dynamic> arguments, {CancelToken? cancelToken}) =>
      _session.callTool(name, arguments, cancelToken: cancelToken);

  Future<List<McpResource>> listResources({CancelToken? cancelToken}) => _session.listResources(cancelToken: cancelToken);

  Future<Object?> readResource(String uri, {CancelToken? cancelToken}) => _session.readResource(uri, cancelToken: cancelToken);

  Future<List<McpPrompt>> listPrompts({CancelToken? cancelToken}) => _session.listPrompts(cancelToken: cancelToken);

  Future<Object?> getPrompt(String name, {Map<String, dynamic> arguments = const {}, CancelToken? cancelToken}) =>
      _session.getPrompt(name, arguments: arguments, cancelToken: cancelToken);

  /// MCP tools as omni_ai [Tool]s. [prefix] is prepended to names (`linear_`)
  /// so several servers can sit in one tool list.
  Future<List<Tool>> tools({String? prefix, ApprovalPolicy? approval, CancelToken? cancelToken}) async {
    final p = prefix ?? '';
    final policy = approval ?? server.approval;
    return [
      for (final t in await listTools(cancelToken: cancelToken))
        Tool(
          name: '$p${t.name}',
          label: t.name.replaceAll('_', ' '),
          description: t.description.isEmpty ? 'MCP tool ${t.name} from ${server.id}.' : t.description,
          parametersJson: t.inputSchema,
          approval: policy,
          execute: (i) => callTool(t.name, i, cancelToken: ToolContext.current?.cancelToken),
        ),
    ];
  }

  Future<void> close() => _session.close();
}

/// Connects to [server] (initialize handshake) and returns a client.
Future<McpClient> createMcpClient(McpServer server, {http.Client? httpClient, Duration timeout = const Duration(seconds: 45)}) async {
  final session = switch (server.transport) {
    McpTransportKind.stdio => StdioMcpSession(server),
    McpTransportKind.sse => HttpMcpSession(server, sse: true, httpClient: httpClient, timeout: timeout),
    McpTransportKind.http => HttpMcpSession(server, sse: false, httpClient: httpClient, timeout: timeout),
  };
  try {
    await session.initialize(discovery: server.protocolVersionDiscovery).timeout(timeout);
  } catch (_) {
    await session.close();
    rethrow;
  }
  return McpClient._(server, session);
}

/// JSON-RPC session used by HTTP, SSE and stdio.
abstract class McpJsonRpcSession {
  String serverName = '';
  String protocolVersion = '2025-03-26';
  Map<String, dynamic> capabilities = const {};

  Future<Map<String, dynamic>> rpc(String method, [Map<String, dynamic>? params, CancelToken? cancelToken]);
  Future<void> notify(String method, [Map<String, dynamic>? params]);

  bool get isModern => protocolVersion == '2026-07-28';

  Map<String, dynamic> requestParams(Map<String, dynamic>? params) => {
        ...?params,
        if (isModern)
          '_meta': {
            ...?params?['_meta'] as Map?,
            'io.modelcontextprotocol/protocolVersion': protocolVersion,
            'io.modelcontextprotocol/clientInfo': {'name': 'omni_ai', 'version': '0.6.0'},
            'io.modelcontextprotocol/clientCapabilities': <String, dynamic>{},
          },
      };

  Future<void> initialize({bool discovery = true}) async {
    if (discovery) {
      protocolVersion = '2026-07-28';
      Map<String, dynamic>? discovered;
      try {
        discovered = await rpc('server/discover', {});
      } on McpException catch (e) {
        // Older servers reject the probe as an unknown method, or as an
        // unsupported protocol version while listing the ones they speak.
        if (e.code != -32601 && e.code != -32600 && !_offersLegacyVersion(e)) rethrow;
      } on AiCancelledException {
        rethrow;
      } on AiException catch (e) {
        if (![400, 404, 405].contains(e.statusCode)) rethrow;
      }
      final versions = discovered?['supportedVersions'] ?? discovered?['protocolVersions'];
      if (versions is List && versions.contains('2026-07-28')) {
        _serverInfo(discovered!);
        return;
      }
    }
    protocolVersion = '2025-03-26';
    final r = await rpc('initialize', {
      'protocolVersion': '2025-03-26',
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'omni_ai', 'version': '0.6.0'},
    });
    protocolVersion = '${r['protocolVersion'] ?? protocolVersion}';
    _serverInfo(r);
    await notify('notifications/initialized');
  }

  /// Versions `initialize` can negotiate.
  static const legacyVersions = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

  /// Whether a rejected probe names a pre-2026 version the server supports,
  /// in the error's data (`supported`) or its message.
  static bool _offersLegacyVersion(McpException e) {
    final listed = <String>{};
    final body = e.body;
    if (body != null) {
      try {
        final data = (jsonDecode(body) as Map?)?['data'];
        final versions = data is Map ? (data['supported'] ?? data['supportedVersions']) : null;
        if (versions is List) listed.addAll(versions.map((v) => '$v'));
      } catch (_) {/* Not JSON; the message may still list them. */}
    }
    listed.addAll(RegExp(r'\d{4}-\d{2}-\d{2}').allMatches(e.message).map((m) => m[0]!));
    return listed.any(legacyVersions.contains);
  }

  void _serverInfo(Map<String, dynamic> r) {
    capabilities = r['capabilities'] is Map ? Map<String, dynamic>.from(r['capabilities'] as Map) : const {};
    final info = r['serverInfo'] ?? (r['_meta'] as Map?)?['io.modelcontextprotocol/serverInfo'];
    serverName = info is Map ? '${info['name'] ?? ''}' : '';
  }

  Future<List<McpToolInfo>> listTools({CancelToken? cancelToken}) => _paginate(
        'tools/list',
        'tools',
        (m) => McpToolInfo.fromJson(m),
        cancelToken: cancelToken,
      );

  Future<Object?> callTool(String name, Map<String, dynamic> arguments, {CancelToken? cancelToken}) async {
    final r = await rpc('tools/call', {'name': name, 'arguments': arguments}, cancelToken);
    if (r['isError'] == true) {
      throw McpException(_contentText(r['content']) ?? 'MCP tool "$name" failed.', body: jsonEncode(r));
    }
    return _toolResult(r);
  }

  Future<List<McpResource>> listResources({CancelToken? cancelToken}) => _paginate(
        'resources/list',
        'resources',
        (m) => McpResource.fromJson(m),
        cancelToken: cancelToken,
      );

  Future<Object?> readResource(String uri, {CancelToken? cancelToken}) async {
    final r = await rpc('resources/read', {'uri': uri}, cancelToken);
    return r['contents'] ?? r;
  }

  Future<List<McpPrompt>> listPrompts({CancelToken? cancelToken}) => _paginate(
        'prompts/list',
        'prompts',
        (m) => McpPrompt.fromJson(m),
        cancelToken: cancelToken,
      );

  Future<Object?> getPrompt(String name, {Map<String, dynamic> arguments = const {}, CancelToken? cancelToken}) =>
      rpc('prompts/get', {'name': name, if (arguments.isNotEmpty) 'arguments': arguments}, cancelToken);

  Future<List<T>> _paginate<T>(String method, String key, T Function(Map) parse, {CancelToken? cancelToken}) async {
    final out = <T>[];
    String? cursor;
    do {
      final r = await rpc(method, {if (cursor != null) 'cursor': cursor}, cancelToken);
      for (final x in (r[key] as List? ?? const [])) {
        if (x is Map) out.add(parse(x));
      }
      cursor = r['nextCursor'] as String?;
    } while (cursor != null && cursor.isNotEmpty);
    return out;
  }

  Future<void> close() async {}
}

Object? _toolResult(Map r) {
  if (r['resultType'] != null && r['resultType'] != 'complete') {
    throw McpException('MCP tool requires further interaction (${r['resultType']}).', body: jsonEncode(r));
  }
  if (r['structuredContent'] != null) return r['structuredContent'];
  final text = _contentText(r['content']);
  if (text == null) return r;
  try {
    return jsonDecode(text);
  } catch (_) {
    return {'text': text};
  }
}

String? _contentText(Object? content) {
  if (content is String) return content;
  if (content is! List) return null;
  final parts = <String>[];
  for (final c in content) {
    if (c is Map && (c['type'] == 'text' || c['text'] != null)) {
      parts.add('${c['text'] ?? ''}');
    } else if (c is Map) {
      parts.add(jsonEncode(c));
    }
  }
  return parts.isEmpty ? null : parts.join('\n');
}

/// Streamable HTTP and SSE MCP transport.
class HttpMcpSession extends McpJsonRpcSession {
  HttpMcpSession(this.server, {required this.sse, http.Client? httpClient, this.timeout = const Duration(seconds: 45)})
      : _owns = httpClient == null,
        _http = httpClient ?? http.Client(),
        _net = AiHttp(provider: 'MCP', client: httpClient);

  final McpServer server;
  final bool sse;
  final Duration timeout;
  final bool _owns;
  final http.Client _http;
  final AiHttp _net;
  int _id = 0;
  String? _sessionId;
  String? _endpoint;
  final _endpointReady = Completer<void>();
  StreamSubscription<String>? _sseSub;
  final _pending = <int, Completer<Map<String, dynamic>>>{};

  Uri get _url {
    final raw = _endpoint ?? server.url;
    if (raw == null || raw.isEmpty) throw const McpException('This MCP server has no URL.');
    return Uri.parse(raw);
  }

  Map<String, String> get _headers => {
        'Accept': 'application/json, text/event-stream',
        'Content-Type': 'application/json',
        if (_sessionId != null && !isModern) 'Mcp-Session-Id': _sessionId!,
        if (protocolVersion.isNotEmpty) 'MCP-Protocol-Version': protocolVersion,
        ...server.headers,
      };

  @override
  Future<void> initialize({bool discovery = true}) async {
    if (sse) await _openSse();
    await super.initialize(discovery: discovery && !sse);
  }

  Future<void> _openSse() async {
    final url = Uri.parse(server.url ?? '');
    final req = http.Request('GET', url)
      ..headers.addAll({
        'Accept': 'text/event-stream',
        ...server.headers,
      });
    final res = await _http.send(req).timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw McpException('MCP SSE answered ${res.statusCode}.', body: await res.stream.bytesToString());
    }
    _sessionId = res.headers['mcp-session-id'] ?? _sessionId;
    _sseSub = sseData(res.stream.transform(utf8.decoder).transform(const LineSplitter())).listen(_onSsePayload, onError: (_) {});
    await _endpointReady.future.timeout(timeout);
  }

  void _onSsePayload(String data) {
    Map? j;
    try {
      j = jsonDecode(data) as Map?;
    } catch (_) {
      if (data.startsWith('/') || data.startsWith('http')) {
        final base = Uri.parse(server.url ?? '');
        _endpoint = data.startsWith('http') ? data : base.resolve(data).toString();
        if (Uri.parse(_endpoint!).origin != base.origin) {
          if (!_endpointReady.isCompleted) _endpointReady.completeError(const McpException('MCP SSE endpoint must use the server origin.'));
          return;
        }
        if (!_endpointReady.isCompleted) _endpointReady.complete();
      }
      return;
    }
    if (j == null) return;
    if (j['method'] == null && j['id'] != null) {
      final id = j['id'] is int ? j['id'] as int : int.tryParse('${j['id']}');
      final c = id == null ? null : _pending.remove(id);
      if (c == null || c.isCompleted) return;
      if (j['error'] != null) {
        c.completeError(_rpcError(j['error']));
      } else {
        c.complete(j['result'] is Map ? Map<String, dynamic>.from(j['result'] as Map) : {'value': j['result']});
      }
    }
  }

  @override
  Future<Map<String, dynamic>> rpc(String method, [Map<String, dynamic>? params, CancelToken? cancelToken]) async {
    final id = ++_id;
    final payload = {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': requestParams(params)};
    if (sse) {
      final c = Completer<Map<String, dynamic>>();
      _pending[id] = c;
      final r = await _net.post(_url, headers: _headers, json: payload, timeout: timeout, cancelToken: cancelToken);
      _sessionId = r.headers['mcp-session-id'] ?? _sessionId;
      if (r.statusCode >= 400) {
        _pending.remove(id);
        throw _net.apiError(r.statusCode, utf8.decode(r.bodyBytes, allowMalformed: true));
      }
      return c.future.timeout(timeout, onTimeout: () {
        _pending.remove(id);
        throw McpException('MCP "$method" timed out.');
      });
    }
    final req = http.Request('POST', _url)
      ..followRedirects = false
      ..headers.addAll({
        ..._headers,
        if (isModern) 'Mcp-Method': method,
        if (isModern && params?['name'] is String) 'Mcp-Name': params!['name'] as String
      })
      ..body = jsonEncode(payload);
    if (cancelToken?.isCancelled ?? false) throw const AiCancelledException();
    final r = await _http.send(req).timeout(timeout);
    if ([301, 302, 303, 307, 308].contains(r.statusCode)) {
      await r.stream.take(0).drain<void>();
      final location = r.headers['location'];
      final target = location == null ? null : req.url.resolve(location);
      throw McpException(
        target == null
            ? 'MCP endpoint redirected (${r.statusCode}). Use the final endpoint URL.'
            : 'MCP endpoint redirected (${r.statusCode}) to $target. Update the saved server URL to this address and reconnect.',
        statusCode: r.statusCode,
      );
    }
    _sessionId = r.headers['mcp-session-id'] ?? _sessionId;
    final type = r.headers['content-type'] ?? '';
    if (type.contains('text/event-stream')) {
      final result = Completer<Map<String, dynamic>>();
      final subscription = sseData(r.stream.transform(utf8.decoder).transform(const LineSplitter())).listen((data) {
        try {
          final j = jsonDecode(data);
          if (!result.isCompleted && j is Map && j['id'] == id) {
            if (j['error'] != null) throw _rpcError(j['error']);
            result.complete(j['result'] is Map ? Map<String, dynamic>.from(j['result'] as Map) : {'value': j['result']});
          }
        } catch (e) {
          if (e is AiException && !result.isCompleted) result.completeError(e);
        }
      }, onError: (Object e) {
        if (!result.isCompleted) result.completeError(e);
      }, onDone: () {
        if (!result.isCompleted) result.completeError(McpException('MCP "$method" returned no result.'));
      });
      final remove = cancelToken?.onCancel(() {
        if (!result.isCompleted) result.completeError(const AiCancelledException());
      });
      try {
        return await result.future.timeout(timeout);
      } finally {
        remove?.call();
        await subscription.cancel();
      }
    }
    final response = await http.Response.fromStream(r).timeout(timeout);
    if (response.statusCode >= 400) {
      try {
        final j = jsonDecode(response.body);
        if (j is Map && j['error'] is Map) throw _rpcError(j['error'], statusCode: response.statusCode);
      } on FormatException catch (_) {/* Readable HTTP error below. */}
      _net.ensureOk(response);
    }
    final j = jsonDecode(utf8.decode(response.bodyBytes));
    if (j is! Map) throw const McpException('MCP answered with something that is not JSON-RPC.');
    if (j['id'] != id) throw const McpException('MCP response id does not match the request.');
    if (j['error'] != null) throw _rpcError(j['error']);
    final result = j['result'];
    return result is Map ? Map<String, dynamic>.from(result) : {'value': result};
  }

  @override
  Future<void> notify(String method, [Map<String, dynamic>? params]) async {
    try {
      await _net.post(
        _url,
        headers: _headers,
        json: {'jsonrpc': '2.0', 'method': method, if (params != null) 'params': params},
        timeout: timeout,
      );
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    await _sseSub?.cancel();
    _sseSub = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(const McpException('MCP client closed.'));
    }
    _pending.clear();
    if (_sessionId != null && !sse && server.url != null) {
      try {
        await _net.delete(Uri.parse(server.url!), headers: _headers, timeout: const Duration(seconds: 5));
      } catch (_) {}
    }
    if (_owns) _http.close();
  }
}

McpException _rpcError(Object error, {int? statusCode}) {
  if (error is Map) {
    return McpException('${error['message'] ?? error}',
        code: (error['code'] as num?)?.toInt(), body: jsonEncode(error), statusCode: statusCode);
  }
  return McpException('$error');
}

/// MCP for agents: one toolkit per installed server. Tools are fetched
/// live; [id] is `mcp_<serverId>`.
class McpToolkit extends Toolkit {
  McpToolkit(this.server, {http.Client? httpClient, this.prefixTools = false}) : _httpClient = httpClient;

  final McpServer server;
  final http.Client? _httpClient;

  /// Prefix tool names with `serverId_` so several MCP servers can share a list.
  final bool prefixTools;

  McpClient? _client;

  @override
  String get id => 'mcp_${server.id}';
  @override
  String get name => 'MCP ${server.id}';
  @override
  bool get needsApiKey => false;
  @override
  bool get isConfigured => (server.url != null && server.url!.isNotEmpty) || (server.command != null && server.command!.isNotEmpty);
  @override
  String? get apiKeyUrl => null;
  @override
  Future<String?> verify() async {
    try {
      await _ensure();
      return null;
    } on AiException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  @override
  String get instructions => 'Tools from the MCP server "${server.id}" ($serverName). Call them when they match the task.';

  String get serverName => _client?.serverName ?? server.id;

  Future<McpClient> _ensure() async => _client ??= await createMcpClient(server, httpClient: _httpClient);

  /// The live client, connecting on first use.
  Future<McpClient> connect() => _ensure();

  @override
  Future<List<Tool>> tools() async {
    final c = await _ensure();
    return c.tools(prefix: prefixTools ? '${server.id}_' : null);
  }

  @override
  Future<void> dispose() async {
    await _client?.close();
    _client = null;
  }
}

/// A value a registry server asks for before it works: a header such as
/// `Authorization: Bearer {api_key}`.
class McpInput {
  const McpInput({required this.name, this.description = '', required this.template, this.isRequired = false, this.isSecret = false});

  /// The header name.
  final String name;
  final String description;

  /// The value with `{variables}` to fill in.
  final String template;
  final bool isRequired;

  /// A key or token: hide it while typed.
  final bool isSecret;

  /// The `{variables}` in [template]; the header name when it has none.
  List<String> get variables {
    final found = [for (final m in McpCatalogHit._placeholder.allMatches(template)) m[1]!];
    return found.isEmpty ? [name] : found;
  }

  Map<String, dynamic> toJson() => {
        'header': name,
        if (description.isNotEmpty) 'description': description,
        'needs': variables,
        'required': isRequired,
        if (isSecret) 'secret': true,
      };
}

/// A server from the official MCP Registry
/// (`https://registry.modelcontextprotocol.io`).
class McpCatalogHit {
  const McpCatalogHit({
    required this.name,
    this.description = '',
    this.version = '',
    this.repositoryUrl,
    this.remotes = const [],
    this.packages = const [],
    this.raw = const {},
  });

  factory McpCatalogHit.fromJson(Map j) {
    final server = j['server'] is Map ? j['server'] as Map : j;
    final remotes = [
      for (final r in (server['remotes'] as List? ?? const []))
        if (r is Map)
          (
            type: '${r['type'] ?? 'http'}',
            url: '${r['url'] ?? ''}',
            headers: [
              for (final h in (r['headers'] as List? ?? const []))
                if (h is Map) Map<String, dynamic>.from(h),
            ],
          ),
    ];
    final packages = [
      for (final p in (server['packages'] as List? ?? const []))
        if (p is Map) Map<String, dynamic>.from(p),
    ];
    final repo = server['repository'];
    return McpCatalogHit(
      name: '${server['name'] ?? ''}',
      description: '${server['description'] ?? ''}',
      version: '${server['version'] ?? ''}',
      repositoryUrl: repo is Map ? repo['url'] as String? : repo as String?,
      remotes: remotes,
      packages: packages,
      raw: Map<String, dynamic>.from(j),
    );
  }

  /// Registry name, e.g. `io.github.user/weather`.
  final String name;
  final String description;
  final String version;
  final String? repositoryUrl;
  final List<({String type, String url, List<Map<String, dynamic>> headers})> remotes;
  final List<Map<String, dynamic>> packages;
  final Map<String, dynamic> raw;

  /// Short id for [McpServer.id].
  String get suggestedId => McpRegistry.shortId(name);

  bool get hasRemote => remotes.any((r) => r.url.isNotEmpty);
  bool get hasPackage => packages.isNotEmpty;

  /// Env var names a stdio package says it needs.
  List<String> get requiredEnv {
    final out = <String>[];
    for (final p in packages) {
      for (final e in (p['environmentVariables'] as List? ?? const [])) {
        if (e is Map && e['isRequired'] == true && e['name'] != null) out.add('${e['name']}');
      }
    }
    return out;
  }

  static final _placeholder = RegExp(r'\{([A-Za-z0-9_\-]+)\}');

  /// What a person has to supply before this server works: each header of
  /// the first remote, with the variables in its template
  /// (`Bearer {smithery_api_key}` → `smithery_api_key`).
  List<McpInput> get inputs {
    final remote = remotes.where((r) => r.url.isNotEmpty).firstOrNull;
    return [
      for (final h in remote?.headers ?? const <Map<String, dynamic>>[])
        if (h['name'] != null)
          McpInput(
            name: '${h['name']}',
            description: '${h['description'] ?? ''}',
            template: '${h['value'] ?? h['default'] ?? '{${h['name']}}'}',
            isRequired: h['isRequired'] == true,
            isSecret: h['isSecret'] == true,
          ),
    ];
  }

  /// [template] with each `{variable}` filled from [values] (by variable or
  /// header name); null while a variable is still missing.
  static String? fill(String template, String name, Map<String, String> values) {
    if (!_placeholder.hasMatch(template)) {
      // A fixed value; one given for the header replaces it.
      final given = values[name]?.trim();
      return given == null || given.isEmpty ? template : given;
    }
    var missing = false;
    final out = template.replaceAllMapped(_placeholder, (m) {
      final v = values[m[1]!] ?? values[name];
      if (v == null || v.trim().isEmpty) {
        missing = true;
        return m[0]!;
      }
      return v.trim();
    });
    return missing ? null : out;
  }

  /// Builds a [McpServer] from the first remote (HTTP/SSE), else the first
  /// npm/pypi package (stdio). [headers] and [env] give secrets by header,
  /// variable or env name. A required header still holding a `{variable}`
  /// throws, naming what is missing; an optional one is left out, so a
  /// placeholder is never saved as if it were a key.
  McpServer toServer({String? id, Map<String, String> headers = const {}, Map<String, String> env = const {}}) {
    final sid = id ?? suggestedId;
    final remote = remotes.where((r) => r.url.isNotEmpty && ['http', 'streamable-http', 'sse'].contains(r.type)).firstOrNull;
    if (remote != null) {
      final sse = remote.type.contains('sse');
      final hdr = <String, String>{};
      final missing = <String>[];
      for (final input in inputs) {
        final value = fill(input.template, input.name, headers);
        if (value != null) {
          hdr[input.name] = value;
        } else if (input.isRequired) {
          missing.add(input.name);
        }
      }
      for (final e in headers.entries) {
        if (!inputs.any((i) => i.name == e.key || i.template.contains('{${e.key}}'))) hdr[e.key] = e.value;
      }
      if (missing.isNotEmpty) throw McpException('"$name" needs a value for ${missing.join(', ')}.');
      return sse ? McpServer.sse(sid, url: remote.url, headers: hdr) : McpServer.http(sid, url: remote.url, headers: hdr);
    }
    final pkg = packages.where((p) => p['identifier'] != null && ['npm', 'pypi'].contains(p['registryType'])).firstOrNull;
    if (pkg == null) {
      throw McpException('Registry server "$name" has no remote URL or installable package.');
    }
    final identifier = '${pkg['identifier']}';
    final kind = '${pkg['registryType'] ?? 'npm'}';
    final hint = '${pkg['runtimeHint'] ?? ''}'.trim();
    List<String> arguments(Object? list) => [
          if (list is List)
            for (final a in list)
              if (a is Map) ...[
                if (a['type'] == 'named' && a['name'] != null) '${a['name']}',
                if (a['value'] != null || a['default'] != null)
                  '${a['value'] ?? a['default']}'
                else if (a['isRequired'] == true)
                  '{${a['name'] ?? a['valueHint'] ?? 'value'}}',
              ],
        ];
    final extra = arguments(pkg['runtimeArguments']);
    final serverArgs = arguments(pkg['packageArguments']);
    final environment = <String, String>{
      for (final v in (pkg['environmentVariables'] as List? ?? const []))
        if (v is Map && v['name'] != null && (v['value'] != null || v['default'] != null))
          '${v['name']}': '${v['value'] ?? v['default']}',
      ...env,
    };
    final missingEnv = [for (final n in requiredEnv) if (environment[n]?.trim().isNotEmpty != true) n];
    if (missingEnv.isNotEmpty) throw McpException('"$name" needs ${missingEnv.join(', ')} set.');
    final packageVersion = pkg['version'] as String?;
    final pinned = packageVersion == null || packageVersion.isEmpty || packageVersion == 'latest'
        ? identifier
        : '$identifier${kind == 'pypi' ? '==' : '@'}$packageVersion';
    if (kind == 'pypi' || hint == 'uvx' || hint == 'uv') {
      return McpServer.stdio(sid,
          command: hint.isEmpty ? 'uvx' : hint,
          args: [if (hint == 'uv') 'tool', if (hint == 'uv') 'run', ...extra, pinned, ...serverArgs],
          env: environment);
    }
    return McpServer.stdio(sid,
        command: hint.isEmpty ? 'npx' : hint,
        args: [if (!extra.contains('-y') && !extra.contains('--yes')) '-y', ...extra, pinned, ...serverArgs],
        env: environment);
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'version': version,
        if (repositoryUrl != null) 'repository': repositoryUrl,
        'id': suggestedId,
        if (hasRemote) 'url': remotes.first.url,
        'transport': hasRemote ? (remotes.first.type.contains('sse') ? 'sse' : 'http') : 'stdio',
        if (inputs.isNotEmpty) 'inputs': [for (final i in inputs) i.toJson()],
        if (requiredEnv.isNotEmpty) 'required_env': requiredEnv,
      };
}

/// Install, list and use MCP servers. Saved in secure device storage
/// unless you pass a [store]. Search the official registry at
/// [catalogUrl] (`https://registry.modelcontextprotocol.io`).
///
/// ```dart
/// final hits = await ai.mcp.search('filesystem');
/// await ai.mcp.installHit(hits.first);
/// print(await ai.mcp.list());
/// ai.agent(toolkits: await ai.mcp.toolkits());
/// ```
class McpRegistry extends ChangeNotifier {
  McpRegistry({
    this.storeKey = 'omni_ai.mcp.servers',
    http.Client? httpClient,
    this.persist = true,
    this.catalogUrl = 'https://registry.modelcontextprotocol.io',
    KeyStore? store,
  })  : store = store ?? SecureKeyStore(),
        _httpClient = httpClient,
        _net = AiHttp(provider: 'MCP registry', client: httpClient);

  final String storeKey;
  final KeyStore store;
  final http.Client? _httpClient;
  final AiHttp _net;
  final bool persist;

  /// Official MCP Registry origin (no trailing slash).
  final String catalogUrl;
  final _servers = <String, McpServer>{};
  final _clients = <String, McpClient>{};
  bool _loaded = false;
  Future<void>? _loading;

  /// Saved servers already in memory (after [load]).
  List<McpServer> get servers => _servers.values.toList();
  bool get hasServers => _servers.isNotEmpty;

  /// Loads saved servers (called automatically).
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    if (_loaded || !persist) {
      _loaded = true;
      return;
    }
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = await store.read(storeKey) ?? prefs.getString(storeKey);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final x in list) {
        if (x is Map) {
          final s = McpServer.fromJson(x);
          _servers[s.id] = s;
        }
      }
      // Migrate older plaintext preferences, including headers and env secrets.
      await _save();
      await prefs.remove(storeKey);
    } catch (e) {
      if (!'$e'.contains('Binding has not yet been initialized')) debugPrint('[omni_ai] could not load MCP servers: $e');
    }
  }

  Future<void> _save() async {
    if (!persist) return;
    await store.write(storeKey, jsonEncode([for (final s in _servers.values) s.toJson()]));
  }

  /// Installs (or replaces) a server and saves it. Does not connect yet.
  Future<McpServer> install(McpServer server) async {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_\-]{0,47}$').hasMatch(server.id)) {
      throw ArgumentError('MCP server ids use 1–48 letters, digits, _ or -.');
    }
    if (server.transport == McpTransportKind.stdio) {
      if (server.command?.trim().isNotEmpty != true) throw ArgumentError('A stdio server requires a command.');
    } else {
      final uri = Uri.tryParse(server.url ?? '');
      if (uri == null || uri.host.isEmpty || !['http', 'https'].contains(uri.scheme)) {
        throw ArgumentError('An HTTP or SSE server requires an HTTP(S) endpoint.');
      }
      // Headers often carry keys: plain http only inside this machine or network.
      if (uri.scheme == 'http' && !isLocalHost(uri.host)) {
        throw ArgumentError('Use https:// for a server on the internet (http only for localhost or your local network).');
      }
      final unfilled = [
        for (final e in server.headers.entries)
          if (McpCatalogHit._placeholder.hasMatch(e.value)) e.key,
      ];
      if (unfilled.isNotEmpty) throw ArgumentError('Fill in ${unfilled.join(', ')}: it still holds a {placeholder}.');
    }
    await load();
    await _clients.remove(server.id)?.close();
    _servers[server.id] = server;
    await _save();
    notifyListeners();
    return server;
  }

  /// Drops a saved server and closes its client.
  Future<bool> uninstall(String id) async {
    await load();
    final gone = _servers.remove(id) != null;
    await _clients.remove(id)?.close();
    if (gone) {
      await _save();
      notifyListeners();
    }
    return gone;
  }

  /// Saved servers.
  Future<List<McpServer>> list() async {
    await load();
    return _servers.values.toList();
  }

  McpServer? operator [](String id) => _servers[id];

  Future<bool> isInstalled(String id) async {
    await load();
    return _servers.containsKey(id);
  }

  /// Catalog and lifecycle tools without connecting to installed servers.
  Future<List<Tool>> managementTools() => _McpRegistryToolkit(this).managementTools();

  /// Whether the agent tools (`mcp_install`, `mcp_install_catalog`) may save
  /// a local command (stdio) server. Off by default: connecting runs that
  /// command on the device, so people add those themselves.
  bool allowAgentStdio = false;

  /// localhost, loopback, private network ranges and `.local` names.
  static bool isLocalHost(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h == '::1' || h == '[::1]' || h.endsWith('.local')) return true;
    final p = h.split('.').map(int.tryParse).toList();
    if (p.length != 4 || p.any((x) => x == null)) return false;
    return p[0] == 127 || p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && p[1]! >= 16 && p[1]! <= 31);
  }

  /// Short toolkit id from a registry name (`io.github.user/weather` → `weather`).
  static String shortId(String name) {
    final last = name.split('/').last;
    var s = last.replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '-').replaceAll(RegExp(r'-+'), '-');
    s = s.replaceAll(RegExp(r'^-+|-+$'), '');
    if (s.isEmpty) s = 'mcp';
    if (!RegExp(r'^[A-Za-z]').hasMatch(s)) s = 'm$s';
    if (s.length > 48) s = s.substring(0, 48);
    return s;
  }

  /// Searches the official MCP Registry. [query] must be at least 3
  /// characters (registry rule). Pass an empty query to browse latest.
  Future<List<McpCatalogHit>> search(String query, {int limit = 20, String version = 'latest', CancelToken? cancelToken}) async {
    final q = query.trim();
    if (q.isNotEmpty && q.length < 3) {
      throw ArgumentError('MCP registry search needs at least 3 characters.');
    }
    final params = <String, String>{
      'limit': '${limit.clamp(1, 100)}',
      if (version.isNotEmpty) 'version': version,
      if (q.isNotEmpty) 'search': q,
    };
    final url = Uri.parse('$catalogUrl/v0.1/servers').replace(queryParameters: params);
    final r = await _net.get(url, headers: {'User-Agent': 'omni_ai', 'Accept': 'application/json'}, cancelToken: cancelToken);
    if (r.statusCode >= 400) {
      throw McpException('MCP registry search failed (${r.statusCode}).', body: utf8.decode(r.bodyBytes, allowMalformed: true));
    }
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    final list = j is Map ? j['servers'] : j;
    return [
      for (final x in (list as List? ?? const []))
        if (x is Map) McpCatalogHit.fromJson(x)
    ];
  }

  /// Latest version of one registry server (`GET .../servers/{name}/versions/latest`).
  Future<McpCatalogHit> getLatest(String name, {CancelToken? cancelToken}) async {
    final encoded = Uri.encodeComponent(name);
    final url = Uri.parse('$catalogUrl/v0.1/servers/$encoded/versions/latest');
    final r = await _net.get(url, headers: {'User-Agent': 'omni_ai', 'Accept': 'application/json'}, cancelToken: cancelToken);
    if (r.statusCode >= 400) {
      throw McpException('No MCP registry server "$name" (${r.statusCode}).', body: utf8.decode(r.bodyBytes, allowMalformed: true));
    }
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map) throw McpException('MCP registry returned a bad payload for "$name".');
    return McpCatalogHit.fromJson(j);
  }

  /// Installs a catalog hit. Prefer HTTP remotes; otherwise stdio from npm/pypi.
  Future<McpServer> installHit(McpCatalogHit hit,
          {String? id, Map<String, String> headers = const {}, Map<String, String> env = const {}}) =>
      install(hit.toServer(id: id, headers: headers, env: env));

  /// Looks up [name] in the official registry and installs it.
  Future<McpServer> installFromCatalog(String name,
          {String? id, Map<String, String> headers = const {}, Map<String, String> env = const {}}) async =>
      installHit(await getLatest(name), id: id, headers: headers, env: env);

  /// Connects to a saved server (cached until [uninstall] or [dispose]).
  Future<McpClient> connect(String id) async {
    await load();
    final s = _servers[id] ?? (throw McpException('No MCP server "$id". Install it first.'));
    return _clients[id] ??= await createMcpClient(s, httpClient: _httpClient);
  }

  /// One toolkit per installed server.
  Future<List<McpToolkit>> toolkits({bool prefixTools = false}) async {
    await load();
    return [for (final s in _servers.values) McpToolkit(s, httpClient: _httpClient, prefixTools: prefixTools)];
  }

  /// Tools from every installed server. Names are `serverId_tool` when more
  /// than one server is installed.
  Future<List<Tool>> tools() async {
    await load();
    final prefix = _servers.length > 1;
    final out = <Tool>[];
    for (final s in _servers.values) {
      try {
        final c = await connect(s.id);
        out.addAll(await c.tools(prefix: prefix ? '${s.id}_' : null));
      } catch (e) {
        debugPrint('[omni_ai] MCP ${s.id} tools failed: $e');
      }
    }
    return out;
  }

  /// Lifecycle and invocation tools, connecting only when called.
  /// Opt into eager, individual tool schemas with [includeServerTools].
  Toolkit asToolkit({bool includeServerTools = false}) => _McpRegistryToolkit(this, includeServerTools: includeServerTools);

  @override
  Future<void> dispose() async {
    for (final c in _clients.values) {
      await c.close();
    }
    _clients.clear();
    super.dispose();
  }
}

class _McpRegistryToolkit extends Toolkit {
  _McpRegistryToolkit(this._r, {this.includeServerTools = false});
  final McpRegistry _r;
  final bool includeServerTools;

  @override
  String get id => 'mcp';
  @override
  String get name => 'MCP servers';
  @override
  bool get needsApiKey => false;
  @override
  bool get isConfigured => true;
  @override
  Future<String?> verify() async => null;

  @override
  String get instructions => 'mcp_search finds MCP servers in the official registry. '
      'mcp_install_catalog installs one by registry name; mcp_install saves explicit configuration. '
      'mcp_list_servers and mcp_is_installed check installations without connecting. '
      'mcp_list_tools returns tool names and input schemas; mcp_call_tool uses one immediately. '
      'mcp_uninstall removes a server. Installation, removal and tool calls require approval.';

  Future<List<Tool>> managementTools() async => [
        Tool(
          name: 'mcp_is_installed',
          label: 'Checking an MCP installation',
          description: 'Checks whether a server id is installed, without starting or connecting to it.',
          parameters: Schema.object({'id': Schema.string()}, required: ['id']),
          execute: (i) async => {'id': i['id'], 'installed': await _r.isInstalled(i['id'] as String)},
        ),
        Tool(
          name: 'mcp_install',
          label: 'Installing an MCP configuration',
          description:
              'Installs or updates a saved MCP server configuration. HTTP/SSE use url and headers; stdio uses command, args, env. Does not connect yet.',
          parameters: Schema.object({
            'server': Schema({
              'type': 'object',
              'properties': {
                'id': {'type': 'string'},
                'transport': {
                  'type': 'string',
                  'enum': ['http', 'sse', 'stdio']
                },
                'url': {'type': 'string'},
                'headers': {
                  'type': 'object',
                  'additionalProperties': {'type': 'string'}
                },
                'command': {'type': 'string'},
                'args': {
                  'type': 'array',
                  'items': {'type': 'string'}
                },
                'env': {
                  'type': 'object',
                  'additionalProperties': {'type': 'string'}
                },
              },
              'required': ['id', 'transport']
            })
          }, required: [
            'server'
          ]),
          approval: ApprovalPolicy.always,
          execute: (i) async {
            final server = McpServer.fromJson(i['server'] as Map);
            if (server.transport == McpTransportKind.stdio && !_r.allowAgentStdio) {
              return {'error': 'Local command servers can only be added by the person, in the app\'s MCP settings.'};
            }
            final s = await _r.install(server);
            return {'installed': s.id, 'transport': s.transport.name};
          },
        ),
        Tool(
          name: 'mcp_uninstall',
          label: 'Removing an MCP server',
          description: 'Removes a saved server and closes its connection or local process.',
          parameters: Schema.object({'id': Schema.string()}, required: ['id']),
          approval: ApprovalPolicy.always,
          execute: (i) async => {'id': i['id'], 'removed': await _r.uninstall(i['id'] as String)},
        ),
        Tool(
          name: 'mcp_list_tools',
          label: 'Listing MCP tools',
          description:
              'Connects to an installed server (starts its command for stdio) and returns all tool names, descriptions and input schemas.',
          parameters: Schema.object({'server': Schema.string()}, required: ['server']),
          execute: (i) async => {
            'tools': [
              for (final t in await (await _r.connect(i['server'] as String)).listTools())
                {'name': t.name, 'description': t.description, 'inputSchema': t.inputSchema}
            ]
          },
        ),
        Tool(
          name: 'mcp_list_resources',
          label: 'Listing MCP resources',
          description: 'Connects to an installed server and lists resources.',
          parameters: Schema.object({'server': Schema.string()}, required: ['server']),
          execute: (i) async => {
            'resources': [
              for (final r in await (await _r.connect(i['server'] as String)).listResources())
                {'uri': r.uri, 'name': r.name, 'description': r.description}
            ]
          },
        ),
        Tool(
          name: 'mcp_read_resource',
          label: 'Reading an MCP resource',
          description: 'Reads a resource URI from an installed MCP server.',
          parameters: Schema.object({'server': Schema.string(), 'uri': Schema.string()}, required: ['server', 'uri']),
          execute: (i) async => (await _r.connect(i['server'] as String)).readResource(i['uri'] as String),
        ),
        Tool(
          name: 'mcp_list_prompts',
          label: 'Listing MCP prompts',
          description: 'Connects to an installed server and lists its prompts and argument definitions.',
          parameters: Schema.object({'server': Schema.string()}, required: ['server']),
          execute: (i) async => {
            'prompts': [
              for (final p in await (await _r.connect(i['server'] as String)).listPrompts())
                {'name': p.name, 'description': p.description, 'arguments': p.arguments}
            ]
          },
        ),
        Tool(
          name: 'mcp_get_prompt',
          label: 'Loading an MCP prompt',
          description: 'Loads a named prompt and its messages from an installed MCP server.',
          parameters: Schema.object({
            'server': Schema.string(),
            'name': Schema.string(),
            'arguments': Schema({
              'type': 'object',
              'additionalProperties': {'type': 'string'}
            })
          }, required: [
            'server',
            'name'
          ]),
          execute: (i) async => (await _r.connect(i['server'] as String))
              .getPrompt(i['name'] as String, arguments: Map<String, dynamic>.from(i['arguments'] as Map? ?? const {})),
        ),
        Tool(
          name: 'mcp_search',
          label: 'Searching MCP servers',
          description:
              'Searches the official MCP Registry (registry.modelcontextprotocol.io). Query must be at least 3 characters. Returns name, description, transport, and install id.',
          parameters: Schema.object({
            'query': Schema.string(description: 'Server name or topic, at least 3 characters.'),
            'limit': Schema.integer(minimum: 1, maximum: 50),
          }, required: [
            'query'
          ]),
          execute: (i) async {
            final hits = await _r.search('${i['query']}', limit: (i['limit'] as num?)?.toInt() ?? 10);
            return {
              'servers': [for (final h in hits) h.toJson()],
            };
          },
        ),
        Tool(
          name: 'mcp_install_catalog',
          label: 'Installing an MCP server',
          description:
              'Installs an MCP server from the official registry by its full name (from mcp_search), e.g. io.github.user/weather. HTTP remotes install on every platform; npm/pypi packages need stdio (desktop).',
          parameters: Schema.object({
            'name': Schema.string(description: 'Registry name from mcp_search, e.g. io.github.user/weather'),
            'id': Schema.string(description: 'Short local id. Defaults to the last path segment.'),
            'headers': Schema({
              'type': 'object',
              'additionalProperties': {'type': 'string'}
            }),
            'env': Schema({
              'type': 'object',
              'additionalProperties': {'type': 'string'}
            }),
          }, required: [
            'name'
          ]),
          approval: ApprovalPolicy.always,
          execute: (i) async {
            final hit = await _r.getLatest('${i['name']}');
            final server = hit.toServer(
                id: '${i['id'] ?? ''}'.isEmpty ? null : '${i['id']}',
                headers: Map<String, String>.from(i['headers'] as Map? ?? const {}),
                env: Map<String, String>.from(i['env'] as Map? ?? const {}));
            if (server.transport == McpTransportKind.stdio && !_r.allowAgentStdio) {
              return {'error': 'This server runs as a local command; the person can add it in the app\'s MCP settings.'};
            }
            final s = await _r.install(server);
            return {
              'id': s.id,
              'transport': s.transport.name,
              if (s.url != null) 'url': s.url,
              if (s.command != null) 'command': s.command
            };
          },
        ),
        Tool(
          name: 'mcp_call_tool',
          label: 'Calling an MCP tool',
          description:
              'Calls a tool on an installed MCP server by name. Works immediately after installation. Use mcp_list_servers to discover tool names.',
          parameters: Schema.object({
            'server': Schema.string(),
            'name': Schema.string(),
            'arguments': Schema({'type': 'object', 'additionalProperties': true}),
          }, required: [
            'server',
            'name',
            'arguments'
          ]),
          approval: ApprovalPolicy.always,
          execute: (i) async => (await _r.connect(i['server'] as String)).callTool(
              i['name'] as String, Map<String, dynamic>.from(i['arguments'] as Map),
              cancelToken: ToolContext.current?.cancelToken),
        ),
        Tool(
          name: 'mcp_list_servers',
          label: 'Listing MCP servers',
          description:
              'Lists installed MCP server ids and transports without starting processes or connecting. Use mcp_list_tools for tool schemas.',
          execute: (_) async {
            final servers = await _r.list();
            final out = <Map<String, dynamic>>[];
            for (final s in servers) {
              out.add({'id': s.id, 'transport': s.transport.name, if (s.url != null) 'url': s.url});
            }
            return {'servers': out};
          },
        ),
      ];

  @override
  Future<List<Tool>> tools() async => [...await managementTools(), if (includeServerTools) ...await _r.tools()];

  @override
  Future<void> dispose() => _r.dispose();
}
