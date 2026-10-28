import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omni_ai/omni_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Jev', () {
    test('decide parses noul, choice, score and box; boolean maps to noul', () async {
      final client = MockClient((req) async {
        expect(req.url.path, '/v1/systemone');
        expect(req.headers['authorization'], 'Bearer ts_test');
        expect(req.headers['typesafe-danger-zone-images'], 'true');
        expect(req.headers['typesafe-danger-zone-long-context'], 'true');
        expect(req.headers['idempotency-key'], 'job-1');
        final body = jsonDecode(req.body) as Map;
        expect(body['model'], 'jev-1.14.0');
        expect((body['questions'] as Map)['urgent']['type'], 'noul');
        expect((body['questions'] as Map)['team']['type'], 'choice');
        return http.Response(
          jsonEncode({
            'model': 'jev-1.14.0',
            'answers': {
              'urgent': {'type': 'noul', 'noul': 0.91},
              'team': {
                'type': 'choice',
                'choice': 'billing',
                'confidence': 0.8,
                'probabilities': {'billing': 0.8, 'other': 0.2},
              },
              'severity': {
                'type': 'score',
                'score': 1.4,
                'confidence': 0.7,
                'legend': {'0': 'low', '1': 'mid', '2': 'high'},
                'probabilities': {'0': 0.1, '1': 0.4, '2': 0.5},
              },
              'mug': {
                'type': 'box',
                'box': {'top': 0.1, 'bottom': 0.5, 'left': 0.2, 'right': 0.8},
                'confidence': 0.9,
              },
            },
            'usage': {'input_tokens': 40, 'output_tokens': 8},
          }),
          200,
          headers: {'x-typesafe-request-id': 'req_1'},
        );
      });

      final jev = JevClient(apiKey: 'ts_test', httpClient: client);
      final d = await jev.decide(
        state: 'Charged twice. Photo: pic',
        model: 'jev-1.14.0',
        longContext: true,
        idempotencyKey: 'job-1',
        images: {
          'pic': JevImage([1, 2, 3], format: 'jpg')
        },
        questions: {
          'urgent': JevQuestion.fromJson({'type': 'boolean', 'instructions': 'Urgent?'}),
          'team': JevQuestion.choice('Team?', {'billing': 'money', 'other': 'else'}),
          'severity': JevQuestion.score('How bad?', ['low', 'mid', 'high']),
          'mug': JevQuestion.box('the mug in pic'),
        },
      );

      expect(d.model, 'jev-1.14.0');
      expect(d.requestId, 'req_1');
      expect(d['urgent']!.noul, 0.91);
      expect(d['urgent']!.isTrue(0.5), isTrue);
      expect(d['team']!.choice, 'billing');
      expect(d['team']!.selectedProbability, 0.8);
      expect(d['severity']!.score, 1.4);
      expect(d['mug']!.location!.left, 0.2);
    });

    test('noul helper and toolkit tools', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/models')) {
          return http.Response(
              jsonEncode({
                'models': ['jev-latest', 'jev-1.14.0']
              }),
              200);
        }
        final body = jsonDecode(req.body) as Map;
        final qs = body['questions'] as Map;
        final id = qs.keys.first;
        return http.Response(
          jsonEncode({
            'model': 'jev-latest',
            'answers': {
              id: {'type': 'noul', 'noul': 0.2},
            },
            'usage': {'input_tokens': 10, 'output_tokens': 1},
          }),
          200,
        );
      });
      final kit = JevToolkit(apiKey: 'k', httpClient: client, threshold: 0.5);
      final a = await kit.client.noul('hello', 'Is this angry?');
      expect(a.isTrue(), isFalse);
      final tools = await kit.tools();
      expect(tools.map((t) => t.name), containsAll(['jev_decide', 'jev_noul', 'jev_choice', 'jev_score', 'jev_box', 'jev_models']));
      final models = await tools.firstWhere((t) => t.name == 'jev_models').execute!({});
      expect(models, {
        'models': ['jev-latest', 'jev-1.14.0']
      });
    });

    test('jev_batch asks the same questions about many items in one tool call', () async {
      var inFlight = 0, peak = 0, calls = 0;
      final client = MockClient((req) async {
        calls++;
        inFlight++;
        if (inFlight > peak) peak = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        inFlight--;
        final body = jsonDecode(req.body) as Map;
        final state = '${body['state']}';
        if (state == 'boom') return http.Response('{"error":"bad"}', 400);
        final positive = state.contains('love');
        return http.Response(
          jsonEncode({
            'model': 'jev-latest',
            'answers': {
              'sentiment': {
                'type': 'choice',
                'choice': positive ? 'positive' : 'negative',
                'probabilities': {'positive': positive ? 0.9 : 0.2, 'negative': positive ? 0.1 : 0.8},
              },
              'spam': {'type': 'noul', 'noul': 0.1},
            },
            'usage': {'input_tokens': 5, 'output_tokens': 0},
          }),
          200,
        );
      });
      final kit = JevToolkit(apiKey: 'k', httpClient: client)..client.maxRetries = 0;
      final tool = (await kit.tools()).firstWhere((t) => t.name == 'jev_batch');
      final items = [
        for (var i = 0; i < 9; i++) {'id': 'm$i', 'state': i.isEven ? 'I love it' : 'This is awful'},
        'boom',
      ];
      final out = await tool.execute!({
        'items': items,
        'questions': {
          'sentiment': {
            'type': 'choice',
            'instructions': 'What is the sentiment?',
            'criteria': {'positive': 'Happy', 'negative': 'Unhappy'},
          },
          'spam': {'type': 'noul', 'instructions': 'Is it spam?'},
        },
      }) as Map;
      expect(calls, 10);
      expect(peak, lessThanOrEqualTo(4));
      expect(peak, greaterThan(1));
      expect(out['count'], 10);
      expect(out['failed'], 1);
      final results = out['results'] as List;
      expect(results.first, {
        'id': 'm0',
        'answers': {
          'sentiment': {'choice': 'positive', 'confidence': 0.9},
          'spam': {'yes': false, 'p': 0.1},
        },
      });
      expect((results.last as Map)['id'], '10');
      expect((results.last as Map)['error'], isNotNull);
      expect(out['totals']['sentiment']['counts'], {'positive': 5, 'negative': 4});
      expect(out['totals']['spam'], {'type': 'noul', 'no': 9});
      expect(out['usage'], {'input_tokens': 45});
      final tooMany = await tool.execute!({
        'items': List.filled(JevToolkit.maxBatchItems + 1, 'x'),
        'questions': {'spam': {'type': 'noul', 'instructions': 'Is it spam?'}},
      }) as Map;
      expect(tooMany['error'], contains('At most'));
    });

    test('Jev questions accept options the way models send them', () {
      final fromOptions = JevQuestion.fromJson({
        'type': 'choice',
        'instructions': 'Sentiment?',
        'options': {'positive': 'good news', 'negative': 'bad news'},
      });
      expect(fromOptions.criteria, {'positive': 'good news', 'negative': 'bad news'});
      expect(JevQuestion.fromJson({'type': 'choice', 'instructions': 'x', 'criteria': ['a', 'b']}).criteria, {'a': '', 'b': ''});
      expect(JevQuestion.fromJson({'type': 'choice', 'instructions': 'x', 'criteria': 'a, b'}).criteria, {'a': '', 'b': ''});
      expect(JevQuestion.fromJson({'type': 'choice', 'instructions': 'x', 'criteria': '{"a": "A"}'}).criteria, {'a': 'A'});
      expect(
          JevQuestion.fromJson({
            'type': 'choice',
            'instructions': 'x',
            'choices': [
              {'name': 'a', 'description': 'A'},
              'b'
            ]
          }).criteria,
          {'a': 'A', 'b': ''});
      expect(JevQuestion.fromJson({'type': 'score', 'instructions': 'x', 'levels': 'low, high'}).criteria, ['low', 'high']);
      expect(() => JevQuestion.fromJson({'type': 'choice', 'instructions': 'x'}),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message', contains('"criteria": {"positive"'))));
    });

    test('Jev tools take pictures and JSON state', () async {
      final png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0];
      final bodies = <Map>[];
      final headers = <Map<String, String>>[];
      final client = MockClient((req) async {
        bodies.add(jsonDecode(req.body) as Map);
        headers.add(req.headers);
        final q = ((jsonDecode(req.body) as Map)['questions'] as Map).keys.first;
        return http.Response(
          jsonEncode({
            'model': 'jev-preview',
            'answers': {
              q: {'type': 'noul', 'noul': 0.9}
            },
            'usage': {'input_tokens': 7, 'output_tokens': 0},
          }),
          200,
        );
      });
      final kit = JevToolkit(apiKey: 'k', httpClient: client)
        ..resolveImage = (ref) async => ref == 'beach.png' ? png : null;
      final tools = {for (final t in await kit.tools()) t.name: t};

      final out = await tools['jev_noul']!.execute!({
        'state': '{"caption": "Sunny day"}',
        'instructions': 'Is it outdoors?',
        'images': {'img1': 'beach.png'},
      }) as Map;
      expect(out['yes'], isTrue);
      expect(out['model'], 'jev-preview');
      expect(bodies.last['model'], 'jev-preview');
      final id = (bodies.last['assets'] as Map).keys.single as String;
      expect(id, startsWith('img-'));
      expect(bodies.last['state'], {'caption': 'Sunny day', 'images': id});
      expect(bodies.last['assets'][id]['format'], 'png');
      expect(headers.last['TypeSafe-Danger-Zone-Images'] ?? headers.last['typesafe-danger-zone-images'], 'true');

      // JSON written as text goes as JSON; no pictures, the chosen model.
      await tools['jev_decide']!.execute!({
        'state': '[1, 2, 3]',
        'questions': {
          'big': {'type': 'noul', 'instructions': 'Is the sum over 5?'}
        },
      });
      expect(bodies.last['state'], [1, 2, 3]);
      expect(bodies.last['model'], 'jev-latest');
      expect(bodies.last.containsKey('assets'), isFalse);

      // A batch with a picture per item.
      final batch = await tools['jev_batch']!.execute!({
        'items': [
          {'id': 'a', 'state': 'photo one', 'images': {'p': 'beach.png'}},
          {'id': 'b', 'state': 'photo two', 'images': {'p': 'beach.png'}},
        ],
        'questions': {
          'outdoor': {'type': 'noul', 'instructions': 'Outdoors?'}
        },
      }) as Map;
      expect(batch['count'], 2);
      // "p" isn't swapped inside "photo": the picture gets its own id.
      final pid = (bodies.last['assets'] as Map).keys.single as String;
      expect(bodies.last['state'], {'content': 'photo two', 'images': pid});

      // A name the call put in state is replaced as a whole word only.
      await tools['jev_noul']!.execute!({
        'state': {'post': 'pic of the day', 'pic': 'pic'},
        'instructions': 'Is pic a cat?',
        'images': {'pic': 'beach.png'},
      });
      final cid = (bodies.last['assets'] as Map).keys.single as String;
      expect(bodies.last['state'], {'post': 'pic of the day'.replaceFirst('pic', cid), 'pic': cid});
      expect(bodies.last['questions']['answer']['instructions'], 'Is $cid a cat?');

      final missing = tools['jev_noul']!.execute!({'state': 'x', 'instructions': 'y', 'images': ['nope.png']});
      await expectLater(missing, throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message', contains('nope.png'))));
      expect(JevImage.detect([0xFF, 0xD8, 0xFF, 0xE0])!.format, 'jpg');
      expect(JevImage.detect([0x47, 0x49, 0x46, 0x38]), isNull);
    });

    test('OmniAI.decide and setApiKey for jev', () async {
      SharedPreferences.setMockInitialValues({});
      final httpClient = MockClient((req) async => http.Response(
            jsonEncode({
              'model': 'jev-latest',
              'answers': {
                'ok': {'type': 'noul', 'noul': 0.99}
              },
              'usage': {'input_tokens': 3, 'output_tokens': 1},
            }),
            200,
          ));
      final ai = OmniAI(keyStore: MemoryKeyStore(), loadSavedKeys: false, jevKey: 'k', httpClient: httpClient);
      expect(ai.jev.isConfigured, isTrue);
      expect(ai.apiKey('jev'), 'k');
      final d = await ai.decide(state: 'hi', questions: {'ok': JevQuestion.noul('Friendly?')});
      expect(d['ok']!.isTrue(), isTrue);
      await ai.setApiKey('jev', null, persist: false);
      expect(ai.jev.isConfigured, isFalse);
    });
  });

  group('MCP', () {
    Map rpc(http.Request req) => jsonDecode(req.body) as Map;

    test('createMcpClient lists and calls tools (AI SDK style)', () async {
      final client = MockClient((req) async {
        final j = rpc(req);
        switch (j['method']) {
          case 'initialize':
            return http.Response(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': j['id'],
                'result': {
                  'protocolVersion': '2025-03-26',
                  'capabilities': {
                    'tools': {'listChanged': true}
                  },
                  'serverInfo': {'name': 'demo'},
                },
              }),
              200,
              headers: {'content-type': 'application/json', 'mcp-session-id': 's1'},
            );
          case 'notifications/initialized':
            return http.Response('', 202);
          case 'tools/list':
            return http.Response(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': j['id'],
                'result': {
                  'tools': [
                    {
                      'name': 'echo',
                      'description': 'Echoes text',
                      'inputSchema': {
                        'type': 'object',
                        'properties': {
                          'text': {'type': 'string'}
                        },
                        'required': ['text'],
                      },
                    }
                  ]
                },
              }),
              200,
            );
          case 'tools/call':
            expect(j['params']['name'], 'echo');
            return http.Response(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': j['id'],
                'result': {
                  'content': [
                    {
                      'type': 'text',
                      'text': jsonEncode({'echo': j['params']['arguments']['text']})
                    }
                  ]
                },
              }),
              200,
            );
          default:
            return http.Response('{"error":"unknown"}', 400);
        }
      });

      final mcp = await createMcpClient(McpServer.http('demo', url: 'https://example.com/mcp'), httpClient: client);
      expect(mcp.serverName, 'demo');
      final listed = await mcp.listTools();
      expect(listed.single.name, 'echo');
      final tools = await mcp.tools();
      expect(tools.single.name, 'echo');
      final result = await tools.single.execute!({'text': 'hi'});
      expect(result, {'echo': 'hi'});
      await mcp.close();
    });

    test('registry install, list, uninstall and toolkit', () async {
      SharedPreferences.setMockInitialValues({});
      var calls = 0;
      final httpClient = MockClient((req) async {
        calls++;
        final j = jsonDecode(req.body) as Map;
        if (j['method'] == 'initialize') {
          return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': j['id'],
              'result': {
                'protocolVersion': '2025-03-26',
                'capabilities': {},
                'serverInfo': {'name': 'x'}
              },
            }),
            200,
          );
        }
        if (j['method'] == 'tools/list') {
          return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': j['id'],
              'result': {
                'tools': [
                  {
                    'name': 'ping',
                    'description': 'Ping',
                    'inputSchema': {'type': 'object'}
                  }
                ]
              },
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'jsonrpc': '2.0', 'id': j['id'], 'result': {}}), 200);
      });

      final reg = McpRegistry(httpClient: httpClient, persist: false);
      await reg.install(McpServer.http('x', url: 'https://x/mcp'));
      expect((await reg.list()).single.id, 'x');
      final tools = await reg.tools();
      expect(tools.single.name, 'ping');
      final kit = (await reg.toolkits()).single;
      expect(kit.id, 'mcp_x');
      expect(await kit.verify(), isNull);
      expect(calls, greaterThan(0));
      expect(await reg.uninstall('x'), isTrue);
      expect(await reg.list(), isEmpty);
    });

    test('search official MCP registry and install a remote hit', () async {
      final httpClient = MockClient((req) async {
        if (req.url.path.endsWith('/v0.1/servers') && req.url.queryParameters['search'] == 'filesystem') {
          return http.Response(
            jsonEncode({
              'servers': [
                {
                  'server': {
                    'name': 'io.github.acme/mcp-filesystem',
                    'description': 'Files in a workspace',
                    'version': '1.2.0',
                    'packages': [
                      {
                        'registryType': 'npm',
                        'identifier': '@acme/mcp-filesystem',
                        'runtimeHint': 'npx',
                        'runtimeArguments': [
                          {'type': 'positional', 'value': '-y'}
                        ],
                      }
                    ],
                  }
                },
                {
                  'server': {
                    'name': 'com.example/docs',
                    'description': 'Docs over HTTP',
                    'version': '0.1.0',
                    'remotes': [
                      {'type': 'streamable-http', 'url': 'https://mcp.example.com/mcp'}
                    ],
                  }
                }
              ]
            }),
            200,
          );
        }
        if (req.url.path.contains('/versions/latest')) {
          return http.Response(
            jsonEncode({
              'server': {
                'name': 'com.example/docs',
                'description': 'Docs over HTTP',
                'version': '0.1.0',
                'remotes': [
                  {'type': 'streamable-http', 'url': 'https://mcp.example.com/mcp'}
                ],
              }
            }),
            200,
          );
        }
        return http.Response('nope', 404);
      });
      final reg = McpRegistry(httpClient: httpClient, persist: false);
      final hits = await reg.search('filesystem');
      expect(hits, hasLength(2));
      expect(hits.first.suggestedId, 'mcp-filesystem');
      final stdio = hits.first.toServer();
      expect(stdio.transport, McpTransportKind.stdio);
      expect(stdio.command, 'npx');
      expect(stdio.args, ['-y', '@acme/mcp-filesystem']);
      final remote = hits[1].toServer();
      expect(remote.transport, McpTransportKind.http);
      expect(remote.url, 'https://mcp.example.com/mcp');
      final installed = await reg.installFromCatalog('com.example/docs');
      expect(installed.id, 'docs');
      expect(installed.url, 'https://mcp.example.com/mcp');
    });
  });

  group('Skills', () {
    test('install from markdown, list, use, uninstall', () async {
      final reg = SkillRegistry(persist: false);
      final added = await reg.install(
        '---\nname: release-notes\ndescription: Use when asked for release notes.\n---\nList merged PRs.',
      );
      expect(added.single.name, 'release-notes');
      expect((await reg.list()).single.description, 'Use when asked for release notes.');
      expect(reg.use(names: ['release-notes']).single.content, contains('merged PRs'));
      final tools = await reg.tools();
      expect(tools.map((t) => t.name), containsAll(['list_skills', 'search_skills', 'load_skill', 'install_skill', 'uninstall_skill']));
      final loaded = await tools.firstWhere((t) => t.name == 'load_skill').execute!({'name': 'release-notes'});
      expect(loaded, {'skill': 'release-notes', 'instructions': 'List merged PRs.'});
      expect(await reg.uninstall('release-notes'), isTrue);
      expect(await reg.list(), isEmpty);
    });

    test('install from GitHub tree (mocked)', () async {
      final httpClient = MockClient((req) async {
        final url = req.url.toString();
        if (url.contains('api.github.com') && url.contains('/git/trees/')) {
          return http.Response(
            jsonEncode({
              'tree': [
                {'path': 'skills/pdf/SKILL.md', 'type': 'blob'},
                {'path': 'skills/pdf/references/tips.md', 'type': 'blob'},
              ]
            }),
            200,
          );
        }
        if (url.contains('raw.githubusercontent.com') && url.endsWith('SKILL.md')) {
          return http.Response('---\nname: pdf\ndescription: PDFs.\n---\nExtract text.', 200);
        }
        if (url.contains('tips.md')) {
          return http.Response('# tips\nUse pdfplumber.', 200);
        }
        return http.Response('nope', 404);
      });
      final reg = SkillRegistry(persist: false, httpClient: httpClient);
      final added = await reg.install('acme/skills@pdf');
      expect(added.single.name, 'pdf');
      expect(added.single.files['references/tips.md'], contains('pdfplumber'));
    });

    test('search skills.sh catalog and installHit source', () async {
      final httpClient = MockClient((req) async {
        expect(req.url.path, '/api/search');
        expect(req.url.queryParameters['q'], 'react');
        return http.Response(
          jsonEncode({
            'query': 'react',
            'skills': [
              {
                'id': 'vercel-labs/agent-skills/vercel-react-best-practices',
                'source': 'vercel-labs/agent-skills',
                'skillId': 'vercel-react-best-practices',
                'name': 'vercel-react-best-practices',
                'installs': 844260,
              }
            ]
          }),
          200,
        );
      });
      final reg = SkillRegistry(persist: false, httpClient: httpClient, searchUrl: '');
      final hits = await reg.search('react');
      expect(hits.single.installSource, 'vercel-labs/agent-skills@vercel-react-best-practices');
      expect(hits.single.installs, 844260);
    });

    test('agent loads an installed skill from the registry', () async {
      final ai = OmniAI(keyStore: MemoryKeyStore(), loadSavedKeys: false);
      await ai.skills.add(Skill.parse('forecast', '---\ndescription: Use for forecasts.\n---\nAlways give highs and lows.'));
      final model = ScriptedModel([
        [
          call('load_skill', {'name': 'forecast'})
        ],
        [const TextDelta('High 20 low 10.')],
      ]);
      final agent = Agent(name: 'weather', ai: ai, languageModel: model);
      final r = await agent.run('Forecast?').result;
      expect(r.toolResults.first.output, {'skill': 'forecast', 'instructions': 'Always give highs and lows.'});
      expect(r.text, 'High 20 low 10.');
    });
  });
}

/// Copied shape from agent_test.dart.
class ScriptedModel implements LanguageModel {
  ScriptedModel(this.steps);
  final List<List<StreamPart>> steps;
  final requests = <LanguageModelRequest>[];

  @override
  String get provider => 'test';
  @override
  String get modelId => 'scripted';

  @override
  Stream<StreamPart> stream(LanguageModelRequest request, {CancelToken? cancelToken}) async* {
    requests.add(request);
    final i = requests.length - 1;
    for (final p in i < steps.length ? steps[i] : [const TextDelta('(no more script)')]) {
      yield p;
    }
    yield const StepFinish(finishReason: FinishReason.stop, usage: Usage(inputTokens: 100, outputTokens: 10));
  }
}

ToolCall call(String name, Map<String, dynamic> input, [String? id]) =>
    ToolCall(ToolCallPart(id: id ?? 'c_$name', name: name, input: input));
