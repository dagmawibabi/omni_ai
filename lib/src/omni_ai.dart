import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'agents/agent.dart';
import 'agents/memory.dart';
import 'agents/memory_files.dart';
import 'agents/skills.dart';
import 'agents/toolkit.dart';
import 'catalog/catalog.dart';
import 'catalog/model_info.dart';
import 'core/cancel.dart';
import 'core/errors.dart';
import 'core/media.dart';
import 'core/messages.dart';
import 'core/models.dart';
import 'core/tools.dart';
import 'core/usage.dart';
import 'device/device_speech.dart';
import 'device/dictation.dart';
import 'flutter/audio.dart';
import 'generate/generate_media.dart' as media;
import 'generate/generate_object.dart' as obj;
import 'generate/generate_text.dart' as gen;
import 'keys/key_store.dart';
import 'providers/addis_ai.dart';
import 'providers/elevenlabs.dart';
import 'providers/google.dart';
import 'providers/lm_studio.dart';
import 'providers/openai_compatible.dart';
import 'providers/openrouter.dart';
import 'providers/provider.dart';
import 'providers/vercel_gateway.dart';
import 'toolkits/cloudflare.dart';
import 'toolkits/composio.dart';
import 'toolkits/e2b.dart';
import 'toolkits/exa.dart';

/// The one object you need. Holds your keys and providers, and does
/// everything with a model id string like `google:gemini-2.5-flash`.
///
/// ```dart
/// final ai = OmniAI(gatewayKey: 'vck_…', googleKey: 'AIza…');
/// print(await ai.generateText(model: 'google:gemini-2.5-flash', prompt: 'Hi!'));
///
/// await for (final words in ai.streamText(prompt: 'Tell a story').textStream) {
///   stdout.write(words);
/// }
/// ```
///
/// Model ids are `provider:model`. Providers: `gateway` (Vercel AI
/// Gateway, the default when there is no prefix), `google`, `openrouter`,
/// `lmstudio`, `elevenlabs`, `addis`, and any you [register].
class OmniAI extends ChangeNotifier {
  OmniAI({
    String? gatewayKey,
    String? googleKey,
    String? openRouterKey,
    String? elevenLabsKey,
    String? addisKey,
    String? lmStudioUrl,
    String? exaKey,
    String? e2bKey,
    String? composioKey,
    String composioUserId = 'default',
    String? cloudflareToken,
    this.defaultProvider = 'gateway',
    KeyStore? keyStore,
    bool loadSavedKeys = true,
    String? appName,
    String? appUrl,
    http.Client? httpClient,
  }) : keyStore = keyStore ?? SecureKeyStore() {
    gateway = VercelGatewayProvider(apiKey: gatewayKey, appName: appName, appUrl: appUrl, httpClient: httpClient);
    google = GoogleProvider(apiKey: googleKey, httpClient: httpClient);
    openRouter = OpenRouterProvider(apiKey: openRouterKey, appName: appName, appUrl: appUrl, httpClient: httpClient);
    lmStudio = LmStudioProvider(serverUrl: lmStudioUrl ?? 'http://localhost:1234', httpClient: httpClient);
    elevenLabs = ElevenLabsProvider(apiKey: elevenLabsKey, httpClient: httpClient);
    addis = AddisAiProvider(apiKey: addisKey, httpClient: httpClient);
    for (final p in [gateway, google, openRouter, lmStudio, elevenLabs, addis]) {
      _providers[p.id] = p;
    }
    exa = ExaToolkit(apiKey: exaKey, httpClient: httpClient);
    e2b = E2BToolkit(apiKey: e2bKey, httpClient: httpClient);
    composio = ComposioToolkit(apiKey: composioKey, userId: composioUserId, httpClient: httpClient);
    cloudflare = CloudflareToolkit(token: cloudflareToken, httpClient: httpClient);
    for (final t in [exa, e2b, composio, cloudflare, memory, memoryFiles]) {
      _toolkits[t.id] = t;
    }
    _given = {
      if (gatewayKey != null) 'gateway',
      if (googleKey != null) 'google',
      if (openRouterKey != null) 'openrouter',
      if (elevenLabsKey != null) 'elevenlabs',
      if (addisKey != null) 'addis',
      if (lmStudioUrl != null) 'lmstudio',
      if (exaKey != null) 'exa',
      if (e2bKey != null) 'e2b',
      if (composioKey != null) 'composio',
      if (cloudflareToken != null) 'cloudflare',
    };
    if (loadSavedKeys) _keysLoaded = loadKeys();
  }

  static OmniAI? _instance;

  /// A shared instance. Set it up once with [OmniAI.configure].
  static OmniAI get instance => _instance ??= OmniAI();

  /// Creates the shared [instance].
  static OmniAI configure({
    String? gatewayKey,
    String? googleKey,
    String? openRouterKey,
    String? elevenLabsKey,
    String? addisKey,
    String? lmStudioUrl,
    String? exaKey,
    String? e2bKey,
    String? composioKey,
    String composioUserId = 'default',
    String? cloudflareToken,
    String defaultProvider = 'gateway',
    KeyStore? keyStore,
    bool loadSavedKeys = true,
    String? appName,
    String? appUrl,
  }) =>
      _instance = OmniAI(
        gatewayKey: gatewayKey,
        googleKey: googleKey,
        openRouterKey: openRouterKey,
        elevenLabsKey: elevenLabsKey,
        addisKey: addisKey,
        lmStudioUrl: lmStudioUrl,
        exaKey: exaKey,
        e2bKey: e2bKey,
        composioKey: composioKey,
        composioUserId: composioUserId,
        cloudflareToken: cloudflareToken,
        defaultProvider: defaultProvider,
        keyStore: keyStore,
        loadSavedKeys: loadSavedKeys,
        appName: appName,
        appUrl: appUrl,
      );

  late final VercelGatewayProvider gateway;
  late final GoogleProvider google;
  late final OpenRouterProvider openRouter;
  late final LmStudioProvider lmStudio;
  late final ElevenLabsProvider elevenLabs;
  late final AddisAiProvider addis;

  /// Web search for agents.
  late final ExaToolkit exa;

  /// A cloud code sandbox for agents.
  late final E2BToolkit e2b;

  /// Your users' apps (Gmail, Slack, GitHub…) for agents.
  late final ComposioToolkit composio;

  /// Cloudflare (DNS, Workers, KV, R2, browser) for agents.
  late final CloudflareToolkit cloudflare;

  /// Long-term memory (teleai-style `remember` / `update_memory` /
  /// `forget_memory` / `list_memories`), on the device. Set
  /// `ai.memory.scope` to your user's id.
  final memory = AgentMemory();

  /// A `memory` tool in the format of Claude's native memory tool (files
  /// under /memories), on the device.
  final memoryFiles = MemoryFilesToolkit();

  /// The basic tools, memory, and every toolkit with a key set: what to
  /// pass as `toolkits:` to give a call or chat everything.
  List<Toolkit> get allToolkits => [BasicToolkit(), ...configuredToolkits.where((t) => t != memoryFiles)];

  /// Provider for ids with no `provider:` prefix.
  String defaultProvider;
  final KeyStore keyStore;
  final _providers = <String, AiProvider>{};
  final _toolkits = <String, Toolkit>{};
  late final Set<String> _given;
  Future<void>? _keysLoaded;

  /// Your preferred model for each job; used when a call has no `model`.
  final defaultModels = <ModelType, String>{};

  /// Every model from your providers, with models.dev details.
  late final ModelCatalog catalog = ModelCatalog(() => providers);

  /// Every registered provider.
  List<AiProvider> get providers => List.unmodifiable(_providers.values);

  AiProvider provider(String id) =>
      _providers[id] ?? (throw UnknownModelException('No provider "$id". Known: ${_providers.keys.join(', ')}'));

  /// Adds a provider (e.g. an [OpenAICompatibleProvider] for Groq or Ollama).
  void register(AiProvider p) {
    _providers[p.id] = p;
    notifyListeners();
  }

  /// Every registered toolkit.
  List<Toolkit> get toolkits => List.unmodifiable(_toolkits.values);

  /// Toolkits with a key set (or needing none).
  List<Toolkit> get configuredToolkits => toolkits.where((t) => t.isConfigured || !t.needsApiKey).toList();

  Toolkit toolkit(String id) => _toolkits[id] ?? (throw UnknownModelException('No toolkit "$id". Known: ${_toolkits.keys.join(', ')}'));

  /// Adds a toolkit so its key can be set and saved like the built-in ones.
  void registerToolkit(Toolkit t) {
    _toolkits[t.id] = t;
    notifyListeners();
  }

  /// Every provider and toolkit that takes a key, for settings screens.
  List<KeyedService> get services => [...providers, ...toolkits.where((t) => t.needsApiKey)];

  /// An agent on this [OmniAI]. With no [toolkits] given, it gets
  /// [allToolkits]: the basic tools, memory, and every toolkit you've set a
  /// key for.
  Agent agent({
    String name = 'assistant',
    String? description,
    String instructions = 'You are a helpful assistant.',
    String? model,
    List<Tool> tools = const [],
    List<Toolkit>? toolkits,
    List<Skill> skills = const [],
    AgentMemory? memory,
    List<Agent> subagents = const [],
    AgentLimits limits = const AgentLimits(),
    AgentHooks hooks = const AgentHooks(),
    ReasoningEffort? reasoning,
    gen.ToolApproval? onToolApproval,
    AskUser? onAskUser,
  }) =>
      Agent(
        ai: this,
        name: name,
        description: description,
        instructions: instructions,
        model: model,
        tools: tools,
        toolkits: toolkits ?? allToolkits,
        skills: skills,
        memory: memory,
        subagents: subagents,
        limits: limits,
        hooks: hooks,
        reasoning: reasoning,
        onToolApproval: onToolApproval,
        onAskUser: onAskUser,
      );

  // ---------------------------------------------------------------- keys

  /// Waits for saved keys to load (they load on creation).
  Future<void> get ready => _keysLoaded ?? Future.value();

  /// Reads saved keys into providers that weren't given one in code.
  Future<void> loadKeys() async {
    for (final p in [gateway, google, openRouter, elevenLabs, addis]) {
      if (_given.contains(p.id)) continue;
      final k = await keyStore.read('key.${p.id}');
      if (k != null && k.isNotEmpty) _setRaw(p.id, k);
    }
    if (!_given.contains('lmstudio')) {
      final url = await keyStore.read('url.lmstudio');
      if (url != null && url.isNotEmpty) lmStudio.serverUrl = url;
    }
    for (final t in toolkits) {
      if (_given.contains(t.id)) continue;
      final k = await keyStore.read('key.${t.id}');
      if (k != null && k.isNotEmpty) _setRaw(t.id, k);
    }
    final account = await keyStore.read('cloudflare.account');
    if (account != null && account.isNotEmpty) cloudflare.client.accountId = account;
    final r2 = await keyStore.read('cloudflare.r2');
    final f = r2?.split('\n') ?? const [];
    if (f.length == 3) cloudflare.client.r2 = R2Credentials(accountId: f[0], accessKeyId: f[1], secretAccessKey: f[2]);
    notifyListeners();
  }

  /// The key set for [providerId], or null.
  String? apiKey(String providerId) => switch (_providers[providerId] ?? _toolkits[providerId]) {
        final ExaToolkit t => t.apiKey,
        final E2BToolkit t => t.apiKey,
        final ComposioToolkit t => t.apiKey,
        final CloudflareToolkit t => t.token,
        final GoogleProvider p => p.apiKey,
        final ElevenLabsProvider p => p.apiKey,
        final AddisAiProvider p => p.apiKey,
        final LmStudioProvider p => p.serverUrl,
        final OpenAICompatibleProvider p => p.apiKey,
        _ => null,
      };

  /// Sets (and saves, unless [persist] is false) a provider's API key.
  /// For `lmstudio` pass the server address.
  ///
  /// Setting the key a provider already has does nothing, so it is cheap to
  /// call whenever your own settings change.
  Future<void> setApiKey(String providerId, String? key, {bool persist = true}) async {
    final k = key?.trim();
    if ((apiKey(providerId) ?? '') == (k ?? '')) return;
    _setRaw(providerId, k);
    if (persist) await keyStore.write(providerId == 'lmstudio' ? 'url.lmstudio' : 'key.$providerId', k);
    // Refresh the catalog only if someone has loaded it.
    if (catalog.fetchedAt != null) unawaited(catalog.refresh());
    notifyListeners();
  }

  void _setRaw(String providerId, String? key) {
    final p = _providers[providerId] ?? _toolkits[providerId];
    switch (p) {
      case ExaToolkit():
        p.apiKey = key;
      case E2BToolkit():
        p.apiKey = key;
      case ComposioToolkit():
        p.apiKey = key;
      case CloudflareToolkit():
        p.token = key;
      case GoogleProvider():
        p.apiKey = key;
      case ElevenLabsProvider():
        p.apiKey = key;
      case AddisAiProvider():
        p.apiKey = key;
      case LmStudioProvider():
        p.serverUrl = key ?? '';
      case OpenAICompatibleProvider():
        p.apiKey = key;
      case null:
        throw UnknownModelException('No provider "$providerId".');
      case AiProvider():
        throw UnsupportedFeatureException('${p.name} takes no API key.');
      default:
        throw UnsupportedFeatureException('$providerId takes no API key.');
    }
  }

  /// Checks a provider's key. Null means it works.
  Future<String?> verifyKey(String providerId) =>
      _providers.containsKey(providerId) ? provider(providerId).verify() : toolkit(providerId).verify();

  /// Sets (and saves) Cloudflare's account id and, optionally, R2 keys for
  /// the R2 file tools.
  Future<void> setCloudflareAccount({String? accountId, R2Credentials? r2}) async {
    if (accountId != null) {
      cloudflare.client.accountId = accountId;
      await keyStore.write('cloudflare.account', accountId);
    }
    if (r2 != null) {
      cloudflare.client.r2 = r2;
      await keyStore.write('cloudflare.r2', [r2.accountId, r2.accessKeyId, r2.secretAccessKey].join('\n'));
    }
    notifyListeners();
  }

  /// Providers with a key (or address) set.
  List<AiProvider> get configuredProviders => providers.where((p) => p.isConfigured).toList();

  // ------------------------------------------------------------- models

  ({AiProvider provider, String modelId}) _resolve(String? ref, ModelType type) {
    ref ??= defaultModels[type];
    if (ref == null) {
      final p = [_providers[defaultProvider], ...configuredProviders]
          .whereType<AiProvider>()
          .where((p) => p.isConfigured && p.defaultModels.containsKey(type))
          .firstOrNull;
      if (p == null) throw UnknownModelException('No ${type.label.toLowerCase()} model given and no provider with a default is set up.');
      return (provider: p, modelId: p.defaultModels[type]!);
    }
    final r = parseModelRef(ref, providers: _providers.keys.toSet(), defaultProvider: defaultProvider);
    return (provider: provider(r.provider), modelId: r.modelId);
  }

  /// A typed model from an id, for the top-level functions.
  LanguageModel languageModel([String? id]) {
    final r = _resolve(id, ModelType.text);
    return r.provider.languageModel(r.modelId);
  }

  ImageModel imageModel([String? id]) {
    final r = _resolve(id, ModelType.image);
    return r.provider.imageModel(r.modelId);
  }

  SpeechModel speechModel([String? id]) {
    final r = _resolve(id, ModelType.speech);
    return r.provider.speechModel(r.modelId);
  }

  TranscriptionModel transcriptionModel([String? id]) {
    final r = _resolve(id, ModelType.transcription);
    return r.provider.transcriptionModel(r.modelId);
  }

  VideoModel videoModel([String? id]) {
    final r = _resolve(id, ModelType.video);
    return r.provider.videoModel(r.modelId);
  }

  EmbeddingModel embeddingModel([String? id]) {
    final r = _resolve(id, ModelType.embedding);
    return r.provider.embeddingModel(r.modelId);
  }

  /// Models from one provider, or every configured provider. Use
  /// [catalog] instead for cached, models.dev-enriched lists.
  Future<List<ModelInfo>> listModels({String? provider, ModelType? type, CancelToken? cancelToken}) async {
    final ps = provider == null ? configuredProviders : [this.provider(provider)];
    final lists = await Future.wait([
      for (final p in ps) p.listModels(cancelToken: cancelToken).catchError((Object _) => <ModelInfo>[]),
    ]);
    final all = [for (final l in lists) ...l];
    return type == null ? all : all.where((m) => m.supports(type)).toList();
  }

  /// Voices for a speech model id (`elevenlabs:eleven_v3`), a provider id
  /// (`google`), or `device` for this device's own voices.
  Future<List<Voice>> listVoices(String modelOrProvider, {String? language}) async {
    if (modelOrProvider == 'device') return DeviceSpeech.instance.voices(language: language);
    if (_providers.containsKey(modelOrProvider)) return provider(modelOrProvider).listVoices(language: language);
    final r = _resolve(modelOrProvider, ModelType.speech);
    return r.provider.listVoices(modelId: r.modelId, language: language);
  }

  // ---------------------------------------------------------------- text

  /// Streams a reply. See [gen.streamText] for every option.
  gen.StreamTextResult streamText({
    String? model,
    String? system,
    String? prompt,
    List<FilePart> files = const [],
    List<Message>? messages,
    List<Tool> tools = const [],
    List<Toolkit> toolkits = const [],
    ToolChoice? toolChoice,
    int? maxSteps,
    bool Function(gen.StepResult step)? stopWhen,
    double? temperature,
    double? topP,
    int? maxOutputTokens,
    List<String>? stopSequences,
    int? seed,
    ReasoningEffort? reasoning,
    bool outputImages = false,
    Map<String, dynamic> providerOptions = const {},
    gen.ToolApproval? onToolApproval,
    void Function(gen.StepResult step)? onStepFinish,
    void Function(gen.GenerateTextResult result)? onFinish,
    CancelToken? cancelToken,
  }) =>
      gen.streamText(
        model: languageModel(model),
        system: system,
        prompt: prompt,
        files: files,
        messages: messages,
        tools: tools,
        toolkits: toolkits,
        toolChoice: toolChoice,
        maxSteps: maxSteps ?? (tools.isEmpty && toolkits.isEmpty ? 1 : 12),
        stopWhen: stopWhen,
        temperature: temperature,
        topP: topP,
        maxOutputTokens: maxOutputTokens,
        stopSequences: stopSequences,
        seed: seed,
        reasoning: reasoning,
        outputImages: outputImages,
        providerOptions: providerOptions,
        onToolApproval: onToolApproval,
        onStepFinish: onStepFinish,
        onFinish: onFinish,
        cancelToken: cancelToken,
      );

  /// Generates a whole reply. With [tools], runs them and lets the model
  /// answer with the results (up to [maxSteps] calls, default 8).
  Future<gen.GenerateTextResult> generateText({
    String? model,
    String? system,
    String? prompt,
    List<FilePart> files = const [],
    List<Message>? messages,
    List<Tool> tools = const [],
    List<Toolkit> toolkits = const [],
    ToolChoice? toolChoice,
    int? maxSteps,
    double? temperature,
    int? maxOutputTokens,
    ReasoningEffort? reasoning,
    bool outputImages = false,
    Map<String, dynamic> providerOptions = const {},
    gen.ToolApproval? onToolApproval,
    void Function(gen.StepResult step)? onStepFinish,
    CancelToken? cancelToken,
  }) =>
      streamText(
        model: model,
        system: system,
        prompt: prompt,
        files: files,
        messages: messages,
        tools: tools,
        toolkits: toolkits,
        toolChoice: toolChoice,
        maxSteps: maxSteps,
        temperature: temperature,
        maxOutputTokens: maxOutputTokens,
        reasoning: reasoning,
        outputImages: outputImages,
        providerOptions: providerOptions,
        onToolApproval: onToolApproval,
        onStepFinish: onStepFinish,
        cancelToken: cancelToken,
      ).result;

  /// Just the answer, as text.
  Future<String> ask(String prompt,
          {String? model, String? system, List<FilePart> files = const [], List<Toolkit> toolkits = const []}) async =>
      (await generateText(model: model, system: system, prompt: prompt, files: files, toolkits: toolkits)).text;

  /// JSON matching [schema], optionally mapped with [fromJson].
  Future<obj.GenerateObjectResult<T>> generateObject<T>({
    required Schema schema,
    String? model,
    T Function(Map<String, dynamic> json)? fromJson,
    String? system,
    String? prompt,
    List<FilePart> files = const [],
    List<Message>? messages,
    double? temperature,
    CancelToken? cancelToken,
  }) =>
      obj.generateObject<T>(
        model: languageModel(model),
        schema: schema,
        fromJson: fromJson,
        system: system,
        prompt: prompt,
        files: files,
        messages: messages,
        temperature: temperature,
        cancelToken: cancelToken,
      );

  /// The JSON object as it is written, growing with each event.
  Stream<Map<String, dynamic>> streamObject({
    required Schema schema,
    String? model,
    String? system,
    String? prompt,
    List<Message>? messages,
    CancelToken? cancelToken,
  }) =>
      obj.streamObject(
          model: languageModel(model), schema: schema, system: system, prompt: prompt, messages: messages, cancelToken: cancelToken);

  /// Picks one of [options] for [prompt].
  Future<String> classify(String prompt, List<String> options, {String? model}) =>
      obj.generateEnum(model: languageModel(model), options: options, prompt: prompt);

  // --------------------------------------------------------------- media

  Future<ImageResult> generateImage({
    required String prompt,
    String? model,
    int n = 1,
    String? size,
    String? aspectRatio,
    int? seed,
    List<Uint8List> referenceImages = const [],
    Map<String, dynamic> providerOptions = const {},
    CancelToken? cancelToken,
  }) =>
      media.generateImage(
        model: imageModel(model),
        prompt: prompt,
        n: n,
        size: size,
        aspectRatio: aspectRatio,
        seed: seed,
        referenceImages: referenceImages,
        providerOptions: providerOptions,
        cancelToken: cancelToken,
      );

  /// Audio of [text]. See [speak] to also play it.
  Future<GeneratedFile> generateSpeech({
    required String text,
    String? model,
    String? voice,
    double? speed,
    String? instructions,
    String? language,
    Map<String, dynamic> providerOptions = const {},
    CancelToken? cancelToken,
  }) =>
      media.generateSpeech(
        model: speechModel(model),
        text: text,
        voice: voice,
        speed: speed,
        instructions: instructions,
        language: language,
        providerOptions: providerOptions,
        cancelToken: cancelToken,
      );

  /// Reads [text] aloud. `model: 'device'` (or no speech model set up)
  /// uses the device voice; otherwise a cloud voice, falling back to the
  /// device voice if it fails.
  Future<void> speak(String text, {String? model, String? voice, double speed = 1, String? language}) async {
    final words = DeviceSpeech.clean(text);
    if (words.isEmpty) return;
    final useDevice = model == 'device' || (model == null && !_hasSpeechDefault);
    if (!useDevice) {
      try {
        for (final part in DeviceSpeech.chunk(words, size: 2000)) {
          final audio = await generateSpeech(text: part, model: model, voice: voice, speed: speed, language: language);
          await AiAudio.instance.play(audio, wait: true);
        }
        return;
      } catch (e) {
        debugPrint('[omni_ai] cloud voice failed, using the device voice: $e');
      }
    }
    await DeviceSpeech.instance.speak(words, voice: model == 'device' ? voice : null, rate: speed, language: language);
  }

  bool get _hasSpeechDefault =>
      defaultModels.containsKey(ModelType.speech) || configuredProviders.any((p) => p.defaultModels.containsKey(ModelType.speech));

  /// Stops [speak].
  Future<void> stopSpeaking() async {
    await AiAudio.instance.stop();
    await DeviceSpeech.instance.stop();
  }

  Future<TranscriptionResult> transcribe({
    required Uint8List audio,
    String? model,
    String? mediaType,
    String? language,
    String? prompt,
    CancelToken? cancelToken,
  }) =>
      media.transcribe(
          model: transcriptionModel(model),
          audio: audio,
          mediaType: mediaType,
          language: language,
          prompt: prompt,
          cancelToken: cancelToken);

  /// A microphone helper: `model: null` uses the device recognizer (live,
  /// free); a model id records and transcribes in the cloud.
  Dictation dictation({String? model, String? language}) =>
      Dictation(model: model == null || model == 'device' ? null : transcriptionModel(model), language: language);

  Future<GeneratedFile> generateVideo({
    required String prompt,
    String? model,
    int? duration,
    String? aspectRatio,
    String? resolution,
    bool? audio,
    Uint8List? image,
    void Function(String status)? onStatus,
    Duration timeout = const Duration(minutes: 10),
    Map<String, dynamic> providerOptions = const {},
    CancelToken? cancelToken,
  }) =>
      media.generateVideo(
        model: videoModel(model),
        prompt: prompt,
        duration: duration,
        aspectRatio: aspectRatio,
        resolution: resolution,
        audio: audio,
        image: image,
        onStatus: onStatus,
        timeout: timeout,
        providerOptions: providerOptions,
        cancelToken: cancelToken,
      );

  Future<List<double>> embed(String value, {String? model, int? dimensions}) =>
      media.embed(model: embeddingModel(model), value: value, dimensions: dimensions);

  Future<EmbeddingResult> embedMany(List<String> values, {String? model, int? dimensions}) =>
      media.embedMany(model: embeddingModel(model), values: values, dimensions: dimensions);

  /// A sound effect from ElevenLabs.
  Future<GeneratedFile> generateSoundEffect(String prompt, {double? durationSeconds}) =>
      elevenLabs.soundEffect(prompt, durationSeconds: durationSeconds);

  /// Music from ElevenLabs.
  Future<GeneratedFile> generateMusic(String prompt, {Duration length = const Duration(seconds: 30)}) =>
      elevenLabs.music(prompt, length: length);

  /// Estimated USD for [usage] on [modelId], from the catalog's prices.
  double? estimateCost(String modelId, Usage usage) =>
      usage.cost ??
      catalog
          .byId(modelId.contains(':') ? modelId : '$defaultProvider:$modelId')
          ?.estimateCost(usage.inputTokens, usage.outputTokens, cachedInput: usage.cachedInputTokens);
}
