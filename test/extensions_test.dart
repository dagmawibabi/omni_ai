import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omni_ai/omni_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response reply(http.Request request, Object result) => http.Response(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': (jsonDecode(request.body) as Map)['id'],
      'result': result,
    }),
    200,
    headers: {'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Jev preserves structured criteria, validates types and normalizes base URLs', () async {
    expect(() => JevQuestion.score('Grade', ['only']), throwsArgumentError);
    expect(() => JevQuestion.fromJson({'type': 'typo'}), throwsArgumentError);
    final question = JevQuestion.fromJson({
      'type': 'choice',
      'instructions': {'task': 'Route'},
      'criteria': {
        'billing': {
          'includes': ['invoices']
        },
        'other': null,
      }
    });
    final client = JevClient(
        apiKey: 'test',
        baseUrl: 'https://example.com/v1/',
        httpClient: MockClient((r) async {
          expect(r.url.path, '/v1/systemone');
          expect(jsonDecode(r.body)['questions']['team']['criteria']['billing'], {
            'includes': ['invoices']
          });
          expect(jsonDecode(r.body)['questions']['team']['criteria']['other'], isNull);
          return http.Response('{"model":"jev-latest","answers":{},"usage":{}}', 200);
        }));
    await client.decide(state: {'message': 'Invoice'}, questions: {'team': question});
    await expectLater(client.decide(state: '[pic]', questions: {'box': JevQuestion.box('cat')}), throwsArgumentError);
  });

  test('Jev cancellation interrupts retry backoff', () async {
    final token = CancelToken();
    final called = Completer<void>();
    var requests = 0;
    final client = JevClient(
        apiKey: 'test',
        httpClient: MockClient((r) async {
          requests++;
          called.complete();
          return http.Response('{}', 429, headers: {'retry-after': '60'});
        }));
    final result = client.decide(state: 'x', questions: {'q': JevQuestion.boolean('True?')}, cancelToken: token);
    final assertion = expectLater(result, throwsA(isA<AiCancelledException>()));
    await called.future;
    token.cancel();
    await assertion.timeout(const Duration(seconds: 2));
    expect(requests, 1);
  });

  test('skill selector and GitHub folder constrain installation; YAML folded descriptions', () async {
    final net = MockClient((r) async {
      if (r.url.host == 'api.github.com') {
        return http.Response(
            jsonEncode({
              'tree': [
                {'type': 'blob', 'path': 'skills/first/SKILL.md'},
                {'type': 'blob', 'path': 'skills/second/SKILL.md'},
                {'type': 'blob', 'path': 'skills/first/references/deep/a/b.md'},
              ]
            }),
            200);
      }
      if (r.url.path.endsWith('b.md')) return http.Response('Deep reference', 200);
      expect(r.url.path, contains('/skills/first/'));
      return http.Response('---\nname: first\ndescription: >-\n  Use for releases\n  and changelogs.\n---\nRelease steps.', 200);
    });
    final registry = SkillRegistry(persist: false, httpClient: net);
    final selected = await registry.install('acme/skills@first');
    expect(selected.single.name, 'first');
    expect(selected.single.description, 'Use for releases and changelogs.');
    expect(selected.single.files['references/deep/a/b.md'], 'Deep reference');
    final folder = await registry.listRemote('https://github.com/acme/skills/tree/main/skills/first');
    expect(folder.single.name, 'first');
  });

  test('skill catalog names can differ from folder names; GitHub blob URLs fetch raw markdown', () async {
    final net = MockClient((r) async {
      if (r.url.host == 'api.github.com') {
        return http.Response(
            jsonEncode({
              'tree': [
                {'type': 'blob', 'path': 'skills/react/SKILL.md'}
              ]
            }),
            200);
      }
      expect(r.url.host, 'raw.githubusercontent.com');
      expect(r.url.path, endsWith('/skills/react/SKILL.md'));
      return http.Response('---\nname: vercel-react-best-practices\ndescription: React performance\n---\nUse memo carefully.', 200);
    });
    final registry = SkillRegistry(persist: false, httpClient: net);
    expect((await registry.install('acme/skills@vercel-react-best-practices')).single.name, 'vercel-react-best-practices');
    expect(
        (await registry.install('https://github.com/acme/skills/blob/main/skills/react/SKILL.md')).single.content, 'Use memo carefully.');
  });

  test('MCP modern discovery and per-request metadata; paginated resources', () async {
    final methods = <String>[];
    final client = await createMcpClient(McpServer.http('modern', url: 'https://example.com/mcp'), httpClient: MockClient((r) async {
      final j = jsonDecode(r.body) as Map;
      final method = j['method'] as String;
      methods.add(method);
      expect(j['params']['_meta']['io.modelcontextprotocol/protocolVersion'], '2026-07-28');
      expect(r.headers['mcp-method'], method);
      if (method == 'server/discover') {
        return reply(r, {
          'supportedVersions': ['2026-07-28'],
          'resultType': 'complete',
          'capabilities': {'resources': {}},
          '_meta': {
            'io.modelcontextprotocol/serverInfo': {'name': 'modern-demo', 'version': '1'}
          },
        });
      }
      if (j['params']['cursor'] == null) {
        return reply(r, {
          'resources': [
            {'uri': 'test:a', 'name': 'A'}
          ],
          'nextCursor': 'page-2'
        });
      }
      expect(j['params']['cursor'], 'page-2');
      return reply(r, {
        'resources': [
          {'uri': 'test:b', 'name': 'B'}
        ]
      });
    }));
    expect(client.serverName, 'modern-demo');
    expect(client.protocolVersion, '2026-07-28');
    expect((await client.listResources()).map((r) => r.name), ['A', 'B']);
    expect(methods, ['server/discover', 'resources/list', 'resources/list']);
    await client.close();
  });

  test('MCP modern unsupported version error does not downgrade', () async {
    final methods = <String>[];
    await expectLater(
        createMcpClient(McpServer.http('demo', url: 'https://example.com/mcp'), httpClient: MockClient((r) async {
          final j = jsonDecode(r.body) as Map;
          methods.add(j['method'] as String);
          return http.Response(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': j['id'],
                'error': {'code': -32022, 'message': 'Unsupported version'}
              }),
              400);
        })),
        throwsA(isA<McpException>().having((e) => e.code, 'code', -32022)));
    expect(methods, ['server/discover']);
  });

  test('MCP falls back to initialize when the probe is rejected with legacy versions listed', () async {
    final methods = <String>[];
    final client = await createMcpClient(McpServer.http('scholarxiv', url: 'https://www.scholarxiv.com/api/mcp'),
        httpClient: MockClient((r) async {
      final j = jsonDecode(r.body) as Map;
      methods.add('${j['method']}');
      if (j['method'] == 'server/discover') {
        expect(r.headers['MCP-Protocol-Version'] ?? r.headers['mcp-protocol-version'], '2026-07-28');
        return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': null,
              'error': {
                'code': -32000,
                'message': 'Bad Request: Unsupported protocol version: 2026-07-28 (supported versions: 2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05, 2024-10-07)'
              }
            }),
            400);
      }
      if (j['method'] == 'initialize') {
        expect(r.headers['MCP-Protocol-Version'] ?? r.headers['mcp-protocol-version'], '2025-03-26');
        return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': j['id'],
              'result': {
                'protocolVersion': '2025-03-26',
                'capabilities': {'tools': {}},
                'serverInfo': {'name': 'ScholarXiv'}
              }
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('', 202);
    }));
    expect(client.serverName, 'ScholarXiv');
    expect(client.protocolVersion, '2025-03-26');
    expect(methods, ['server/discover', 'initialize', 'notifications/initialized']);
    await client.close();
  });

  test('redirects show the final MCP URL without forwarding credentials', () async {
    var requests = 0;
    await expectLater(
        createMcpClient(
            McpServer.http('scholarxiv', url: 'https://scholarxiv.com/api/mcp', headers: {'Authorization': 'Bearer test-secret'}),
            httpClient: MockClient((r) async {
          requests++;
          expect(r.followRedirects, isFalse);
          return http.Response('{"redirect":"https://www.scholarxiv.com/api/mcp","status":"307"}', 307,
              headers: {'location': 'https://www.scholarxiv.com/api/mcp'});
        })),
        throwsA(isA<McpException>()
            .having(
                (e) => e.message, 'message', allOf(contains('https://www.scholarxiv.com/api/mcp'), contains('Update the saved server URL')))
            .having((e) => e.statusCode, 'status', 307)));
    expect(requests, 1);
  });

  test('missing MCP credentials preserve the server authentication instructions', () async {
    await expectLater(
        createMcpClient(McpServer.http('scholarxiv', url: 'https://www.scholarxiv.com/api/mcp'),
            httpClient: MockClient((r) async =>
                http.Response('{"error":"API Key is required. Pass it via Authorization: Bearer sxv_... or the x-api-key header."}', 401))),
        throwsA(isA<AiException>()
            .having((e) => e.isAuthError, 'authentication error', isTrue)
            .having((e) => e.message, 'message', contains('Authorization: Bearer sxv_'))));
  });

  test('MCP stdio starts a real server, discovers tools and executes one', () async {
    final client = await createMcpClient(McpServer.stdio('fixture', command: 'dart', args: ['test/fixtures/mcp_server.dart']));
    try {
      expect(client.serverName, 'stdio-fixture');
      expect((await client.listTools()).single.name, 'echo');
      expect(await client.callTool('echo', {'message': 'hello'}), {'message': 'hello'});
    } finally {
      await client.close();
    }
  });

  test('management tools install, check, inspect, use and remove MCP on the same tool list', () async {
    // This test drives a local fixture server, which the agent may only add when allowed.
    final registry = McpRegistry(persist: false)..allowAgentStdio = true;
    final tools = {for (final t in await registry.managementTools()) t.name: t};
    expect(
        tools.keys,
        containsAll([
          'mcp_search',
          'mcp_list_servers',
          'mcp_install_catalog',
          'mcp_install',
          'mcp_is_installed',
          'mcp_uninstall',
          'mcp_list_tools',
          'mcp_call_tool',
          'mcp_list_resources',
          'mcp_read_resource',
          'mcp_list_prompts',
          'mcp_get_prompt'
        ]));
    await tools['mcp_install']!.execute!({
      'server': {
        'id': 'on-demand',
        'transport': 'stdio',
        'command': 'dart',
        'args': ['test/fixtures/mcp_server.dart'],
      }
    });
    expect(await tools['mcp_is_installed']!.execute!({'id': 'on-demand'}), {'id': 'on-demand', 'installed': true});
    expect((await tools['mcp_list_servers']!.execute!({}) as Map)['servers'], hasLength(1));
    final listed = await tools['mcp_list_tools']!.execute!({'server': 'on-demand'}) as Map;
    expect((listed['tools'] as List).single['inputSchema'], {'type': 'object'});
    expect(
        await tools['mcp_call_tool']!.execute!({
          'server': 'on-demand',
          'name': 'echo',
          'arguments': {'value': 42}
        }),
        {'value': 42});
    expect(await tools['mcp_uninstall']!.execute!({'id': 'on-demand'}), {'id': 'on-demand', 'removed': true});
    expect(await tools['mcp_is_installed']!.execute!({'id': 'on-demand'}), {'id': 'on-demand', 'installed': false});
    expect(tools['mcp_install']!.approval, ApprovalPolicy.always);
    expect(tools['mcp_uninstall']!.approval, ApprovalPolicy.always);
    await registry.dispose();
  });

  test('MCP toolkit resolves on-demand tools without contacting installed servers', () async {
    var requests = 0;
    final registry = McpRegistry(
        persist: false,
        httpClient: MockClient((r) async {
          requests++;
          return http.Response('Unexpected connection', 500);
        }));
    await registry.install(McpServer.http('saved', url: 'https://example.com/mcp'));
    final tools = await registry.asToolkit().tools();
    await tools.firstWhere((t) => t.name == 'mcp_list_servers').execute!({});
    expect(requests, 0);
    expect(tools.map((t) => t.name), contains('mcp_call_tool'));
    await registry.dispose();
  });

  test('skill tools install, check, load and remove on demand', () async {
    final registry = SkillRegistry(persist: false);
    final tools = {for (final t in await registry.tools()) t.name: t};
    expect(
        tools.keys,
        containsAll([
          'preview_skill',
          'is_skill_installed',
          'list_skills',
          'search_skills',
          'load_skill',
          'read_skill_file',
          'install_skill',
          'uninstall_skill'
        ]));
    await tools['install_skill']!.execute!({'source': '---\nname: on-demand\ndescription: A test procedure\n---\nDo it carefully.'});
    expect(await tools['is_skill_installed']!.execute!({'name': 'on-demand'}), {'name': 'on-demand', 'installed': true});
    expect((await tools['load_skill']!.execute!({'name': 'on-demand'}) as Map)['instructions'], 'Do it carefully.');
    await tools['uninstall_skill']!.execute!({'name': 'on-demand'});
    expect(await tools['is_skill_installed']!.execute!({'name': 'on-demand'}), {'name': 'on-demand', 'installed': false});
  });

  test('hosts can disable automatic installed-skill exposure', () async {
    final ai = OmniAI(loadSavedKeys: false, keyStore: MemoryKeyStore());
    await ai.skills.add(Skill(name: 'private-skill', description: 'Private procedure', content: 'Secret body.'));
    final agent = ai.agent(toolkits: [], useInstalledSkills: false);
    expect((await agent.resolveTools()).where((t) => t.name == 'load_skill'), isEmpty);
    expect(await agent.systemPrompt(), isNot(contains('private-skill')));
  });

  test('Streamable HTTP returns without waiting for an SSE connection to close', () async {
    var cancelled = false;
    final stream = StreamController<List<int>>(onCancel: () {
      cancelled = true;
    });
    final net = _StreamingClient((r) async {
      final j = jsonDecode((r as http.Request).body) as Map;
      if (j['method'] == 'initialize') {
        return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode({
              'jsonrpc': '2.0',
              'id': j['id'],
              'result': {'protocolVersion': '2025-03-26', 'capabilities': {}}
            }))),
            200);
      }
      if (j['method'] == 'notifications/initialized') return http.StreamedResponse(const Stream.empty(), 202);
      stream.add(utf8.encode('data: ${jsonEncode({
            'jsonrpc': '2.0',
            'id': j['id'],
            'result': {'tools': []}
          })}\n\n'));
      return http.StreamedResponse(stream.stream, 200, headers: {'content-type': 'text/event-stream'});
    });
    final client =
        await createMcpClient(McpServer(id: 'stream', url: 'https://example.com/mcp', protocolVersionDiscovery: false), httpClient: net);
    expect(await client.listTools().timeout(const Duration(seconds: 2)), isEmpty);
    expect(cancelled, isTrue);
    await client.close();
    await stream.close();
  });

  test('MCP config retains registry headers, package versions and arguments', () {
    final remote = McpCatalogHit.fromJson({
      'name': 'acme/docs',
      'remotes': [
        {
          'type': 'streamable-http',
          'url': 'https://example.com/mcp',
          'headers': [
            {'name': 'Authorization', 'value': 'Bearer {token}', 'isRequired': true}
          ]
        }
      ]
    }).toServer(headers: {'token': 't-1'});
    expect(remote.headers['Authorization'], 'Bearer t-1');
    final local = McpCatalogHit.fromJson({
      'name': 'acme/files',
      'packages': [
        {
          'registryType': 'npm',
          'identifier': '@acme/files',
          'version': '1.2.3',
          'packageArguments': [
            {'type': 'named', 'name': '--root', 'value': '/workspace'}
          ]
        }
      ]
    }).toServer();
    expect(local.args, ['-y', '@acme/files@1.2.3', '--root', '/workspace']);
  });

  test('MCP configuration migrates to secure storage and survives reload', () async {
    final server = McpServer.http('saved', url: 'https://example.com/mcp', headers: {'Authorization': 'secret'});
    SharedPreferences.setMockInitialValues({
      'omni_ai.mcp.servers': jsonEncode([server.toJson()])
    });
    final store = MemoryKeyStore();
    final registry = McpRegistry(store: store);
    expect((await registry.list()).single.headers['Authorization'], 'secret');
    expect((await SharedPreferences.getInstance()).getString('omni_ai.mcp.servers'), isNull);
    final reloaded = McpRegistry(store: store);
    expect((await reloaded.list()).single.id, 'saved');
  });

  testWidgets('manual remote setup saves an endpoint and authorization without editing JSON', (tester) async {
    final ai = OmniAI(loadSavedKeys: false, keyStore: MemoryKeyStore());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ExtensionsView(ai: ai, mcp: true))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add server manually'));
    await tester.pumpAndSettle();
    Finder field(String label) => find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == label);
    await tester.enterText(field('Server id'), 'scholarxiv');
    await tester.enterText(field('MCP endpoint URL'), 'www.scholarxiv.com/api/mcp');
    await tester.ensureVisible(field('Authorization header (optional)'));
    await tester.enterText(field('Authorization header (optional)'), 'Bearer sxv_test');
    await tester.tap(find.text('Save server'));
    await tester.pumpAndSettle();
    final server = (await ai.mcp.list()).single;
    expect(server.id, 'scholarxiv');
    expect(server.transport, McpTransportKind.http);
    expect(server.url, 'https://www.scholarxiv.com/api/mcp');
    expect(server.headers, {'Authorization': 'Bearer sxv_test'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('Extensions searches skills and servers and displays installed capabilities', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final ai = OmniAI(
        loadSavedKeys: false,
        keyStore: MemoryKeyStore(),
        httpClient: MockClient((r) async {
          if (r.url.path == '/api/search') {
            return http.Response(
                jsonEncode({
                  'skills': [
                    {'name': 'flutter-guide', 'source': 'acme/skills', 'skillId': 'flutter-guide', 'installs': 100}
                  ]
                }),
                200);
          }
          return http.Response(
              jsonEncode({
                'servers': [
                  {
                    'server': {
                      'name': 'acme/docs',
                      'remotes': [
                        {'type': 'streamable-http', 'url': 'https://example.com/mcp'}
                      ]
                    }
                  }
                ]
              }),
              200);
        }));
    await ai.skills.add(Skill(name: 'installed', description: 'Installed instructions', content: 'Do the task.'));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ExtensionsView(ai: ai))));
    await tester.pumpAndSettle();
    expect(find.text('installed'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'flutter');
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    expect(find.text('flutter-guide'), findsOneWidget);
    await tester.tap(find.text('MCP servers'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    expect(find.text('acme/docs'), findsOneWidget);
    await tester.tap(find.text('Configure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save server'));
    await tester.pumpAndSettle();
    expect((await ai.mcp.list()).single.url, 'https://example.com/mcp');
    expect(tester.takeException(), isNull);
  });
}

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.respond);
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => respond(request);
}
