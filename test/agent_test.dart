import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omni_ai/omni_ai.dart';

/// A model that answers each call with the next scripted step.
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

OmniAI testAi() => OmniAI(keyStore: MemoryKeyStore(), loadSavedKeys: false);

void main() {
  group('Agent', () {
    test('runs tools, asks approval once per session, and keeps history', () async {
      var asked = 0;
      var ran = 0;
      final model = ScriptedModel([
        [
          call('send_note', {'text': 'hi'})
        ],
        [const TextDelta('Sent.')],
        [
          call('send_note', {'text': 'again'}, 'c2')
        ],
        [const TextDelta('Sent again.')],
      ]);
      final agent = Agent(
        name: 'notes',
        ai: testAi(),
        languageModel: model,
        tools: [
          Tool(
            name: 'send_note',
            description: 'Sends a note',
            parameters: Schema.object({'text': Schema.string()}),
            approval: ApprovalPolicy.once,
            execute: (i) {
              ran++;
              return {'sent': i['text']};
            },
          ),
        ],
        onToolApproval: (_) async {
          asked++;
          return true;
        },
      );
      final session = agent.session();
      final run1 = session.send('Send hi');
      final parts = await run1.fullStream.toList();
      expect(await run1.text, 'Sent.');
      expect(parts.whereType<ToolApprovalRequest>(), hasLength(1));
      expect(parts.whereType<ToolApprovalResponse>().single.approved, isTrue);

      expect(await session.send('Again').text, 'Sent again.');
      expect(asked, 1, reason: 'once: the second call runs without asking');
      expect(ran, 2);
      expect(session.history.where((m) => m.role == Role.user), hasLength(2));
      expect(model.requests.last.messages.where((m) => m.role == Role.tool), hasLength(2));
    });

    test('a refused tool goes back to the model as an error', () async {
      final model = ScriptedModel([
        [call('delete_all', {})],
        [const TextDelta('Okay, I did not delete anything.')],
      ]);
      final agent = Agent(
        name: 'cautious',
        ai: testAi(),
        languageModel: model,
        tools: [Tool(name: 'delete_all', description: 'Deletes', approval: ApprovalPolicy.always, execute: (_) => fail('must not run'))],
        onToolApproval: (_) async => false,
      );
      final r = await agent.run('Delete everything').result;
      expect(r.toolResults.single.isError, isTrue);
      expect(r.text, contains('did not delete'));
    });

    test('delegates to a subagent and relays its progress', () async {
      final child = ScriptedModel([
        [const TextDelta('Paris is the capital.')],
      ]);
      final parent = ScriptedModel([
        [
          call('agent_geo', {'message': 'What is the capital of France?'})
        ],
        [const TextDelta('The helper says: Paris.')],
      ]);
      final ai = testAi();
      final geo = Agent(name: 'geo', description: 'Answers geography questions.', ai: ai, languageModel: child);
      final boss = Agent(name: 'boss', ai: ai, languageModel: parent, subagents: [geo]);

      final run = boss.run('Capital of France?');
      final parts = await run.fullStream.toList();
      final r = await run.result;
      expect(r.text, 'The helper says: Paris.');
      expect(r.toolResults.single.output, {'task_id': 'geo_1', 'result': 'Paris is the capital.'});
      expect(child.requests.single.messages.last.text, 'What is the capital of France?');
      expect(parts.whereType<SubagentUpdate>().any((u) => u.part is TextDelta), isTrue);
      expect(parent.requests.first.tools.map((t) => t.name), contains('agent_geo'));
    });

    test('skills are listed in the prompt and loaded on demand; memory is recalled', () async {
      final store = InMemoryStore();
      await store.save('u1', 'Prefers metric units.');
      final model = ScriptedModel([
        [
          call('load_skill', {'name': 'forecast'})
        ],
        [
          call('remember', {'content': 'Lives in Addis Ababa.'})
        ],
        [const TextDelta('Noted.')],
      ]);
      final agent = Agent(
        name: 'weather',
        ai: testAi(),
        languageModel: model,
        instructions: 'You help with weather.',
        skills: [Skill.parse('forecast', '---\ndescription: Use for forecasts.\n---\nAlways give highs and lows.')],
        memory: AgentMemory(store: store, scope: 'u1'),
      );
      final r = await agent.run('Forecast?').result;
      final system = model.requests.first.messages.first.text;
      expect(system, contains('- forecast: Use for forecasts.'));
      expect(system, contains('Prefers metric units.'));
      expect(r.toolResults.first.output, {'skill': 'forecast', 'instructions': 'Always give highs and lows.'});
      expect((await store.list('u1')).map((m) => m.text), contains('Lives in Addis Ababa.'));
    });

    test('stops at the token limit', () async {
      final model = ScriptedModel([
        for (var i = 0; i < 10; i++) [call('current_time', {}, 't$i')],
      ]);
      final agent = Agent(
        name: 'loop',
        ai: testAi(),
        languageModel: model,
        toolkits: [BasicToolkit(fetch: false)],
        limits: const AgentLimits(maxTokens: 250),
      );
      final r = await agent.run('Loop').result;
      expect(r.steps, hasLength(3), reason: '110 tokens a step: stops once 250 is reached');
    });

    test('hooks can answer for a tool', () async {
      final model = ScriptedModel([
        [
          call('calculate', {'expression': '1+1'})
        ],
        [const TextDelta('done')],
      ]);
      final agent = Agent(
        name: 'hooked',
        ai: testAi(),
        languageModel: model,
        toolkits: [BasicToolkit(fetch: false)],
        hooks: AgentHooks(beforeToolCall: (c) => c.name == 'calculate' ? {'result': 42} : null),
      );
      final r = await agent.run('?').result;
      expect(r.toolResults.single.output, {'result': 42});
    });

    test('sessions save and restore', () async {
      final model = ScriptedModel([
        [const TextDelta('Hello!')],
      ]);
      final agent = Agent(name: 'a', ai: testAi(), languageModel: model);
      final s = agent.session();
      await s.send('Hi').result;
      final restored = AgentSession.fromJson(agent, jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(restored.history.map((m) => m.text), ['Hi', 'Hello!']);
    });
  });

  group('Memory', () {
    test('teleai-style memory: remember, update, forget, list, and recall in the prompt', () async {
      final mem = AgentMemory(store: InMemoryStore(), scope: 'u1');
      final tools = {for (final t in await mem.tools()) t.name: t};
      final saved = await tools['remember']!.execute!({
        'content': 'Likes jazz',
        'tags': ['music'],
      }) as Map;
      final id = saved['memory_id'] as String;
      expect(await mem.prompt(), contains('$id: Likes jazz [music]'));
      expect(
          await tools['update_memory']!.execute!({'memory_id': id, 'content': 'Likes jazz and blues'}), {'updated': true, 'memory_id': id});
      final listed = await tools['list_memories']!.execute!({'query': 'music'}) as Map;
      expect((listed['memories'] as List).single['content'], 'Likes jazz and blues');
      expect(await tools['forget_memory']!.execute!({'memory_id': id}), {'forgotten': true});
      expect(await tools['forget_memory']!.execute!({'memory_id': id}), {'error': 'No memory with that id.'});
      expect(await mem.recall(), isNull);
    });

    test('native memory tool: view, create, str_replace, insert, rename, delete', () async {
      final kit = MemoryFilesToolkit(store: InMemoryFileStore());
      final memory = (await kit.tools()).single;
      Future<String> m(Map<String, dynamic> i) async => await memory.execute!(i) as String;

      expect(await m({'command': 'view', 'path': '/memories'}), contains('(empty)'));
      expect(await m({'command': 'create', 'path': '/memories/notes/prefs.md', 'file_text': 'Name: Abebe\nLikes: tea'}),
          'File created successfully at: /memories/notes/prefs.md');
      expect(await m({'command': 'view', 'path': '/memories'}), contains('/memories/notes/'));
      expect(await m({'command': 'str_replace', 'path': '/memories/notes/prefs.md', 'old_str': 'tea', 'new_str': 'coffee'}),
          'The memory file has been edited.');
      await m({'command': 'insert', 'path': '/memories/notes/prefs.md', 'insert_line': 1, 'insert_text': 'City: Addis'});
      expect(await m({'command': 'view', 'path': '/memories/notes/prefs.md'}), contains('     2\tCity: Addis\n     3\tLikes: coffee'));
      expect(await m({'command': 'rename', 'old_path': '/memories/notes', 'new_path': '/memories/user'}), contains('Successfully renamed'));
      expect(await m({'command': 'view', 'path': '/memories/user/prefs.md'}), contains('Name: Abebe'));
      expect(await m({'command': 'delete', 'path': '/memories/user'}), 'Successfully deleted /memories/user');
      expect(await m({'command': 'view', 'path': '/memories/user/prefs.md'}), contains('does not exist'));
    });

    test('native memory tool refuses paths outside /memories', () async {
      expect(MemoryFilesToolkit.clean('/memories/../etc/passwd'), isNull);
      expect(MemoryFilesToolkit.clean('/etc/passwd'), isNull);
      expect(MemoryFilesToolkit.clean('memories/a.md'), '/memories/a.md');
      final memory = (await MemoryFilesToolkit(store: InMemoryFileStore()).tools()).single;
      expect(await memory.execute!({'command': 'create', 'path': '/memories/../x', 'file_text': 'x'}), startsWith('Error'));
    });

    test('plain generateText takes toolkits: tools run and memories reach the prompt', () async {
      final store = InMemoryStore();
      await store.save('default', 'Prefers short answers.');
      final model = ScriptedModel([
        [
          call('calculate', {'expression': '6*7'})
        ],
        [const TextDelta('42')],
      ]);
      final r = await generateText(
        model: model,
        system: 'Be helpful.',
        prompt: 'What is 6*7?',
        toolkits: [BasicToolkit(fetch: false), AgentMemory(store: store)],
        maxSteps: 3,
      );
      expect(r.text, '42');
      expect(r.toolResults.single.output, {'result': 42});
      final system = model.requests.first.messages.first;
      expect(system.role, Role.system);
      expect(system.text, startsWith('Be helpful.'));
      expect(system.text, contains('Prefers short answers.'));
      expect(model.requests.first.tools.map((t) => t.name), containsAll(['calculate', 'remember', 'list_memories']));
    });

    test('OmniAI.allToolkits has the basics, memory and keyed toolkits', () async {
      final ai = OmniAI(keyStore: MemoryKeyStore(), loadSavedKeys: false, e2bKey: 'k');
      expect(ai.allToolkits.map((t) => t.id), ['basic', 'e2b', 'memory']);
      expect(ai.services.map((s) => s.id), isNot(contains('memory')));
    });
  });

  group('Toolkits', () {
    test('basic: calculator and html to text', () {
      expect(BasicToolkit.calculate('(12.5 * 4) ^ 2 / 2'), 1250);
      expect(BasicToolkit.calculate('-3 + 10 % 4'), -1);
      expect(BasicToolkit.htmlToText('<p>Hi&nbsp;<b>there</b></p><script>x()</script>'), 'Hi there');
    });

    test('Exa web_search sends the key and shapes results', () async {
      final client = MockClient((req) async {
        expect(req.url.toString(), 'https://api.exa.ai/search');
        expect(req.headers['x-api-key'], 'exa-key');
        final body = jsonDecode(req.body) as Map;
        expect(body['query'], 'flutter 4');
        expect(body['includeDomains'], ['flutter.dev']);
        return http.Response(
            jsonEncode({
              'results': [
                {
                  'url': 'https://flutter.dev/x',
                  'title': 'Flutter 4',
                  'highlights': ['Released today'],
                },
              ],
            }),
            200);
      });
      final exa = ExaToolkit(apiKey: 'exa-key', httpClient: client);
      final search = (await exa.tools()).firstWhere((t) => t.name == 'web_search');
      final out = await search.execute!({
        'query': 'flutter 4',
        'include_domains': ['flutter.dev'],
      }) as Map;
      expect((out['results'] as List).single, {
        'url': 'https://flutter.dev/x',
        'title': 'Flutter 4',
        'highlights': ['Released today'],
      });
    });

    test('E2B runs code in a sandbox and hands charts to the app', () async {
      var created = 0;
      final png = base64Encode([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
      final client = MockClient((req) async {
        if (req.url.path == '/v2/sandboxes' && req.method == 'POST') {
          created++;
          expect(req.headers['X-API-KEY'], 'e2b-key');
          return http.Response(jsonEncode({'sandboxID': 'sb1', 'envdAccessToken': 'tok'}), 201);
        }
        expect(req.url.host, '49999-sb1.e2b.app');
        expect(req.headers['X-Access-Token'], 'tok');
        return http.Response(
          [
            jsonEncode({'type': 'stdout', 'text': '42\n'}),
            jsonEncode({'type': 'result', 'png': png, 'is_main_result': false}),
            jsonEncode({'type': 'result', 'text': '6 * 7', 'is_main_result': true}),
          ].join('\n'),
          200,
        );
      });
      final e2b = E2BToolkit(apiKey: 'e2b-key', httpClient: client);
      final model = ScriptedModel([
        [
          call('run_code', {'code': 'print(6*7)'})
        ],
        [
          call('run_code', {'code': 'plt.show()'}, 'c2')
        ],
        [const TextDelta('The answer is 42.')],
      ]);
      final run = Agent(name: 'coder', ai: testAi(), languageModel: model, toolkits: [e2b]).run('Compute');
      final parts = await run.fullStream.toList();
      final r = await run.result;
      expect(created, 1, reason: 'the sandbox is reused');
      expect(r.toolResults.first.output, {
        'stdout': '42\n',
        'results': [
          {'text': '6 * 7'},
        ],
        'images': '1 image shown to the user.',
      });
      expect(parts.whereType<FileOutput>().first.file.mediaType, 'image/png');
    });

    test('Composio asks approval for writes but not reads', () async {
      final ran = <String>[];
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/tool_router/session')) return http.Response(jsonEncode({'session_id': 's1'}), 200);
        if (req.url.path.endsWith('/s1/execute')) {
          final b = jsonDecode(req.body) as Map;
          ran.add('${b['tool_slug']}');
          return http.Response(
              jsonEncode({
                'data': {'ok': true}
              }),
              200);
        }
        return http.Response('{}', 404);
      });
      final composio = ComposioToolkit(apiKey: 'ak_x', userId: 'u1', httpClient: client);
      final approvals = <String>[];
      final model = ScriptedModel([
        [
          call('run_app_action', {'slug': 'GMAIL_FETCH_EMAILS', 'arguments': {}}, 'a'),
          call(
              'run_app_action',
              {
                'slug': 'GMAIL_SEND_EMAIL',
                'arguments': {'to': 'x@y.z'},
              },
              'b'),
        ],
        [const TextDelta('Done.')],
      ]);
      await Agent(
        name: 'mail',
        ai: testAi(),
        languageModel: model,
        toolkits: [composio],
        onToolApproval: (c) async {
          approvals.add('${c.input['slug']}');
          return true;
        },
      ).run('Read and send').result;
      expect(approvals, ['GMAIL_SEND_EMAIL']);
      expect(ran.toSet(), {'GMAIL_FETCH_EMAILS', 'GMAIL_SEND_EMAIL'});
    });

    test('Cloudflare resolves zones by name and makes R2 links', () async {
      final client = MockClient((req) async {
        expect(req.headers['Authorization'], 'Bearer cf-token');
        if (req.url.path == '/client/v4/zones' && req.url.queryParameters['name'] == 'example.com') {
          return http.Response(
              jsonEncode({
                'success': true,
                'result': [
                  {'id': 'a' * 32},
                ],
              }),
              200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response(
            jsonEncode({
              'success': true,
              'result': [
                {'id': 'r1', 'type': 'A', 'name': 'example.com', 'content': '1.2.3.4'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'});
      });
      final cf = CloudflareToolkit(
        token: 'cf-token',
        r2: const R2Credentials(accountId: 'acc', accessKeyId: 'AK', secretAccessKey: 'SK'),
        httpClient: client,
      );
      final dns = (await cf.tools()).firstWhere((t) => t.name == 'cloudflare_dns_records');
      final out = await dns.execute!({'zone': 'example.com'}) as Map;
      expect((out['records'] as List).single['content'], '1.2.3.4');
      final link = cf.client.presign('files', 'a b/c.txt');
      expect(link, startsWith('https://acc.r2.cloudflarestorage.com/files/a%20b/c.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256'));
      expect(link, contains('X-Amz-Signature='));
      expect((await cf.tools()).firstWhere((t) => t.name == 'cloudflare_set_dns_record').approval, ApprovalPolicy.always);
    });

    test('OmniAI saves toolkit keys and gives agents the configured toolkits', () async {
      final store = MemoryKeyStore();
      final ai = OmniAI(keyStore: store, loadSavedKeys: false);
      await ai.setApiKey('exa', 'exa-key');
      expect(await store.read('key.exa'), 'exa-key');
      expect(ai.apiKey('exa'), 'exa-key');
      final agent = ai.agent();
      expect(agent.toolkits.map((t) => t.id), ['basic', 'exa', 'memory']);
      expect(ai.services.map((s) => s.id), containsAll(['gateway', 'exa', 'e2b', 'composio', 'cloudflare']));

      final ai2 = OmniAI(keyStore: store);
      await ai2.ready;
      expect(ai2.exa.apiKey, 'exa-key');
    });
  });
}
