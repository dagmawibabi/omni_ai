import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/cancel.dart';
import '../core/http.dart';

/// One part of a UI message from an AI SDK backend.
class UiPart {
  UiPart(this.type, [Map<String, dynamic>? data]) : data = data ?? {};

  /// `text`, `reasoning`, `tool-<name>`, `dynamic-tool`, `file`,
  /// `source-url`, `data-<name>`, `step-start`…
  final String type;
  final Map<String, dynamic> data;

  String get text => '${data['text'] ?? ''}';

  /// For tools: `input-streaming`, `input-available`, `output-available`,
  /// `output-error`, `output-denied`.
  String? get state => data['state'] as String?;
  bool get isTool => type.startsWith('tool-') || type == 'dynamic-tool';
  String? get toolName => type == 'dynamic-tool' ? data['toolName'] as String? : (isTool ? type.substring(5) : null);

  Map<String, dynamic> toJson() => {'type': type, ...data};
}

/// A message in the AI SDK's `UIMessage` shape.
class UiMessage {
  UiMessage({required this.id, required this.role, List<UiPart>? parts, this.metadata}) : parts = parts ?? [];

  factory UiMessage.user(String text, {String? id}) =>
      UiMessage(id: id ?? 'u${DateTime.now().microsecondsSinceEpoch}', role: 'user', parts: [
        UiPart('text', {'text': text})
      ]);

  factory UiMessage.fromJson(Map<String, dynamic> j) => UiMessage(
        id: '${j['id']}',
        role: '${j['role']}',
        parts: [
          for (final p in (j['parts'] as List? ?? const []).whereType<Map>())
            UiPart('${p['type']}', {
              for (final e in p.entries)
                if (e.key != 'type') '${e.key}': e.value
            }),
        ],
        metadata: j['metadata'] as Map<String, dynamic>?,
      );

  final String id;
  final String role;
  final List<UiPart> parts;
  Map<String, dynamic>? metadata;

  String get text => parts.where((p) => p.type == 'text').map((p) => p.text).join();
  String get reasoning => parts.where((p) => p.type == 'reasoning').map((p) => p.text).join();
  List<UiPart> get tools => parts.where((p) => p.isTool).toList();

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'parts': [for (final p in parts) p.toJson()],
        if (metadata != null) 'metadata': metadata,
      };
}

/// Talks to a backend built with the Vercel AI SDK (`toUIMessageStreamResponse()`),
/// like `useChat` does: posts the messages, reads the UI message stream,
/// and yields the assistant message as it grows.
///
/// ```dart
/// final client = UiMessageStreamClient(Uri.parse('https://my.app/api/chat'));
/// await for (final m in client.send([UiMessage.user('Hi')])) {
///   print(m.text);
/// }
/// ```
class UiMessageStreamClient {
  UiMessageStreamClient(this.endpoint, {this.headers = const {}, this.body = const {}, http.Client? httpClient})
      : _net = AiHttp(provider: endpoint.host, client: httpClient);

  final Uri endpoint;

  /// e.g. your auth header.
  final Map<String, String> headers;

  /// Extra fields sent with every request.
  final Map<String, dynamic> body;
  final AiHttp _net;

  /// Sends [messages] and yields the reply after each part arrives.
  /// Custom `data-*` parts go to [onData]; [onFinish] gets the final message.
  Stream<UiMessage> send(
    List<UiMessage> messages, {
    String? chatId,
    Map<String, dynamic> extraBody = const {},
    void Function(UiPart part)? onData,
    void Function(UiMessage message)? onFinish,
    CancelToken? cancelToken,
  }) async* {
    final req = http.Request('POST', endpoint)
      ..headers.addAll({'Content-Type': 'application/json', ...headers})
      ..body = jsonEncode({
        if (chatId != null) 'id': chatId,
        'messages': [for (final m in messages) m.toJson()],
        'trigger': 'submit-message',
        ...body,
        ...extraBody,
      });
    final b = UiMessageBuilder();
    await for (final data in sseData(_net.lines(req, cancelToken: cancelToken))) {
      final Map<String, dynamic> j;
      try {
        j = jsonDecode(data) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final changed = b.apply(j);
      final type = '${j['type']}';
      if (type.startsWith('data-')) onData?.call(UiPart(type, {'data': j['data'], if (j['id'] != null) 'id': j['id']}));
      if (b.error != null) throw Exception(b.error);
      if (changed) yield b.message;
    }
    onFinish?.call(b.message);
  }
}

/// Builds a [UiMessage] from UI message stream chunks.
class UiMessageBuilder {
  UiMessage message = UiMessage(id: 'assistant', role: 'assistant');
  String? error;
  bool finished = false;
  final _open = <String, UiPart>{};

  /// Applies one chunk. Returns whether the message changed.
  bool apply(Map<String, dynamic> j) {
    final type = '${j['type']}';
    final parts = message.parts;
    switch (type) {
      case 'start':
        if (j['messageId'] != null) {
          message = UiMessage(id: '${j['messageId']}', role: 'assistant', parts: parts, metadata: message.metadata);
        }
        if (j['messageMetadata'] is Map) message.metadata = {...?message.metadata, ...j['messageMetadata'] as Map<String, dynamic>};
        return false;
      case 'text-start' || 'reasoning-start':
        final kind = type.split('-').first;
        final p = UiPart(kind, {'text': '', 'state': 'streaming'});
        _open['$kind:${j['id']}'] = p;
        parts.add(p);
        return true;
      case 'text-delta' || 'reasoning-delta':
        final kind = type.split('-').first;
        var p = _open['$kind:${j['id']}'];
        if (p == null) {
          p = UiPart(kind, {'text': '', 'state': 'streaming'});
          _open['$kind:${j['id']}'] = p;
          parts.add(p);
        }
        p.data['text'] = '${p.data['text']}${j['delta'] ?? ''}';
        return true;
      case 'text-end' || 'reasoning-end':
        _open.remove('${type.split('-').first}:${j['id']}')?.data['state'] = 'done';
        return true;
      case 'start-step':
        parts.add(UiPart('step-start'));
        return false;
      case 'tool-input-start' || 'tool-input-delta' || 'tool-input-available' || 'tool-input-error':
        final p = _tool(j);
        if (type == 'tool-input-delta') {
          p.data['inputText'] = '${p.data['inputText'] ?? ''}${j['inputTextDelta'] ?? ''}';
          p.data['state'] = 'input-streaming';
        } else if (type == 'tool-input-available') {
          p.data['input'] = j['input'];
          p.data['state'] = 'input-available';
        } else if (type == 'tool-input-error') {
          p.data['input'] = j['input'];
          p.data['errorText'] = j['errorText'];
          p.data['state'] = 'output-error';
        } else {
          p.data['state'] = 'input-streaming';
        }
        return true;
      case 'tool-output-available':
        final p = _tool(j);
        p.data['output'] = j['output'];
        p.data['state'] = 'output-available';
        return true;
      case 'tool-output-error':
        final p = _tool(j);
        p.data['errorText'] = j['errorText'];
        p.data['state'] = 'output-error';
        return true;
      case 'tool-output-denied':
        _tool(j).data['state'] = 'output-denied';
        return true;
      case 'tool-approval-request':
        _tool(j)
          ..data['state'] = 'approval-requested'
          ..data['approval'] = {'id': j['approvalId']};
        return true;
      case 'source-url':
        parts.add(UiPart('source-url', {'sourceId': j['sourceId'], 'url': j['url'], 'title': j['title']}));
        return true;
      case 'source-document':
        parts.add(UiPart('source-document', {'sourceId': j['sourceId'], 'mediaType': j['mediaType'], 'title': j['title']}));
        return true;
      case 'file':
        parts.add(UiPart('file', {'url': j['url'], 'mediaType': j['mediaType']}));
        return true;
      case 'message-metadata':
        if (j['messageMetadata'] is Map) message.metadata = {...?message.metadata, ...j['messageMetadata'] as Map<String, dynamic>};
        return true;
      case 'error':
        error = '${j['errorText'] ?? 'The server reported an error.'}';
        return true;
      case 'finish':
        finished = true;
        if (j['messageMetadata'] is Map) message.metadata = {...?message.metadata, ...j['messageMetadata'] as Map<String, dynamic>};
        return true;
      case 'abort':
        finished = true;
        return true;
      default:
        if (type.startsWith('data-')) {
          if (j['transient'] == true) return false;
          final id = j['id'];
          final existing = id == null ? null : parts.where((p) => p.type == type && p.data['id'] == id).firstOrNull;
          if (existing != null) {
            existing.data['data'] = j['data'];
          } else {
            parts.add(UiPart(type, {if (id != null) 'id': id, 'data': j['data']}));
          }
          return true;
        }
        return false;
    }
  }

  UiPart _tool(Map<String, dynamic> j) {
    final id = '${j['toolCallId']}';
    final existing = message.parts.where((p) => p.isTool && p.data['toolCallId'] == id).firstOrNull;
    if (existing != null) return existing;
    final dynamicTool = j['dynamic'] == true;
    final p = UiPart(dynamicTool ? 'dynamic-tool' : 'tool-${j['toolName']}', {
      'toolCallId': id,
      if (dynamicTool) 'toolName': j['toolName'],
      'state': 'input-streaming',
    });
    message.parts.add(p);
    return p;
  }
}
