import 'dart:typed_data';

import 'cancel.dart';
import 'media.dart';
import 'messages.dart';
import 'stream_parts.dart';
import 'tools.dart';
import 'usage.dart';

/// Ask for JSON output.
class ResponseFormat {
  const ResponseFormat.json({this.schema, this.name = 'response', this.description});
  final Map<String, dynamic>? schema;
  final String name;
  final String? description;
}

/// What a language model is asked, after `streamText` has resolved the
/// prompt into messages.
class LanguageModelRequest {
  const LanguageModelRequest({
    required this.messages,
    this.tools = const [],
    this.toolChoice,
    this.temperature,
    this.topP,
    this.topK,
    this.maxOutputTokens,
    this.stopSequences,
    this.seed,
    this.reasoning,
    this.responseFormat,
    this.outputImages = false,
    this.providerOptions = const {},
    this.headers = const {},
  });

  final List<Message> messages;
  final List<Tool> tools;
  final ToolChoice? toolChoice;
  final double? temperature;
  final double? topP;
  final int? topK;
  final int? maxOutputTokens;
  final List<String>? stopSequences;
  final int? seed;

  /// Null lets the provider decide.
  final ReasoningEffort? reasoning;
  final ResponseFormat? responseFormat;

  /// Ask a multimodal model for images in its reply.
  final bool outputImages;

  /// Merged into the request body as-is, e.g. `{'top_k': 20}` or
  /// `{'providerOptions': {'gateway': {'order': ['vertex']}}}`.
  final Map<String, dynamic> providerOptions;
  final Map<String, String> headers;
}

/// Something every model has.
abstract interface class AiModel {
  /// Provider id, e.g. `gateway`, `google`.
  String get provider;

  /// The provider's own model id, e.g. `openai/gpt-5`.
  String get modelId;
}

/// Writes text, calls tools, may think and make images.
abstract interface class LanguageModel implements AiModel {
  /// One model call. Emits [TextDelta], [ReasoningDelta], [ToolCallStart],
  /// [ToolInputDelta], [ToolCall], [FileOutput], [SourceOutput], and ends
  /// with exactly one [StepFinish].
  Stream<StreamPart> stream(LanguageModelRequest request, {CancelToken? cancelToken});
}

class ImageRequest {
  const ImageRequest({
    required this.prompt,
    this.n = 1,
    this.size,
    this.aspectRatio,
    this.seed,
    this.referenceImages = const [],
    this.providerOptions = const {},
  });
  final String prompt;
  final int n;

  /// e.g. `1024x1024`.
  final String? size;

  /// e.g. `16:9`.
  final String? aspectRatio;
  final int? seed;

  /// Images to edit or take style from, for models that accept them.
  final List<Uint8List> referenceImages;
  final Map<String, dynamic> providerOptions;
}

class ImageResult {
  const ImageResult(this.images, {this.text, this.usage = const Usage()});
  final List<GeneratedFile> images;

  /// Words a multimodal model wrote alongside.
  final String? text;
  final Usage usage;
  GeneratedFile get image => images.first;
}

abstract interface class ImageModel implements AiModel {
  Future<ImageResult> generate(ImageRequest request, {CancelToken? cancelToken});
}

class SpeechRequest {
  const SpeechRequest({
    required this.text,
    this.voice,
    this.speed,
    this.instructions,
    this.language,
    this.outputFormat,
    this.providerOptions = const {},
  });
  final String text;

  /// A voice id or name the provider knows.
  final String? voice;
  final double? speed;

  /// How to speak: "cheerful", "whisper"…
  final String? instructions;

  /// ISO code, e.g. `en`, `am`.
  final String? language;
  final String? outputFormat;
  final Map<String, dynamic> providerOptions;
}

abstract interface class SpeechModel implements AiModel {
  Future<GeneratedFile> speak(SpeechRequest request, {CancelToken? cancelToken});
}

/// A voice a speech model can use, with a sample when the provider has one.
class Voice {
  const Voice({
    required this.id,
    required this.name,
    required this.provider,
    this.language,
    this.gender,
    this.description,
    this.previewUrl,
    this.labels = const {},
  });
  final String id;
  final String name;
  final String provider;
  final String? language;
  final String? gender;
  final String? description;

  /// A short audio clip of the voice.
  final String? previewUrl;
  final Map<String, String> labels;

  /// "American · female · young"
  String get traits => [
        language,
        gender,
        ...labels.entries.where((e) => e.key != 'gender' && e.key != 'language').map((e) => e.value),
      ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');

  @override
  String toString() => 'Voice($id, $name)';
}

class TranscriptionRequest {
  const TranscriptionRequest({required this.audio, this.mediaType, this.language, this.prompt, this.providerOptions = const {}});
  final Uint8List audio;
  final String? mediaType;
  final String? language;

  /// Hints: names, spelling, context.
  final String? prompt;
  final Map<String, dynamic> providerOptions;
}

class TranscriptionSegment {
  const TranscriptionSegment({required this.text, required this.start, required this.end, this.speaker});
  final String text;
  final Duration start;
  final Duration end;
  final String? speaker;
}

class TranscriptionResult {
  const TranscriptionResult({required this.text, this.language, this.segments = const [], this.duration});
  final String text;
  final String? language;
  final List<TranscriptionSegment> segments;
  final Duration? duration;
  @override
  String toString() => text;
}

abstract interface class TranscriptionModel implements AiModel {
  Future<TranscriptionResult> transcribe(TranscriptionRequest request, {CancelToken? cancelToken});
}

class VideoRequest {
  const VideoRequest({
    required this.prompt,
    this.duration,
    this.aspectRatio,
    this.resolution,
    this.audio,
    this.image,
    this.negativePrompt,
    this.timeout = const Duration(minutes: 10),
    this.onStatus,
    this.providerOptions = const {},
  });
  final String prompt;

  /// Seconds.
  final int? duration;

  /// `16:9`, `9:16`, `1:1`.
  final String? aspectRatio;

  /// `480p`, `720p`, `1080p`.
  final String? resolution;
  final bool? audio;

  /// A first frame to animate.
  final Uint8List? image;
  final String? negativePrompt;
  final Duration timeout;

  /// "Queued", "Rendering"… while the job runs.
  final void Function(String status)? onStatus;
  final Map<String, dynamic> providerOptions;
}

abstract interface class VideoModel implements AiModel {
  Future<GeneratedFile> generate(VideoRequest request, {CancelToken? cancelToken});
}

class EmbeddingResult {
  const EmbeddingResult(this.embeddings, {this.usage = const Usage()});
  final List<List<double>> embeddings;
  final Usage usage;
}

abstract interface class EmbeddingModel implements AiModel {
  Future<EmbeddingResult> embed(List<String> values, {int? dimensions, CancelToken? cancelToken});
}
