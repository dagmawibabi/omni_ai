import 'dart:convert';
import 'dart:io';

// A real subprocess for the stdio transport integration test.
Future<void> main() async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map;
    if (request['id'] == null) continue;
    final result = switch (request['method']) {
      'server/discover' => {
          'supportedVersions': ['2026-07-28'],
          'capabilities': {'tools': {}},
          '_meta': {
            'io.modelcontextprotocol/serverInfo': {'name': 'stdio-fixture', 'version': '1'}
          },
        },
      'tools/list' => {
          'tools': [
            {
              'name': 'echo',
              'description': 'Echo input',
              'inputSchema': {'type': 'object'}
            }
          ]
        },
      'tools/call' => {'structuredContent': request['params']['arguments'], 'content': []},
      _ => <String, Object?>{},
    };
    stdout.writeln(jsonEncode({
      'jsonrpc': '2.0',
      'id': request['id'],
      'result': {'resultType': 'complete', ...result}
    }));
  }
}
