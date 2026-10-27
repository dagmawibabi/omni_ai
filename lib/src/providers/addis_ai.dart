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
import '../core/usage.dart';
import 'openai_compatible.dart' show downloadFile;
import 'provider.dart';

/// Addis AI: chat, voices and transcription in Amharic, Afaan Oromo and
/// Tigrinya. Get a key at https://platform.addisassistant.com.
///
/// Chat model id: `addis-chat` (the language is set with [language]).
/// Speech: pass an Addis voice id from [listVoices].
class AddisAiProvider extends AiProvider {
  AddisAiProvider({this.apiKey, this.language = 'am', http.Client? httpClient}) : net = AiHttp(provider: 'Addis AI', client: httpClient);

  static const baseUrl = 'https://api.addisassistant.com';

  String? apiKey;

  /// Reply language: `am` (Amharic), `om` (Afaan Oromo) or `ti` (Tigrinya, voices).
  String language;
  final AiHttp net;

  /// Languages Addis voices speak.
  static const voiceLanguages = {'am', 'om', 'ti'};

  @override
  String get id => 'addis';
  @override
  String get name => 'Addis AI';
  @override
  String get apiKeyUrl => 'https://platform.addisassistant.com';
  @override
  String get docsUrl => 'https://docs.addisassistant.com';
  @override
  bool get isConfigured => apiKey?.trim().isNotEmpty ?? false;
  @override
  Set<ModelType> get capabilities => const {ModelType.text, ModelType.speech, ModelType.transcription};

  @override
  Map<ModelType, String> get defaultModels => const {
        ModelType.text: 'addis-chat',
        ModelType.speech: 'voices-2',
        ModelType.transcription: 'stt-v2',
      };

  Map<String, String> headers({bool json = true}) {
    final key = apiKey?.trim() ?? '';
    if (key.isEmpty) throw MissingApiKeyException(id, name);
    return {'x-api-key': key, if (json) 'Content-Type': 'application/json'};
  }

  @override
  LanguageModel languageModel(String modelId) => _AddisChat(this, modelId);
  @override
  SpeechModel speechModel(String modelId) => _AddisSpeech(this, modelId);
  @override
  TranscriptionModel transcriptionModel(String modelId) => _AddisStt(this, modelId);

  @override
  Future<List<ModelInfo>> listModels({CancelToken? cancelToken}) async => [
        ModelInfo(
          provider: id,
          modelId: 'addis-chat',
          name: 'Addis AI Chat',
          lab: 'addis',
          description: 'Chat in Amharic and Afaan Oromo.',
          types: const {ModelType.text},
        ),
        ModelInfo(
          provider: id,
          modelId: 'voices-2',
          name: 'Addis Voices 2',
          lab: 'addis',
          description: 'Speech in Amharic, Afaan Oromo and Tigrinya.',
          types: const {ModelType.speech},
          outputModalities: const ['audio'],
        ),
        ModelInfo(
          provider: id,
          modelId: 'stt-v2',
          name: 'Addis Speech to Text',
          lab: 'addis',
          description: 'Transcribes Amharic and Afaan Oromo.',
          types: const {ModelType.transcription},
          inputModalities: const ['audio'],
        ),
      ];

  @override
  Future<List<Voice>> listVoices({String? modelId, String? language, CancelToken? cancelToken}) async {
    final q = language == null || language.isEmpty ? '' : '?language=$language';
    final j = net.json(await net.get(Uri.parse('$baseUrl/api/v1/voice/voices$q'), headers: headers(), cancelToken: cancelToken));
    final list = j is Map ? (j['data'] ?? j['voices'] ?? const []) : j;
    return [
      for (final v in (list as List? ?? const []).whereType<Map>())
        if ('${v['id'] ?? ''}'.isNotEmpty)
          Voice(
            id: '${v['id']}',
            name: '${v['name'] ?? v['id']}',
            provider: id,
            language: v['language'] as String?,
            gender: v['gender'] as String?,
            description: v['style'] as String?,
            previewUrl: v['preview_url'] as String?,
          ),
    ]..sort((a, b) => a.name.compareTo(b.name));
  }

  /// A ready-made sample of [voiceId], when Addis has one.
  Future<String?> voicePreviewUrl(String voiceId) async {
    try {
      final j = net.json(await net.get(Uri.parse('$baseUrl/api/v1/voice/voices/$voiceId/preview'), headers: headers()));
      final d = j is Map ? (j['data'] ?? j) : null;
      if (d is! Map) return null;
      return '${d['preview_url'] ?? d['url'] ?? d['audio_url'] ?? (d['playback'] is Map ? d['playback']['url'] : '')}'.nullIfEmpty;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> verify() async {
    try {
      await listVoices();
      return null;
    } on AiException catch (e) {
      return e.message;
    }
  }

  /// The language of a voice id: from its prefix (`am-…`) or the catalog.
  Future<String?> languageOfVoice(String voiceId) async {
    final prefix = voiceId.split(RegExp(r'[-_]')).first.toLowerCase();
    if (voiceLanguages.contains(prefix)) return prefix;
    final match = (await listVoices()).where((v) => v.id == voiceId).firstOrNull;
    return match?.language;
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty || this == 'null' ? null : this;
}

class _AddisChat implements LanguageModel {
  _AddisChat(this.p, this.modelId);
  final AddisAiProvider p;
  @override
  final String modelId;
  @override
  String get provider => p.id;

  @override
  Stream<StreamPart> stream(LanguageModelRequest r, {CancelToken? cancelToken}) async* {
    if (r.tools.isNotEmpty) throw UnsupportedFeatureException('Addis AI does not support tools.', provider: p.id);
    final turns = r.messages.where((m) => m.role != Role.system && m.role != Role.tool).toList();
    final last = turns.lastWhere((m) => m.role == Role.user, orElse: () => throw const AiException('Addis AI needs a user message.'));
    final system = r.messages.where((m) => m.role == Role.system).map((m) => m.text).join('\n\n');
    final history = turns.sublist(0, turns.lastIndexOf(last));
    final hasFiles = last.files.isNotEmpty;
    final lang = (r.providerOptions['target_language'] as String?) ?? p.language;
    final body = <String, dynamic>{
      'prompt': system.isEmpty ? last.text : '$system\n\n${last.text}',
      'target_language': lang,
      if (history.isNotEmpty)
        'conversation_history': [
          for (final m in history)
            {
              'role': m.role == Role.assistant ? 'assistant' : 'user',
              'content': m.text,
            },
        ],
      'generation_config': {
        if (r.temperature != null) 'temperature': r.temperature,
        if (r.maxOutputTokens != null) 'maxOutputTokens': r.maxOutputTokens,
        'stream': !hasFiles,
      },
      ...Map.of(r.providerOptions)..remove('target_language'),
    };

    var usage = const Usage();
    var finish = FinishReason.stop;
    if (hasFiles) {
      // Attachments go as multipart and can't stream.
      final j = p.net.json(await p.net.multipart(
        Uri.parse('${AddisAiProvider.baseUrl}/api/v1/chat_generate'),
        headers: p.headers(json: false),
        fields: {'request_data': jsonEncode(body)},
        files: [
          for (final (i, f) in last.files.indexed)
            if (f.bytes != null)
              http.MultipartFile.fromBytes('attachment${i + 1}', f.bytes!,
                  filename: f.filename ?? 'file$i.${GeneratedFile.extensionFor(f.mediaType)}'),
        ],
        cancelToken: cancelToken,
      ));
      final text = _text(j);
      if (text.isNotEmpty) yield TextDelta(text);
      usage = Usage.fromJson(_usage(j));
      yield StepFinish(finishReason: FinishReason.parse(_finish(j) ?? 'stop'), usage: usage);
      return;
    }

    final req = http.Request('POST', Uri.parse('${AddisAiProvider.baseUrl}/api/v1/chat_generate'))
      ..headers.addAll(p.headers())
      ..body = jsonEncode(body);
    await for (final raw in p.net.lines(req, cancelToken: cancelToken)) {
      var line = raw.trim();
      if (line.isEmpty || line.startsWith(':') || line.startsWith('event:')) continue;
      if (line.startsWith('data:')) line = line.substring(5).trim();
      if (line == '[DONE]') break;
      final Object? j;
      try {
        j = jsonDecode(line);
      } catch (_) {
        continue;
      }
      if (j is Map && j['error'] != null) throw p.net.apiError(400, line);
      final text = _text(j);
      if (text.isNotEmpty) yield TextDelta(text);
      if (_usage(j) != null) usage = Usage.fromJson(_usage(j));
      final f = _finish(j);
      if (f != null) finish = FinishReason.parse(f);
    }
    yield StepFinish(finishReason: finish, usage: usage);
  }

  /// Text from a native (`response_text`) or OpenAI-shaped chunk.
  static String _text(Object? j) {
    if (j is! Map) return '';
    final data = j['data'] is Map ? j['data'] as Map : j;
    final t = data['response_text'] ?? data['text'];
    if (t is String) return t;
    final choices = data['choices'];
    if (choices is List && choices.isNotEmpty) {
      final c = choices.first as Map;
      final d = c['delta'] ?? c['message'];
      if (d is Map && d['content'] is String) return d['content'] as String;
    }
    return '';
  }

  static Object? _usage(Object? j) =>
      j is Map ? (j['usage_metadata'] ?? j['usage'] ?? (j['data'] is Map ? (j['data'] as Map)['usage_metadata'] : null)) : null;

  static String? _finish(Object? j) {
    if (j is! Map) return null;
    final f = j['finish_reason'] ?? (j['is_last_chunk'] == true ? 'stop' : null);
    return f?.toString();
  }
}

class _AddisSpeech implements SpeechModel {
  _AddisSpeech(this.p, this.modelId);
  final AddisAiProvider p;
  @override
  final String modelId;
  @override
  String get provider => p.id;

  @override
  Future<GeneratedFile> speak(SpeechRequest r, {CancelToken? cancelToken}) async {
    final voice = r.voice;
    if (voice == null || voice.isEmpty) throw AiException('Pick an Addis AI voice (see listVoices).', provider: p.id);
    final language = r.language ?? await p.languageOfVoice(voice) ?? p.language;
    final j = p.net.json(await p.net.post(
      Uri.parse('${AddisAiProvider.baseUrl}/api/v1/voice/generations'),
      headers: p.headers(),
      json: deepMerge({
        'text': r.text,
        'voice_id': voice,
        'language': language,
        'output_format': r.outputFormat ?? 'mp3_44100',
        'stream': false,
        'client_request_id': '${DateTime.now().microsecondsSinceEpoch}',
        if (r.speed != null) 'voice_settings': {'speed': r.speed},
      }, r.providerOptions),
      timeout: const Duration(seconds: 95),
      cancelToken: cancelToken,
    ));
    final data = j is Map ? (j['data'] ?? j) : const {};
    if (data is Map && data['audio'] is String) return GeneratedFile.fromBase64(data['audio'] as String);
    final playback = data is Map ? data['playback'] : null;
    final url = data is Map ? '${data['audio_url'] ?? (playback is Map ? playback['url'] : '') ?? ''}' : '';
    if (url.isEmpty || url == 'null') throw AiException('Addis AI returned no audio.', provider: p.id);
    return downloadFile(p.net, url, cancelToken: cancelToken);
  }
}

class _AddisStt implements TranscriptionModel {
  _AddisStt(this.p, this.modelId);
  final AddisAiProvider p;
  @override
  final String modelId;
  @override
  String get provider => p.id;

  @override
  Future<TranscriptionResult> transcribe(TranscriptionRequest r, {CancelToken? cancelToken}) async {
    final lang = r.language ?? p.language;
    final type = r.mediaType ?? sniffMediaType(r.audio, fallback: 'audio/wav');
    final j = p.net.json(await p.net.multipart(
      Uri.parse('${AddisAiProvider.baseUrl}/api/v2/stt'),
      headers: p.headers(json: false),
      fields: {
        'request_data': jsonEncode({'language_code': lang, ...r.providerOptions})
      },
      files: [http.MultipartFile.fromBytes('audio', r.audio, filename: 'audio.${GeneratedFile.extensionFor(type)}')],
      cancelToken: cancelToken,
    ));
    final data = j is Map ? (j['data'] ?? j) : const {};
    return TranscriptionResult(text: '${data is Map ? data['transcription'] ?? data['text'] ?? '' : ''}'.trim(), language: lang);
  }
}
