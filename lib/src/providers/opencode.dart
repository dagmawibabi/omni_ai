import '../catalog/model_info.dart';
import '../core/cancel.dart';
import '../core/errors.dart';
import 'openai_compatible.dart';

/// OpenCode Zen: pay-as-you-go models (GPT, Claude, Gemini, GLM, Kimi,
/// DeepSeek, Qwen…) behind one key, billed from prepaid credits.
/// Model ids are short: `glm-5.3`, `claude-sonnet-5-5`, `gpt-5.4-mini`.
///
/// Every text model is called through Zen's Chat Completions endpoint,
/// which translates for models whose native API differs.
///
/// Zen's free models (`big-pickle`, `…-free`) only work from the OpenCode
/// app itself, so [listModels] leaves them out unless [includeFree] is set.
class OpenCodeProvider extends OpenAICompatibleProvider {
  OpenCodeProvider({super.apiKey, this.includeFree = false, super.httpClient})
      : super(
          id: 'opencode',
          name: 'OpenCode Zen',
          baseUrl: defaultBaseUrl,
          supportedTypes: const {ModelType.text},
        );

  static const defaultBaseUrl = 'https://opencode.ai/inference/openai/v1';

  /// List the free models too. OpenCode says they answer only the OpenCode
  /// app, so other apps get an error from them.
  bool includeFree;

  @override
  String get apiKeyUrl => 'https://opencode.ai/console';
  @override
  String get docsUrl => 'https://opencode.ai/docs/zen';
  @override
  String get modelsDevId => 'opencode';

  @override
  Map<ModelType, String> get defaultModels => const {ModelType.text: 'glm-5.3-flash'};

  /// Whether [model] (an entry of Zen's model list) is free to call.
  static bool isFree(Map model) {
    final id = '${model['id']}';
    if (id.endsWith('-free') || id == 'big-pickle') return true;
    final text = ((model['cost'] as Map?)?['text'] as Map?) ?? const {};
    final input = ((text['input'] as Map?)?['price']);
    final output = ((text['output'] as Map?)?['price']);
    return input == 0 && output == 0;
  }

  /// `image/png` → `image`, `application/pdf` → `pdf`, `text` → `text`.
  static List<String> modalities(Object? list) {
    final out = <String>[];
    for (final m in (list as List? ?? const ['text'])) {
      final s = '$m';
      final kind = s == 'application/pdf' ? 'pdf' : s.split('/').first;
      if (!out.contains(kind)) out.add(kind);
    }
    return out.isEmpty ? const ['text'] : out;
  }

  /// The list is public, so the key is only sent when there is one: a wrong
  /// key is refused here, which is how [verify] checks it.
  @override
  Future<List<ModelInfo>> listModels({CancelToken? cancelToken}) async {
    final key = apiKey?.trim() ?? '';
    final j = net.json(await net.get(
      Uri.parse('$baseUrl/models'),
      headers: key.isEmpty ? null : authHeaders(),
      cancelToken: cancelToken,
    ));
    double? n(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
    final out = <ModelInfo>[];
    for (final m in ((j is Map ? j['data'] : j) as List? ?? const []).whereType<Map>()) {
      if (m['id'] == null) continue;
      if ('${m['type'] ?? 'chat'}' != 'chat') continue;
      if (!includeFree && isFree(m)) continue;
      final id = '${m['id']}';
      final canonical = m['canonical_id'] as String?;
      final mods = (m['modalities'] as Map?) ?? const {};
      final inMods = modalities(mods['input']);
      final caps = (m['capabilities'] as Map?) ?? const {};
      bool supported(Object? c) => c == true || (c is Map && c['supported'] == true);
      final limit = (m['limit'] as Map?) ?? const {};
      final text = ((m['cost'] as Map?)?['text'] as Map?) ?? const {};
      final input = (text['input'] as Map?) ?? const {};
      out.add(ModelInfo(
        provider: this.id,
        modelId: id,
        name: '${m['name'] ?? id}',
        lab: canonical != null && canonical.contains('/') ? canonical.split('/').first : m['owned_by'] as String?,
        family: m['family'] as String?,
        description: '${m['description'] ?? ''}',
        contextWindow: (limit['context'] as num?)?.toInt(),
        maxOutput: (limit['output'] as num?)?.toInt(),
        inputPrice: n(input['price']),
        outputPrice: n((text['output'] as Map?)?['price']),
        cacheReadPrice: n((input['cache'] as Map?)?['read']),
        inputModalities: inMods,
        outputModalities: modalities(mods['output']),
        attachment: inMods.any((x) => x != 'text'),
        reasoning: supported(caps['reasoning']),
        toolCall: supported(caps['tools']),
        structuredOutput: supported(caps['structured_output']),
        temperature: caps['temperature'] != false,
        openWeights: m['open_weights'] == true,
        releaseDate: m['release_date'] as String?,
        lastUpdated: m['last_updated'] as String?,
        knowledge: m['knowledge'] as String?,
        tags: [if (isFree(m)) 'free'],
        extra: {if (canonical != null) 'canonical_id': canonical, if (m['api'] is Map) 'api': (m['api'] as Map).keys.toList()},
      ));
    }
    return out;
  }

  /// The model list answers without a key, so a missing one is reported
  /// here; a wrong one is refused by [listModels].
  @override
  Future<String?> verify() async {
    try {
      authHeaders();
      await listModels();
      return null;
    } on AiException catch (e) {
      return e.message;
    }
  }
}
