import '../agents/toolkit.dart';
import '../catalog/model_info.dart';
import '../core/cancel.dart';
import '../core/errors.dart';
import '../core/models.dart';

/// A service that runs models: Vercel AI Gateway, Google, ElevenLabs…
///
/// Each provider makes typed models from its own model ids:
/// `provider.languageModel('openai/gpt-5')`.
abstract class AiProvider implements KeyedService {
  /// Short id used in model refs: `gateway` in `gateway:openai/gpt-5`.
  @override
  String get id;

  /// Display name.
  @override
  String get name;

  /// What this provider can do.
  Set<ModelType> get capabilities;

  /// Where people get an API key, for settings screens.
  @override
  String? get apiKeyUrl => null;

  /// Its documentation.
  String? get docsUrl => null;

  /// models.dev provider id, for enriching model info.
  String? get modelsDevId => null;

  /// False for local servers like LM Studio.
  @override
  bool get needsApiKey => true;

  /// Whether a key (or server address) is set.
  @override
  bool get isConfigured;

  LanguageModel languageModel(String modelId) => throw _unsupported('chat');
  ImageModel imageModel(String modelId) => throw _unsupported('image generation');
  SpeechModel speechModel(String modelId) => throw _unsupported('text to speech');
  TranscriptionModel transcriptionModel(String modelId) => throw _unsupported('transcription');
  VideoModel videoModel(String modelId) => throw _unsupported('video generation');
  EmbeddingModel embeddingModel(String modelId) => throw _unsupported('embeddings');

  /// Every model this provider offers (or has loaded, for local servers).
  Future<List<ModelInfo>> listModels({CancelToken? cancelToken});

  /// Voices for text to speech. Empty when the provider has none to list.
  Future<List<Voice>> listVoices({String? modelId, String? language, CancelToken? cancelToken}) async => const [];

  /// Checks the key with a cheap call. Returns null when it works, or what
  /// went wrong in words.
  @override
  Future<String?> verify();

  /// Default model ids for each job, used when no model is given.
  Map<ModelType, String> get defaultModels => const {};

  UnsupportedFeatureException _unsupported(String what) => UnsupportedFeatureException('$name does not offer $what here.', provider: id);

  @override
  String toString() => '$name ($id)';
}

/// Splits `gateway:openai/gpt-5` into provider and model. Ids without a
/// known prefix belong to [defaultProvider].
({String provider, String modelId}) parseModelRef(String ref, {required Set<String> providers, required String defaultProvider}) {
  final colon = ref.indexOf(':');
  if (colon > 0) {
    final p = ref.substring(0, colon);
    if (providers.contains(p)) return (provider: p, modelId: ref.substring(colon + 1));
  }
  return (provider: defaultProvider, modelId: ref);
}

/// Merges [b] into [a], recursing into nested maps.
Map<String, dynamic> deepMerge(Map<String, dynamic> a, Map<String, dynamic> b) {
  final out = Map<String, dynamic>.of(a);
  b.forEach((k, v) {
    final cur = out[k];
    out[k] = cur is Map<String, dynamic> && v is Map<String, dynamic> ? deepMerge(cur, v) : v;
  });
  return out;
}
