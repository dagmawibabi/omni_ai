import 'dart:async';

import '../core/cancel.dart';
import '../core/errors.dart';
import '../core/messages.dart';
import '../core/models.dart';
import '../core/stream_parts.dart';
import '../core/tools.dart';
import '../core/usage.dart';
import '../generate/generate_text.dart';
import '../generate/replay_stream.dart';
import '../omni_ai.dart';
import 'memory.dart';
import 'skills.dart';
import 'toolkit.dart';

/// When an agent must stop, besides answering.
class AgentLimits {
  const AgentLimits({this.maxSteps = 25, this.maxTokens, this.maxCostUsd, this.timeout, this.maxHistoryMessages});

  /// Model calls per run.
  final int maxSteps;

  /// Input + output tokens per run.
  final int? maxTokens;

  /// Dollars per run (reported cost, or estimated from catalog prices).
  final double? maxCostUsd;

  /// Wall time per run; the run is cancelled after it.
  final Duration? timeout;

  /// Older turns of a session are dropped beyond this many messages.
  final int? maxHistoryMessages;
}

/// Code that runs around an agent's tools and steps.
class AgentHooks {
  const AgentHooks({this.beforeToolCall, this.afterToolCall, this.onStepFinish});

  /// Return a value to skip the tool and use that as its result (e.g. a
  /// cached answer or a refusal). Return null to run it.
  final FutureOr<Object?> Function(ToolCallPart call)? beforeToolCall;

  /// Sees each result; return a replacement or null to keep it.
  final FutureOr<Object?> Function(ToolCallPart call, Object? result)? afterToolCall;
  final void Function(StepResult step)? onStepFinish;
}

/// Asks a person a question and returns their answer.
typedef AskUser = Future<String> Function(String question, List<String>? options);

/// An AI agent: instructions, a model, tools and toolkits, skills, memory
/// and helper agents, run in a loop until the job is done.
///
/// ```dart
/// final agent = Agent(
///   name: 'researcher',
///   instructions: 'You research topics thoroughly and cite sources.',
///   model: 'gateway:anthropic/claude-sonnet-4.5',
///   toolkits: [ExaToolkit(apiKey: exaKey), E2BToolkit(apiKey: e2bKey)],
/// );
/// final answer = await agent.ask('Compare the three most popular Flutter state libraries.');
/// ```
///
/// Use [session] for a conversation that remembers earlier turns, and
/// [run] for streaming events (text, tool calls, approvals, subagents).
class Agent {
  Agent({
    required this.name,
    this.description,
    this.instructions = 'You are a helpful assistant.',
    this.model,
    this.languageModel,
    OmniAI? ai,
    this.tools = const [],
    this.toolkits = const [],
    this.skills = const [],
    this.useInstalledSkills = true,
    this.memory,
    this.subagents = const [],
    this.limits = const AgentLimits(),
    this.hooks = const AgentHooks(),
    this.reasoning,
    this.temperature,
    this.onToolApproval,
    this.onAskUser,
    this.providerOptions = const {},
    this.parallelToolCalls = true,
  })  : _ai = ai,
        assert(RegExp(r'^[A-Za-z0-9_\-]{1,48}$').hasMatch(name), 'Agent names use letters, digits, _ and -.');

  final String name;

  /// What this agent is for. A parent agent reads it to decide when to
  /// delegate, so it is required for subagents.
  final String? description;
  final String instructions;

  /// A model id (`google:gemini-2.5-flash`), resolved with [ai].
  final String? model;

  /// Or a model object, used instead of [model].
  final LanguageModel? languageModel;
  final OmniAI? _ai;
  final List<Tool> tools;
  final List<Toolkit> toolkits;
  final List<Skill> skills;

  /// Hosts managing tool permissions can disable automatic skill exposure.
  final bool useInstalledSkills;
  final AgentMemory? memory;

  /// Helper agents this one can delegate to. Each becomes a tool named
  /// `agent_<name>` that takes a self-contained `message`.
  final List<Agent> subagents;
  final AgentLimits limits;
  final AgentHooks hooks;
  final ReasoningEffort? reasoning;
  final double? temperature;

  /// Asks a person before a tool with an approval policy runs. Without it,
  /// such tools are refused.
  final ToolApproval? onToolApproval;

  /// Lets the agent ask the user a question mid-task (adds `ask_user`).
  final AskUser? onAskUser;
  final Map<String, dynamic> providerOptions;

  /// Runs the tools of one step at the same time (the default), or one by
  /// one in order: for tools that share a rate limit, or approvals asked
  /// one at a time.
  final bool parallelToolCalls;

  OmniAI get ai => _ai ?? OmniAI.instance;

  LanguageModel get _model => languageModel ?? ai.languageModel(model);

  /// A conversation with this agent.
  AgentSession session({List<Message>? history, String? id}) => AgentSession._(this, history: history, id: id);

  /// One task without history. See [AgentRun] for what you can read.
  AgentRun run(String prompt, {List<FilePart> files = const [], CancelToken? cancelToken}) =>
      session().send(prompt, files: files, cancelToken: cancelToken);

  /// The final answer to [prompt].
  Future<String> ask(String prompt, {List<FilePart> files = const []}) async => (await run(prompt, files: files).result).text;

  /// This agent as a tool for another agent.
  Tool asTool({ReplayStream<StreamPart>? relay, Map<String, AgentSession>? tasks}) {
    final children = tasks ?? <String, AgentSession>{};
    return Tool(
      name: 'agent_$name',
      label: 'Asking $name',
      description: '${description ?? 'A helper agent named $name.'} It does not see this conversation: put everything it '
          'needs in message. It answers with its result. Pass task_id from an earlier answer to continue that thread.',
      parametersJson: const {
        'type': 'object',
        'properties': {
          'message': {'type': 'string', 'description': 'The task, with all context needed.'},
          'task_id': {'type': 'string', 'description': 'Continue an earlier task.'},
        },
        'required': ['message'],
      },
      execute: (i) async {
        final taskId =
            '${i['task_id'] ?? ''}'.isNotEmpty && children.containsKey(i['task_id']) ? '${i['task_id']}' : '${name}_${children.length + 1}';
        final child = children[taskId] ??= session(id: taskId);
        final run = child.send('${i['message']}');
        if (relay != null) {
          run.fullStream.listen((p) => relay.add(SubagentUpdate(agent: name, taskId: taskId, part: p)), onError: (_) {});
        }
        final r = await run.result;
        return {
          'task_id': taskId,
          'result': r.text,
          if (r.toolCalls.isNotEmpty) 'tools_used': r.toolCalls.map((c) => c.name).toSet().toList()
        };
      },
    );
  }

  /// Frees what toolkits opened (sandboxes, sessions), for this agent and its subagents.
  Future<void> dispose() async {
    for (final t in toolkits) {
      await t.dispose();
    }
    for (final a in subagents) {
      await a.dispose();
    }
  }

  /// [toolkits] plus [memory].
  List<Toolkit> get allToolkits => [...toolkits, if (memory != null && !toolkits.contains(memory)) memory!];

  /// The system prompt for a run: instructions, toolkit guidance (with
  /// memories), helpers and skills.
  Future<String> systemPrompt() async {
    await _ai?.skills.load();
    final b = StringBuffer(instructions.trim());
    final guidance = [for (final t in allToolkits) await t.prompt()].whereType<String>();
    if (guidance.isNotEmpty) b.write('\n\n# Tools\n${guidance.map((g) => '- $g').join('\n')}');
    if (subagents.isNotEmpty) {
      b.write('\n\n# Helpers\nDelegate with agent_<name> when a helper fits:\n');
      b.write(subagents.map((a) => '- ${a.name}: ${a.description ?? ''}').join('\n'));
    }
    final listed = _allSkills.where((s) => !s.deferred);
    if (_allSkills.isNotEmpty) {
      b.write('\n\n# Skills\nWhen a task matches a skill, call load_skill first and follow it.');
      if (listed.isNotEmpty) b.write('\n${listed.map((s) => '- ${s.name}: ${s.description}').join('\n')}');
      if (listed.length < _allSkills.length) b.write('\nMore skills can be found with find_skills.');
    }
    return b.toString();
  }

  /// Skills passed in plus those installed on [ai.skills].
  List<Skill> get _allSkills {
    final seen = <String>{};
    return [
      for (final s in skills)
        if (seen.add(s.name)) s,
      if (_ai != null && useInstalledSkills)
        for (final s in _ai.skills.all)
          if (seen.add(s.name)) s,
    ];
  }

  List<Tool> _builtins() => [
        if (_allSkills.isNotEmpty) ...[
          Tool(
            name: 'load_skill',
            label: 'Loading a skill',
            description: 'Loads a skill\'s full instructions.',
            parameters: Schema.object({
              'name': Schema.enumOf([for (final s in _allSkills) s.name])
            }),
            execute: (i) {
              final s = _allSkills.where((s) => s.name == i['name']).firstOrNull;
              if (s == null) return {'error': 'No skill "${i['name']}".'};
              return {
                'skill': s.name,
                'instructions': s.content,
                if (s.files.isNotEmpty) 'files': s.files.keys.toList(),
              };
            },
          ),
          if (_allSkills.any((s) => s.files.isNotEmpty))
            Tool(
              name: 'read_skill_file',
              label: 'Reading a skill file',
              description: 'Reads a reference file that belongs to a skill.',
              parameters: Schema.object({'skill': Schema.string(), 'path': Schema.string()}),
              execute: (i) => _allSkills.where((s) => s.name == i['skill']).firstOrNull?.files[i['path']] ?? {'error': 'No such file.'},
            ),
          if (_allSkills.any((s) => s.deferred))
            Tool(
              name: 'find_skills',
              label: 'Finding skills',
              description: 'Searches skills not listed in your instructions.',
              parameters: Schema.object({'query': Schema.string()}),
              execute: (i) {
                final q = '${i['query']}'.toLowerCase().split(RegExp(r'\s+'));
                return {
                  'skills': [
                    for (final s in _allSkills)
                      if (q.any((w) => '${s.name} ${s.description}'.toLowerCase().contains(w)))
                        {'name': s.name, 'description': s.description},
                  ],
                };
              },
            ),
        ],
        if (onAskUser != null)
          Tool(
            name: 'ask_user',
            label: 'Asking you',
            description: 'Asks the user one question and waits for the answer. Use when you can\'t continue without it.',
            parameters: Schema.object({
              'question': Schema.string(),
              'options': Schema.array(Schema.string(), description: 'Suggested answers, if any.'),
            }, required: [
              'question'
            ]),
            execute: (i) async => {
              'answer': await onAskUser!('${i['question']}', (i['options'] as List?)?.map((o) => '$o').toList()),
            },
          ),
      ];

  /// Every tool for a run, with hooks applied.
  Future<List<Tool>> resolveTools({ReplayStream<StreamPart>? relay, Map<String, AgentSession>? tasks}) async {
    await _ai?.skills.load();
    final all = <Tool>[
      ...tools,
      for (final t in allToolkits)
        if (t.isConfigured) ...await t.tools(),
      ..._builtins(),
      for (final a in subagents) a.asTool(relay: relay, tasks: tasks),
    ];
    final seen = <String>{};
    final out = <Tool>[];
    for (final t in all) {
      if (!seen.add(t.name)) continue;
      out.add(t.execute == null || (hooks.beforeToolCall == null && hooks.afterToolCall == null) ? t : _hooked(t));
    }
    return out;
  }

  Tool _hooked(Tool t) => t.copyWith(execute: (input) async {
        final call = ToolContext.current?.call ?? ToolCallPart(id: '', name: t.name, input: input);
        final early = await hooks.beforeToolCall?.call(call);
        var out = early ?? await t.execute!(input);
        final after = await hooks.afterToolCall?.call(call, out is ToolOutput ? out.value : out);
        if (after != null) out = out is ToolOutput ? ToolOutput(after, files: out.files) : after;
        return out;
      });
}

/// One run of an agent: stream it or await its [result].
class AgentRun {
  AgentRun._(this._parts, this._result, this._cancel);

  final ReplayStream<StreamPart> _parts;
  final Future<GenerateTextResult> _result;
  final CancelToken _cancel;

  /// Text, reasoning, tool calls and results, approvals, subagent updates,
  /// steps and finish.
  Stream<StreamPart> get fullStream => _parts.stream;
  Stream<String> get textStream => fullStream.where((p) => p is TextDelta).map((p) => (p as TextDelta).text);
  Future<GenerateTextResult> get result => _result;
  Future<String> get text => _result.then((r) => r.text);

  /// The messages this run added (used by chat controllers).
  Future<List<Message>> get responseMessages => _result.then((r) => r.responseMessages);

  void cancel() => _cancel.cancel();
}

/// A conversation with an [Agent]: keeps history, remembers tools approved
/// "once", and keeps subagent threads.
class AgentSession {
  AgentSession._(this.agent, {List<Message>? history, String? id})
      : history = [...?history],
        id = id ?? 's${DateTime.now().microsecondsSinceEpoch}';

  final Agent agent;
  final String id;
  final List<Message> history;

  /// Tools approved under [ApprovalPolicy.once] in this session.
  final approvedOnce = <String>{};
  final _tasks = <String, AgentSession>{};

  /// Usage over every run in this session.
  Usage usage = const Usage();

  /// Sends a message and runs the agent.
  AgentRun send(String prompt, {List<FilePart> files = const [], CancelToken? cancelToken}) =>
      _start([Message.user(prompt, files: files)], cancelToken);

  /// Runs the agent on the history as it stands (e.g. to answer again).
  AgentRun respond({CancelToken? cancelToken}) => _start(const [], cancelToken);

  /// Continues after tools you ran yourself (tools without `execute`).
  AgentRun submitToolResults(List<ToolResultPart> results, {CancelToken? cancelToken}) =>
      _start([Message.toolResults(results)], cancelToken);

  AgentRun _start(List<Message> newMessages, CancelToken? outer) {
    final parts = ReplayStream<StreamPart>();
    final token = CancelToken();
    outer?.onCancel(token.cancel);
    history.addAll(newMessages);
    _trim();
    final a = agent;
    Timer? timer;
    if (a.limits.timeout != null) timer = Timer(a.limits.timeout!, token.cancel);

    Future<GenerateTextResult> go() async {
      final tools = await a.resolveTools(relay: parts, tasks: _tasks);
      final byName = {for (final t in tools) t.name: t};
      final model = a._model;
      var spent = const Usage();

      Future<ToolApprovalDecision> approve(ToolCallPart call) async {
        final t = byName[call.name];
        if (t != null && t.approval.kind == 'once' && approvedOnce.contains(t.name)) return const ToolApprovalDecision.approve();
        // Let the tool-call part reach listeners first.
        await Future<void>(() {});
        parts.add(ToolApprovalRequest(call));
        final decision = ToolApprovalDecision.from(a.onToolApproval == null ? false : await a.onToolApproval!(call));
        if (decision.approved && t?.approval.kind == 'once') approvedOnce.add(t!.name);
        parts.add(ToolApprovalResponse(call, approved: decision.approved));
        return decision;
      }

      bool overLimit(StepResult step) {
        spent = spent + step.usage;
        final l = a.limits;
        if (l.maxTokens != null && spent.totalTokens >= l.maxTokens!) return true;
        if (l.maxCostUsd != null) {
          final cost = spent.cost ?? a.ai.estimateCost('${model.provider}:${model.modelId}', spent);
          if (cost != null && cost >= l.maxCostUsd!) return true;
        }
        return false;
      }

      final s = streamText(
        model: model,
        system: await a.systemPrompt(),
        messages: List.of(history),
        tools: tools,
        maxSteps: a.limits.maxSteps,
        stopWhen: overLimit,
        reasoning: a.reasoning,
        temperature: a.temperature,
        providerOptions: a.providerOptions,
        onToolApproval: approve,
        parallelToolCalls: a.parallelToolCalls,
        onStepFinish: a.hooks.onStepFinish,
        cancelToken: token,
      );
      await for (final p in s.fullStream) {
        parts.add(p);
      }
      final r = await s.result;
      history.addAll(r.responseMessages);
      usage = usage + r.usage;
      return r;
    }

    final future = go().then((r) {
      timer?.cancel();
      parts.close();
      return r;
    }, onError: (Object e, StackTrace st) {
      timer?.cancel();
      if (e is AiCancelledException && a.limits.timeout != null && !(outer?.isCancelled ?? false)) {
        e = AiException('${a.name} ran out of time (${a.limits.timeout!.inSeconds} s).');
      }
      parts.addError(e, st);
      parts.close();
      throw e;
    });
    future.ignore();
    return AgentRun._(parts, future, token);
  }

  void _trim() {
    final max = agent.limits.maxHistoryMessages;
    if (max == null || history.length <= max) return;
    // Cut at a user turn so tool calls stay with their results.
    var cut = history.length - max;
    while (cut < history.length && history[cut].role != Role.user) {
      cut++;
    }
    if (cut < history.length) history.removeRange(0, cut);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'history': [for (final m in history) m.toJson()],
        'approvedOnce': approvedOnce.toList()
      };

  /// Restores a session saved with [toJson].
  static AgentSession fromJson(Agent agent, Map<String, dynamic> j) => AgentSession._(agent,
      id: j['id'] as String?,
      history: [for (final m in (j['history'] as List? ?? const [])) Message.fromJson(Map<String, dynamic>.from(m as Map))])
    ..approvedOnce.addAll([for (final t in (j['approvedOnce'] as List? ?? const [])) '$t']);
}
