/// What a model is for.
enum ModelType {
  text('Chat'),
  image('Image'),
  speech('Voice'),
  transcription('Dictation'),
  video('Video'),
  embedding('Embedding'),
  music('Music'),
  soundEffect('Sound effects');

  const ModelType(this.label);
  final String label;
}

/// A model with everything known about it, from its provider's list and
/// models.dev.
class ModelInfo {
  const ModelInfo({
    required this.provider,
    required this.modelId,
    required this.name,
    this.types = const {ModelType.text},
    this.description = '',
    this.lab,
    this.family,
    this.contextWindow,
    this.maxOutput,
    this.inputPrice,
    this.outputPrice,
    this.cacheReadPrice,
    this.imagePrice,
    this.inputModalities = const ['text'],
    this.outputModalities = const ['text'],
    this.reasoning = false,
    this.toolCall = false,
    this.structuredOutput = false,
    this.openWeights = false,
    this.attachment = false,
    this.temperature = true,
    this.releaseDate,
    this.lastUpdated,
    this.knowledge,
    this.tags = const [],
    this.voices = const [],
    this.loaded,
    this.extra = const {},
  });

  /// Provider id, e.g. `gateway`.
  final String provider;

  /// The provider's own id, e.g. `openai/gpt-5`.
  final String modelId;

  /// What you pass to `OmniAI` calls: `gateway:openai/gpt-5`.
  String get id => '$provider:$modelId';

  final String name;
  final Set<ModelType> types;
  final String description;

  /// Who made it: `openai`, `google`, `anthropic`…
  final String? lab;
  final String? family;
  final int? contextWindow;
  final int? maxOutput;

  /// USD per million tokens.
  final double? inputPrice;
  final double? outputPrice;
  final double? cacheReadPrice;

  /// USD per image.
  final double? imagePrice;
  final List<String> inputModalities;
  final List<String> outputModalities;
  final bool reasoning;
  final bool toolCall;
  final bool structuredOutput;
  final bool openWeights;
  final bool attachment;
  final bool temperature;
  final String? releaseDate;
  final String? lastUpdated;
  final String? knowledge;
  final List<String> tags;

  /// Built-in voices of a speech model.
  final List<String> voices;

  /// LM Studio: whether the model is loaded in memory now.
  final bool? loaded;
  final Map<String, dynamic> extra;

  bool get vision => inputModalities.contains('image');
  bool get audioIn => inputModalities.contains('audio');
  bool get pdfIn => inputModalities.contains('pdf') || inputModalities.contains('file') || attachment;
  bool get makesImages => types.contains(ModelType.image) || outputModalities.contains('image');
  bool get isFree => modelId.endsWith(':free') || (inputPrice == 0 && outputPrice == 0);
  bool supports(ModelType t) => types.contains(t) || (t == ModelType.image && makesImages);

  /// A batch-only or otherwise special listing of another model (e.g.
  /// `…-batch`), which most pickers should hide.
  bool get isVariant => modelId.endsWith('-batch') || modelId.endsWith(':batch') || (inputPrice ?? 0) < 0;

  /// One number to sort by price: input weighted 3:1 over output, the way a
  /// chat with long context spends it. Unknown prices sort last.
  double get blendedPrice => (inputPrice ?? 999) * 0.75 + (outputPrice ?? 999) * 0.25;

  /// The lab's logo, from models.dev.
  String get logoUrl => 'https://models.dev/logos/${lab ?? provider}.svg';

  /// `$1.25 / $10` per million in / out, `$0.04/img`, `Free` or `—`.
  String get priceLabel {
    if (isFree) return 'Free';
    if (imagePrice != null && !types.contains(ModelType.text)) return '${usd(imagePrice!)}/img';
    if (inputPrice == null && outputPrice == null) return '—';
    return '${usd(inputPrice ?? 0)} / ${usd(outputPrice ?? 0)}';
  }

  /// `128K`, `1M`.
  String get contextLabel => tokens(contextWindow);

  static String usd(double v) =>
      v >= 10 ? '\$${v.toStringAsFixed(0)}' : (v >= 1 ? '\$${v.toStringAsFixed(2)}' : '\$${v.toStringAsFixed(3)}');

  static String tokens(int? c) {
    if (c == null) return '—';
    if (c >= 1000000) return '${(c / 1000000).toStringAsFixed(c % 1000000 == 0 ? 0 : 1)}M';
    return '${(c / 1000).round()}K';
  }

  /// Estimated USD for a call with these token counts. [cachedInput] (part
  /// of [input]) is priced at the cache-read price when there is one.
  double? estimateCost(int input, int output, {int cachedInput = 0}) {
    if (inputPrice == null && outputPrice == null) return null;
    final cached = cachedInput.clamp(0, input);
    return ((input - cached) * (inputPrice ?? 0) + cached * (cacheReadPrice ?? inputPrice ?? 0) + output * (outputPrice ?? 0)) / 1e6;
  }

  ModelInfo copyWith({
    String? name,
    Set<ModelType>? types,
    String? description,
    String? lab,
    String? family,
    int? contextWindow,
    int? maxOutput,
    double? inputPrice,
    double? outputPrice,
    double? cacheReadPrice,
    List<String>? inputModalities,
    List<String>? outputModalities,
    bool? reasoning,
    bool? toolCall,
    bool? structuredOutput,
    bool? openWeights,
    bool? attachment,
    bool? temperature,
    String? releaseDate,
    String? lastUpdated,
    String? knowledge,
  }) =>
      ModelInfo(
        provider: provider,
        modelId: modelId,
        name: name ?? this.name,
        types: types ?? this.types,
        description: description ?? this.description,
        lab: lab ?? this.lab,
        family: family ?? this.family,
        contextWindow: contextWindow ?? this.contextWindow,
        maxOutput: maxOutput ?? this.maxOutput,
        inputPrice: inputPrice ?? this.inputPrice,
        outputPrice: outputPrice ?? this.outputPrice,
        cacheReadPrice: cacheReadPrice ?? this.cacheReadPrice,
        imagePrice: imagePrice,
        inputModalities: inputModalities ?? this.inputModalities,
        outputModalities: outputModalities ?? this.outputModalities,
        reasoning: reasoning ?? this.reasoning,
        toolCall: toolCall ?? this.toolCall,
        structuredOutput: structuredOutput ?? this.structuredOutput,
        openWeights: openWeights ?? this.openWeights,
        attachment: attachment ?? this.attachment,
        temperature: temperature ?? this.temperature,
        releaseDate: releaseDate ?? this.releaseDate,
        lastUpdated: lastUpdated ?? this.lastUpdated,
        knowledge: knowledge ?? this.knowledge,
        tags: tags,
        voices: voices,
        loaded: loaded,
        extra: extra,
      );

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'modelId': modelId,
        'name': name,
        'types': [for (final t in types) t.name],
        'description': description,
        'lab': lab,
        'family': family,
        'contextWindow': contextWindow,
        'maxOutput': maxOutput,
        'inputPrice': inputPrice,
        'outputPrice': outputPrice,
        'cacheReadPrice': cacheReadPrice,
        'imagePrice': imagePrice,
        'inputModalities': inputModalities,
        'outputModalities': outputModalities,
        'reasoning': reasoning,
        'toolCall': toolCall,
        'structuredOutput': structuredOutput,
        'openWeights': openWeights,
        'attachment': attachment,
        'temperature': temperature,
        'releaseDate': releaseDate,
        'lastUpdated': lastUpdated,
        'knowledge': knowledge,
        'tags': tags,
        'voices': voices,
        'loaded': loaded,
      };

  factory ModelInfo.fromJson(Map<String, dynamic> j) {
    List<String> list(Object? v) => [for (final x in (v as List? ?? const [])) '$x'];
    double? d(Object? v) => (v as num?)?.toDouble();
    return ModelInfo(
      provider: j['provider'] as String,
      modelId: j['modelId'] as String,
      name: j['name'] as String? ?? j['modelId'] as String,
      types: {
        for (final t in list(j['types']))
          if (ModelType.values.any((v) => v.name == t)) ModelType.values.byName(t),
      },
      description: j['description'] as String? ?? '',
      lab: j['lab'] as String?,
      family: j['family'] as String?,
      contextWindow: (j['contextWindow'] as num?)?.toInt(),
      maxOutput: (j['maxOutput'] as num?)?.toInt(),
      inputPrice: d(j['inputPrice']),
      outputPrice: d(j['outputPrice']),
      cacheReadPrice: d(j['cacheReadPrice']),
      imagePrice: d(j['imagePrice']),
      inputModalities: list(j['inputModalities']),
      outputModalities: list(j['outputModalities']),
      reasoning: j['reasoning'] == true,
      toolCall: j['toolCall'] == true,
      structuredOutput: j['structuredOutput'] == true,
      openWeights: j['openWeights'] == true,
      attachment: j['attachment'] == true,
      temperature: j['temperature'] != false,
      releaseDate: j['releaseDate'] as String?,
      lastUpdated: j['lastUpdated'] as String?,
      knowledge: j['knowledge'] as String?,
      tags: list(j['tags']),
      voices: list(j['voices']),
      loaded: j['loaded'] as bool?,
    );
  }

  @override
  String toString() => 'ModelInfo($id)';
}
