import '../catalog/model_info.dart';
import '../core/cancel.dart';
import '../core/errors.dart';
import '../core/usage.dart';
import 'openai_compatible.dart';

/// LM Studio running on this computer or another on your network.
///
/// In LM Studio: Developer → Start server, and turn on "Serve on Local
/// Network" to reach it from a phone. Address like `192.168.1.20:1234`.
/// Model ids are what LM Studio shows, e.g. `qwen/qwen3-8b`.
class LmStudioProvider extends OpenAICompatibleProvider {
  LmStudioProvider({String serverUrl = 'http://localhost:1234', super.apiKey, super.httpClient})
      : _server = normalizeUrl(serverUrl),
        super(
          id: 'lmstudio',
          name: 'LM Studio',
          baseUrl: '${normalizeUrl(serverUrl)}/v1',
          supportedTypes: const {ModelType.text, ModelType.embedding},
        );

  String _server;

  /// `http://host:port`, without `/v1`.
  String get serverUrl => _server;
  set serverUrl(String url) {
    _server = normalizeUrl(url);
    baseUrl = '$_server/v1';
  }

  @override
  bool get needsApiKey => false;
  @override
  bool get isConfigured => _server.isNotEmpty;
  @override
  String get docsUrl => 'https://lmstudio.ai/docs/developer';
  @override
  String get modelsDevId => 'lmstudio';

  /// Local models load slowly the first time.
  @override
  Duration get connectTimeout => const Duration(minutes: 6);

  /// Small local models otherwise spend the whole reply thinking.
  @override
  Map<String, dynamic> reasoningBody(String modelId, ReasoningEffort? effort) => effort == null
      ? const {}
      : {'reasoning_effort': effort == ReasoningEffort.medium || effort == ReasoningEffort.high ? effort.name : 'none'};

  /// `192.168.1.20:1234/v1/` → `http://192.168.1.20:1234`.
  static String normalizeUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) return '';
    if (!u.contains('://')) u = 'http://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (u.endsWith('/v1')) u = u.substring(0, u.length - 3);
    return u;
  }

  /// Models downloaded in LM Studio, with whether each is loaded. Uses LM
  /// Studio's own API for details, else the OpenAI-style list.
  @override
  Future<List<ModelInfo>> listModels({CancelToken? cancelToken}) async {
    if (_server.isEmpty) throw const AiException('Enter your LM Studio server address.', provider: 'lmstudio');
    try {
      final rich = await net.get(Uri.parse('$_server/api/v0/models'), timeout: const Duration(seconds: 8), cancelToken: cancelToken);
      if (rich.statusCode == 200) {
        final data = (net.json(rich) as Map)['data'] as List? ?? const [];
        return [
          for (final m in data.whereType<Map>())
            if (m['id'] is String)
              ModelInfo(
                provider: id,
                modelId: m['id'] as String,
                name: m['id'] as String,
                lab: (m['publisher'] as String?) ?? (m['id'] as String).split('/').first,
                types: m['type'] == 'embeddings' ? const {ModelType.embedding} : const {ModelType.text},
                inputModalities: m['type'] == 'vlm' ? const ['text', 'image'] : const ['text'],
                contextWindow: (m['loaded_context_length'] as num?)?.toInt() ?? (m['max_context_length'] as num?)?.toInt(),
                loaded: m['state'] == 'loaded',
                openWeights: true,
                toolCall: m['type'] != 'embeddings',
                inputPrice: 0,
                outputPrice: 0,
                extra: {
                  if (m['arch'] != null) 'arch': m['arch'],
                  if (m['quantization'] != null) 'quantization': m['quantization'],
                  if (m['max_context_length'] != null) 'maxContext': m['max_context_length'],
                },
              ),
        ];
      }
      final models = await super.listModels(cancelToken: cancelToken);
      return [
        for (final m in models)
          ModelInfo(provider: id, modelId: m.modelId, name: m.name, types: m.types, openWeights: true, inputPrice: 0, outputPrice: 0),
      ];
    } on AiException catch (e) {
      if (e.statusCode != null) rethrow;
      throw AiException(
        'Could not reach LM Studio at $_server. Check that the server is running, '
        '"Serve on Local Network" is on, and this device is on the same network.',
        provider: id,
      );
    }
  }

  /// Whether LM Studio answers within a few seconds.
  Future<bool> isReachable() async {
    if (_server.isEmpty) return false;
    try {
      final r = await net.get(Uri.parse('$baseUrl/models'), timeout: const Duration(seconds: 4));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> verify() async => await isReachable() ? null : 'LM Studio is not answering at $_server.';
}
