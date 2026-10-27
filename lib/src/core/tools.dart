import 'dart:async';

import 'cancel.dart';
import 'media.dart';
import 'messages.dart';

/// A JSON Schema, built without writing maps by hand.
///
/// ```dart
/// Schema.object({
///   'city': Schema.string(description: 'City name'),
///   'unit': Schema.enumOf(['c', 'f']),
/// }, required: ['city'])
/// ```
class Schema {
  const Schema(this.json);
  final Map<String, dynamic> json;

  static Schema string({String? description, String? format}) =>
      Schema({'type': 'string', if (description != null) 'description': description, if (format != null) 'format': format});
  static Schema number({String? description, num? minimum, num? maximum}) => Schema({
        'type': 'number',
        if (description != null) 'description': description,
        if (minimum != null) 'minimum': minimum,
        if (maximum != null) 'maximum': maximum,
      });
  static Schema integer({String? description, int? minimum, int? maximum}) => Schema({
        'type': 'integer',
        if (description != null) 'description': description,
        if (minimum != null) 'minimum': minimum,
        if (maximum != null) 'maximum': maximum,
      });
  static Schema boolean({String? description}) => Schema({'type': 'boolean', if (description != null) 'description': description});
  static Schema enumOf(List<String> values, {String? description}) =>
      Schema({'type': 'string', 'enum': values, if (description != null) 'description': description});
  static Schema array(Schema items, {String? description}) =>
      Schema({'type': 'array', 'items': items.json, if (description != null) 'description': description});

  /// [required] defaults to every property.
  static Schema object(Map<String, Schema> properties, {List<String>? required, String? description}) => Schema({
        'type': 'object',
        if (description != null) 'description': description,
        'properties': {for (final e in properties.entries) e.key: e.value.json},
        'required': required ?? properties.keys.toList(),
        'additionalProperties': false,
      });
}

/// Runs a tool. Return anything JSON-encodable, or a [ToolOutput] to also
/// hand files (charts, downloads) to the app.
typedef ToolExecute = FutureOr<Object?> Function(Map<String, dynamic> input);

/// A tool result with files for the app. The model sees [value]; the app
/// gets [files] as `FileOutput` stream parts.
///
/// [modelFiles] are images (or PDFs, audio) for the model itself to look
/// at, such as a screenshot or a photo a tool fetched. Tool results can't
/// carry pictures in most APIs, so they follow the results as a user
/// message.
class ToolOutput {
  const ToolOutput(this.value, {this.files = const [], this.modelFiles = const []});
  final Object? value;
  final List<GeneratedFile> files;
  final List<FilePart> modelFiles;
}

/// What a person decided about a tool call. `onToolApproval` may return
/// one instead of a bool, to change the call's input before it runs (an
/// edited message draft) or to tell the model why it was refused.
///
/// ```dart
/// onToolApproval: (call) async {
///   final text = await showDraftEditor(call.input['text']);
///   return text == null
///       ? const ToolApprovalDecision.deny('The user declined. Don't retry unless they ask.')
///       : ToolApprovalDecision.approve(input: {...call.input, 'text': text});
/// }
/// ```
class ToolApprovalDecision {
  const ToolApprovalDecision.approve({this.input})
      : approved = true,
        reason = null;
  const ToolApprovalDecision.deny([this.reason])
      : approved = false,
        input = null;

  final bool approved;

  /// Replaces the model's input when approved.
  final Map<String, dynamic>? input;

  /// Sent to the model when refused.
  final String? reason;

  /// Reads what an approval callback returned: a decision, or a bool.
  static ToolApprovalDecision from(Object? value) =>
      value is ToolApprovalDecision ? value : (value == true ? const ToolApprovalDecision.approve() : const ToolApprovalDecision.deny());
}

/// The call a tool is running for, and the generation's cancel token.
/// Read it with [ToolContext.current] inside `execute`, to tell calls
/// apart (say, to show progress per call) or to stop work on cancel.
class ToolContext {
  const ToolContext({required this.call, this.cancelToken});
  final ToolCallPart call;
  final CancelToken? cancelToken;

  static const _key = #omniAiToolContext;

  /// The context of the tool running now, or null outside a tool.
  static ToolContext? get current => Zone.current[_key] as ToolContext?;

  /// Runs [body] with this as [current].
  R run<R>(R Function() body) => runZoned(body, zoneValues: {_key: this});
}

/// When a tool must be approved by a person before it runs.
///
/// ```dart
/// Tool(..., approval: ApprovalPolicy.always)                         // every call
/// Tool(..., approval: ApprovalPolicy.once)                           // first call per session
/// Tool(..., approval: ApprovalPolicy.when((i) => i['amount'] > 100)) // depends on input
/// ```
class ApprovalPolicy {
  const ApprovalPolicy._(this.kind, [this._when]);

  /// Runs without asking.
  static const never = ApprovalPolicy._('never');

  /// Asks before every call.
  static const always = ApprovalPolicy._('always');

  /// Asks before the first call in a session; later calls run.
  static const once = ApprovalPolicy._('once');

  /// Asks when [test] says so for this input.
  factory ApprovalPolicy.when(bool Function(Map<String, dynamic> input) test) => ApprovalPolicy._('when', test);

  /// `never`, `always`, `once` or `when`.
  final String kind;
  final bool Function(Map<String, dynamic> input)? _when;

  /// Whether this input needs a person's yes (before any `once` memory).
  bool requires(Map<String, dynamic> input) => switch (kind) {
        'never' => false,
        'when' => _when!(input),
        _ => true,
      };
}

/// A function the model may call.
///
/// Leave [execute] out to handle calls yourself: the loop stops and the
/// calls come back in `result.toolCalls`.
class Tool {
  Tool({
    required this.name,
    required this.description,
    Schema? parameters,
    Map<String, dynamic>? parametersJson,
    this.execute,
    bool needsApproval = false,
    ApprovalPolicy? approval,
    this.label,
  })  : parameters = parametersJson ?? parameters?.json ?? const {'type': 'object', 'properties': {}},
        approval = approval ?? (needsApproval ? ApprovalPolicy.always : ApprovalPolicy.never);

  final String name;
  final String description;

  /// JSON Schema of the input.
  final Map<String, dynamic> parameters;
  final ToolExecute? execute;

  /// When to ask `onToolApproval` before running.
  final ApprovalPolicy approval;

  /// What to show people while it runs ("Searching the web").
  final String? label;

  /// Whether this tool may ask for approval at all.
  bool get needsApproval => approval.kind != 'never';

  /// A readable name for UIs: [label], or `search_web` → "Search web".
  String get displayName {
    if (label != null) return label!;
    final s = name.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
    return s.isEmpty ? name : s[0].toUpperCase() + s.substring(1);
  }

  /// This tool with some fields changed.
  Tool copyWith({String? name, String? description, ToolExecute? execute, ApprovalPolicy? approval, String? label}) => Tool(
        name: name ?? this.name,
        description: description ?? this.description,
        parametersJson: parameters,
        execute: execute ?? this.execute,
        approval: approval ?? this.approval,
        label: label ?? this.label,
      );

  Map<String, dynamic> toOpenAI() => {
        'type': 'function',
        'function': {'name': name, 'description': description, 'parameters': parameters},
      };
}

/// Whether and which tool the model must call.
sealed class ToolChoice {
  const ToolChoice();
  static const auto = _Simple('auto');
  static const required = _Simple('required');
  static const none = _Simple('none');
  const factory ToolChoice.tool(String name) = SpecificTool;
}

class _Simple extends ToolChoice {
  const _Simple(this.value);
  final String value;
  @override
  String toString() => value;
}

class SpecificTool extends ToolChoice {
  const SpecificTool(this.name);
  final String name;
  @override
  String toString() => 'tool:$name';
}

extension ToolChoiceX on ToolChoice {
  /// `auto`, `required`, `none` or `tool`.
  String get kind => switch (this) {
        _Simple(:final value) => value,
        SpecificTool() => 'tool',
      };
  String? get toolName => switch (this) {
        SpecificTool(:final name) => name,
        _ => null,
      };
}
