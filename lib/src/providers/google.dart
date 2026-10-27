import 'dart:convert';

import 'package:http/http.dart' as http;

import '../catalog/model_info.dart';
import '../core/cancel.dart';
import '../core/errors.dart';
import '../core/http.dart';
import '../core/media.dart';
import '../core/messages.dart';
import '../core/models.dart';
import '../core/stream_parts.dart';
import '../core/tools.dart';
import '../core/usage.dart';
import 'openai_compatible.dart' show ChatTranscriptionModel, downloadFile;
import 'provider.dart';

/// Google AI Studio (Gemini API), called natively.
///
/// Model ids: `gemini-2.5-flash`, `gemini-2.5-pro`, `gemini-3.1-flash-image`,
/// `gemini-3.8-flash-tts`, `gemini-omni-1.1-flash` (video),
/// `gemini-embedding-001`. Get a key at https://aistudio.google.com/apikey.
class GoogleProvider extends AiProvider {
  GoogleProvider({this.apiKey, this.baseUrl = 'https://generativelanguage.googleapis.com/v1beta', http.Client? httpClient})
      : net = AiHttp(provider: 'Google AI', client: httpClient);

  String? apiKey;
  final String baseUrl;
  final AiHttp net;

  @override
  String get id => 'google';
  @override
  String get name => 'Google AI Studio';
  @override
  String get apiKeyUrl => 'https://aistudio.google.com/apikey';
  @override
  String get docsUrl => 'https://ai.google.dev/gemini-api/docs';
  @override
  String get modelsDevId => 'google';
  @override
  bool get isConfigured => apiKey?.trim().isNotEmpty ?? false;
  @override
  Set<ModelType> get capabilities => const {
        ModelType.text,
        ModelType.image,
        ModelType.speech,
        ModelType.transcription,
        ModelType.video,
        ModelType.embedding,
      };

  @override
  Map<ModelType, String> get defaultModels => const {
        ModelType.text: 'gemini-2.5-flash',
        ModelType.image: 'gemini-3.1-flash-image',
        ModelType.speech: 'gemini-3.8-flash-tts',
        ModelType.transcription: 'gemini-2.5-flash',
        ModelType.video: 'gemini-omni-1.1-flash',
        ModelType.embedding: 'gemini-embedding-001',
      };

  /// Gemini's 30 prebuilt speech voices.
  static const voices = [
    'Zephyr', 'Puck', 'Charon', 'Kore', 'Fenrir', 'Leda', 'Orus', 'Aoede', 'Callirrhoe', 'Autonoe', //
    'Enceladus', 'Iapetus', 'Umbriel', 'Algieba', 'Despina', 'Erinome', 'Algenib', 'Rasalgethi', 'Laomedeia', 'Achernar',
    'Alnilam', 'Schedar', 'Gacrux', 'Pulcherrima', 'Achird', 'Zubenelgenubi', 'Vindemiatrix', 'Sadachbia', 'Sadaltager', 'Sulafat',
  ];

  Map<String, String> headers() {
    final key = apiKey?.trim() ?? '';
    if (key.isEmpty) throw MissingApiKeyException(id, name);
    return {'x-goog-api-key': key, 'Content-Type': 'application/json'};
  }

  static String bare(String modelId) => modelId.startsWith('models/') ? modelId.substring(7) : modelId;

  @override
  LanguageModel languageModel(String modelId) => GeminiModel(this, bare(modelId));
  @override
  ImageModel imageModel(String modelId) => _GeminiImage(this, bare(modelId));
  @override
  SpeechModel speechModel(String modelId) => _GeminiSpeech(this, bare(modelId));
  @override
  TranscriptionModel transcriptionModel(String modelId) => ChatTranscriptionModel(languageModel(modelId));
  @override
  VideoModel videoModel(String modelId) => _GeminiVideo(this, bare(modelId));
  @override
  EmbeddingModel embeddingModel(String modelId) => _GeminiEmbedding(this, bare(modelId));

  @override
  Future<List<ModelInfo>> listModels({CancelToken? cancelToken}) async {
    final out = <ModelInfo>[];
    String? page;
    do {
      final url = Uri.parse('$baseUrl/models?pageSize=1000${page == null ? '' : '&pageToken=$page'}');
      final j = net.json(await net.get(url, headers: headers(), cancelToken: cancelToken)) as Map;
      for (final m in (j['models'] as List? ?? const []).whereType<Map>()) {
        final mid = bare('${m['name']}');
        final methods = [for (final x in (m['supportedGenerationMethods'] as List? ?? const [])) '$x'];
        final types = <ModelType>{
          if (mid.contains('embedding') || methods.contains('embedContent'))
            ModelType.embedding
          else if (mid.contains('tts'))
            ModelType.speech
          else if (mid.contains('image'))
            ModelType.image
          else if (mid.contains('omni') || mid.contains('veo'))
            ModelType.video
          else if (methods.contains('generateContent')) ...{ModelType.text, ModelType.transcription},
        };
        if (types.isEmpty || mid.contains('aqa')) continue;
        out.add(ModelInfo(
          provider: id,
          modelId: mid,
          name: '${m['displayName'] ?? mid}',
          lab: 'google',
          types: types,
          description: '${m['description'] ?? ''}',
          contextWindow: (m['inputTokenLimit'] as num?)?.toInt(),
          maxOutput: (m['outputTokenLimit'] as num?)?.toInt(),
          inputModalities: types.contains(ModelType.text) ? const ['text', 'image', 'audio', 'video', 'pdf'] : const ['text'],
          outputModalities: [
            if (types.contains(ModelType.image)) 'image',
            if (types.contains(ModelType.speech)) 'audio',
            if (types.contains(ModelType.video)) 'video',
            if (types.contains(ModelType.text) || types.contains(ModelType.image)) 'text',
          ],
          reasoning: m['thinking'] == true,
          toolCall: types.contains(ModelType.text),
          structuredOutput: types.contains(ModelType.text),
          attachment: types.contains(ModelType.text),
          temperature: m['temperature'] != null,
          voices: types.contains(ModelType.speech) ? voices : const [],
        ));
      }
      page = j['nextPageToken'] as String?;
    } while (page != null && page.isNotEmpty);
    return out;
  }

  @override
  Future<List<Voice>> listVoices({String? modelId, String? language, CancelToken? cancelToken}) async => [
        for (final v in voices) Voice(id: v, name: v, provider: id),
      ];

  @override
  Future<String?> verify() async {
    try {
      net.json(await net.get(Uri.parse('$baseUrl/models?pageSize=1'), headers: headers(), timeout: const Duration(seconds: 20)));
      return null;
    } on AiException catch (e) {
      return e.message;
    }
  }

  // ------------------------------------------------------- interactions

  /// POSTs to the Interactions API, which Google now uses for images,
  /// speech and video.
  Future<Map<String, dynamic>> interact(Map<String, dynamic> body,
      {CancelToken? cancelToken, Duration timeout = const Duration(minutes: 4)}) async {
    final j = net.json(await net.post(Uri.parse('$baseUrl/interactions'),
        headers: headers(), body: jsonEncode(body), timeout: timeout, cancelToken: cancelToken));
    final m = Map<String, dynamic>.from(j as Map);
    if (m['status'] == 'failed') {
      final errors = m['errors'] ?? m['error'];
      throw AiException('Google could not finish: ${errors ?? 'failed'}', provider: id);
    }
    return m;
  }

  /// Every media item (image/audio/video) anywhere in an interaction.
  static List<Map<String, dynamic>> mediaItems(Object? node, String type) {
    final out = <Map<String, dynamic>>[];
    void walk(Object? n) {
      if (n is Map) {
        if (n['type'] == type && (n['data'] is String || n['uri'] is String)) {
          out.add(Map<String, dynamic>.from(n));
          return;
        }
        // Older shape: inlineData parts.
        final inline = n['inlineData'] ?? n['inline_data'];
        if (inline is Map && '${inline['mimeType'] ?? inline['mime_type'] ?? ''}'.startsWith('$type/')) {
          out.add({'data': inline['data'], 'mime_type': inline['mimeType'] ?? inline['mime_type']});
          return;
        }
        n.values.forEach(walk);
      } else if (n is List) {
        n.forEach(walk);
      }
    }

    walk(node);
    return out;
  }

  Future<GeneratedFile> fileFrom(Map<String, dynamic> item, {CancelToken? cancelToken}) async {
    final mime = '${item['mime_type'] ?? item['mimeType'] ?? ''}';
    if (item['data'] is String) {
      return GeneratedFile.fromBase64(item['data'] as String, mediaType: mime.isEmpty ? null : mime);
    }
    var uri = '${item['uri']}';
    if (uri.startsWith('$baseUrl/files/') && !uri.contains(':download')) uri = '$uri:download?alt=media';
    return downloadFile(net, uri,
        headers: {'x-goog-api-key': apiKey!.trim()}, cancelToken: cancelToken, mediaType: mime.isEmpty ? null : mime);
  }
}

/// Gemini through `generateContent` / `streamGenerateContent`, with tools,
/// thinking, files, JSON output and image output.
class GeminiModel implements LanguageModel {
  GeminiModel(this.p, this.modelId);
  final GoogleProvider p;
  @override
  final String modelId;
  @override
  String get provider => p.id;

  Map<String, dynamic> body(LanguageModelRequest r) {
    final system = r.messages.where((m) => m.role == Role.system).map((m) => m.text).join('\n\n');
    final contents = <Map<String, dynamic>>[];
    for (final m in r.messages.where((m) => m.role != Role.system)) {
      final parts = <Map<String, dynamic>>[];
      for (final part in m.parts) {
        switch (part) {
          case TextPart(:final text) when text.isNotEmpty:
            parts.add({'text': text});
          case FilePart() when part.bytes != null:
            parts.add({
              'inlineData': {'mimeType': part.mediaType == 'image/*' ? 'image/png' : part.mediaType, 'data': part.base64},
            });
          case FilePart(:final url?):
            parts.add({
              'fileData': {'mimeType': part.mediaType, 'fileUri': url.toString()},
            });
          case ReasoningPart(:final text, :final providerData) when providerData != null && providerData['thoughtSignature'] != null:
            parts.add({'text': text, 'thought': true, 'thoughtSignature': providerData['thoughtSignature']});
          case ToolCallPart(:final name, :final input, :final providerData):
            final signature = thoughtSignatureOf(providerData);
            parts.add({
              'functionCall': {'name': name, 'args': input},
              if (signature != null) 'thoughtSignature': signature,
            });
          case ToolResultPart(:final toolName, :final output):
            parts.add({
              'functionResponse': {
                'name': toolName,
                'response': output is Map ? output : {'result': output},
              },
            });
          default:
        }
      }
      if (parts.isEmpty) continue;
      contents.add({'role': m.role == Role.assistant ? 'model' : 'user', 'parts': parts});
    }

    final tc = r.toolChoice;
    final rf = r.responseFormat;
    final thinking = _thinking(r.reasoning);
    final gen = <String, dynamic>{
      if (r.temperature != null) 'temperature': r.temperature,
      if (r.topP != null) 'topP': r.topP,
      if (r.topK != null) 'topK': r.topK,
      if (r.maxOutputTokens != null) 'maxOutputTokens': r.maxOutputTokens,
      if (r.stopSequences != null) 'stopSequences': r.stopSequences,
      if (r.seed != null) 'seed': r.seed,
      if (rf != null) 'responseMimeType': 'application/json',
      if (rf?.schema != null) 'responseJsonSchema': _clean(rf!.schema!),
      if (r.outputImages) 'responseModalities': ['TEXT', 'IMAGE'],
      if (thinking != null) 'thinkingConfig': thinking,
    };
    return deepMerge({
      if (system.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': system},
          ],
        },
      'contents': contents,
      if (r.tools.isNotEmpty)
        'tools': [
          {
            'functionDeclarations': [
              for (final t in r.tools) {'name': t.name, 'description': t.description, 'parametersJsonSchema': _clean(t.parameters)},
            ],
          },
        ],
      if (r.tools.isNotEmpty && tc != null)
        'toolConfig': {
          'functionCallingConfig': {
            'mode': switch (tc.kind) {
              'required' || 'tool' => 'ANY',
              'none' => 'NONE',
              _ => 'AUTO',
            },
            if (tc.toolName != null) 'allowedFunctionNames': [tc.toolName],
          },
        },
      if (gen.isNotEmpty) 'generationConfig': gen,
    }, r.providerOptions);
  }

  Map<String, dynamic>? _thinking(ReasoningEffort? e) {
    if (e == null) return const {'includeThoughts': true};
    if (e == ReasoningEffort.none) return const {'thinkingBudget': 0};
    // Gemini 3 takes levels; 2.5 takes budgets.
    if (modelId.startsWith('gemini-2')) {
      return {
        'includeThoughts': true,
        'thinkingBudget': switch (e) {
          ReasoningEffort.minimal => 512,
          ReasoningEffort.low => 2048,
          ReasoningEffort.medium => 8192,
          _ => 24576,
        },
      };
    }
    return {
      'includeThoughts': true,
      'thinkingLevel': switch (e) {
        ReasoningEffort.minimal || ReasoningEffort.low => 'low',
        ReasoningEffort.medium => 'medium',
        _ => 'high',
      },
    };
  }

  /// A tool call's thought signature, as Gemini sent it natively or as
  /// Google's OpenAI-compatible endpoint (and gateways in front of it) sent
  /// it: `extra_content.google.thought_signature`. History recorded through
  /// either route keeps working through the other.
  static String? thoughtSignatureOf(Map<String, dynamic>? providerData) {
    if (providerData == null) return null;
    final native = providerData['thoughtSignature'];
    if (native is String) return native;
    final extra = providerData['extra_content'];
    final google = extra is Map ? extra['google'] : null;
    final sig = google is Map ? google['thought_signature'] : null;
    return sig is String ? sig : null;
  }

  /// Gemini rejects `$schema` and a few JSON Schema extras.
  static Object? _clean(Object? node) {
    if (node is Map) {
      return {
        for (final e in node.entries)
          if (e.key != r'$schema' && e.key != 'strict') '${e.key}': _clean(e.value),
      };
    }
    if (node is List) return node.map(_clean).toList();
    return node;
  }

  @override
  Stream<StreamPart> stream(LanguageModelRequest r, {CancelToken? cancelToken}) async* {
    // `await for`, not `yield*`, so the retry below can catch the error.
    try {
      await for (final e in _stream(r, cancelToken, plain: false)) {
        yield e;
      }
    } on _RetryPlain {
      // Some models refuse a thinking setting (e.g. a budget of 0 on a
      // model that always thinks); ask again and let the model decide.
      await for (final e in _stream(r, cancelToken, plain: true)) {
        yield e;
      }
    }
  }

  Stream<StreamPart> _stream(LanguageModelRequest r, CancelToken? cancelToken, {required bool plain}) async* {
    final json = body(r);
    if (plain) (json['generationConfig'] as Map?)?.remove('thinkingConfig');
    final req = http.Request('POST', Uri.parse('${p.baseUrl}/models/$modelId:streamGenerateContent?alt=sse'))
      ..headers.addAll({...p.headers(), ...r.headers})
      ..body = jsonEncode(json);

    var usage = const Usage();
    var finish = FinishReason.unknown;
    var hasCalls = false;
    var wrote = false;
    var n = 0;
    String? reasoningSignature;
    final Stream<String> events;
    if (plain || r.reasoning == null) {
      events = sseData(p.net.lines(req, cancelToken: cancelToken));
    } else {
      events = sseData(p.net.lines(req, cancelToken: cancelToken)).handleError(
        (Object e) => throw _RetryPlain(),
        test: (e) => !wrote && e is AiException && e.statusCode == 400 && '${e.message}'.toLowerCase().contains('think'),
      );
    }
    await for (final data in events) {
      wrote = true;
      final Map<String, dynamic> j;
      try {
        j = jsonDecode(data) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (j['error'] != null) throw p.net.apiError(400, data);
      if (j['usageMetadata'] != null) usage = Usage.fromJson(j['usageMetadata']);
      final feedback = j['promptFeedback'];
      if (feedback is Map && feedback['blockReason'] != null) {
        throw AiException('Google blocked the prompt: ${feedback['blockReason']}', provider: p.id);
      }
      final candidates = j['candidates'];
      if (candidates is! List || candidates.isEmpty) continue;
      final c = candidates.first as Map;
      if (c['finishReason'] != null) finish = FinishReason.parse('${c['finishReason']}');
      final grounding = c['groundingMetadata'];
      if (grounding is Map) {
        for (final g in (grounding['groundingChunks'] as List? ?? const []).whereType<Map>()) {
          final web = g['web'];
          if (web is Map && web['uri'] != null) yield SourceOutput(url: '${web['uri']}', title: web['title'] as String?);
        }
      }
      final parts = (c['content'] as Map?)?['parts'];
      if (parts is! List) continue;
      for (final part in parts.whereType<Map>()) {
        final sig = part['thoughtSignature'] as String?;
        if (part['functionCall'] is Map) {
          final fc = part['functionCall'] as Map;
          final id = '${fc['id'] ?? 'call_${DateTime.now().microsecondsSinceEpoch}_${n++}'}';
          final input = Map<String, dynamic>.from((fc['args'] as Map?) ?? const {});
          hasCalls = true;
          yield ToolCallStart(id: id, name: '${fc['name']}');
          yield ToolCall(ToolCallPart(
            id: id,
            name: '${fc['name']}',
            input: input,
            providerData: sig == null ? null : {'thoughtSignature': sig},
          ));
        } else if (part['text'] is String) {
          if (part['thought'] == true) {
            if (sig != null) reasoningSignature = sig;
            yield ReasoningDelta(part['text'] as String);
          } else {
            yield TextDelta(part['text'] as String);
          }
        } else if (part['inlineData'] is Map) {
          final d = part['inlineData'] as Map;
          yield FileOutput(GeneratedFile.fromBase64('${d['data']}', mediaType: d['mimeType'] as String?));
        }
      }
    }
    if (hasCalls && (finish == FinishReason.stop || finish == FinishReason.unknown)) finish = FinishReason.toolCalls;
    yield StepFinish(
      finishReason: finish,
      usage: usage,
      providerData: reasoningSignature == null
          ? null
          : {
              'reasoning': {'thoughtSignature': reasoningSignature},
            },
    );
  }
}

class _RetryPlain implements Exception {}

class _GeminiImage implements ImageModel {
  _GeminiImage(this.p, this.modelId);
  final GoogleProvider p;
  @override
  final String modelId;
  @override
  String get provider => p.id;

  @override
  Future<ImageResult> generate(ImageRequest r, {CancelToken? cancelToken}) async {
    final images = <GeneratedFile>[];
    String? text;
    for (var i = 0; i < r.n; i++) {
      final input = [
        {'type': 'text', 'text': r.prompt},
        for (final img in r.referenceImages)
          {'type': 'image', 'mime_type': sniffMediaType(img, fallback: 'image/png'), 'data': base64Encode(img)},
      ];
      Map<String, dynamic> j;
      try {
        j = await p.interact(
          deepMerge({
            'model': modelId,
            'input': input,
            'response_format': {
              'type': 'image',
              if (r.aspectRatio != null) 'aspect_ratio': r.aspectRatio,
            },
          }, r.providerOptions),
          cancelToken: cancelToken,
        );
      } on AiException catch (e) {
        if (e.statusCode != 404 && e.statusCode != 400) rethrow;
        j = await _generateContent(r, cancelToken);
      }
      for (final item in GoogleProvider.mediaItems(j, 'image')) {
        images.add(await p.fileFrom(item, cancelToken: cancelToken));
      }
      text ??= _firstText(j);
    }
    if (images.isEmpty) throw AiException('Gemini answered without an image${text == null ? '' : ': $text'}', provider: p.id);
    return ImageResult(images, text: text);
  }

  /// The older way: generateContent with image output.
  Future<Map<String, dynamic>> _generateContent(ImageRequest r, CancelToken? token) async {
    final j = p.net.json(await p.net.post(
      Uri.parse('${p.baseUrl}/models/$modelId:generateContent'),
      headers: p.headers(),
      json: {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': r.prompt},
              for (final img in r.referenceImages)
                {
                  'inlineData': {'mimeType': sniffMediaType(img, fallback: 'image/png'), 'data': base64Encode(img)},
                },
            ],
          },
        ],
        'generationConfig': {
          'responseModalities': ['TEXT', 'IMAGE'],
          if (r.aspectRatio != null) 'imageConfig': {'aspectRatio': r.aspectRatio},
        },
      },
      timeout: const Duration(minutes: 3),
      cancelToken: token,
    ));
    return Map<String, dynamic>.from(j as Map);
  }
}

String? _firstText(Object? node) {
  String? found;
  void walk(Object? n) {
    if (found != null) return;
    if (n is Map) {
      if ((n['type'] == 'text' || n.containsKey('text')) &&
          n['text'] is String &&
          (n['text'] as String).isNotEmpty &&
          n['thought'] != true) {
        found = n['text'] as String;
        return;
      }
      n.values.forEach(walk);
    } else if (n is List) {
      n.forEach(walk);
    }
  }

  walk(node);
  return found;
}

class _GeminiSpeech implements SpeechModel {
  _GeminiSpeech(this.p, this.modelId);
  final GoogleProvider p;
  @override
  final String modelId;
  @override
  String get provider => p.id;

  @override
  Future<GeneratedFile> speak(SpeechRequest r, {CancelToken? cancelToken}) async {
    final voice = r.voice ?? 'Kore';
    try {
      final j = await p.interact(
        deepMerge({
          'model': modelId,
          'input': [
            {
              'type': 'user_input',
              'content': [
                {
                  'type': 'text',
                  'text': r.text,
                  if (r.instructions != null)
                    'annotations': [
                      {'type': 'speech_metadata', 'style': r.instructions},
                    ],
                },
              ],
            },
          ],
          'response_format': {'type': 'audio', 'mime_type': 'audio/wav', 'sample_rate': 24000},
          'generation_config': {
            'speech_config': [
              {'voice': voice},
            ],
          },
        }, r.providerOptions),
        cancelToken: cancelToken,
      );
      final items = GoogleProvider.mediaItems(j, 'audio');
      if (items.isEmpty) throw AiException('Gemini returned no audio.', provider: p.id);
      return _wav(await p.fileFrom(items.first, cancelToken: cancelToken));
    } on AiException catch (e) {
      if (e.statusCode != 404 && e.statusCode != 400) rethrow;
      return _generateContent(r, voice, cancelToken);
    }
  }

  /// The older way: generateContent with AUDIO output (raw PCM).
  Future<GeneratedFile> _generateContent(SpeechRequest r, String voice, CancelToken? token) async {
    final text = r.instructions == null ? r.text : '${r.instructions}: ${r.text}';
    final j = p.net.json(await p.net.post(
      Uri.parse('${p.baseUrl}/models/$modelId:generateContent'),
      headers: p.headers(),
      json: {
        'contents': [
          {
            'parts': [
              {'text': text},
            ],
          },
        ],
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {'voiceName': voice},
            },
          },
        },
      },
      cancelToken: token,
    ));
    final items = GoogleProvider.mediaItems(j, 'audio');
    if (items.isEmpty) throw AiException('Gemini returned no audio.', provider: p.id);
    return _wav(await p.fileFrom(items.first));
  }

  /// Raw L16 PCM gets a WAV header so players can open it.
  static GeneratedFile _wav(GeneratedFile f) {
    if (f.mediaType == 'audio/wav' && sniffMediaType(f.bytes) == 'audio/wav') return f;
    if (f.mediaType.startsWith('audio/l16') ||
        f.mediaType.startsWith('audio/pcm') ||
        sniffMediaType(f.bytes) == 'application/octet-stream') {
      final rate = int.tryParse(RegExp(r'rate=(\d+)').firstMatch(f.mediaType)?.group(1) ?? '') ?? 24000;
      return GeneratedFile(pcmToWav(f.bytes, sampleRate: rate), mediaType: 'audio/wav');
    }
    return f;
  }
}

class _GeminiVideo implements VideoModel {
  _GeminiVideo(this.p, this.modelId);
  final GoogleProvider p;
  @override
  final String modelId;
  @override
  String get provider => p.id;

  @override
  Future<GeneratedFile> generate(VideoRequest r, {CancelToken? cancelToken}) async {
    r.onStatus?.call('Rendering');
    final j = await p.interact(
      deepMerge({
        'model': modelId,
        'input': r.image == null
            ? r.prompt
            : [
                {'type': 'text', 'text': r.prompt},
                {'type': 'image', 'mime_type': sniffMediaType(r.image!, fallback: 'image/png'), 'data': base64Encode(r.image!)},
              ],
        'response_format': {
          'type': 'video',
          if (r.aspectRatio != null) 'aspect_ratio': r.aspectRatio,
          if (r.resolution != null) 'resolution': r.resolution,
        },
        if (r.duration != null || r.negativePrompt != null)
          'generation_config': {
            'video_config': {
              if (r.duration != null) 'duration_seconds': r.duration,
              if (r.negativePrompt != null) 'negative_prompt': r.negativePrompt,
            },
          },
      }, r.providerOptions),
      cancelToken: cancelToken,
      timeout: r.timeout,
    );
    final items = GoogleProvider.mediaItems(j, 'video');
    if (items.isEmpty) throw AiException('Gemini returned no video.', provider: p.id);
    return p.fileFrom(items.first, cancelToken: cancelToken);
  }
}

class _GeminiEmbedding implements EmbeddingModel {
  _GeminiEmbedding(this.p, this.modelId);
  final GoogleProvider p;
  @override
  final String modelId;
  @override
  String get provider => p.id;

  @override
  Future<EmbeddingResult> embed(List<String> values, {int? dimensions, CancelToken? cancelToken}) async {
    final j = p.net.json(await p.net.post(
      Uri.parse('${p.baseUrl}/models/$modelId:batchEmbedContents'),
      headers: p.headers(),
      json: {
        'requests': [
          for (final v in values)
            {
              'model': 'models/$modelId',
              'content': {
                'parts': [
                  {'text': v},
                ],
              },
              if (dimensions != null) 'outputDimensionality': dimensions,
            },
        ],
      },
      cancelToken: cancelToken,
    )) as Map;
    return EmbeddingResult([
      for (final e in (j['embeddings'] as List? ?? const [])) [for (final v in ((e as Map)['values'] as List)) (v as num).toDouble()],
    ]);
  }
}
