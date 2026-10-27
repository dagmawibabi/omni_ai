import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../catalog/model_info.dart';
import '../core/cancel.dart';
import '../core/errors.dart';
import '../core/http.dart';
import '../core/media.dart';
import '../core/models.dart';
import 'provider.dart';

/// ElevenLabs: lifelike voices, transcription (Scribe), sound effects and
/// music. Get a key at https://elevenlabs.io/app/settings/api-keys.
///
/// Speech model ids: `eleven_flash_v2_5` (fast, cheap), `eleven_multilingual_v2`,
/// `eleven_v3` (most expressive). Pass a voice id from [listVoices].
class ElevenLabsProvider extends AiProvider {
  ElevenLabsProvider({this.apiKey, http.Client? httpClient}) : net = AiHttp(provider: 'ElevenLabs', client: httpClient);

  static const baseUrl = 'https://api.elevenlabs.io/v1';

  /// "Rachel", a default voice every account has.
  static const defaultVoice = '21m00Tcm4TlvDq8ikWAM';

  String? apiKey;
  final AiHttp net;

  @override
  String get id => 'elevenlabs';
  @override
  String get name => 'ElevenLabs';
  @override
  String get apiKeyUrl => 'https://elevenlabs.io/app/settings/api-keys';
  @override
  String get docsUrl => 'https://elevenlabs.io/docs/api-reference/introduction';
  @override
  bool get isConfigured => apiKey?.trim().isNotEmpty ?? false;
  @override
  Set<ModelType> get capabilities => const {ModelType.speech, ModelType.transcription, ModelType.soundEffect, ModelType.music};

  @override
  Map<ModelType, String> get defaultModels => const {
        ModelType.speech: 'eleven_flash_v2_5',
        ModelType.transcription: 'scribe_v1',
      };

  Map<String, String> headers({bool json = true}) {
    final key = apiKey?.trim() ?? '';
    if (key.isEmpty) throw MissingApiKeyException(id, name);
    return {'xi-api-key': key, if (json) 'Content-Type': 'application/json'};
  }

  @override
  SpeechModel speechModel(String modelId) => ElevenLabsSpeechModel(this, modelId);
  @override
  TranscriptionModel transcriptionModel(String modelId) => _Scribe(this, modelId);

  /// Speech models from the account's model list.
  @override
  Future<List<ModelInfo>> listModels({CancelToken? cancelToken}) async {
    final j = net.json(await net.get(Uri.parse('$baseUrl/models'), headers: headers(), cancelToken: cancelToken));
    return [
      for (final m in (j as List? ?? const []).whereType<Map>())
        if (m['can_do_text_to_speech'] == true)
          ModelInfo(
            provider: id,
            modelId: '${m['model_id']}',
            name: '${m['name'] ?? m['model_id']}',
            lab: 'elevenlabs',
            types: const {ModelType.speech},
            description: '${m['description'] ?? ''}',
            inputModalities: const ['text'],
            outputModalities: const ['audio'],
            extra: {
              'languages': [for (final l in (m['languages'] as List? ?? const []).whereType<Map>()) '${l['language_id']}'],
              'maxCharacters': m['maximum_text_length_per_request'],
              'costFactor': m['model_rates'] is Map ? (m['model_rates'] as Map)['character_cost_multiplier'] : null,
            },
          ),
      ModelInfo(
        provider: id,
        modelId: 'scribe_v1',
        name: 'Scribe v1',
        lab: 'elevenlabs',
        types: const {ModelType.transcription},
        inputModalities: const ['audio'],
        outputModalities: const ['text'],
      ),
    ];
  }

  /// The account's voices, each with a free preview clip.
  @override
  Future<List<Voice>> listVoices({String? modelId, String? language, CancelToken? cancelToken}) async {
    final j = net.json(await net.get(Uri.parse('$baseUrl/voices'), headers: headers(), cancelToken: cancelToken)) as Map;
    final out = <Voice>[
      for (final v in (j['voices'] as List? ?? const []).whereType<Map>())
        Voice(
          id: '${v['voice_id']}',
          name: '${v['name'] ?? 'Voice'}',
          provider: id,
          gender: (v['labels'] as Map?)?['gender'] as String?,
          language: (v['labels'] as Map?)?['language'] as String?,
          description: v['description'] as String?,
          previewUrl: v['preview_url'] as String?,
          labels: {for (final e in ((v['labels'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
        ),
    ]..sort((a, b) => a.name.compareTo(b.name));
    return language == null ? out : out.where((v) => v.language == null || v.language == language).toList();
  }

  @override
  Future<String?> verify() async {
    try {
      net.json(await net.get(Uri.parse('$baseUrl/user'), headers: headers(), timeout: const Duration(seconds: 20)));
      return null;
    } on AiException catch (e) {
      return e.message;
    }
  }

  /// Characters used and left this period: `{character_count, character_limit, tier…}`.
  Future<Map<String, dynamic>> subscription() async =>
      Map<String, dynamic>.from(net.json(await net.get(Uri.parse('$baseUrl/user/subscription'), headers: headers())) as Map);

  /// Speech as it is made, for playback that starts sooner.
  Stream<Uint8List> streamSpeech({
    required String text,
    String voice = defaultVoice,
    String model = 'eleven_flash_v2_5',
    String outputFormat = 'mp3_44100_128',
    Map<String, dynamic> voiceSettings = const {},
    CancelToken? cancelToken,
  }) {
    final req = http.Request('POST', Uri.parse('$baseUrl/text-to-speech/$voice/stream?output_format=$outputFormat'))
      ..headers.addAll({...headers(), 'Accept': 'audio/mpeg'})
      ..body = jsonEncode({'text': text, 'model_id': model, if (voiceSettings.isNotEmpty) 'voice_settings': voiceSettings});
    return net.bytes(req, cancelToken: cancelToken).map(Uint8List.fromList);
  }

  /// A sound effect from a description ("glass shattering on tile").
  Future<GeneratedFile> soundEffect(String prompt,
      {double? durationSeconds, double? promptInfluence, bool loop = false, CancelToken? cancelToken}) async {
    final r = await net.post(
      Uri.parse('$baseUrl/sound-generation'),
      headers: headers(),
      json: {
        'text': prompt,
        if (durationSeconds != null) 'duration_seconds': durationSeconds,
        if (promptInfluence != null) 'prompt_influence': promptInfluence,
        if (loop) 'loop': true,
      },
      cancelToken: cancelToken,
    );
    net.ensureOk(r);
    return GeneratedFile(r.bodyBytes, mediaType: sniffMediaType(r.bodyBytes, fallback: 'audio/mpeg'));
  }

  /// A song or score from a prompt ("upbeat lo-fi for studying").
  Future<GeneratedFile> music(String prompt, {Duration length = const Duration(seconds: 30), CancelToken? cancelToken}) async {
    final r = await net.post(
      Uri.parse('$baseUrl/music'),
      headers: headers(),
      json: {'prompt': prompt, 'music_length_ms': length.inMilliseconds},
      timeout: const Duration(minutes: 5),
      cancelToken: cancelToken,
    );
    net.ensureOk(r);
    return GeneratedFile(r.bodyBytes, mediaType: sniffMediaType(r.bodyBytes, fallback: 'audio/mpeg'));
  }
}

class ElevenLabsSpeechModel implements SpeechModel {
  ElevenLabsSpeechModel(this.p, this.modelId);
  final ElevenLabsProvider p;
  @override
  final String modelId;
  @override
  String get provider => p.id;

  @override
  Future<GeneratedFile> speak(SpeechRequest r, {CancelToken? cancelToken}) async {
    final voice = r.voice == null || r.voice!.isEmpty ? ElevenLabsProvider.defaultVoice : r.voice!;
    final format = r.outputFormat ?? 'mp3_44100_128';
    final settings = {
      if (r.speed != null) 'speed': r.speed!.clamp(0.7, 1.2),
      ...?(r.providerOptions['voice_settings'] as Map<String, dynamic>?),
    };
    final res = await p.net.post(
      Uri.parse('${ElevenLabsProvider.baseUrl}/text-to-speech/$voice?output_format=$format'),
      headers: {...p.headers(), 'Accept': 'audio/mpeg'},
      json: {
        'text': r.instructions != null && modelId == 'eleven_v3' ? '[${r.instructions}] ${r.text}' : r.text,
        'model_id': modelId,
        if (r.language != null) 'language_code': r.language,
        if (settings.isNotEmpty) 'voice_settings': settings,
        ...Map.of(r.providerOptions)..remove('voice_settings'),
      },
      cancelToken: cancelToken,
    );
    p.net.ensureOk(res);
    return GeneratedFile(res.bodyBytes, mediaType: sniffMediaType(res.bodyBytes, fallback: 'audio/mpeg'));
  }
}

class _Scribe implements TranscriptionModel {
  _Scribe(this.p, this.modelId);
  final ElevenLabsProvider p;
  @override
  final String modelId;
  @override
  String get provider => p.id;

  @override
  Future<TranscriptionResult> transcribe(TranscriptionRequest r, {CancelToken? cancelToken}) async {
    final type = r.mediaType ?? sniffMediaType(r.audio, fallback: 'audio/wav');
    final j = p.net.json(await p.net.multipart(
      Uri.parse('${ElevenLabsProvider.baseUrl}/speech-to-text'),
      headers: p.headers(json: false),
      fields: {
        'model_id': modelId,
        if (r.language != null) 'language_code': r.language!,
        for (final e in r.providerOptions.entries) e.key: '${e.value}',
      },
      files: [http.MultipartFile.fromBytes('file', r.audio, filename: 'audio.${GeneratedFile.extensionFor(type)}')],
      cancelToken: cancelToken,
    )) as Map;
    final words = (j['words'] as List? ?? const []).whereType<Map>().where((w) => w['type'] != 'spacing').toList();
    Duration t(Object? s) => Duration(milliseconds: (((s as num?) ?? 0) * 1000).round());
    return TranscriptionResult(
      text: '${j['text'] ?? ''}'.trim(),
      language: j['language_code'] as String?,
      segments: [
        for (final w in words)
          TranscriptionSegment(text: '${w['text']}', start: t(w['start']), end: t(w['end']), speaker: w['speaker_id'] as String?),
      ],
      duration: words.isEmpty ? null : t(words.last['end']),
    );
  }
}
