import 'media.dart';
import 'messages.dart';
import 'usage.dart';

/// Everything a streamed generation can emit, in order. Providers emit
/// the text, reasoning, tool-call, file and finish parts; `streamText` adds
/// step, tool-result and finish-of-everything parts.
///
/// ```dart
/// await for (final part in result.fullStream) {
///   switch (part) {
///     case TextDelta(:final text): stdout.write(text);
///     case ToolResult(:final result): print(result);
///     default:
///   }
/// }
/// ```
sealed class StreamPart {
  const StreamPart();
}

class TextDelta extends StreamPart {
  const TextDelta(this.text);
  final String text;
}

class ReasoningDelta extends StreamPart {
  const ReasoningDelta(this.text);
  final String text;
}

/// A tool call started streaming; its input is not complete yet.
class ToolCallStart extends StreamPart {
  const ToolCallStart({required this.id, required this.name});
  final String id;
  final String name;
}

/// A fragment of a tool call's JSON input.
class ToolInputDelta extends StreamPart {
  const ToolInputDelta({required this.id, required this.delta});
  final String id;
  final String delta;
}

/// A tool call with its whole input.
class ToolCall extends StreamPart {
  const ToolCall(this.call);
  final ToolCallPart call;
}

/// A tool finished (emitted by `streamText`).
class ToolResult extends StreamPart {
  const ToolResult(this.result);
  final ToolResultPart result;
}

/// A file the model made inside a text reply (e.g. an image from Gemini).
class FileOutput extends StreamPart {
  const FileOutput(this.file);
  final GeneratedFile file;
}

/// A web source the model cited.
class SourceOutput extends StreamPart {
  const SourceOutput({required this.url, this.title});
  final String url;
  final String? title;
}

class StepStart extends StreamPart {
  const StepStart(this.step);
  final int step;
}

/// The end of one model call. Providers emit it with [usage] and
/// [finishReason]; [providerData] is kept on the assistant message.
class StepFinish extends StreamPart {
  const StepFinish({
    this.step = 0,
    this.finishReason = FinishReason.unknown,
    this.usage = const Usage(),
    this.providerData,
  });
  final int step;
  final FinishReason finishReason;
  final Usage usage;
  final Map<String, dynamic>? providerData;
}

/// The whole generation ended (emitted by `streamText`).
class Finish extends StreamPart {
  const Finish({required this.finishReason, required this.usage});
  final FinishReason finishReason;

  /// Usage summed over every step.
  final Usage usage;
}

/// An agent is waiting for a person to allow [call] (emitted by `Agent`).
class ToolApprovalRequest extends StreamPart {
  const ToolApprovalRequest(this.call);
  final ToolCallPart call;
}

/// A person allowed or refused [call] (emitted by `Agent`).
class ToolApprovalResponse extends StreamPart {
  const ToolApprovalResponse(this.call, {required this.approved});
  final ToolCallPart call;
  final bool approved;
}

/// Something a subagent did, relayed to its parent's stream.
class SubagentUpdate extends StreamPart {
  const SubagentUpdate({required this.agent, required this.taskId, required this.part});

  /// The subagent's name.
  final String agent;

  /// Pass back as `task_id` to continue that subagent's conversation.
  final String taskId;
  final StreamPart part;
}

class StreamError extends StreamPart {
  const StreamError(this.error);
  final Object error;
}
