import 'dart:async';
import 'dart:convert';

import '../core/cancel.dart';
import '../core/errors.dart';
import '../core/json_utils.dart';
import '../core/messages.dart';
import '../core/models.dart';
import '../core/tools.dart';
import '../core/usage.dart';
import 'generate_text.dart';

class GenerateObjectResult<T> {
  const GenerateObjectResult({required this.object, required this.json, required this.text, required this.usage});

  /// The parsed object, mapped through `fromJson` when given.
  final T object;

  /// The raw decoded JSON.
  final Object? json;
  final String text;
  final Usage usage;
}

String _schemaPrompt(Schema schema) =>
    'Answer with JSON only, no prose and no code fences, matching this JSON Schema:\n${jsonEncode(schema.json)}';

/// Generates JSON matching [schema], parsed into [T] with [fromJson].
///
/// ```dart
/// final r = await generateObject(
///   model: model,
///   schema: Schema.object({'name': Schema.string(), 'age': Schema.integer()}),
///   prompt: 'Invent a person.',
/// );
/// print(r.object['name']);
/// ```
Future<GenerateObjectResult<T>> generateObject<T>({
  required LanguageModel model,
  required Schema schema,
  T Function(Map<String, dynamic> json)? fromJson,
  String? system,
  String? prompt,
  List<FilePart> files = const [],
  List<Message>? messages,
  String schemaName = 'response',
  double? temperature,
  int? maxOutputTokens,
  ReasoningEffort? reasoning,
  Map<String, dynamic> providerOptions = const {},
  CancelToken? cancelToken,
}) async {
  final r = await generateText(
    model: model,
    system: [if (system != null) system, _schemaPrompt(schema)].join('\n\n'),
    prompt: prompt,
    files: files,
    messages: messages,
    temperature: temperature,
    maxOutputTokens: maxOutputTokens,
    reasoning: reasoning,
    responseFormat: ResponseFormat.json(schema: schema.json, name: schemaName),
    providerOptions: providerOptions,
    cancelToken: cancelToken,
  );
  final json = extractJson(r.text);
  if (json == null) {
    throw ObjectParseException('The model did not answer with JSON.', text: r.text);
  }
  final T object;
  try {
    object = fromJson != null ? fromJson(Map<String, dynamic>.from(json as Map)) : json as T;
  } catch (e) {
    throw ObjectParseException('The JSON did not match: $e', text: r.text);
  }
  return GenerateObjectResult(object: object, json: json, text: r.text, usage: r.usage);
}

/// Streams a JSON object as it is written: each event is the object so far
/// (partial, with missing fields absent). The last event is complete.
Stream<Map<String, dynamic>> streamObject({
  required LanguageModel model,
  required Schema schema,
  String? system,
  String? prompt,
  List<FilePart> files = const [],
  List<Message>? messages,
  String schemaName = 'response',
  double? temperature,
  int? maxOutputTokens,
  Map<String, dynamic> providerOptions = const {},
  CancelToken? cancelToken,
}) async* {
  final s = streamText(
    model: model,
    system: [if (system != null) system, _schemaPrompt(schema)].join('\n\n'),
    prompt: prompt,
    files: files,
    messages: messages,
    temperature: temperature,
    maxOutputTokens: maxOutputTokens,
    responseFormat: ResponseFormat.json(schema: schema.json, name: schemaName),
    providerOptions: providerOptions,
    cancelToken: cancelToken,
  );
  String? last;
  await for (final text in s.accumulatedText) {
    final partial = parsePartialJson(text);
    if (partial is Map) {
      final encoded = jsonEncode(partial);
      if (encoded == last) continue;
      last = encoded;
      yield Map<String, dynamic>.from(partial);
    }
  }
}

/// Picks one of [options] (classification).
Future<String> generateEnum({
  required LanguageModel model,
  required List<String> options,
  required String prompt,
  String? system,
  CancelToken? cancelToken,
}) async {
  final r = await generateObject<Map<String, dynamic>>(
    model: model,
    schema: Schema.object({'result': Schema.enumOf(options)}),
    system: system,
    prompt: prompt,
    cancelToken: cancelToken,
  );
  final v = '${r.object['result']}';
  return options.contains(v) ? v : options.firstWhere((o) => o.toLowerCase() == v.toLowerCase(), orElse: () => v);
}
