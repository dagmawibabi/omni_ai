import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omni_ai/omni_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Trimmed from a real `GET https://opencode.ai/inference/openai/v1/models`.
const _models = {
  'object': 'list',
  'data': [
    {
      'id': 'big-pickle',
      'name': 'Big Pickle',
      'type': 'chat',
      'owned_by': 'opencode',
      'modalities': {
        'input': ['text'],
        'output': ['text'],
      },
      'cost': {
        'text': {
          'input': {'price': 0},
          'output': {'price': 0},
        },
      },
    },
    {
      'id': 'glm-5.3-flash',
      'canonical_id': 'zhipuai/glm-5.3-flash',
      'name': 'GLM-5.3 Flash',
      'type': 'chat',
      'owned_by': 'opencode',
      'family': 'glm',
      'description': 'Fast GLM',
      'open_weights': true,
      'release_date': '2026-09-01',
      'knowledge': '2026-03',
      'modalities': {
        'input': ['text', 'image/jpeg', 'image/png', 'video/mp4'],
        'output': ['text'],
      },
      'capabilities': {
        'tools': {'supported': true},
        'reasoning': {'supported': true},
        'structured_output': true,
        'temperature': true,
      },
      'limit': {'context': 200000, 'output': 32000},
      'cost': {
        'text': {
          'input': {
            'price': 0.15,
            'cache': {'read': 0.03, 'write': 0},
          },
          'output': {'price': 0.5},
        },
      },
      'api': {
        'chat-completions': {'base_url': 'https://opencode.ai/inference/openai/v1'},
      },
    },
    {
      'id': 'claude-sonnet-5-5',
      'canonical_id': 'anthropic/claude-sonnet-5-5',
      'name': 'Claude Sonnet 5.5',
      'type': 'chat',
      'modalities': {
        'input': ['text', 'image/png', 'application/pdf'],
        'output': ['text'],
      },
      'capabilities': {
        'tools': {'supported': true},
        'reasoning': {'supported': true},
        'temperature': false,
      },
      'cost': {
        'text': {
          'input': {'price': 2},
          'output': {'price': 10},
        },
      },
      'api': {'messages': {}},
    },
    {
      'id': 'deepseek-v4.1-flash-free',
      'name': 'DeepSeek V4.1 Flash Free',
      'type': 'chat',
      'cost': {
        'text': {
          'input': {'price': 0},
          'output': {'price': 0},
        },
      },
    },
  ],
};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('OpenCodeProvider', () {
    test('lists paid models with prices, limits and features', () async {
      final seen = <http.Request>[];
      final p = OpenCodeProvider(
        apiKey: 'oc-key',
        httpClient: MockClient((r) async {
          seen.add(r);
          return _json(_models);
        }),
      );
      final models = await p.listModels();

      expect(seen.single.url.toString(), 'https://opencode.ai/inference/openai/v1/models');
      expect(seen.single.headers['Authorization'], 'Bearer oc-key');
      expect(models.map((m) => m.modelId), ['glm-5.3-flash', 'claude-sonnet-5-5']);

      final glm = models.first;
      expect(glm.provider, 'opencode');
      expect(glm.name, 'GLM-5.3 Flash');
      expect(glm.lab, 'zhipuai');
      expect(glm.family, 'glm');
      expect(glm.contextWindow, 200000);
      expect(glm.maxOutput, 32000);
      expect(glm.inputPrice, 0.15);
      expect(glm.outputPrice, 0.5);
      expect(glm.cacheReadPrice, 0.03);
      expect(glm.inputModalities, ['text', 'image', 'video']);
      expect(glm.attachment, isTrue);
      expect(glm.reasoning, isTrue);
      expect(glm.toolCall, isTrue);
      expect(glm.structuredOutput, isTrue);
      expect(glm.openWeights, isTrue);
      expect(glm.knowledge, '2026-03');

      final claude = models.last;
      expect(claude.lab, 'anthropic');
      expect(claude.inputModalities, ['text', 'image', 'pdf']);
      expect(claude.temperature, isFalse);
      expect(claude.structuredOutput, isFalse);
    });

    test('includeFree lists the OpenCode-only free models, tagged', () async {
      final p = OpenCodeProvider(includeFree: true, httpClient: MockClient((_) async => _json(_models)));
      final models = await p.listModels();
      expect(models.map((m) => m.modelId), contains('big-pickle'));
      expect(models.firstWhere((m) => m.modelId == 'deepseek-v4.1-flash-free').tags, ['free']);
      expect(models.firstWhere((m) => m.modelId == 'glm-5.3-flash').tags, isEmpty);
    });

    test('lists models without a key (the list is public)', () async {
      final seen = <http.Request>[];
      final p = OpenCodeProvider(httpClient: MockClient((r) async {
        seen.add(r);
        return _json(_models);
      }));
      expect(await p.listModels(), hasLength(2));
      expect(seen.single.headers.containsKey('Authorization'), isFalse);
    });

    test('verify reports a missing key and a refused one', () async {
      final noKey = OpenCodeProvider(httpClient: MockClient((_) async => _json(_models)));
      expect(await noKey.verify(), contains('OpenCode Zen'));

      final bad = OpenCodeProvider(
        apiKey: 'wrong',
        httpClient: MockClient((_) async => _json({
              'error': {'type': 'authentication_error', 'message': 'Invalid credential'},
            }, 401)),
      );
      expect(await bad.verify(), isNotNull);

      final good = OpenCodeProvider(apiKey: 'oc-key', httpClient: MockClient((_) async => _json(_models)));
      expect(await good.verify(), isNull);
    });

    test('chat goes to Chat Completions with the bare model id', () async {
      late http.Request sent;
      final ai = OmniAI(
        openCodeKey: 'oc-key',
        loadSavedKeys: false,
        keyStore: MemoryKeyStore(),
        httpClient: MockClient((r) async {
          sent = r;
          final events = [
            {
              'choices': [
                {'index': 0, 'delta': {'role': 'assistant', 'content': 'Hello!'}},
              ],
            },
            {
              'choices': [
                {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
              ],
              'usage': {'prompt_tokens': 3, 'completion_tokens': 2, 'total_tokens': 5},
            },
          ];
          return http.Response(
            '${events.map((e) => 'data: ${jsonEncode(e)}\n\n').join()}data: [DONE]\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      final r = await ai.generateText(model: 'opencode:claude-sonnet-5-5', prompt: 'Hi');

      expect(r.text, 'Hello!');
      expect(sent.url.toString(), 'https://opencode.ai/inference/openai/v1/chat/completions');
      expect(sent.headers['Authorization'], 'Bearer oc-key');
      expect((jsonDecode(sent.body) as Map)['model'], 'claude-sonnet-5-5');
    });

    test('is registered on OmniAI and takes a key like the others', () async {
      final ai = OmniAI(loadSavedKeys: false, keyStore: MemoryKeyStore());
      expect(ai.provider('opencode'), same(ai.openCode));
      expect(ai.openCode.isConfigured, isFalse);
      await ai.setApiKey('opencode', 'oc-key', persist: false);
      expect(ai.apiKey('opencode'), 'oc-key');
      expect(ai.openCode.isConfigured, isTrue);
      expect(ai.openCode.defaultModels[ModelType.text], 'glm-5.3-flash');
    });
  });
}
