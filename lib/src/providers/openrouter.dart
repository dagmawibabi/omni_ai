import '../catalog/model_info.dart';
import '../core/cancel.dart';
import '../core/errors.dart';
import '../core/media.dart';
import '../core/models.dart';
import '../core/usage.dart';
import 'openai_compatible.dart';
import 'provider.dart';
import 'vercel_gateway.dart' show pollDelay;

/// OpenRouter: many models, free ones too, behind one key.
/// Model ids look like `anthropic/claude-sonnet-4.5` or `…:free`.
class OpenRouterProvider extends OpenAICompatibleProvider {
  OpenRouterProvider({super.apiKey, String? appName, String? appUrl, super.httpClient})
      : super(
          id: 'openrouter',
          name: 'OpenRouter',
          baseUrl: 'https://openrouter.ai/api/v1',
          headers: {
            if (appUrl != null) 'HTTP-Referer': appUrl,
            if (appName != null) 'X-Title': appName,
          },
          supportedTypes: const {
            ModelType.text,
            ModelType.image,
            ModelType.speech,
            ModelType.video,
            ModelType.embedding,
            ModelType.transcription
          },
        );

  @override
  String get apiKeyUrl => 'https://openrouter.ai/settings/keys';
  @override
  String get docsUrl => 'https://openrouter.ai/docs';
  @override
  String get modelsDevId => 'openrouter';

  @override
  Map<ModelType, String> get defaultModels => const {
        ModelType.text: 'openai/gpt-5-mini',
        ModelType.image: 'google/gemini-2.5-flash-image',
        ModelType.transcription: 'google/gemini-2.5-flash',
      };

  @override
  Map<String, dynamic> reasoningBody(String modelId, ReasoningEffort? effort) => switch (effort) {
        null => const {'include_reasoning': true},
        ReasoningEffort.none => const {
            'reasoning': {'enabled': false},
          },
        _ => {
            'reasoning': {'effort': effort.name},
          },
      };

  /// Ask OpenRouter to report each call's cost.
  @override
  Map<String, dynamic> extraBody(String modelId, LanguageModelRequest request) => const {
        'usage': {'include': true},
      };

  @override
  bool chatImages(String modelId) => true;

  @override
  TranscriptionModel transcriptionModel(String modelId) => ChatTranscriptionModel(languageModel(modelId));

  @override
  VideoModel videoModel(String modelId) => _OpenRouterVideo(this, modelId);

  @override
  Future<List<ModelInfo>> listModels({CancelToken? cancelToken}) async {
    final j = net.json(await net.get(Uri.parse('$baseUrl/models?output_modalities=all'), cancelToken: cancelToken));
    num? n(Object? v) => v is num ? v : num.tryParse('${v ?? ''}');
    final out = <ModelInfo>[];
    for (final m in ((j as Map)['data'] as List? ?? const []).whereType<Map>()) {
      final id = '${m['id']}';
      final arch = (m['architecture'] as Map?) ?? const {};
      final outMods = [
        for (final x in (arch['output_modalities'] as List? ?? const ['text'])) '$x'
      ];
      final inMods = [
        for (final x in (arch['input_modalities'] as List? ?? const ['text'])) '$x'
      ];
      final types = <ModelType>{
        if (outMods.contains('text')) ModelType.text,
        if (outMods.contains('image')) ModelType.image,
        if (outMods.contains('audio') || outMods.contains('speech')) ModelType.speech,
        if (outMods.contains('video')) ModelType.video,
        if (outMods.contains('embeddings')) ModelType.embedding,
        if (outMods.contains('text') && inMods.contains('audio')) ModelType.transcription,
      };
      if (types.isEmpty) continue;
      final pricing = (m['pricing'] as Map?) ?? const {};
      final params = [for (final x in (m['supported_parameters'] as List? ?? const [])) '$x'];
      final name = '${m['name'] ?? id}';
      final prompt = n(pricing['prompt']);
      final completion = n(pricing['completion']);
      final cache = n(pricing['input_cache_read']);
      out.add(ModelInfo(
        provider: this.id,
        modelId: id,
        name: name.contains(': ') ? name.substring(name.indexOf(': ') + 2) : name,
        lab: id.split('/').first,
        types: types,
        description: '${m['description'] ?? ''}',
        contextWindow: (m['context_length'] as num?)?.toInt(),
        maxOutput: ((m['top_provider'] as Map?)?['max_completion_tokens'] as num?)?.toInt(),
        inputPrice: prompt == null ? null : prompt * 1e6,
        outputPrice: completion == null ? null : completion * 1e6,
        cacheReadPrice: cache == null ? null : cache * 1e6,
        imagePrice: outMods.contains('image') ? (n(pricing['image_output'])?.toDouble() ?? 0) * 1290 : null,
        inputModalities: inMods,
        outputModalities: outMods,
        reasoning: params.contains('reasoning'),
        toolCall: params.contains('tools'),
        structuredOutput: params.contains('structured_outputs'),
        temperature: params.contains('temperature'),
        openWeights: '${m['hugging_face_id'] ?? ''}'.isNotEmpty,
        releaseDate: m['created'] is num
            ? DateTime.fromMillisecondsSinceEpoch(((m['created'] as num) * 1000).toInt(), isUtc: true).toIso8601String().substring(0, 10)
            : null,
        voices: [for (final v in (m['supported_voices'] as List? ?? const [])) '$v'],
      ));
    }
    return out;
  }

  @override
  Future<String?> verify() async {
    try {
      net.json(await net.get(Uri.parse('$baseUrl/key'), headers: authHeaders(), timeout: const Duration(seconds: 20)));
      return null;
    } on AiException catch (e) {
      return e.message;
    }
  }

  /// The key's limits and spend: `{usage, limit, is_free_tier…}`.
  Future<Map<String, dynamic>> keyInfo() async {
    final j = net.json(await net.get(Uri.parse('$baseUrl/key'), headers: authHeaders())) as Map;
    return Map<String, dynamic>.from((j['data'] as Map?) ?? j);
  }
}

class _OpenRouterVideo implements VideoModel {
  _OpenRouterVideo(this.p, this.modelId);
  final OpenRouterProvider p;
  @override
  final String modelId;
  @override
  String get provider => p.id;

  @override
  Future<GeneratedFile> generate(VideoRequest r, {CancelToken? cancelToken}) async {
    final start = p.net.json(await p.net.post(
      Uri.parse('${p.baseUrl}/videos'),
      headers: p.authHeaders(),
      json: deepMerge({
        'model': modelId,
        'prompt': r.prompt,
        if (r.duration != null) 'duration': r.duration,
        if (r.aspectRatio != null) 'aspect_ratio': r.aspectRatio,
        if (r.resolution != null) 'resolution': r.resolution,
        if (r.audio != null) 'generate_audio': r.audio,
        if (r.image != null) 'image': dataUrl(r.image!, sniffMediaType(r.image!, fallback: 'image/png')),
      }, r.providerOptions),
      timeout: const Duration(seconds: 60),
      cancelToken: cancelToken,
    )) as Map;
    final poll = '${start['polling_url'] ?? '${p.baseUrl}/videos/${start['id']}'}';
    final deadline = DateTime.now().add(r.timeout);
    r.onStatus?.call('Queued');
    while (DateTime.now().isBefore(deadline)) {
      await pollDelay(const Duration(seconds: 5), cancelToken);
      final j = p.net.json(await p.net.get(Uri.parse(poll), headers: p.authHeaders(), cancelToken: cancelToken)) as Map;
      final status = '${j['status'] ?? ''}';
      if (status == 'completed') {
        final signed = j['urls'] is List && (j['urls'] as List).isNotEmpty;
        final urls = (signed ? j['urls'] : j['unsigned_urls']) as List? ?? const [];
        if (urls.isEmpty) throw AiException('The video finished but has no download link.', provider: p.id);
        return downloadFile(p.net, '${urls.first}',
            headers: signed ? null : p.authHeaders(), cancelToken: cancelToken, mediaType: 'video/mp4');
      }
      if (status == 'failed' || status == 'cancelled') {
        throw AiException('Video generation failed: ${j['error'] ?? status}', provider: p.id);
      }
      r.onStatus?.call(status == 'in_progress' ? 'Rendering' : 'Queued');
    }
    throw AiException('The video took too long. It may still finish on OpenRouter.', provider: p.id);
  }
}
