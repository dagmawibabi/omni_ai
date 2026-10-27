import 'dart:async';

import 'package:flutter/foundation.dart';

import '../agents/agent.dart';
import '../agents/toolkit.dart';
import '../core/cancel.dart';
import '../core/errors.dart';
import '../core/media.dart';
import '../core/messages.dart';
import '../core/stream_parts.dart';
import '../core/tools.dart';
import '../core/usage.dart';
import '../generate/generate_text.dart';
import '../omni_ai.dart';

/// A message in a chat UI: the turn plus what is still streaming.
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    this.text = '',
    this.reasoning = '',
    List<FilePart>? files,
    List<GeneratedFile>? generated,
    List<ToolActivity>? tools,
    this.streaming = false,
    this.error,
    this.usage,
    this.model,
  })  : files = files ?? [],
        generated = generated ?? [],
        tools = tools ?? [];

  final String id;
  final Role role;
  String text;
  String reasoning;

  /// What the user attached.
  final List<FilePart> files;

  /// Images the model made.
  final List<GeneratedFile> generated;

  /// Tool calls and their results, in order.
  final List<ToolActivity> tools;
  bool streaming;
  String? error;
  Usage? usage;
  String? model;

  bool get isUser => role == Role.user;
}

/// One tool call shown in the chat.
class ToolActivity {
  ToolActivity({required this.id, required this.name, this.input, this.output, this.done = false, this.isError = false});
  final String id;
  final String name;
  Map<String, dynamic>? input;
  Object? output;
  bool done;
  bool isError;

  /// Waiting for a person to allow it.
  bool awaitingApproval = false;

  /// What a subagent has written so far, for `agent_*` tools.
  String progress = '';
}

/// State for a chat screen, like the AI SDK's `useChat`: keeps messages,
/// streams replies into them, runs tools, and can stop or retry.
///
/// ```dart
/// final chat = ai.chat(model: 'google:gemini-2.5-flash', system: 'Be brief.');
/// ListenableBuilder(listenable: chat, builder: (_, __) => ...chat.messages...);
/// chat.send('Hello!');
/// ```
class AiChatController extends ChangeNotifier {
  AiChatController({
    required this.ai,
    this.model,
    this.system,
    this.tools = const [],
    this.toolkits = const [],
    this.maxSteps = 12,
    this.reasoning,
    this.temperature,
    this.outputImages = false,
    this.onToolApproval,
    this.onFinish,
    this.agent,
    List<Message>? history,
  }) : _history = [...?history];

  /// Chat with an [Agent] instead: its instructions, tools, toolkits,
  /// skills, memory and helpers are used, and [model], [system] and
  /// [tools] here are ignored.
  final Agent? agent;
  AgentSession? _session;

  final OmniAI ai;

  /// Switch models mid-chat by setting this.
  String? model;
  String? system;
  List<Tool> tools;

  /// Toolkits for the chat, e.g. `ai.allToolkits`.
  List<Toolkit> toolkits;
  int maxSteps;
  ReasoningEffort? reasoning;
  double? temperature;
  bool outputImages;
  ToolApproval? onToolApproval;
  void Function(ChatMessage message)? onFinish;

  final List<Message> _history;
  final messages = <ChatMessage>[];
  CancelToken? _cancel;
  int _n = 0;

  bool get isStreaming => _cancel != null;

  /// The conversation as model messages (save this to restore a chat).
  List<Message> get history => List.unmodifiable(_history);

  /// Total usage across the chat.
  Usage get usage => messages.fold(const Usage(), (a, m) => a + (m.usage ?? const Usage()));

  String _id() => '${DateTime.now().microsecondsSinceEpoch}_${_n++}';

  /// Sends a user message and streams the reply.
  Future<void> send(String text, {List<FilePart> files = const []}) async {
    if (text.trim().isEmpty && files.isEmpty) return;
    if (isStreaming) await stop();
    messages.add(ChatMessage(id: _id(), role: Role.user, text: text, files: [...files]));
    _history.add(Message.user(text, files: files));
    await _reply();
  }

  /// Asks again for the last reply.
  Future<void> regenerate() async {
    if (isStreaming) await stop();
    while (messages.isNotEmpty && !messages.last.isUser) {
      messages.removeLast();
    }
    while (_history.isNotEmpty && _history.last.role != Role.user) {
      _history.removeLast();
    }
    if (_history.isEmpty) return;
    await _reply();
  }

  /// Stops the reply in progress, keeping what was written.
  Future<void> stop() async {
    _cancel?.cancel();
    _cancel = null;
    for (final m in messages.where((m) => m.streaming)) {
      m.streaming = false;
    }
    notifyListeners();
  }

  void clear() {
    _cancel?.cancel();
    _cancel = null;
    messages.clear();
    _history.clear();
    notifyListeners();
  }

  /// Edits a user message and replies again from there.
  Future<void> edit(String messageId, String text) async {
    final i = messages.indexWhere((m) => m.id == messageId && m.isUser);
    if (i < 0) return;
    final userIndex = messages.take(i).where((m) => m.isUser).length;
    messages.removeRange(i, messages.length);
    var seen = -1;
    final cut = _history.indexWhere((m) => m.role == Role.user && ++seen == userIndex);
    if (cut >= 0) _history.removeRange(cut, _history.length);
    await send(text);
  }

  Future<void> _reply() async {
    final token = _cancel = CancelToken();
    final reply = ChatMessage(id: _id(), role: Role.assistant, streaming: true, model: model);
    messages.add(reply);
    notifyListeners();

    try {
      final ({Stream<StreamPart> fullStream, Future<List<Message>> responseMessages}) result;
      if (agent != null) {
        final s = _session ??= agent!.session();
        s.history
          ..clear()
          ..addAll(_history);
        final run = s.respond(cancelToken: token);
        result = (fullStream: run.fullStream, responseMessages: run.responseMessages);
      } else {
        final run = ai.streamText(
          model: model,
          system: system,
          messages: List.of(_history),
          tools: tools,
          toolkits: toolkits,
          maxSteps: maxSteps,
          reasoning: reasoning,
          temperature: temperature,
          outputImages: outputImages,
          onToolApproval: onToolApproval,
          cancelToken: token,
        );
        result = (fullStream: run.fullStream, responseMessages: run.responseMessages);
      }
      await for (final part in result.fullStream) {
        switch (part) {
          case ToolApprovalRequest(:final call):
            reply.tools.where((t) => t.id == call.id).firstOrNull?.awaitingApproval = true;
          case ToolApprovalResponse(:final call):
            reply.tools.where((t) => t.id == call.id).firstOrNull?.awaitingApproval = false;
          case SubagentUpdate(:final agent, part: TextDelta(:final text)):
            reply.tools.where((t) => t.name == 'agent_$agent' && !t.done).lastOrNull?.progress += text;
          case TextDelta(:final text):
            reply.text += text;
          case ReasoningDelta(:final text):
            reply.reasoning += text;
          case ToolCallStart(:final id, :final name):
            reply.tools.add(ToolActivity(id: id, name: name));
          case ToolCall(:final call):
            final t = reply.tools.where((t) => t.id == call.id).firstOrNull;
            if (t == null) {
              reply.tools.add(ToolActivity(id: call.id, name: call.name, input: call.input));
            } else {
              t.input = call.input;
            }
          case ToolResult(:final result):
            final t = reply.tools.where((t) => t.id == result.toolCallId).firstOrNull;
            t?.output = result.output;
            t?.isError = result.isError;
            t?.done = true;
          case FileOutput(:final file):
            reply.generated.add(file);
          case StepStart(:final step) when step > 0 && reply.text.isNotEmpty:
            reply.text += '\n\n';
          case Finish(:final usage):
            reply.usage = usage;
          default:
        }
        notifyListeners();
      }
      _history.addAll(await result.responseMessages);
    } on AiCancelledException {
      // Keep what was written.
      if (reply.text.isNotEmpty) _history.add(Message.assistant(reply.text));
    } catch (e) {
      if (!token.isCancelled) reply.error = '$e';
    } finally {
      reply.streaming = false;
      if (identical(_cancel, token)) _cancel = null;
      notifyListeners();
      onFinish?.call(reply);
    }
  }

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }
}

extension OmniAIChat on OmniAI {
  /// A chat controller on this [OmniAI].
  AiChatController chat({
    String? model,
    String? system,
    List<Tool> tools = const [],
    List<Toolkit> toolkits = const [],
    int maxSteps = 12,
    ReasoningEffort? reasoning,
    bool outputImages = false,
    ToolApproval? onToolApproval,
    List<Message>? history,
  }) =>
      AiChatController(
        ai: this,
        model: model,
        system: system,
        tools: tools,
        toolkits: toolkits,
        maxSteps: maxSteps,
        reasoning: reasoning,
        outputImages: outputImages,
        onToolApproval: onToolApproval,
        history: history,
      );
}

extension AgentChat on Agent {
  /// A chat controller that talks to this agent (for [AiChatView]).
  AiChatController chat({List<Message>? history}) => AiChatController(ai: ai, agent: this, history: history);
}
