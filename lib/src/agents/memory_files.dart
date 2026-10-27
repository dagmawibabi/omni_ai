import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/tools.dart';
import 'toolkit.dart';

/// Files under `/memories` for [MemoryFilesToolkit].
abstract class MemoryFileStore {
  /// Every file: path → content.
  Future<Map<String, String>> files(String scope);
  Future<void> write(String scope, String path, String content);
  Future<void> delete(String scope, String path);
}

class InMemoryFileStore implements MemoryFileStore {
  final _m = <String, Map<String, String>>{};
  @override
  Future<Map<String, String>> files(String scope) async => Map.of(_m[scope] ?? const {});
  @override
  Future<void> write(String scope, String path, String content) async => (_m[scope] ??= {})[path] = content;
  @override
  Future<void> delete(String scope, String path) async => _m[scope]?.remove(path);
}

/// Memory files on the device, in shared preferences.
class PrefsMemoryFileStore implements MemoryFileStore {
  PrefsMemoryFileStore({this.prefix = 'omni_ai.memory_files.'});
  final String prefix;

  Future<Map<String, String>> _read(SharedPreferences p, String scope) async {
    final raw = p.getString('$prefix$scope');
    if (raw == null) return {};
    try {
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (e) {
      debugPrint('[omni_ai] memory files unreadable: $e');
      return {};
    }
  }

  @override
  Future<Map<String, String>> files(String scope) async => _read(await SharedPreferences.getInstance(), scope);

  @override
  Future<void> write(String scope, String path, String content) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('$prefix$scope', jsonEncode({...await _read(p, scope), path: content}));
  }

  @override
  Future<void> delete(String scope, String path) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('$prefix$scope', jsonEncode((await _read(p, scope))..remove(path)));
  }
}

/// A `memory` tool with the commands Claude's native memory tool uses —
/// `view`, `create`, `str_replace`, `insert`, `delete`, `rename` — on a
/// small file system under `/memories`. Claude models know it by heart;
/// other models follow the same schema as an ordinary tool.
///
/// Unlike [AgentMemory] (short facts always in the prompt), the AI decides
/// what files to keep and reads them when it needs them, so it suits
/// longer notes: project progress, decisions, how a user likes things done.
class MemoryFilesToolkit extends Toolkit {
  MemoryFilesToolkit({MemoryFileStore? store, this.scope = 'default', this.maxFileCharacters = 20000})
      : store = store ?? PrefsMemoryFileStore();

  final MemoryFileStore store;

  /// Whose memory: one user, a project. Take it from your own sign-in.
  String scope;
  final int maxFileCharacters;

  static const root = '/memories';

  @override
  String get id => 'memory_files';
  @override
  String get name => 'Memory files';
  @override
  bool get needsApiKey => false;
  @override
  bool get isConfigured => true;
  @override
  Future<String?> verify() async => null;

  @override
  String get instructions => 'You have a memory directory at /memories (memory tool). At the start of a task, view it to '
      'see earlier progress. As you work, record what you would want to know next time (progress, decisions, user '
      'preferences) in it. Keep it organized; don\'t store secrets.';

  /// A safe absolute path under /memories, or null.
  static String? clean(Object? raw) {
    var p = '${raw ?? ''}'.trim().replaceAll('\\', '/');
    if (p.isEmpty) return null;
    if (!p.startsWith('/')) p = '/$p';
    final parts = <String>[];
    for (final s in p.split('/')) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..' || s.contains('%2e') || s.contains('%2E')) return null;
      parts.add(s);
    }
    final out = '/${parts.join('/')}';
    return out == root || out.startsWith('$root/') ? out : null;
  }

  static String _numbered(String text, [List<int>? range]) {
    final lines = text.split('\n');
    final start = range == null || range.isEmpty ? 1 : range[0].clamp(1, lines.length);
    final end = range == null || range.length < 2 || range[1] == -1 ? lines.length : range[1].clamp(start, lines.length);
    return [for (var i = start; i <= end; i++) '${'$i'.padLeft(6)}\t${lines[i - 1]}'].join('\n');
  }

  Future<String> run(Map<String, dynamic> i) async {
    final files = await store.files(scope);
    final command = '${i['command'] ?? ''}';
    switch (command) {
      case 'view':
        final path = clean(i['path'] ?? root);
        if (path == null) return 'Error: paths must be inside $root.';
        if (files.containsKey(path)) {
          final range = (i['view_range'] as List?)?.map((v) => (v as num).toInt()).toList();
          return 'Here\'s the content of $path with line numbers:\n${_numbered(files[path]!, range)}';
        }
        final prefix = path == root ? '$root/' : '$path/';
        final inside = files.keys.where((k) => k.startsWith(prefix)).toList()..sort();
        if (inside.isEmpty && path != root) return 'Error: the path $path does not exist.';
        final lines = <String>{};
        for (final k in inside) {
          final rest = k.substring(prefix.length).split('/');
          lines.add(rest.length == 1 ? '${files[k]!.length}\t$prefix${rest.first}' : '-\t$prefix${rest.first}/');
        }
        return 'Here are the files and directories in $path:\n${lines.isEmpty ? '(empty)' : lines.join('\n')}';
      case 'create':
        final path = clean(i['path']);
        if (path == null || path == root) return 'Error: give a file path inside $root.';
        final text = '${i['file_text'] ?? ''}';
        if (text.length > maxFileCharacters) return 'Error: files are limited to $maxFileCharacters characters.';
        await store.write(scope, path, text);
        return 'File created successfully at: $path';
      case 'str_replace':
        final path = clean(i['path']);
        final text = path == null ? null : files[path];
        if (text == null) return 'Error: the path ${i['path']} does not exist.';
        final old = '${i['old_str'] ?? ''}';
        final count = old.isEmpty ? 0 : old.allMatches(text).length;
        if (count == 0) return 'No replacement was performed, old_str did not appear verbatim in $path.';
        if (count > 1) return 'No replacement was performed. Multiple occurrences of old_str in $path. Make it unique.';
        await store.write(scope, path!, text.replaceFirst(old, '${i['new_str'] ?? ''}'));
        return 'The memory file has been edited.';
      case 'insert':
        final path = clean(i['path']);
        final text = path == null ? null : files[path];
        if (text == null) return 'Error: the path ${i['path']} does not exist.';
        final lines = text.isEmpty ? <String>[] : text.split('\n');
        final at = (i['insert_line'] as num?)?.toInt() ?? lines.length;
        if (at < 0 || at > lines.length) return 'Error: insert_line must be between 0 and ${lines.length}.';
        lines.insertAll(at, '${i['insert_text'] ?? ''}'.split('\n'));
        await store.write(scope, path!, lines.join('\n'));
        return 'The file $path has been edited.';
      case 'delete':
        final path = clean(i['path']);
        if (path == null || path == root) return 'Error: give a path inside $root (the directory itself can\'t be deleted).';
        final hits = files.keys.where((k) => k == path || k.startsWith('$path/')).toList();
        if (hits.isEmpty) return 'Error: the path $path does not exist.';
        for (final k in hits) {
          await store.delete(scope, k);
        }
        return 'Successfully deleted $path';
      case 'rename':
        final from = clean(i['old_path']), to = clean(i['new_path']);
        if (from == null || to == null || to == root) return 'Error: both paths must be inside $root.';
        if (files.containsKey(to)) return 'Error: the destination $to already exists.';
        final hits = files.keys.where((k) => k == from || k.startsWith('$from/')).toList();
        if (hits.isEmpty) return 'Error: the path $from does not exist.';
        for (final k in hits) {
          await store.write(scope, to + k.substring(from.length), files[k]!);
          await store.delete(scope, k);
        }
        return 'Successfully renamed $from to $to';
      default:
        return 'Error: unknown command "$command". Use view, create, str_replace, insert, delete or rename.';
    }
  }

  @override
  Future<List<Tool>> tools() async => [
        Tool(
          name: 'memory',
          label: 'Using memory',
          description: 'Your persistent memory directory (/memories), kept between conversations. Commands: view (a file '
              'with line numbers, or a directory), create (write a file), str_replace (replace a unique string), insert '
              '(add text after a line; 0 = top), delete (a file or directory), rename (move).',
          parametersJson: const {
            'type': 'object',
            'properties': {
              'command': {
                'type': 'string',
                'enum': ['view', 'create', 'str_replace', 'insert', 'delete', 'rename'],
              },
              'path': {'type': 'string', 'description': 'e.g. /memories/preferences.md'},
              'view_range': {
                'type': 'array',
                'items': {'type': 'integer'},
                'description': '[start, end] lines for view; end -1 = to the end.',
              },
              'file_text': {'type': 'string', 'description': 'create: the content.'},
              'old_str': {'type': 'string'},
              'new_str': {'type': 'string'},
              'insert_line': {'type': 'integer'},
              'insert_text': {'type': 'string'},
              'old_path': {'type': 'string'},
              'new_path': {'type': 'string'},
            },
            'required': ['command'],
          },
          execute: run,
        ),
      ];
}
