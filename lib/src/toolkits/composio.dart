import 'dart:convert';

import 'package:http/http.dart' as http;

import '../agents/toolkit.dart';
import '../core/errors.dart';
import '../core/http.dart';
import '../core/tools.dart';

/// An app account a user connected through Composio.
class ConnectedApp {
  const ConnectedApp({required this.id, required this.toolkit, required this.status, this.alias});
  final String id;

  /// Composio's toolkit slug, e.g. `gmail`.
  final String toolkit;
  final String status;
  final String? alias;
  bool get active => status == 'ACTIVE';

  /// The app's logo.
  String get logoUrl => 'https://logos.composio.dev/api/$toolkit';
}

/// A Composio action, e.g. `GMAIL_SEND_EMAIL`.
class ComposioAction {
  const ComposioAction(
      {required this.slug, required this.name, required this.description, required this.toolkit, this.parameters = const {}});
  final String slug;
  final String name;
  final String description;
  final String toolkit;

  /// JSON Schema of the input.
  final Map<String, dynamic> parameters;

  factory ComposioAction.fromJson(Map t) => ComposioAction(
        slug: '${t['slug']}',
        name: '${t['name'] ?? t['slug']}',
        description: '${t['description'] ?? ''}',
        toolkit: '${(t['toolkit'] as Map?)?['slug'] ?? ''}',
        parameters: t['input_parameters'] is Map ? Map<String, dynamic>.from(t['input_parameters'] as Map) : const {},
      );
}

/// Composio's REST API (v3.1): one tool-router session per user runs
/// actions and makes sign-in links; Composio keeps the OAuth tokens.
///
/// Use the project API key (`ak_…`) and any stable [userId] that names
/// this person's connections.
class ComposioClient {
  ComposioClient({this.apiKey, this.userId = 'default', http.Client? httpClient}) : _net = AiHttp(provider: 'Composio', client: httpClient);

  static const base = 'https://backend.composio.dev/api/v3.1';

  String? apiKey;
  String userId;
  final AiHttp _net;
  String? _session;

  /// The key and user [_session] was made for; a new key or user needs a
  /// new session.
  String? _sessionFor;

  Map<String, String> get _headers => {'x-api-key': apiKey?.trim() ?? ''};

  /// A clearer reason than the API gives for the wrong kind of key.
  static String? keyProblem(String key) {
    final k = key.trim();
    if (k.isEmpty) return 'Paste a Composio API key first.';
    if (k.startsWith('ck_')) return 'That is a Connect consumer key. Use the project API key (ak_…) from Composio → Settings → API keys.';
    if (k.startsWith('uak_')) return 'That is a user API key. Use the project API key, which starts with ak_.';
    return null;
  }

  Future<dynamic> _get(String path) async => _net.json(await _net.get(Uri.parse('$base$path'), headers: _headers));
  Future<dynamic> _post(String path, Map<String, dynamic> body) async =>
      _net.json(await _net.post(Uri.parse('$base$path'), headers: _headers, json: body, timeout: const Duration(minutes: 2)));

  Future<String> _sessionId({bool fresh = false}) async {
    final owner = '${apiKey?.trim()} $userId';
    if (!fresh && _session != null && _sessionFor == owner) return _session!;
    final j = await _post('/tool_router/session', {
      'user_id': userId,
      'manage_connections': {'enable': false},
      'workbench': {'enable': false},
    });
    final id = j is Map ? '${j['session_id'] ?? ''}' : '';
    if (id.isEmpty) throw const AiException('Composio did not return a session.', provider: 'composio');
    _sessionFor = owner;
    return _session = id;
  }

  /// Calls the session, making a new one once if it expired.
  Future<dynamic> _inSession(String action, Map<String, dynamic> body) async {
    try {
      return await _post('/tool_router/session/${await _sessionId()}/$action', body);
    } on AiException catch (e) {
      if (e.statusCode != 404 && e.statusCode != 410) rethrow;
      return _post('/tool_router/session/${await _sessionId(fresh: true)}/$action', body);
    }
  }

  /// Runs an action as this user and returns its data.
  Future<dynamic> execute(String slug, Map<String, dynamic> arguments) async {
    final j = await _inSession('execute', {'tool_slug': slug.toUpperCase(), 'arguments': arguments});
    if (j is! Map) return j;
    final type = '${j['result_type'] ?? ''}';
    if (type == 'blocked') throw AiException('${j['message'] ?? 'Composio blocked the call.'}', provider: 'composio');
    if (type == 'input_required') {
      throw const AiException('Composio needs more input. Try again with fuller arguments.', provider: 'composio');
    }
    final error = j['error'];
    if (type == 'failed' || (error != null && '$error'.isNotEmpty)) {
      throw AiException('${error ?? 'The action failed.'}', provider: 'composio');
    }
    return j['data'] ?? j;
  }

  /// A Composio page where the user signs in to [toolkit] (e.g. `gmail`).
  Future<String> connectLink(String toolkit) async {
    final j = await _inSession('link', {'toolkit': toolkit.toLowerCase()});
    final url = j is Map ? '${j['redirect_url'] ?? ''}' : '';
    if (url.isEmpty) throw AiException('Composio did not return a sign-in link for $toolkit.', provider: 'composio');
    return url;
  }

  /// The user's connected apps.
  Future<List<ConnectedApp>> connections() async {
    final out = <ConnectedApp>[];
    String? cursor;
    for (var page = 0; page < 5; page++) {
      final q = Uri(queryParameters: {'user_ids': userId, 'limit': '50', if (cursor != null) 'cursor': cursor}).query;
      final j = await _get('/connected_accounts?$q');
      for (final item in (j is Map ? (j['items'] as List? ?? const []) : const []).whereType<Map>()) {
        if (item['is_disabled'] == true) continue;
        out.add(ConnectedApp(
          id: '${item['id']}',
          toolkit: '${(item['toolkit'] as Map?)?['slug'] ?? ''}'.toLowerCase(),
          status: '${item['status'] ?? ''}',
          alias: item['alias'] as String?,
        ));
      }
      cursor = j is Map ? j['next_cursor'] as String? : null;
      if (cursor == null || cursor.isEmpty) break;
    }
    return out;
  }

  Future<void> disconnect(String accountId) async {
    _net.ensureOk(await _net.delete(Uri.parse('$base/connected_accounts/$accountId'), headers: _headers));
  }

  /// Searches the catalog of actions.
  Future<List<ComposioAction>> findActions({String? toolkit, String? query, int limit = 10}) async {
    final q = Uri(queryParameters: {
      if (toolkit != null && toolkit.isNotEmpty) 'toolkit_slug': toolkit.toLowerCase(),
      if (query != null && query.isNotEmpty) 'search': query,
      'limit': '${limit.clamp(1, 50)}',
    }).query;
    final j = await _get('/tools?$q');
    return [for (final t in (j is Map ? (j['items'] as List? ?? const []) : const []).whereType<Map>()) ComposioAction.fromJson(t)];
  }

  /// One action with its input schema.
  Future<ComposioAction> action(String slug) async => ComposioAction.fromJson(await _get('/tools/${slug.toUpperCase()}') as Map);
}

/// Your users' apps (Gmail, Calendar, Slack, GitHub, Notion, Drive and
/// hundreds more) for agents, through Composio.
///
/// By default the agent gets four general tools: connect an app, list
/// connections, search actions, and run an action. Name [actions] (e.g.
/// `['GMAIL_SEND_EMAIL', 'GOOGLECALENDAR_FIND_EVENT']`) to also give it
/// those as typed tools of their own.
class ComposioToolkit extends Toolkit {
  ComposioToolkit({
    String? apiKey,
    String userId = 'default',
    this.actions = const [],
    this.apps,
    this.approval = ApprovalPolicy.always,
    this.readOnlyApproval = ApprovalPolicy.never,
    this.onConnectLink,
    http.Client? httpClient,
  }) : client = ComposioClient(apiKey: apiKey, userId: userId, httpClient: httpClient);

  final ComposioClient client;

  /// Actions to offer as their own tools.
  final List<String> actions;

  /// Limit the general tools to these toolkits (e.g. `['gmail', 'slack']`).
  final List<String>? apps;

  /// Approval for actions that change things (send, create, delete…).
  final ApprovalPolicy approval;

  /// Approval for actions whose names look read-only (GET, LIST, FIND,
  /// SEARCH, FETCH, READ).
  final ApprovalPolicy readOnlyApproval;

  /// Opens a sign-in link (e.g. with url_launcher) when the agent asks the
  /// user to connect an app. The link is also returned to the model.
  final void Function(String toolkit, String url)? onConnectLink;

  String? get apiKey => client.apiKey;
  set apiKey(String? v) => client.apiKey = v;

  /// Whose connections the agent uses.
  String get userId => client.userId;
  set userId(String v) => client.userId = v;

  @override
  String get id => 'composio';
  @override
  String get name => 'Composio apps';
  @override
  String get apiKeyUrl => 'https://platform.composio.dev';
  @override
  bool get isConfigured => apiKey?.trim().isNotEmpty ?? false;

  @override
  String get instructions =>
      'You can act in the user\'s apps (email, calendar, chat, docs, code…) through Composio. Check list_connected_apps; '
      'if an app isn\'t connected, call connect_app and give the user the link. Find the right action with find_app_actions '
      'and run it with run_app_action. Confirm details before sending or deleting anything.';

  static final _readOnly = RegExp(r'_(GET|LIST|FIND|SEARCH|FETCH|READ|RETRIEVE)(_|$)');

  ApprovalPolicy _policyFor(String slug) => _readOnly.hasMatch(slug.toUpperCase()) ? readOnlyApproval : approval;

  @override
  Future<String?> verify() async {
    final problem = ComposioClient.keyProblem(apiKey ?? '');
    if (problem != null) return problem;
    try {
      await client.connections();
      return null;
    } catch (e) {
      return '$e';
    }
  }

  bool _allowed(String toolkit) => apps == null || apps!.map((a) => a.toLowerCase()).contains(toolkit.toLowerCase());

  @override
  Future<List<Tool>> tools() async {
    final appList = apps == null ? '' : ' Available apps: ${apps!.join(', ')}.';
    final out = <Tool>[
      Tool(
        name: 'list_connected_apps',
        label: 'Checking connected apps',
        description: 'Lists the apps the user has connected (Gmail, Slack, GitHub…).$appList',
        execute: (_) async {
          requireKey(this, apiKey);
          final apps = await client.connections();
          return {
            'connected': [
              for (final a in apps.where((a) => _allowed(a.toolkit)))
                {'app': a.toolkit, 'status': a.status, if (a.alias != null) 'alias': a.alias},
            ],
          };
        },
      ),
      Tool(
        name: 'connect_app',
        label: 'Connecting an app',
        description: 'Makes a sign-in link so the user can connect an app (e.g. gmail, googlecalendar, slack, github, notion). '
            'Give the user the link; they sign in, then you can use the app.$appList',
        parameters: Schema.object({'app': Schema.string(description: 'Composio toolkit slug, e.g. gmail.')}),
        execute: (i) async {
          requireKey(this, apiKey);
          final app = '${i['app']}'.toLowerCase();
          if (!_allowed(app)) return {'error': '$app is not available to this agent.'};
          final url = await client.connectLink(app);
          onConnectLink?.call(app, url);
          return {'app': app, 'link': url, 'note': 'Ask the user to open the link and sign in, then try again.'};
        },
      ),
      Tool(
        name: 'find_app_actions',
        label: 'Finding app actions',
        description: 'Searches the actions available in an app, with their input parameters. Use before run_app_action.',
        parameters: Schema.object({
          'app': Schema.string(description: 'Toolkit slug, e.g. gmail.'),
          'query': Schema.string(description: 'What you want to do, e.g. "send email".'),
        }, required: [
          'query'
        ]),
        execute: (i) async {
          requireKey(this, apiKey);
          final app = i['app'] as String?;
          if (app != null && !_allowed(app)) return {'error': '$app is not available to this agent.'};
          final found = await client.findActions(toolkit: app, query: '${i['query']}', limit: 8);
          return {
            'actions': [
              for (final a in found.where((a) => _allowed(a.toolkit)))
                {'slug': a.slug, 'app': a.toolkit, 'description': a.description, 'parameters': a.parameters['properties'] ?? a.parameters},
            ],
          };
        },
      ),
      Tool(
        name: 'run_app_action',
        label: 'Using an app',
        description: 'Runs an app action found with find_app_actions, as the user. Pass the exact slug and its arguments.',
        approval: ApprovalPolicy.when((i) => _policyFor('${i['slug']}').requires(i)),
        // `arguments` is free-form; each action has its own shape.
        parametersJson: {
          'type': 'object',
          'properties': {
            'slug': {'type': 'string', 'description': 'e.g. GMAIL_SEND_EMAIL'},
            'arguments': {'type': 'object', 'description': 'The action\'s input, as an object.'},
          },
          'required': ['slug'],
        },
        execute: (i) async {
          requireKey(this, apiKey);
          final slug = '${i['slug']}'.toUpperCase();
          if (!_allowed(slug.split('_').first)) return {'error': 'That app is not available to this agent.'};
          var args = i['arguments'];
          if (args is String) args = args.trim().isEmpty ? const {} : jsonDecode(args);
          return {'result': await client.execute(slug, Map<String, dynamic>.from((args as Map?) ?? const {}))};
        },
      ),
    ];

    for (final slug in actions) {
      final a = await client.action(slug);
      final params = a.parameters.isEmpty ? const {'type': 'object', 'properties': {}} : a.parameters;
      out.add(Tool(
        name: a.slug.toLowerCase(),
        label: a.name,
        description: a.description.isEmpty ? a.name : a.description,
        parametersJson: Map<String, dynamic>.from(params),
        approval: _policyFor(a.slug),
        execute: (i) async => {'result': await client.execute(a.slug, i)},
      ));
    }
    return out;
  }
}
