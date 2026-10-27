import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../catalog/model_info.dart';
import '../core/cancel.dart';
import '../core/errors.dart';
import '../core/media.dart';
import '../core/models.dart';
import '../core/usage.dart';
import 'openai_compatible.dart';
import 'provider.dart';

/// Vercel AI Gateway: hundreds of models from every lab behind one key.
///
/// Model ids look like `openai/gpt-5`, `anthropic/claude-sonnet-4.5`,
/// `google/gemini-2.5-flash`. Get a key at https://vercel.com/ai-gateway.
class VercelGatewayProvider extends OpenAICompatibleProvider {
  /// [appName] and [appUrl] attribute requests to your app in the
  /// gateway's dashboard.
  VercelGatewayProvider({
    super.apiKey,
    this.promptCaching = true,
    String? appName,
    String? appUrl,
    super.httpClient,
  }) : super(
          id: 'gateway',
          name: 'Vercel AI Gateway',
          baseUrl: 'https://ai-gateway.vercel.sh/v1',
          headers: {
            if (appUrl != null) 'http-referer': appUrl,
            if (appName != null) 'x-title': appName,
          },
          supportedTypes: const {
            ModelType.text,
            ModelType.image,
            ModelType.speech,
            ModelType.transcription,
            ModelType.video,
            ModelType.embedding,
          },
        );

  static const aiUrl = 'https://ai-gateway.vercel.sh/v4/ai';

  /// Let the gateway add cache markers itself (cheaper repeat prompts).
  bool promptCaching;

  @override
  String get apiKeyUrl => 'https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fai%2Fapi-keys&title=Get+an+AI+Gateway+API+key';
  @override
  String get docsUrl => 'https://vercel.com/docs/ai-gateway';
  @override
  String get modelsDevId => 'vercel';

  @override
  Map<ModelType, String> get defaultModels => const {
        ModelType.text: 'openai/gpt-5-mini',
        ModelType.image: 'google/gemini-2.5-flash-image',
        ModelType.speech: 'openai/gpt-4o-mini-tts',
        ModelType.transcription: 'google/gemini-2.5-flash',
        ModelType.embedding: 'openai/text-embedding-3-small',
      };

  @override
  Map<String, dynamic> reasoningBody(String modelId, ReasoningEffort? effort) => switch (effort) {
        null => const {},
        ReasoningEffort.none => const {
            'reasoning': {'enabled': false},
          },
        _ => {
            'reasoning': {'effort': effort.name},
          },
      };

  @override
  Map<String, dynamic> extraBody(String modelId, LanguageModelRequest request) => promptCaching
      ? const {
          'providerOptions': {
            'gateway': {'caching': 'auto'},
          },
        }
      : const {};

  /// Multimodal chat models (Gemini image models) make images through
  /// chat; image-only models (gpt-image, Flux, Imagen…) through
  /// `/images/generations`.
  @override
  bool chatImages(String modelId) => modelId.startsWith('google/gemini');

  @override
  SpeechModel speechModel(String modelId) => _GatewaySpeech(this, modelId);

  /// Gateway models that hear audio transcribe it (default: Gemini Flash).
  @override
  TranscriptionModel transcriptionModel(String modelId) => ChatTranscriptionModel(languageModel(modelId));

  @override
  VideoModel videoModel(String modelId) => _GatewayVideo(this, modelId);

  Map<String, String> aiHeaders(String modelId, String spec) => {
        ...authHeaders(),
        'Content-Type': 'application/json',
        'ai-gateway-protocol-version': '0.0.1',
        'ai-gateway-auth-method': 'api-key',
        'ai-$spec-model-specification-version': '4',
        'ai-model-id': modelId,
      };

  /// The full catalog with prices, context sizes and modalities. Needs no key.
  @override
  Future<List<ModelInfo>> listModels({CancelToken? cancelToken}) async {
    final j = net.json(await net.get(Uri.parse('$baseUrl/models'), cancelToken: cancelToken));
    final out = <ModelInfo>[];
    for (final m in ((j as Map)['data'] as List? ?? const []).whereType<Map>()) {
      final id = '${m['id']}';
      final type = '${m['type'] ?? 'language'}';
      final pricing = (m['pricing'] as Map?) ?? const {};
      final mods = (m['modalities'] as Map?) ?? const {};
      final tags = [for (final t in (m['tags'] as List? ?? const [])) '$t'];
      final types = switch (type) {
        'image' => {ModelType.image},
        'speech' => {ModelType.speech},
        'transcription' => {ModelType.transcription},
        'video' => {ModelType.video},
        'embedding' => {ModelType.embedding},
        _ => {ModelType.text},
      };
      final input = [
        for (final x in (mods['input'] as List? ?? const ['text'])) '$x'
      ];
      final output = [
        for (final x in (mods['output'] as List? ??
            switch (type) {
              'image' => const ['image'],
              'speech' => const ['audio'],
              'video' => const ['video'],
              _ => const ['text'],
            }))
          '$x',
      ];
      if (types.contains(ModelType.text) && input.contains('audio')) types.add(ModelType.transcription);
      out.add(ModelInfo(
        provider: this.id,
        modelId: id,
        name: '${m['name'] ?? id}',
        lab: '${m['owned_by'] ?? id.split('/').first}',
        types: types,
        description: '${m['description'] ?? ''}',
        contextWindow: (m['context_window'] as num?)?.toInt(),
        maxOutput: (m['max_tokens'] as num?)?.toInt(),
        inputPrice: _perMillion(pricing['input']),
        outputPrice: _perMillion(pricing['output']),
        cacheReadPrice: _perMillion(pricing['input_cache_read']),
        imagePrice: double.tryParse('${pricing['image'] ?? ''}'),
        inputModalities: input,
        outputModalities: output,
        reasoning: tags.contains('reasoning'),
        toolCall: tags.contains('tool-use'),
        openWeights: tags.contains('open-weights'),
        releaseDate: _released(m['released']),
        tags: tags,
        voices: [for (final v in (m['voices'] as List? ?? const [])) '$v'],
      ));
    }
    return out;
  }

  /// A tiny chat call; the model list needs no key so can't check one.
  @override
  Future<String?> verify() async {
    try {
      final r = await net.post(
        Uri.parse(chatUrl),
        headers: authHeaders(),
        json: {
          'model': 'openai/gpt-4o-mini',
          'messages': [
            {'role': 'user', 'content': 'Reply with OK'},
          ],
          'max_tokens': 2,
        },
        timeout: const Duration(seconds: 30),
      );
      if (r.statusCode == 401 || r.statusCode == 403) return net.apiError(r.statusCode, r.body).message;
      return null;
    } on AiException catch (e) {
      return e.message;
    }
  }

  /// Credits left on the account: `{balance, total_used}`.
  Future<Map<String, dynamic>> credits() async =>
      Map<String, dynamic>.from(net.json(await net.get(Uri.parse('$baseUrl/credits'), headers: authHeaders())) as Map);

  @override
  Future<List<Voice>> listVoices({String? modelId, String? language, CancelToken? cancelToken}) async {
    final models = await listModels(cancelToken: cancelToken);
    return [
      for (final m in models.where((m) => m.types.contains(ModelType.speech) && (modelId == null || m.modelId == modelId)))
        for (final v in m.voices) Voice(id: v, name: _title(v), provider: id, description: m.name),
    ];
  }
}

String _title(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

double? _perMillion(Object? v) {
  final d = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
  return d == null ? null : d * 1e6;
}

String? _released(Object? unix) {
  final n = unix is num ? unix : num.tryParse('${unix ?? ''}');
  if (n == null || n <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch((n * 1000).toInt(), isUtc: true).toIso8601String().substring(0, 10);
}

class _GatewaySpeech implements SpeechModel {
  _GatewaySpeech(this.p, this.modelId);
  final VercelGatewayProvider p;
  @override
  final String modelId;
  @override
  String get provider => p.id;

  @override
  Future<GeneratedFile> speak(SpeechRequest r, {CancelToken? cancelToken}) async {
    final j = p.net.json(await p.net.post(
      Uri.parse('${VercelGatewayProvider.aiUrl}/speech-model'),
      headers: p.aiHeaders(modelId, 'speech'),
      body: jsonEncode(deepMerge({
        'text': r.text,
        if (r.voice != null && r.voice!.isNotEmpty) 'voice': r.voice,
        if (r.instructions != null) 'instructions': r.instructions,
        if (r.language != null) 'language': r.language,
        'outputFormat': r.outputFormat ?? 'mp3',
        if (r.speed != null) 'speed': r.speed,
      }, r.providerOptions)),
      cancelToken: cancelToken,
    ));
    final audio = j is Map ? j['audio'] : null;
    if (audio is! String || audio.isEmpty) throw AiException('The voice model returned no audio.', provider: p.id);
    return GeneratedFile.fromBase64(audio);
  }
}

/// Video jobs: start, then poll; older deployments answer one long SSE call.
class _GatewayVideo implements VideoModel {
  _GatewayVideo(this.p, this.modelId);
  final VercelGatewayProvider p;
  @override
  final String modelId;
  @override
  String get provider => p.id;

  static String size(String label, String aspect) {
    final h = switch (label) {
      '1080p' => 1080,
      '720p' => 720,
      _ => 480,
    };
    final w = (h * 16 / 9 / 2).round() * 2;
    return switch (aspect) {
      '9:16' => '${h}x$w',
      '1:1' => '${h}x$h',
      _ => '${w}x$h',
    };
  }

  @override
  Future<GeneratedFile> generate(VideoRequest r, {CancelToken? cancelToken}) async {
    final aspect = r.aspectRatio ?? '16:9';
    final body = deepMerge({
      'prompt': r.prompt,
      'n': 1,
      'aspectRatio': aspect,
      if (r.duration != null) 'duration': r.duration,
      if (r.resolution != null) 'resolution': size(r.resolution!, aspect),
      if (r.audio != null) 'generateAudio': r.audio,
      if (r.negativePrompt != null) 'negativePrompt': r.negativePrompt,
      if (r.image != null) 'image': {'type': 'base64', 'data': base64Encode(r.image!), 'mediaType': sniffMediaType(r.image!)},
    }, r.providerOptions);
    final start = await p.net.post(
      Uri.parse('${VercelGatewayProvider.aiUrl}/video-model/start'),
      headers: p.aiHeaders(modelId, 'video'),
      body: jsonEncode(body),
      timeout: const Duration(seconds: 60),
      cancelToken: cancelToken,
    );
    if (start.statusCode == 404) return _sync(body, cancelToken);
    final operation = (p.net.json(start) as Map)['operation'];
    final deadline = DateTime.now().add(r.timeout);
    r.onStatus?.call('Queued');
    while (DateTime.now().isBefore(deadline)) {
      await _wait(const Duration(seconds: 5), cancelToken);
      final j = p.net.json(await p.net.post(
        Uri.parse('${VercelGatewayProvider.aiUrl}/video-model/status'),
        headers: p.aiHeaders(modelId, 'video'),
        body: jsonEncode({'operation': operation}),
        timeout: const Duration(seconds: 30),
        cancelToken: cancelToken,
      )) as Map;
      switch (j['status']) {
        case 'completed':
          return _result(j['videos'], cancelToken);
        case 'error' || 'failed' || 'cancelled':
          throw AiException('Video generation failed: ${j['error'] ?? j['status']}', provider: p.id);
      }
      r.onStatus?.call('Rendering');
    }
    throw AiException('The video took too long. Try a shorter clip or a faster model.', provider: p.id);
  }

  Future<GeneratedFile> _sync(Map<String, dynamic> body, CancelToken? token) async {
    final req = http.Request('POST', Uri.parse('${VercelGatewayProvider.aiUrl}/video-model'))
      ..headers.addAll({...p.aiHeaders(modelId, 'video'), 'accept': 'text/event-stream'})
      ..body = jsonEncode(body);
    await for (final line in p.net.lines(req, cancelToken: token, connectTimeout: const Duration(minutes: 10))) {
      if (!line.startsWith('data:')) continue;
      final j = jsonDecode(line.substring(5).trim());
      if (j is Map && j['type'] == 'error') {
        throw AiException('${j['message'] ?? 'Video generation failed'}', provider: p.id, statusCode: (j['statusCode'] as num?)?.toInt());
      }
      if (j is Map && j['type'] == 'result') return _result(j['videos'], token);
    }
    throw AiException('The video model returned nothing.', provider: p.id);
  }

  Future<GeneratedFile> _result(Object? videos, CancelToken? token) async {
    if (videos is! List || videos.isEmpty) throw AiException('The video model returned no video.', provider: p.id);
    final v = videos.first as Map;
    final mime = '${v['mediaType'] ?? 'video/mp4'}';
    if (v['type'] == 'base64' || v['data'] is String) return GeneratedFile.fromBase64(v['data'] as String, mediaType: mime);
    return downloadFile(p.net, '${v['url']}', cancelToken: token, mediaType: mime);
  }
}

/// Waits, but wakes early (and throws) on cancel.
Future<void> _wait(Duration d, CancelToken? token) async {
  if (token == null) return Future.delayed(d);
  await Future.any([Future.delayed(d), token.whenCancelled]);
  if (token.isCancelled) throw const AiCancelledException();
}

/// Exposed for other providers' polling loops.
Future<void> pollDelay(Duration d, CancelToken? token) => _wait(d, token);
