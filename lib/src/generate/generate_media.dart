import 'dart:math' as math;
import 'dart:typed_data';

import '../core/cancel.dart';
import '../core/media.dart';
import '../core/models.dart';

/// Makes images from a prompt.
Future<ImageResult> generateImage({
  required ImageModel model,
  required String prompt,
  int n = 1,
  String? size,
  String? aspectRatio,
  int? seed,
  List<Uint8List> referenceImages = const [],
  Map<String, dynamic> providerOptions = const {},
  CancelToken? cancelToken,
}) =>
    model.generate(
      ImageRequest(
        prompt: prompt,
        n: n,
        size: size,
        aspectRatio: aspectRatio,
        seed: seed,
        referenceImages: referenceImages,
        providerOptions: providerOptions,
      ),
      cancelToken: cancelToken,
    );

/// Turns text into audio bytes.
Future<GeneratedFile> generateSpeech({
  required SpeechModel model,
  required String text,
  String? voice,
  double? speed,
  String? instructions,
  String? language,
  String? outputFormat,
  Map<String, dynamic> providerOptions = const {},
  CancelToken? cancelToken,
}) =>
    model.speak(
      SpeechRequest(
        text: text,
        voice: voice,
        speed: speed,
        instructions: instructions,
        language: language,
        outputFormat: outputFormat,
        providerOptions: providerOptions,
      ),
      cancelToken: cancelToken,
    );

/// Turns recorded audio into text.
Future<TranscriptionResult> transcribe({
  required TranscriptionModel model,
  required Uint8List audio,
  String? mediaType,
  String? language,
  String? prompt,
  Map<String, dynamic> providerOptions = const {},
  CancelToken? cancelToken,
}) =>
    model.transcribe(
      TranscriptionRequest(
        audio: audio,
        mediaType: mediaType,
        language: language,
        prompt: prompt,
        providerOptions: providerOptions,
      ),
      cancelToken: cancelToken,
    );

/// Makes a video. Usually takes a minute or more; follow [onStatus].
Future<GeneratedFile> generateVideo({
  required VideoModel model,
  required String prompt,
  int? duration,
  String? aspectRatio,
  String? resolution,
  bool? audio,
  Uint8List? image,
  String? negativePrompt,
  Duration timeout = const Duration(minutes: 10),
  void Function(String status)? onStatus,
  Map<String, dynamic> providerOptions = const {},
  CancelToken? cancelToken,
}) =>
    model.generate(
      VideoRequest(
        prompt: prompt,
        duration: duration,
        aspectRatio: aspectRatio,
        resolution: resolution,
        audio: audio,
        image: image,
        negativePrompt: negativePrompt,
        timeout: timeout,
        onStatus: onStatus,
        providerOptions: providerOptions,
      ),
      cancelToken: cancelToken,
    );

/// One embedding vector for [value].
Future<List<double>> embed({required EmbeddingModel model, required String value, int? dimensions, CancelToken? cancelToken}) async =>
    (await model.embed([value], dimensions: dimensions, cancelToken: cancelToken)).embeddings.first;

/// Embedding vectors for [values], in order.
Future<EmbeddingResult> embedMany({
  required EmbeddingModel model,
  required List<String> values,
  int? dimensions,
  int batchSize = 96,
  CancelToken? cancelToken,
}) async {
  final out = <List<double>>[];
  var usage = const EmbeddingResult([]).usage;
  for (var i = 0; i < values.length; i += batchSize) {
    final r =
        await model.embed(values.sublist(i, math.min(i + batchSize, values.length)), dimensions: dimensions, cancelToken: cancelToken);
    out.addAll(r.embeddings);
    usage = usage + r.usage;
  }
  return EmbeddingResult(out, usage: usage);
}

/// How alike two embeddings are, from -1 to 1.
double cosineSimilarity(List<double> a, List<double> b) {
  if (a.length != b.length) throw ArgumentError('Vectors differ in length: ${a.length} vs ${b.length}');
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}
