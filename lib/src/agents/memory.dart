import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/tools.dart';
import 'toolkit.dart';

/// One thing the AI was asked to remember.
class MemoryItem {
  const MemoryItem({required this.id, required this.text, this.tags = const [], required this.savedAt, DateTime? updatedAt})
      : updatedAt = updatedAt ?? savedAt;

  factory MemoryItem.fromJson(Map j) => MemoryItem(
        id: '${j['id']}',
        text: '${j['text'] ?? j['content'] ?? ''}',
        tags: [for (final t in (j['tags'] as List? ?? const [])) '$t'],
        savedAt: DateTime.tryParse('${j['at']}') ?? DateTime.now(),
        updatedAt: DateTime.tryParse('${j['updated']}'),
      );

  final String id;
  final String text;
  final List<String> tags;
  final DateTime savedAt;
  final DateTime updatedAt;

  MemoryItem copyWith({String? text, List<String>? tags}) =>
      MemoryItem(id: id, text: text ?? this.text, tags: tags ?? this.tags, savedAt: savedAt, updatedAt: DateTime.now());

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        if (tags.isNotEmpty) 'tags': tags,
        'at': savedAt.toIso8601String(),
        'updated': updatedAt.toIso8601String(),
      };
}

/// Where memories are kept. Implement it to use your own database.
abstract class MemoryStore {
  Future<List<MemoryItem>> list(String scope);
  Future<MemoryItem> save(String scope, String text, {List<String> tags = const []});

  /// Returns the updated item, or null when there is no such id.
  Future<MemoryItem?> update(String scope, String id, {String? text, List<String>? tags});

  /// Returns whether something was removed.
  Future<bool> remove(String scope, String id);
  Future<void> clear(String scope);
}

String _newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36).substring(3);

/// Memories in RAM (tests, or one-off use).
class InMemoryStore implements MemoryStore {
  final _m = <String, List<MemoryItem>>{};

  @override
  Future<List<MemoryItem>> list(String scope) async => List.of(_m[scope] ?? const []);

  @override
  Future<MemoryItem> save(String scope, String text, {List<String> tags = const []}) async {
    final item = MemoryItem(id: 'm${(_m[scope]?.length ?? 0) + 1}${_newId()}', text: text, tags: tags, savedAt: DateTime.now());
    (_m[scope] ??= []).add(item);
    return item;
  }

  @override
  Future<MemoryItem?> update(String scope, String id, {String? text, List<String>? tags}) async {
    final list = _m[scope] ?? [];
    final i = list.indexWhere((m) => m.id == id);
    if (i < 0) return null;
    return list[i] = list[i].copyWith(text: text, tags: tags);
  }

  @override
  Future<bool> remove(String scope, String id) async {
    final list = _m[scope];
    if (list == null) return false;
    final before = list.length;
    list.removeWhere((m) => m.id == id);
    return list.length != before;
  }

  @override
  Future<void> clear(String scope) async => _m.remove(scope);
}

/// Memories on the device, in shared preferences.
class PrefsMemoryStore implements MemoryStore {
  PrefsMemoryStore({this.prefix = 'omni_ai.memory.'});
  final String prefix;

  List<MemoryItem> _read(SharedPreferences p, String scope) {
    final raw = p.getString('$prefix$scope');
    if (raw == null) return [];
    try {
      return [for (final m in jsonDecode(raw) as List) MemoryItem.fromJson(m as Map)];
    } catch (e) {
      debugPrint('[omni_ai] memory unreadable: $e');
      return [];
    }
  }

  Future<void> _write(SharedPreferences p, String scope, List<MemoryItem> items) =>
      p.setString('$prefix$scope', jsonEncode([for (final m in items) m.toJson()]));

  @override
  Future<List<MemoryItem>> list(String scope) async => _read(await SharedPreferences.getInstance(), scope);

  @override
  Future<MemoryItem> save(String scope, String text, {List<String> tags = const []}) async {
    final p = await SharedPreferences.getInstance();
    final item = MemoryItem(id: _newId(), text: text, tags: tags, savedAt: DateTime.now());
    await _write(p, scope, [..._read(p, scope), item]);
    return item;
  }

  @override
  Future<MemoryItem?> update(String scope, String id, {String? text, List<String>? tags}) async {
    final p = await SharedPreferences.getInstance();
    final items = _read(p, scope);
    final i = items.indexWhere((m) => m.id == id);
    if (i < 0) return null;
    items[i] = items[i].copyWith(text: text, tags: tags);
    await _write(p, scope, items);
    return items[i];
  }

  @override
  Future<bool> remove(String scope, String id) async {
    final p = await SharedPreferences.getInstance();
    final items = _read(p, scope);
    final before = items.length;
    items.removeWhere((m) => m.id == id);
    await _write(p, scope, items);
    return items.length != before;
  }

  @override
  Future<void> clear(String scope) async => (await SharedPreferences.getInstance()).remove('$prefix$scope');
}

/// Long-term memory as a toolkit, the way teleai does it: the memories are
/// in the prompt of every conversation (`id: content`), and the AI keeps
/// them with `remember`, `update_memory`, `forget_memory` and
/// `list_memories`. Nothing is saved unless the AI decides to.
///
/// Works with `ai.generateText(toolkits: [ai.memory])`, chats and agents.
class AgentMemory extends Toolkit {
  AgentMemory(
      {MemoryStore? store,
      this.scope = 'default',
      this.description = 'Preferences, facts about the user and people they mention, and standing requests.',
      this.maxRecall = 100})
      : store = store ?? PrefsMemoryStore();

  final MemoryStore store;

  /// Whose memory: one user, a team, a chat. Take it from your own sign-in,
  /// never from what the model says.
  String scope;

  /// What is worth remembering, for the model.
  final String description;

  /// Most memories put in the prompt (the newest).
  final int maxRecall;

  @override
  String get id => 'memory';
  @override
  String get name => 'Memory';
  @override
  bool get needsApiKey => false;
  @override
  bool get isConfigured => true;
  @override
  Future<String?> verify() async => null;

  /// All memories for [scope], for a "what I remember" screen.
  Future<List<MemoryItem>> all() => store.list(scope);

  /// The memories as `- id: content` lines, or null when there are none.
  Future<String?> recall() async {
    final items = await store.list(scope);
    if (items.isEmpty) return null;
    final recent = items.length > maxRecall ? items.sublist(items.length - maxRecall) : items;
    return [for (final m in recent) '- ${m.id}: ${m.text}${m.tags.isEmpty ? '' : ' [${m.tags.join(', ')}]'}'].join('\n');
  }

  @override
  Future<String?> prompt() async {
    final recalled = await recall();
    return 'Memory: when the user says "remember…" or shares a lasting preference or fact ($description), save it with '
        'remember; update or forget memories when they change. Don\'t save trivia, passwords, keys or payment details.'
        '${recalled == null ? '' : '\nWhat you remember (memory_id: content):\n$recalled'}';
  }

  @override
  Future<List<Tool>> tools() async => [
        Tool(
          name: 'remember',
          label: 'Remembering',
          description: 'Saves something to long-term memory so it is known in every future conversation: preferences, facts '
              'about people, standing requests. Use when the user says "remember…" or shares something clearly worth '
              'keeping. Keep each memory short and self-contained.',
          parametersJson: const {
            'type': 'object',
            'properties': {
              'content': {'type': 'string'},
              'tags': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
            'required': ['content'],
          },
          execute: (i) async {
            final text = '${i['content'] ?? ''}'.trim();
            if (text.isEmpty) return {'error': 'content is empty'};
            final m = await store.save(scope, text, tags: [for (final t in (i['tags'] as List? ?? const [])) '$t']);
            return {'saved': true, 'memory_id': m.id};
          },
        ),
        Tool(
          name: 'update_memory',
          label: 'Updating a memory',
          description: 'Rewrites a saved memory (ids are listed in your instructions and by list_memories).',
          parameters: Schema.object({'memory_id': Schema.string(), 'content': Schema.string()}),
          execute: (i) async {
            final m = await store.update(scope, '${i['memory_id']}', text: '${i['content']}'.trim());
            return m == null ? {'error': 'No memory with that id.'} : {'updated': true, 'memory_id': m.id};
          },
        ),
        Tool(
          name: 'forget_memory',
          label: 'Forgetting',
          description: 'Deletes a saved memory, when the user asks you to forget something or it is no longer true.',
          parameters: Schema.object({'memory_id': Schema.string()}),
          execute: (i) async => await store.remove(scope, '${i['memory_id']}') ? {'forgotten': true} : {'error': 'No memory with that id.'},
        ),
        Tool(
          name: 'list_memories',
          label: 'Checking memory',
          description: 'Everything saved in long-term memory, optionally filtered by words or tags.',
          parameters: Schema.object({'query': Schema.string()}, required: []),
          execute: (i) async {
            final q = '${i['query'] ?? ''}'.trim().toLowerCase();
            final items = await store.list(scope);
            return {
              'memories': [
                for (final m in items)
                  if (q.isEmpty || m.text.toLowerCase().contains(q) || m.tags.any((t) => t.toLowerCase().contains(q)))
                    {'memory_id': m.id, 'content': m.text, if (m.tags.isNotEmpty) 'tags': m.tags, 'updated': m.updatedAt.toIso8601String()},
              ],
            };
          },
        ),
      ];
}

/// The same toolkit under a name that reads better outside agents.
typedef MemoryToolkit = AgentMemory;
