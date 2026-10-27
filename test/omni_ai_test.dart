import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omni_ai/omni_ai.dart';

String sse(List<Object> events) => '${events.map((e) => 'data: ${e is String ? e : jsonEncode(e)}\n\n').join()}data: [DONE]\n\n';

Map<String, dynamic> chunk(Map<String, dynamic> delta, {String? finish}) => {
      'choices': [
        {'index': 0, 'delta': delta, 'finish_reason': finish},
      ],
    };

void main() {
  group('OpenAI-compatible streaming + tool loop', () {
    test('streams reasoning and text, runs a tool, answers with its result', () async {
      final bodies = <Map<String, dynamic>>[];
      final client = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        bodies.add(body);
        expect(req.headers['Authorization'], 'Bearer test-key');
        if (bodies.length == 1) {
          return http.Response(
            sse([
              chunk({'reasoning': 'Need weather. '}),
              chunk({
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_1',
                    'function': {'name': 'weather', 'arguments': '{"ci'},
                  },
                ],
              }),
              chunk({
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': 'ty":"Addis"}'},
                  },
                ],
              }, finish: 'tool_calls'),
              {
                'choices': [],
                'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
              },
            ]),
            200,
          );
        }
        return http.Response(
          sse([
            chunk({'content': 'It is '}),
            chunk({'content': 'sunny.'}, finish: 'stop'),
            {
              'choices': [],
              'usage': {'prompt_tokens': 20, 'completion_tokens': 3, 'cost': 0.001},
            },
          ]),
          200,
        );
      });

      final provider = VercelGatewayProvider(apiKey: 'test-key', httpClient: client);
      final weather = Tool(
        name: 'weather',
        description: 'Weather for a city',
        parameters: Schema.object({'city': Schema.string()}),
        execute: (input) => {'city': input['city'], 'sky': 'sunny'},
      );

      final result = streamText(
        model: provider.languageModel('openai/gpt-5'),
        prompt: 'Weather in Addis?',
        tools: [weather],
        maxSteps: 3,
        reasoning: ReasoningEffort.low,
      );
      final text = await result.textStream.join();
      final r = await result.result;

      expect(text, 'It is sunny.');
      expect(r.text, 'It is sunny.');
      expect(r.reasoning, 'Need weather. ');
      expect(r.steps, hasLength(2));
      expect(r.toolCalls.single.input, {'city': 'Addis'});
      expect(r.toolResults.single.output, {'city': 'Addis', 'sky': 'sunny'});
      expect(r.usage.inputTokens, 30);
      expect(r.usage.cost, 0.001);
      expect(r.responseMessages.map((m) => m.role), [Role.assistant, Role.tool, Role.assistant]);

      // First request: tools, reasoning and gateway caching.
      expect(bodies[0]['tools'], isNotEmpty);
      expect(bodies[0]['reasoning'], {'effort': 'low'});
      expect(bodies[0]['providerOptions']['gateway']['caching'], 'auto');
      // Second request carries the call and its result.
      final msgs = bodies[1]['messages'] as List;
      expect(msgs[1]['tool_calls'][0]['function']['name'], 'weather');
      expect(msgs[2], {'role': 'tool', 'tool_call_id': 'call_1', 'content': '{"city":"Addis","sky":"sunny"}'});
    });

    test('retries without reasoning options when the provider refuses them', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        final body = jsonDecode(req.body) as Map;
        if (body.containsKey('reasoning_effort')) return http.Response('{"error":{"message":"bad param"}}', 400);
        return http.Response(
            sse([
              chunk({'content': 'ok'}, finish: 'stop')
            ]),
            200);
      });
      final p = OpenAICompatibleProvider(id: 'x', name: 'X', baseUrl: 'http://x/v1', apiKey: 'k', httpClient: client);
      final r = await generateText(model: p.languageModel('m'), prompt: 'hi', reasoning: ReasoningEffort.high);
      expect(r.text, 'ok');
      expect(calls, 2);
    });

    test('tools without execute stop the loop and return the calls', () async {
      final client = MockClient((_) async => http.Response(
            sse([
              chunk({
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'c',
                    'function': {'name': 'ask_user', 'arguments': '{}'},
                  },
                ],
              }, finish: 'tool_calls'),
            ]),
            200,
          ));
      final p = OpenAICompatibleProvider(id: 'x', name: 'X', baseUrl: 'http://x/v1', apiKey: 'k', httpClient: client);
      final r = await generateText(
        model: p.languageModel('m'),
        prompt: 'hi',
        tools: [Tool(name: 'ask_user', description: 'Ask')],
        maxSteps: 5,
      );
      expect(r.steps, hasLength(1));
      expect(r.toolCalls.single.name, 'ask_user');
      expect(r.finishReason, FinishReason.toolCalls);
    });

    test('a missing key throws a clear error', () async {
      final p = VercelGatewayProvider();
      expect(
        () => generateText(model: p.languageModel('openai/gpt-5'), prompt: 'hi'),
        throwsA(isA<MissingApiKeyException>()),
      );
    });

    test('an API error becomes a readable AiException', () async {
      final client = MockClient((_) async => http.Response('{"error":{"message":"Invalid API key"}}', 401));
      final p = VercelGatewayProvider(apiKey: 'bad', httpClient: client);
      try {
        await generateText(model: p.languageModel('openai/gpt-5'), prompt: 'hi');
        fail('should throw');
      } on AiException catch (e) {
        expect(e.statusCode, 401);
        expect(e.isAuthError, isTrue);
        expect(e.message, contains('Invalid API key'));
      }
    });
  });

  group('Google Gemini', () {
    test('streams thoughts, text and function calls, and sends thought signatures back', () async {
      final bodies = <Map<String, dynamic>>[];
      final client = MockClient((req) async {
        expect(req.url.path, endsWith('/models/gemini-2.5-flash:streamGenerateContent'));
        expect(req.headers['x-goog-api-key'], 'g-key');
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        if (bodies.length == 1) {
          return http.Response.bytes(
            utf8.encode(sse([
              {
                'candidates': [
                  {
                    'content': {
                      'role': 'model',
                      'parts': [
                        {'text': 'Thinking…', 'thought': true},
                        {
                          'functionCall': {
                            'name': 'add',
                            'args': {'a': 2, 'b': 3},
                          },
                          'thoughtSignature': 'sig-1',
                        },
                      ],
                    },
                    'finishReason': 'STOP',
                  },
                ],
                'usageMetadata': {'promptTokenCount': 7, 'candidatesTokenCount': 4},
              },
            ])),
            200,
          );
        }
        return http.Response(
          sse([
            {
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'The sum is 5.'},
                    ],
                  },
                  'finishReason': 'STOP',
                },
              ],
            },
          ]),
          200,
        );
      });
      final google = GoogleProvider(apiKey: 'g-key', httpClient: client);
      final r = await generateText(
        model: google.languageModel('gemini-2.5-flash'),
        system: 'Be exact.',
        prompt: 'Add 2 and 3',
        tools: [
          Tool(
            name: 'add',
            description: 'Adds',
            parameters: Schema.object({'a': Schema.number(), 'b': Schema.number()}),
            execute: (i) => (i['a'] as num) + (i['b'] as num),
          ),
        ],
        maxSteps: 3,
      );
      expect(r.text, 'The sum is 5.');
      expect(r.reasoning, 'Thinking…');
      expect(bodies[0]['systemInstruction']['parts'][0]['text'], 'Be exact.');
      expect(bodies[0]['tools'][0]['functionDeclarations'][0]['name'], 'add');
      final second = bodies[1]['contents'] as List;
      final modelTurn = second[1] as Map;
      expect(modelTurn['role'], 'model');
      final call = (modelTurn['parts'] as List).firstWhere((p) => (p as Map).containsKey('functionCall')) as Map;
      expect(call['thoughtSignature'], 'sig-1');
      final response = (second[2]['parts'] as List).first as Map;
      expect(response['functionResponse'], {
        'name': 'add',
        'response': {'result': 5},
      });
    });

    test('finds media anywhere in an interaction', () {
      final items = GoogleProvider.mediaItems({
        'steps': [
          {
            'type': 'model_output',
            'content': [
              {'type': 'text', 'text': 'Here you go'},
              {'type': 'image', 'mime_type': 'image/png', 'data': 'iVBORw0KGgo='},
            ],
          },
        ],
      }, 'image');
      expect(items.single['mime_type'], 'image/png');
    });
  });

  group('Addis AI', () {
    test('streams native response_text chunks with history', () async {
      late Map<String, dynamic> body;
      final client = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(req.headers['x-api-key'], 'a-key');
        return http.Response.bytes(
          utf8.encode('${jsonEncode({'response_text': 'ሰላም'})}\n${jsonEncode({'response_text': '!', 'is_last_chunk': true})}\n'),
          200,
        );
      });
      final addis = AddisAiProvider(apiKey: 'a-key', httpClient: client);
      final r = await generateText(
        model: addis.languageModel('addis-chat'),
        messages: [Message.user('hi'), Message.assistant('hello'), Message.user('ሰላም')],
      );
      expect(r.text, 'ሰላም!');
      expect(body['prompt'], 'ሰላም');
      expect(body['target_language'], 'am');
      expect(body['conversation_history'], hasLength(2));
    });
  });

  group('helpers', () {
    test('partial JSON closes open strings and objects', () {
      expect(parsePartialJson('{"name": "Ab'), {'name': 'Ab'});
      expect(parsePartialJson('{"a": 1, "list": [1, 2'), {
        'a': 1,
        'list': [1, 2],
      });
      expect(parsePartialJson('{"a": 1, "b'), {'a': 1});
      expect(parsePartialJson('```json\n{"x": true}\n```'), {'x': true});
      expect(parsePartialJson('nothing'), isNull);
    });

    test('extractJson finds JSON among words', () {
      expect(extractJson('Sure! {"ok": true} Hope that helps'), {'ok': true});
    });

    test('model refs pick the provider by prefix', () {
      final ids = {'gateway', 'google', 'lmstudio'};
      expect(parseModelRef('google:gemini-2.5-flash', providers: ids, defaultProvider: 'gateway'),
          (provider: 'google', modelId: 'gemini-2.5-flash'));
      expect(parseModelRef('openai/gpt-5', providers: ids, defaultProvider: 'gateway'), (provider: 'gateway', modelId: 'openai/gpt-5'));
      // A colon that isn't a provider stays in the id (OpenRouter's :free).
      expect(
          parseModelRef('meta/llama:free', providers: ids, defaultProvider: 'gateway'), (provider: 'gateway', modelId: 'meta/llama:free'));
    });

    test('OmniAI resolves models and keys', () async {
      final ai = OmniAI(googleKey: 'g', keyStore: MemoryKeyStore(), loadSavedKeys: false);
      final m = ai.languageModel('google:gemini-2.5-pro');
      expect(m.provider, 'google');
      expect(m.modelId, 'gemini-2.5-pro');
      // With no model given, a configured provider's default is used.
      expect(ai.languageModel().modelId, 'gemini-2.5-flash');
      expect(ai.apiKey('google'), 'g');
      await ai.setApiKey('lmstudio', '192.168.1.5:1234/v1/', persist: false);
      expect(ai.lmStudio.baseUrl, 'http://192.168.1.5:1234/v1');
    });

    test('PCM becomes a playable WAV', () {
      final wav = pcmToWav(Uint8List(48000));
      expect(sniffMediaType(wav), 'audio/wav');
      expect(wav.length, 48044);
    });

    test('usage adds up across providers', () {
      final u =
          Usage.fromJson({'prompt_tokens': 3, 'completion_tokens': 2}) + Usage.fromJson({'promptTokenCount': 4, 'candidatesTokenCount': 1});
      expect(u.inputTokens, 7);
      expect(u.outputTokens, 3);
    });

    test('cosine similarity', () {
      expect(cosineSimilarity([1, 0], [1, 0]), closeTo(1, 1e-9));
      expect(cosineSimilarity([1, 0], [0, 1]), closeTo(0, 1e-9));
    });

    test('models.dev enriches a bare model', () {
      final dev = ModelsDev.parse(jsonEncode({
        'vercel': {
          'models': {
            'openai/gpt-5': {
              'name': 'GPT-5',
              'reasoning': true,
              'tool_call': true,
              'limit': {'context': 400000, 'output': 128000},
              'cost': {'input': 1.25, 'output': 10},
              'modalities': {
                'input': ['text', 'image'],
                'output': ['text'],
              },
            },
          },
        },
      }));
      final m = ModelsDev.enrich(
        const ModelInfo(provider: 'gateway', modelId: 'openai/gpt-5', name: 'openai/gpt-5'),
        dev.lookup('vercel', 'openai/gpt-5'),
      );
      expect(m.name, 'GPT-5');
      expect(m.contextLabel, '400K');
      expect(m.priceLabel, r'$1.25 / $10');
      expect(m.vision, isTrue);
      expect(m.reasoning, isTrue);
    });
  });

  group('AI SDK UI message stream', () {
    test('builds text, reasoning and tool parts', () async {
      final client = MockClient((req) async {
        expect((jsonDecode(req.body) as Map)['messages'][0]['parts'][0]['text'], 'Hi');
        return http.Response(
          sse([
            {'type': 'start', 'messageId': 'm1'},
            {'type': 'start-step'},
            {'type': 'reasoning-start', 'id': 'r'},
            {'type': 'reasoning-delta', 'id': 'r', 'delta': 'hmm'},
            {'type': 'reasoning-end', 'id': 'r'},
            {'type': 'tool-input-start', 'toolCallId': 't1', 'toolName': 'search'},
            {
              'type': 'tool-input-available',
              'toolCallId': 't1',
              'toolName': 'search',
              'input': {'q': 'x'},
            },
            {'type': 'tool-output-available', 'toolCallId': 't1', 'output': 'found'},
            {'type': 'text-start', 'id': 't'},
            {'type': 'text-delta', 'id': 't', 'delta': 'Hel'},
            {'type': 'text-delta', 'id': 't', 'delta': 'lo'},
            {'type': 'text-end', 'id': 't'},
            {
              'type': 'data-weather',
              'id': 'w',
              'data': {'temp': 20},
            },
            {'type': 'finish'},
          ]),
          200,
        );
      });
      final c = UiMessageStreamClient(Uri.parse('https://example.com/api/chat'), httpClient: client);
      final data = <UiPart>[];
      final last = await c.send([UiMessage.user('Hi')], onData: data.add).last;
      expect(last.id, 'm1');
      expect(last.text, 'Hello');
      expect(last.reasoning, 'hmm');
      expect(last.tools.single.toolName, 'search');
      expect(last.tools.single.state, 'output-available');
      expect(last.tools.single.data['output'], 'found');
      expect(data.single.type, 'data-weather');
    });
  });
}
