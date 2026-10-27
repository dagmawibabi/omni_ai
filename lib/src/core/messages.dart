import 'dart:convert';
import 'dart:typed_data';

import 'media.dart';

enum Role { system, user, assistant, tool }

/// One piece of a [Message]: text, a file, reasoning, a tool call or result.
sealed class Part {
  const Part();

  Map<String, dynamic> toJson();

  static Part fromJson(Map<String, dynamic> j) => switch (j['type']) {
        'text' => TextPart(j['text'] as String? ?? ''),
        'file' => FilePart.fromJson(j),
        'reasoning' => ReasoningPart(j['text'] as String? ?? '', providerData: _map(j['providerData'])),
        'tool-call' => ToolCallPart(
            id: j['id'] as String,
            name: j['name'] as String,
            input: _map(j['input']) ?? const {},
            providerData: _map(j['providerData']),
          ),
        'tool-result' => ToolResultPart(
            toolCallId: j['toolCallId'] as String,
            toolName: j['toolName'] as String,
            output: j['output'],
            isError: j['isError'] == true,
          ),
        _ => TextPart('${j['text'] ?? ''}'),
      };
}

class TextPart extends Part {
  const TextPart(this.text);
  final String text;

  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};
}

/// An image, PDF, audio clip or other file, as bytes or a URL.
class FilePart extends Part {
  const FilePart({this.bytes, this.url, required this.mediaType, this.filename});

  /// An image from bytes; the type is read from the bytes when not given.
  factory FilePart.image(Uint8List bytes, {String? mediaType}) =>
      FilePart(bytes: bytes, mediaType: mediaType ?? sniffMediaType(bytes, fallback: 'image/png'));

  /// An image a model can fetch itself.
  factory FilePart.imageUrl(String url, {String mediaType = 'image/*'}) => FilePart(url: Uri.parse(url), mediaType: mediaType);

  factory FilePart.audio(Uint8List bytes, {String? mediaType}) =>
      FilePart(bytes: bytes, mediaType: mediaType ?? sniffMediaType(bytes, fallback: 'audio/wav'));

  factory FilePart.pdf(Uint8List bytes, {String filename = 'document.pdf'}) =>
      FilePart(bytes: bytes, mediaType: 'application/pdf', filename: filename);

  factory FilePart.fromJson(Map<String, dynamic> j) => FilePart(
        bytes: j['data'] is String ? base64Decode(j['data'] as String) : null,
        url: j['url'] is String ? Uri.parse(j['url'] as String) : null,
        mediaType: j['mediaType'] as String? ?? 'application/octet-stream',
        filename: j['filename'] as String?,
      );

  final Uint8List? bytes;
  final Uri? url;
  final String mediaType;
  final String? filename;

  bool get isImage => mediaType.startsWith('image/');
  bool get isAudio => mediaType.startsWith('audio/');
  bool get isPdf => mediaType == 'application/pdf';

  /// A `data:` URL for bytes, or the URL itself.
  String get dataUrl =>
      bytes != null ? 'data:${mediaType == 'image/*' ? 'image/png' : mediaType};base64,${base64Encode(bytes!)}' : url.toString();

  String? get base64 => bytes == null ? null : base64Encode(bytes!);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'file',
        if (bytes != null) 'data': base64Encode(bytes!),
        if (url != null) 'url': url.toString(),
        'mediaType': mediaType,
        if (filename != null) 'filename': filename,
      };
}

/// What a model thought before answering. [providerData] carries signatures
/// some providers need back on the next turn.
class ReasoningPart extends Part {
  const ReasoningPart(this.text, {this.providerData});
  final String text;
  final Map<String, dynamic>? providerData;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'reasoning',
        'text': text,
        if (providerData != null) 'providerData': providerData,
      };
}

/// A tool the model asked to run.
class ToolCallPart extends Part {
  const ToolCallPart({required this.id, required this.name, required this.input, this.providerData});
  final String id;
  final String name;
  final Map<String, dynamic> input;

  /// Opaque provider data that must go back with the call (Gemini's
  /// thought signature, for one).
  final Map<String, dynamic>? providerData;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'tool-call',
        'id': id,
        'name': name,
        'input': input,
        if (providerData != null) 'providerData': providerData,
      };

  @override
  String toString() => 'ToolCall($name ${jsonEncode(input)})';
}

/// What a tool returned.
class ToolResultPart extends Part {
  const ToolResultPart({required this.toolCallId, required this.toolName, required this.output, this.isError = false});
  final String toolCallId;
  final String toolName;
  final Object? output;
  final bool isError;

  /// [output] as text for providers that take a string.
  String get outputText => output is String ? output as String : jsonEncode(output);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'tool-result',
        'toolCallId': toolCallId,
        'toolName': toolName,
        'output': output,
        if (isError) 'isError': true,
      };

  @override
  String toString() => 'ToolResult($toolName → $outputText)';
}

/// One turn of a conversation.
class Message {
  const Message(this.role, this.parts, {this.providerData});

  factory Message.system(String text) => Message(Role.system, [TextPart(text)]);

  /// A user turn with optional images, audio or PDFs.
  factory Message.user(String text, {List<FilePart> files = const []}) =>
      Message(Role.user, [if (text.isNotEmpty) TextPart(text), ...files]);

  factory Message.assistant(String text) => Message(Role.assistant, [TextPart(text)]);

  factory Message.toolResults(List<ToolResultPart> results) => Message(Role.tool, results);

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        Role.values.byName(j['role'] as String),
        [for (final p in (j['parts'] as List? ?? const [])) Part.fromJson(Map<String, dynamic>.from(p as Map))],
        providerData: _map(j['providerData']),
      );

  final Role role;
  final List<Part> parts;

  /// Opaque provider data kept with the turn (e.g. OpenRouter/Gateway
  /// `reasoning_details`).
  final Map<String, dynamic>? providerData;

  /// All text parts joined.
  String get text => parts.whereType<TextPart>().map((p) => p.text).join();
  String get reasoning => parts.whereType<ReasoningPart>().map((p) => p.text).join();
  List<FilePart> get files => parts.whereType<FilePart>().toList();
  List<ToolCallPart> get toolCalls => parts.whereType<ToolCallPart>().toList();
  List<ToolResultPart> get toolResults => parts.whereType<ToolResultPart>().toList();

  Message copyWith({List<Part>? parts, Map<String, dynamic>? providerData}) =>
      Message(role, parts ?? this.parts, providerData: providerData ?? this.providerData);

  Map<String, dynamic> toJson() => {
        'role': role.name,
        'parts': [for (final p in parts) p.toJson()],
        if (providerData != null) 'providerData': providerData,
      };

  @override
  String toString() => '${role.name}: ${text.isEmpty ? parts : text}';
}

Map<String, dynamic>? _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : null;
