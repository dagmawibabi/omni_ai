import 'dart:async';

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

/// Runs a tool. Return anything JSON-encodable.
typedef ToolExecute = FutureOr<Object?> Function(Map<String, dynamic> input);

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
    this.needsApproval = false,
  }) : parameters = parametersJson ?? parameters?.json ?? const {'type': 'object', 'properties': {}};

  final String name;
  final String description;

  /// JSON Schema of the input.
  final Map<String, dynamic> parameters;
  final ToolExecute? execute;

  /// Ask `onToolApproval` before running.
  final bool needsApproval;

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
