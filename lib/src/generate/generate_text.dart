import 'dart:async';
import 'dart:convert';

import '../core/cancel.dart';
import '../core/errors.dart';
import '../core/media.dart';
import '../core/messages.dart';
import '../core/models.dart';
import '../core/stream_parts.dart';
import '../core/tools.dart';
import '../core/usage.dart';
import 'replay_stream.dart';

/// Asks before a tool marked `needsApproval` runs. Return false to refuse.
typedef ToolApproval = FutureOr<bool> Function(ToolCallPart call);

/// One model call inside a generation.
class StepResult {
  const StepResult({
    required this.stepNumber,
    required this.text,
    required this.reasoning,
    required this.toolCalls,
    required this.toolResults,
    required this.files,
    required this.finishReason,
    required this.usage,
    required this.messages,
  });
  final int stepNumber;
  final String text;
  final String reasoning;
  final List<ToolCallPart> toolCalls;
  final List<ToolResultPart> toolResults;
  final List<GeneratedFile> files;
  final FinishReason finishReason;
  final Usage usage;

  /// The assistant message (and tool message) this step added.
  final List<Message> messages;
}

/// What a whole generation produced.
class GenerateTextResult {
  const GenerateTextResult({required this.steps, required this.responseMessages, required this.sources});

  final List<StepResult> steps;

  /// The messages to add to your history: assistant turns and tool results.
  final List<Message> responseMessages;
  final List<SourceOutput> sources;

  /// The text of the last step (what the model finally said).
  String get text => steps.isEmpty ? '' : steps.last.text;

  /// Text of every step joined.
  String get allText => steps.map((s) => s.text).where((t) => t.isNotEmpty).join('\n\n');
  String get reasoning => steps.map((s) => s.reasoning).where((t) => t.isNotEmpty).join('\n\n');
  List<ToolCallPart> get toolCalls => [for (final s in steps) ...s.toolCalls];
  List<ToolResultPart> get toolResults => [for (final s in steps) ...s.toolResults];

  /// Images and other files the model made.
  List<GeneratedFile> get files => [for (final s in steps) ...s.files];
  FinishReason get finishReason => steps.isEmpty ? FinishReason.unknown : steps.last.finishReason;
  Usage get usage => steps.fold(const Usage(), (a, s) => a + s.usage);

  @override
  String toString() => text;
}

/// A generation in progress. Read [textStream] for words as they arrive,
/// [fullStream] for everything, or await [text] / [result].
class StreamTextResult {
  StreamTextResult._(this._parts, this._result);

  final ReplayStream<StreamPart> _parts;
  final Future<GenerateTextResult> _result;

  /// Every part: text, reasoning, tool calls and results, steps, finish.
  Stream<StreamPart> get fullStream => _parts.stream;

  /// Only the words.
  Stream<String> get textStream => fullStream.where((p) => p is TextDelta).map((p) => (p as TextDelta).text);

  /// Only the thinking.
  Stream<String> get reasoningStream => fullStream.where((p) => p is ReasoningDelta).map((p) => (p as ReasoningDelta).text);

  /// The text so far, growing with each delta. Handy for `StreamBuilder`.
  Stream<String> get accumulatedText async* {
    final buf = StringBuffer();
    await for (final t in textStream) {
      buf.write(t);
      yield buf.toString();
    }
  }

  Future<GenerateTextResult> get result => _result;
  Future<String> get text => _result.then((r) => r.text);
  Future<String> get reasoning => _result.then((r) => r.reasoning);
  Future<Usage> get usage => _result.then((r) => r.usage);
  Future<List<ToolCallPart>> get toolCalls => _result.then((r) => r.toolCalls);
  Future<List<Message>> get responseMessages => _result.then((r) => r.responseMessages);
}

/// Builds the message list from the friendly arguments.
List<Message> buildMessages({String? system, String? prompt, List<Message>? messages, List<FilePart> files = const []}) {
  if (prompt == null && (messages == null || messages.isEmpty)) {
    throw ArgumentError('Pass a prompt or messages.');
  }
  return [
    if (system != null && system.isNotEmpty) Message.system(system),
    ...?messages,
    if (prompt != null) Message.user(prompt, files: files),
  ];
}

/// Streams a reply, running tools between steps the way the Vercel AI SDK
/// does. Starts at once; listen to any of the result's streams or futures.
///
/// [maxSteps] caps model calls: with tools, `maxSteps: 5` lets the model
/// call tools and then answer with their results.
StreamTextResult streamText({
  required LanguageModel model,
  String? system,
  String? prompt,
  List<FilePart> files = const [],
  List<Message>? messages,
  List<Tool> tools = const [],
  ToolChoice? toolChoice,
  int maxSteps = 1,
  bool Function(StepResult step)? stopWhen,
  double? temperature,
  double? topP,
  int? topK,
  int? maxOutputTokens,
  List<String>? stopSequences,
  int? seed,
  ReasoningEffort? reasoning,
  ResponseFormat? responseFormat,
  bool outputImages = false,
  Map<String, dynamic> providerOptions = const {},
  Map<String, String> headers = const {},
  ToolApproval? onToolApproval,
  void Function(StepResult step)? onStepFinish,
  void Function(GenerateTextResult result)? onFinish,
  void Function(Object error)? onError,
  CancelToken? cancelToken,
}) {
  final parts = ReplayStream<StreamPart>();
  final history = buildMessages(system: system, prompt: prompt, messages: messages, files: files);
  final toolMap = {for (final t in tools) t.name: t};

  Future<GenerateTextResult> run() async {
    final steps = <StepResult>[];
    final added = <Message>[];
    final sources = <SourceOutput>[];
    var convo = List<Message>.of(history);
    for (var step = 0; step < maxSteps; step++) {
      if (cancelToken?.isCancelled ?? false) throw const AiCancelledException();
      parts.add(StepStart(step));
      final text = StringBuffer();
      final thought = StringBuffer();
      final calls = <ToolCallPart>[];
      final stepFiles = <GeneratedFile>[];
      var finish = const StepFinish();

      final request = LanguageModelRequest(
        messages: convo,
        tools: tools,
        toolChoice: toolChoice,
        temperature: temperature,
        topP: topP,
        topK: topK,
        maxOutputTokens: maxOutputTokens,
        stopSequences: stopSequences,
        seed: seed,
        reasoning: reasoning,
        responseFormat: responseFormat,
        outputImages: outputImages,
        providerOptions: providerOptions,
        headers: headers,
      );
      await for (final p in model.stream(request, cancelToken: cancelToken)) {
        switch (p) {
          case TextDelta(text: final t):
            if (t.isEmpty) continue;
            text.write(t);
            parts.add(p);
          case ReasoningDelta(text: final t):
            thought.write(t);
            parts.add(p);
          case ToolCall(:final call):
            calls.add(call);
            parts.add(p);
          case FileOutput(:final file):
            stepFiles.add(file);
            parts.add(p);
          case SourceOutput():
            sources.add(p);
            parts.add(p);
          case StepFinish():
            finish = p;
          default:
            parts.add(p);
        }
      }

      final assistant = Message(
        Role.assistant,
        [
          if (thought.isNotEmpty)
            ReasoningPart(thought.toString(), providerData: finish.providerData?['reasoning'] as Map<String, dynamic>?),
          if (text.isNotEmpty) TextPart(text.toString()),
          ...calls,
        ],
        providerData: finish.providerData,
      );
      final stepMessages = <Message>[assistant];

      // Run the tools the model called.
      final results = <ToolResultPart>[];
      final runnable = calls.isNotEmpty && calls.every((c) => toolMap[c.name]?.execute != null);
      if (runnable) {
        results.addAll(await Future.wait([
          for (final c in calls) _runTool(toolMap[c.name]!, c, onToolApproval),
        ]));
        for (final r in results) {
          parts.add(ToolResult(r));
        }
        stepMessages.add(Message.toolResults(results));
      } else {
        for (final c in calls.where((c) => !toolMap.containsKey(c.name))) {
          parts.add(StreamError(AiException('The model called an unknown tool "${c.name}".')));
        }
      }

      final result = StepResult(
        stepNumber: step,
        text: text.toString(),
        reasoning: thought.toString(),
        toolCalls: calls,
        toolResults: results,
        files: stepFiles,
        finishReason: finish.finishReason,
        usage: finish.usage,
        messages: stepMessages,
      );
      steps.add(result);
      added.addAll(stepMessages);
      convo = [...convo, ...stepMessages];
      parts.add(StepFinish(
        step: step,
        finishReason: finish.finishReason,
        usage: finish.usage,
        providerData: finish.providerData,
      ));
      onStepFinish?.call(result);

      final continueLoop = runnable && results.isNotEmpty && !(stopWhen?.call(result) ?? false);
      if (!continueLoop) break;
    }
    final out = GenerateTextResult(steps: steps, responseMessages: added, sources: sources);
    parts.add(Finish(finishReason: out.finishReason, usage: out.usage));
    return out;
  }

  final future = run().then((r) {
    parts.close();
    onFinish?.call(r);
    return r;
  }, onError: (Object e, StackTrace s) {
    parts.add(StreamError(e));
    parts.addError(e, s);
    parts.close();
    onError?.call(e);
    throw e;
  });
  // Nobody may await the future; keep the error from being "unhandled".
  future.ignore();
  return StreamTextResult._(parts, future);
}

/// Generates a whole reply, running tools between steps. See [streamText].
Future<GenerateTextResult> generateText({
  required LanguageModel model,
  String? system,
  String? prompt,
  List<FilePart> files = const [],
  List<Message>? messages,
  List<Tool> tools = const [],
  ToolChoice? toolChoice,
  int maxSteps = 1,
  bool Function(StepResult step)? stopWhen,
  double? temperature,
  double? topP,
  int? topK,
  int? maxOutputTokens,
  List<String>? stopSequences,
  int? seed,
  ReasoningEffort? reasoning,
  ResponseFormat? responseFormat,
  bool outputImages = false,
  Map<String, dynamic> providerOptions = const {},
  Map<String, String> headers = const {},
  ToolApproval? onToolApproval,
  void Function(StepResult step)? onStepFinish,
  CancelToken? cancelToken,
}) =>
    streamText(
      model: model,
      system: system,
      prompt: prompt,
      files: files,
      messages: messages,
      tools: tools,
      toolChoice: toolChoice,
      maxSteps: maxSteps,
      stopWhen: stopWhen,
      temperature: temperature,
      topP: topP,
      topK: topK,
      maxOutputTokens: maxOutputTokens,
      stopSequences: stopSequences,
      seed: seed,
      reasoning: reasoning,
      responseFormat: responseFormat,
      outputImages: outputImages,
      providerOptions: providerOptions,
      headers: headers,
      onToolApproval: onToolApproval,
      onStepFinish: onStepFinish,
      cancelToken: cancelToken,
    ).result;

Future<ToolResultPart> _runTool(Tool tool, ToolCallPart call, ToolApproval? approve) async {
  if (tool.needsApproval) {
    final ok = approve == null ? false : await approve(call);
    if (!ok) {
      return ToolResultPart(
        toolCallId: call.id,
        toolName: call.name,
        output: {'error': 'The user did not allow this tool to run.'},
        isError: true,
      );
    }
  }
  try {
    final out = await tool.execute!(call.input);
    // Make sure the output can be sent back as JSON.
    final safe = out == null || out is String || out is num || out is bool ? out : jsonDecode(jsonEncode(out));
    return ToolResultPart(toolCallId: call.id, toolName: call.name, output: safe);
  } catch (e) {
    return ToolResultPart(
      toolCallId: call.id,
      toolName: call.name,
      output: {'error': '$e'},
      isError: true,
    );
  }
}
