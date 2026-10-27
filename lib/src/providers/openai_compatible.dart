import 'dart:convert';
import 'dart:typed_data';

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
import 'provider.dart';

/// Any server that speaks the OpenAI Chat Completions API: OpenAI, Groq,
/// Together, Ollama, vLLM, LM Studio, Vercel AI Gateway, OpenRouter…
///
/// ```dart
/// final groq = OpenAICompatibleProvider(
///   id: 'groq', name: 'Groq',
///   baseUrl: 'https://api.groq.com/openai/v1', apiKey: '...');
/// ```
class OpenAICompatibleProvider extends AiProvider {
  OpenAICompatibleProvider({
    required String id,
    required String name,
    required this.baseUrl,
    this.apiKey,
    this.headers = const {},
    this.supportedTypes = const {ModelType.text, ModelType.embedding, ModelType.image, ModelType.speech, ModelType.transcription},
    http.Client? httpClient,
  })  : _id = id,
        _name = name,
        net = AiHttp(provider: name, client: httpClient);

  final String _id;
  final String _name;

  /// e.g. `https://api.openai.com/v1` (no trailing slash).
  String baseUrl;
  String? apiKey;
  final Map<String, String> headers;
  final Set<ModelType> supportedTypes;
  final AiHttp net;

  @override
  String get id => _id;
  @override
  String get name => _name;
  @override
  Set<ModelType> get capabilities => supportedTypes;
  @override
  bool get isConfigured => !needsApiKey || (apiKey?.trim().isNotEmpty ?? false);

  /// How long to wait for the first byte. Local servers load models slowly.
  Duration get connectTimeout => const Duration(seconds: 120);

  String get chatUrl => '$baseUrl/chat/completions';

  Map<String, String> authHeaders() {
    final key = apiKey?.trim() ?? '';
    if (needsApiKey && key.isEmpty) throw MissingApiKeyException(id, name);
    return {if (key.isNotEmpty) ...bearer(key), ...headers};
  }

  /// The body fields that ask for (or turn off) reasoning.
  Map<String, dynamic> reasoningBody(String modelId, ReasoningEffort? effort) =>
      effort == null ? const {} : {'reasoning_effort': effort.name};

  /// Extra fields this provider always sends.
  Map<String, dynamic> extraBody(String modelId, LanguageModelRequest request) => const {};

  /// Tool schemas as this provider wants them.
  List<Map<String, dynamic>> toolsJson(String modelId, List<Tool> tools) => [for (final t in tools) t.toOpenAI()];

  /// Whether [modelId] makes images through chat (`modalities`) rather than
  /// `/images/generations`.
  bool chatImages(String modelId) => false;

  @override
  LanguageModel languageModel(String modelId) => OpenAIChatModel(this, modelId);
  @override
  ImageModel imageModel(String modelId) => OpenAIImageModel(this, modelId);
  @override
  EmbeddingModel embeddingModel(String modelId) => OpenAIEmbeddingModel(this, modelId);
  @override
  SpeechModel speechModel(String modelId) => OpenAISpeechModel(this, modelId);
  @override
  TranscriptionModel transcriptionModel(String modelId) => OpenAITranscriptionModel(this, modelId);

  @override
  Future<List<ModelInfo>> listModels({CancelToken? cancelToken}) async {
    final j = net.json(await net.get(Uri.parse('$baseUrl/models'), headers: authHeaders(), cancelToken: cancelToken));
    final data = j is Map ? j['data'] : j;
    return [
      for (final m in (data as List? ?? const []))
        if (m is Map && m['id'] != null)
          ModelInfo(
            provider: id,
            modelId: '${m['id']}',
            name: '${m['name'] ?? m['id']}',
            lab: m['owned_by'] as String?,
            types: '${m['id']}'.contains('embed') ? const {ModelType.embedding} : const {ModelType.text},
          ),
    ];
  }

  @override
  Future<String?> verify() async {
    try {
      await listModels();
      return null;
    } on AiException catch (e) {
      return e.message;
    }
  }

  // ------------------------------------------------------------ messages

  /// Messages in Chat Completions form.
  List<Map<String, dynamic>> messagesJson(List<Message> messages, {bool withProviderData = true}) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      switch (m.role) {
        case Role.system:
          out.add({'role': 'system', 'content': m.text});
        case Role.user:
          final files = m.files;
          out.add({
            'role': 'user',
            'content': files.isEmpty
                ? m.text
                : [
                    for (final p in m.parts)
                      if (p is TextPart) {'type': 'text', 'text': p.text} else if (p is FilePart) _fileJson(p),
                  ],
          });
        case Role.assistant:
          final calls = m.toolCalls;
          final details = m.providerData?['reasoning_details'];
          out.add({
            'role': 'assistant',
            'content': m.text.isEmpty && calls.isNotEmpty ? null : m.text,
            if (calls.isNotEmpty)
              'tool_calls': [
                for (final c in calls)
                  {
                    'id': c.id,
                    'type': 'function',
                    'function': {'name': c.name, 'arguments': jsonEncode(c.input)},
                    if (withProviderData && c.providerData?['extra_content'] != null) 'extra_content': c.providerData!['extra_content'],
                  },
              ],
            if (withProviderData && details is List && details.isNotEmpty) 'reasoning_details': details,
          });
        case Role.tool:
          for (final r in m.toolResults) {
            out.add({'role': 'tool', 'tool_call_id': r.toolCallId, 'content': r.outputText});
          }
      }
    }
    return out;
  }

  Map<String, dynamic> _fileJson(FilePart p) {
    if (p.isImage) {
      return {
        'type': 'image_url',
        'image_url': {'url': p.dataUrl},
      };
    }
    if (p.isAudio && p.bytes != null) {
      return {
        'type': 'input_audio',
        'input_audio': {'data': p.base64, 'format': inputAudioFormat(p.mediaType, filename: p.filename)},
      };
    }
    return {
      'type': 'file',
      'file': {
        'filename': p.filename ?? 'file.${GeneratedFile.extensionFor(p.mediaType)}',
        'file_data': p.dataUrl,
      },
    };
  }

  Map<String, dynamic> chatBody(String modelId, LanguageModelRequest r, {required bool stream, bool plain = false}) {
    final tc = r.toolChoice;
    final rf = r.responseFormat;
    final body = <String, dynamic>{
      'model': modelId,
      'messages': messagesJson(r.messages, withProviderData: !plain),
      'stream': stream,
      if (stream) 'stream_options': {'include_usage': true},
      if (r.tools.isNotEmpty) 'tools': toolsJson(modelId, r.tools),
      if (r.tools.isNotEmpty && tc != null)
        'tool_choice': tc.kind == 'tool'
            ? {
                'type': 'function',
                'function': {'name': tc.toolName},
              }
            : tc.kind,
      if (r.temperature != null) 'temperature': r.temperature,
      if (r.topP != null) 'top_p': r.topP,
      if (r.maxOutputTokens != null) 'max_tokens': r.maxOutputTokens,
      if (r.stopSequences != null) 'stop': r.stopSequences,
      if (r.seed != null) 'seed': r.seed,
      if (rf != null)
        'response_format': rf.schema == null
            ? {'type': 'json_object'}
            : {
                'type': 'json_schema',
                'json_schema': {'name': rf.name, 'schema': rf.schema, 'strict': false},
              },
      if (r.outputImages) 'modalities': ['image', 'text'],
      if (!plain) ...reasoningBody(modelId, r.reasoning),
      ...extraBody(modelId, r),
    };
    return deepMerge(body, r.providerOptions);
  }
}

/// A chat model on an [OpenAICompatibleProvider].
class OpenAIChatModel implements LanguageModel {
  OpenAIChatModel(this.p, this.modelId);
  final OpenAICompatibleProvider p;
  @override
  final String modelId;
  @override
  String get provider => p.id;

  @override
  Stream<StreamPart> stream(LanguageModelRequest request, {CancelToken? cancelToken}) async* {
    // `await for`, not `yield*`, so the retry below can catch the error.
    try {
      await for (final e in _stream(request, cancelToken, plain: false)) {
        yield e;
      }
    } on _RetryPlain {
      // The provider refused reasoning options or returned details; ask
      // again without them.
      await for (final e in _stream(request, cancelToken, plain: true)) {
        yield e;
      }
    }
  }

  Stream<StreamPart> _stream(LanguageModelRequest r, CancelToken? token, {required bool plain}) async* {
    final req = http.Request('POST', Uri.parse(p.chatUrl))
      ..headers.addAll({...p.authHeaders(), 'Content-Type': 'application/json', ...r.headers})
      ..body = jsonEncode(p.chatBody(modelId, r, stream: true, plain: plain));

    final calls = <int, ({String id, String name, StringBuffer args, Map<String, dynamic> extra})>{};
    final details = <Map<String, dynamic>>[];
    var finish = FinishReason.unknown;
    var usage = const Usage();
    var wrote = false;

    Stream<String> data;
    try {
      data = sseData(p.net.lines(req, cancelToken: token, connectTimeout: p.connectTimeout));
      await for (final chunk in data) {
        final Map<String, dynamic> j;
        try {
          j = jsonDecode(chunk) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        if (j['error'] != null) throw p.net.apiError(400, chunk);
        if (j['usage'] is Map) usage = Usage.fromJson(j['usage']);
        final choices = j['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final first = choices.first as Map;
        if (first['finish_reason'] != null) finish = FinishReason.parse('${first['finish_reason']}');
        final d = first['delta'] ?? first['message'];
        if (d is! Map) continue;

        final thinking = d['reasoning'] ?? d['reasoning_content'];
        if (thinking is String && thinking.isNotEmpty) {
          wrote = true;
          yield ReasoningDelta(thinking);
        }
        if (d['reasoning_details'] is List) {
          for (final rd in d['reasoning_details'] as List) {
            _mergeDetail(details, rd);
            if (thinking == null && rd is Map) {
              final t = rd['text'] ?? rd['summary'];
              if (t is String && t.isNotEmpty) yield ReasoningDelta(t);
            }
          }
        }

        final content = d['content'];
        final text = content is List ? content.map((c) => c is Map ? (c['text'] ?? '') : '$c').join() : content;
        if (text is String && text.isNotEmpty) {
          wrote = true;
          yield TextDelta(text);
        }

        final images = d['images'];
        if (images is List) {
          for (final img in images.whereType<Map>()) {
            final url = (img['image_url'] as Map?)?['url'] as String?;
            if (url == null) continue;
            wrote = true;
            yield FileOutput(url.startsWith('data:') ? GeneratedFile.fromDataUrl(url) : await downloadFile(p.net, url, cancelToken: token));
          }
        }

        final annotations = d['annotations'];
        if (annotations is List) {
          for (final a in annotations.whereType<Map>()) {
            final c = a['url_citation'];
            if (c is Map && c['url'] != null) yield SourceOutput(url: '${c['url']}', title: c['title'] as String?);
          }
        }

        final toolCalls = d['tool_calls'];
        if (toolCalls is List) {
          for (final tc in toolCalls.whereType<Map>()) {
            final index = (tc['index'] as num?)?.toInt() ?? calls.length;
            final fn = (tc['function'] as Map?) ?? const {};
            var call = calls[index];
            if (call == null) {
              final id = '${tc['id'] ?? 'call_${DateTime.now().microsecondsSinceEpoch}_$index'}';
              call = calls[index] = (id: id, name: '${fn['name'] ?? ''}', args: StringBuffer(), extra: <String, dynamic>{});
              wrote = true;
              yield ToolCallStart(id: id, name: call.name);
            }
            if (tc['extra_content'] is Map) call.extra.addAll(Map<String, dynamic>.from(tc['extra_content'] as Map));
            final args = fn['arguments'];
            final piece = args is String ? args : (args is Map ? jsonEncode(args) : null);
            if (piece != null && piece.isNotEmpty) {
              call.args.write(piece);
              yield ToolInputDelta(id: call.id, delta: piece);
            }
          }
        }
      }
    } on AiException catch (e) {
      final hasDetails = r.messages.any((m) => m.providerData?['reasoning_details'] != null);
      if (!plain && !wrote && e.statusCode == 400 && (r.reasoning != null || hasDetails)) throw _RetryPlain();
      rethrow;
    }

    final ordered = calls.keys.toList()..sort();
    for (final i in ordered) {
      final c = calls[i]!;
      yield ToolCall(ToolCallPart(
        id: c.id,
        name: c.name,
        input: parseToolArgs(c.args.toString()),
        providerData: c.extra.isEmpty ? null : {'extra_content': c.extra},
      ));
    }
    if (calls.isNotEmpty && finish == FinishReason.stop) finish = FinishReason.toolCalls;
    yield StepFinish(
      finishReason: finish,
      usage: usage,
      providerData: details.isEmpty ? null : {'reasoning_details': details},
    );
  }

  /// Reasoning details arrive in fragments sharing an index; text and
  /// signatures are joined per index, as the provider wants them back.
  static void _mergeDetail(List<Map<String, dynamic>> details, Object? r) {
    if (r is! Map) return;
    final index = r['index'];
    final existing = index == null ? null : details.where((d) => d['index'] == index).firstOrNull;
    if (existing == null) {
      details.add(Map<String, dynamic>.from(r));
      return;
    }
    for (final key in const ['text', 'signature', 'data', 'summary']) {
      final v = r[key];
      if (v is String) existing[key] = '${existing[key] ?? ''}$v';
    }
    r.forEach((k, v) => existing.putIfAbsent('$k', () => v));
  }
}

class _RetryPlain implements Exception {}

/// The `input_audio.format` name for a clip: `wav`, `mp3`, `ogg`, `flac`,
/// `aac`, `webm`. Voice notes from messengers (Opus in Ogg, `.oga`) and
/// phone recordings (`.m4a`) are common; the file name decides when the
/// media type is vague.
String inputAudioFormat(String mediaType, {String? filename}) {
  final ext = filename == null || !filename.contains('.') ? '' : filename.split('.').last.toLowerCase();
  switch (mediaType.toLowerCase()) {
    case 'audio/mpeg' || 'audio/mp3':
      return 'mp3';
    case 'audio/wav' || 'audio/x-wav' || 'audio/wave':
      return 'wav';
    case 'audio/ogg' || 'audio/opus':
      return 'ogg';
    case 'audio/flac' || 'audio/x-flac':
      return 'flac';
    case 'audio/aac' || 'audio/mp4' || 'audio/x-m4a' || 'audio/m4a':
      return 'aac';
    case 'audio/webm':
      return 'webm';
  }
  return switch (ext) {
    'mp3' => 'mp3',
    'ogg' || 'oga' || 'opus' => 'ogg',
    'flac' => 'flac',
    'm4a' || 'aac' || 'mp4' => 'aac',
    'webm' => 'webm',
    _ => 'wav',
  };
}

/// Tool arguments as a map, tolerating empty or broken JSON.
Map<String, dynamic> parseToolArgs(String raw) {
  if (raw.trim().isEmpty) return {};
  try {
    final v = jsonDecode(raw);
    if (v is Map) return Map<String, dynamic>.from(v);
    if (v is String) return parseToolArgs(v);
    return {'value': v};
  } catch (_) {
    return {'_raw': raw};
  }
}

/// Fetches a URL into a [GeneratedFile]; decodes `data:` URLs.
Future<GeneratedFile> downloadFile(AiHttp net, String url,
    {Map<String, String>? headers, CancelToken? cancelToken, String? mediaType}) async {
  if (url.startsWith('data:')) return GeneratedFile.fromDataUrl(url);
  final r = await net.get(Uri.parse(url), headers: headers, timeout: const Duration(minutes: 3), cancelToken: cancelToken);
  if (r.statusCode != 200) {
    throw AiException('Could not download the generated file (${r.statusCode}).', provider: net.provider, statusCode: r.statusCode);
  }
  final type = mediaType ?? r.headers['content-type']?.split(';').first;
  return GeneratedFile(r.bodyBytes,
      mediaType: type == null || type == 'application/octet-stream' || type == 'binary/octet-stream' ? sniffMediaType(r.bodyBytes) : type,
      url: url);
}

/// Images through `/images/generations` (and `/images/edits`), or through
/// chat `modalities` for multimodal models, falling back between the two.
class OpenAIImageModel implements ImageModel {
  OpenAIImageModel(this.p, this.modelId);
  final OpenAICompatibleProvider p;
  @override
  final String modelId;
  @override
  String get provider => p.id;

  @override
  Future<ImageResult> generate(ImageRequest r, {CancelToken? cancelToken}) async {
    final viaChat = p.chatImages(modelId);
    try {
      return viaChat ? await _chat(r, cancelToken) : await _images(r, cancelToken);
    } on AiException catch (e) {
      final retry = e.statusCode == 400 || e.statusCode == 404 || e.statusCode == 422 || e is _NoImage;
      if (!retry) rethrow;
      return viaChat ? _images(r, cancelToken) : _chat(r, cancelToken);
    }
  }

  Future<ImageResult> _images(ImageRequest r, CancelToken? token) async {
    final dynamic j;
    if (r.referenceImages.isNotEmpty) {
      j = p.net.json(await p.net.multipart(
        Uri.parse('${p.baseUrl}/images/edits'),
        headers: p.authHeaders(),
        fields: {
          'model': modelId,
          'prompt': r.prompt,
          'n': '${r.n}',
          if (r.size != null) 'size': r.size!,
          for (final e in r.providerOptions.entries) e.key: '${e.value}',
        },
        files: [
          for (var i = 0; i < r.referenceImages.length; i++)
            http.MultipartFile.fromBytes('image[]', r.referenceImages[i],
                filename: 'image$i.${GeneratedFile.extensionFor(sniffMediaType(r.referenceImages[i]))}'),
        ],
        timeout: const Duration(minutes: 4),
        cancelToken: token,
      ));
    } else {
      j = p.net.json(await p.net.post(
        Uri.parse('${p.baseUrl}/images/generations'),
        headers: p.authHeaders(),
        json: deepMerge({
          'model': modelId,
          'prompt': r.prompt,
          'n': r.n,
          if (r.size != null) 'size': r.size,
          if (r.aspectRatio != null) 'aspect_ratio': r.aspectRatio,
          if (r.seed != null) 'seed': r.seed,
          'response_format': 'b64_json',
        }, r.providerOptions),
        timeout: const Duration(minutes: 4),
        cancelToken: token,
      ));
    }
    final data = j is Map ? j['data'] : null;
    final images = <GeneratedFile>[];
    for (final d in (data as List? ?? const []).whereType<Map>()) {
      if (d['b64_json'] is String) {
        images.add(GeneratedFile.fromBase64(d['b64_json'] as String));
      } else if (d['url'] is String) {
        images.add(await downloadFile(p.net, d['url'] as String, cancelToken: token));
      }
    }
    if (images.isEmpty) throw _NoImage();
    return ImageResult(images, usage: Usage.fromJson(j is Map ? j['usage'] : null));
  }

  Future<ImageResult> _chat(ImageRequest r, CancelToken? token) async {
    final content = r.referenceImages.isEmpty
        ? r.prompt
        : [
            {'type': 'text', 'text': r.prompt},
            for (final img in r.referenceImages)
              {
                'type': 'image_url',
                'image_url': {'url': 'data:${sniffMediaType(img, fallback: 'image/png')};base64,${base64Encode(img)}'},
              },
          ];
    final j = p.net.json(await p.net.post(
      Uri.parse(p.chatUrl),
      headers: p.authHeaders(),
      json: deepMerge({
        'model': modelId,
        'messages': [
          {'role': 'user', 'content': content},
        ],
        'modalities': ['image', 'text'],
        if (r.aspectRatio != null) 'image_config': {'aspect_ratio': r.aspectRatio},
        'stream': false,
      }, r.providerOptions),
      timeout: const Duration(minutes: 4),
      cancelToken: token,
    ));
    final choices = j is Map ? j['choices'] : null;
    final message = choices is List && choices.isNotEmpty ? choices.first['message'] : null;
    final images = <GeneratedFile>[];
    for (final img in ((message is Map ? message['images'] : null) as List? ?? const []).whereType<Map>()) {
      final url = (img['image_url'] as Map?)?['url'] as String?;
      if (url != null) images.add(await downloadFile(p.net, url, cancelToken: token));
    }
    if (images.isEmpty) throw _NoImage();
    final text = message is Map ? message['content'] : null;
    return ImageResult(images, text: text is String && text.isNotEmpty ? text : null, usage: Usage.fromJson(j['usage']));
  }
}

class _NoImage extends AiException {
  _NoImage() : super('The model answered without an image. Pick an image model.');
}

/// `/embeddings`.
class OpenAIEmbeddingModel implements EmbeddingModel {
  OpenAIEmbeddingModel(this.p, this.modelId);
  final OpenAICompatibleProvider p;
  @override
  final String modelId;
  @override
  String get provider => p.id;

  @override
  Future<EmbeddingResult> embed(List<String> values, {int? dimensions, CancelToken? cancelToken}) async {
    final j = p.net.json(await p.net.post(
      Uri.parse('${p.baseUrl}/embeddings'),
      headers: p.authHeaders(),
      json: {'model': modelId, 'input': values, if (dimensions != null) 'dimensions': dimensions},
      cancelToken: cancelToken,
    )) as Map;
    final data = [for (final d in (j['data'] as List)) d as Map]
      ..sort((a, b) => ((a['index'] as num?) ?? 0).compareTo((b['index'] as num?) ?? 0));
    return EmbeddingResult(
      [
        for (final d in data) [for (final v in d['embedding'] as List) (v as num).toDouble()],
      ],
      usage: Usage.fromJson(j['usage']),
    );
  }
}

/// `/audio/speech`.
class OpenAISpeechModel implements SpeechModel {
  OpenAISpeechModel(this.p, this.modelId);
  final OpenAICompatibleProvider p;
  @override
  final String modelId;
  @override
  String get provider => p.id;

  @override
  Future<GeneratedFile> speak(SpeechRequest r, {CancelToken? cancelToken}) async {
    final res = await p.net.post(
      Uri.parse('${p.baseUrl}/audio/speech'),
      headers: p.authHeaders(),
      json: deepMerge({
        'model': modelId,
        'input': r.text,
        'voice': r.voice ?? 'alloy',
        'response_format': r.outputFormat ?? 'mp3',
        if (r.speed != null) 'speed': r.speed,
        if (r.instructions != null) 'instructions': r.instructions,
      }, r.providerOptions),
      cancelToken: cancelToken,
    );
    p.net.ensureOk(res);
    if (res.bodyBytes.isEmpty) throw AiException('The voice model returned no audio.', provider: p.id);
    return GeneratedFile(res.bodyBytes, mediaType: sniffMediaType(res.bodyBytes, fallback: 'audio/mpeg'));
  }
}

/// `/audio/transcriptions` (Whisper-style).
class OpenAITranscriptionModel implements TranscriptionModel {
  OpenAITranscriptionModel(this.p, this.modelId);
  final OpenAICompatibleProvider p;
  @override
  final String modelId;
  @override
  String get provider => p.id;

  @override
  Future<TranscriptionResult> transcribe(TranscriptionRequest r, {CancelToken? cancelToken}) async {
    final type = r.mediaType ?? sniffMediaType(r.audio, fallback: 'audio/wav');
    final j = p.net.json(await p.net.multipart(
      Uri.parse('${p.baseUrl}/audio/transcriptions'),
      headers: p.authHeaders(),
      fields: {
        'model': modelId,
        'response_format': modelId.contains('whisper') ? 'verbose_json' : 'json',
        if (r.language != null) 'language': r.language!,
        if (r.prompt != null) 'prompt': r.prompt!,
        for (final e in r.providerOptions.entries) e.key: '${e.value}',
      },
      files: [http.MultipartFile.fromBytes('file', r.audio, filename: 'audio.${GeneratedFile.extensionFor(type)}')],
      cancelToken: cancelToken,
    ));
    if (j is! Map) return const TranscriptionResult(text: '');
    return TranscriptionResult(
      text: '${j['text'] ?? ''}'.trim(),
      language: j['language'] as String?,
      duration: j['duration'] is num ? Duration(milliseconds: ((j['duration'] as num) * 1000).round()) : null,
      segments: [
        for (final s in (j['segments'] as List? ?? const []).whereType<Map>())
          TranscriptionSegment(
            text: '${s['text'] ?? ''}'.trim(),
            start: Duration(milliseconds: (((s['start'] as num?) ?? 0) * 1000).round()),
            end: Duration(milliseconds: (((s['end'] as num?) ?? 0) * 1000).round()),
          ),
      ],
    );
  }
}

/// Transcribes with any chat model that hears audio (Gemini, GPT-4o
/// audio…): sends the recording and asks for the words.
class ChatTranscriptionModel implements TranscriptionModel {
  ChatTranscriptionModel(this.model);
  final LanguageModel model;
  @override
  String get modelId => model.modelId;
  @override
  String get provider => model.provider;

  @override
  Future<TranscriptionResult> transcribe(TranscriptionRequest r, {CancelToken? cancelToken}) async {
    final buf = StringBuffer();
    final ask = 'Transcribe this recording verbatim, in the language spoken'
        '${r.language == null ? '' : ' (${r.language})'}. Reply with the transcript only, no quotes or notes. '
        'If nothing is said, reply with nothing.${r.prompt == null ? '' : '\nContext: ${r.prompt}'}';
    await for (final part in model.stream(
      LanguageModelRequest(
        messages: [
          Message.user(ask, files: [FilePart(bytes: r.audio, mediaType: r.mediaType ?? sniffMediaType(r.audio, fallback: 'audio/wav'))]),
        ],
        temperature: 0,
        providerOptions: r.providerOptions,
      ),
      cancelToken: cancelToken,
    )) {
      if (part is TextDelta) buf.write(part.text);
    }
    return TranscriptionResult(text: buf.toString().trim(), language: r.language);
  }
}

/// Bytes into a `data:` URL.
String dataUrl(Uint8List bytes, String mediaType) => 'data:$mediaType;base64,${base64Encode(bytes)}';
