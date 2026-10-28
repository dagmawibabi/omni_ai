import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omni_ai/omni_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A registry hit whose remote needs a key, as Smithery's do.
McpCatalogHit _keyedHit() => McpCatalogHit.fromJson({
  'server': {
    'name': 'ai.smithery/acme-docs',
    'description': 'Docs',
    'version': '1.0.0',
    'remotes': [
      {
        'type': 'streamable-http',
        'url': 'https://server.smithery.ai/acme/mcp',
        'headers': [
          {'name': 'Authorization', 'value': 'Bearer {smithery_api_key}', 'isRequired': true, 'isSecret': true},
          {'name': 'X-Workspace', 'value': '{workspace}', 'isRequired': false},
        ],
      },
    ],
  },
});

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Jev hardening', () {
    test('retries carry one idempotency key, so a decision is billed once', () async {
      final keys = <String?>[];
      var calls = 0;
      final client = MockClient((req) async {
        keys.add(req.headers['Idempotency-Key']);
        if (++calls == 1) return http.Response('busy', 529, headers: {'retry-after': '0'});
        return http.Response(
          jsonEncode({
            'model': 'jev-1.13.0',
            'answers': {
              'billing': {'type': 'noul', 'noul': 0.9},
            },
            'usage': {'input_tokens': 5, 'output_tokens': 1},
          }),
          200,
        );
      });
      final d = await JevClient(apiKey: 'k', httpClient: client).decide(
        state: 'charged twice',
        questions: {'billing': JevQuestion.noul('About billing?')},
      );
      expect(d.answers['billing']!.isTrue(), isTrue);
      expect(keys, hasLength(2));
      expect(keys.first, isNotNull);
      expect(keys.first, keys.last);
    });

    test('the key never goes over plain http to another machine', () async {
      final remote = JevClient(apiKey: 'k', baseUrl: 'http://example.com', httpClient: MockClient((_) async => http.Response('{}', 200)));
      expect(() => remote.listModels(), throwsA(isA<AiException>()));
      final local = JevClient(
        apiKey: 'k',
        baseUrl: 'http://localhost:8080',
        httpClient: MockClient((_) async => http.Response(jsonEncode({'models': ['jev-latest']}), 200)),
      );
      expect(await local.listModelIds(), ['jev-latest']);
    });
  });

  group('MCP hardening', () {
    test('a registry placeholder is never saved as a key', () async {
      final hit = _keyedHit();
      expect(hit.inputs.first.variables, ['smithery_api_key']);
      expect(() => hit.toServer(), throwsA(isA<McpException>()));
      final server = hit.toServer(headers: {'smithery_api_key': 'sk-1'});
      expect(server.headers, {'Authorization': 'Bearer sk-1'});
      final reg = McpRegistry(persist: false);
      expect(
        () => reg.install(McpServer.http('x', url: 'https://a.example/mcp', headers: {'Authorization': 'Bearer {key}'})),
        throwsArgumentError,
      );
    });

    test('plain http only reaches this machine or the local network', () async {
      final reg = McpRegistry(persist: false);
      expect(() => reg.install(McpServer.http('x', url: 'http://mcp.example.com/mcp')), throwsArgumentError);
      expect((await reg.install(McpServer.http('lan', url: 'http://192.168.1.20:3000/mcp'))).id, 'lan');
      expect(McpRegistry.isLocalHost('172.20.0.4'), isTrue);
      expect(McpRegistry.isLocalHost('172.40.0.4'), isFalse);
    });

    test('the agent cannot add a local command server unless allowed', () async {
      final reg = McpRegistry(persist: false);
      final install = (await reg.managementTools()).firstWhere((t) => t.name == 'mcp_install');
      final out = await install.execute!({
        'server': {'id': 'shell', 'transport': 'stdio', 'command': 'sh'},
      });
      expect((out as Map)['error'], isNotNull);
      expect(await reg.isInstalled('shell'), isFalse);
      reg.allowAgentStdio = true;
      await install.execute!({
        'server': {'id': 'shell', 'transport': 'stdio', 'command': 'sh'},
      });
      expect(await reg.isInstalled('shell'), isTrue);
    });
  });

  group('Skills hardening', () {
    test('search returns what each skill does (Skyll)', () async {
      final client = MockClient((req) async {
        expect(req.url.host, 'api.skyll.app');
        return http.Response(
          jsonEncode({
            'skills': [
              {
                'id': 'pdf',
                'title': 'pdf',
                'description': 'Read and fill PDFs.',
                'source': 'anthropics/skills',
                'install_count': 10,
                'refs': {'raw': 'https://raw.githubusercontent.com/anthropics/skills/main/skills/pdf/SKILL.md'},
              },
            ],
          }),
          200,
        );
      });
      final hit = (await SkillRegistry(persist: false, httpClient: client).search('pdf')).single;
      expect(hit.description, 'Read and fill PDFs.');
      expect(hit.installSource, 'anthropics/skills@pdf');
      expect(hit.rawUrl, contains('SKILL.md'));
    });

    test('remote skills install over https only', () async {
      final reg = SkillRegistry(persist: false);
      expect(() => reg.install('http://example.com/SKILL.md'), throwsA(isA<AiException>()));
    });

    test('listeners hear installs and removals', () async {
      final reg = SkillRegistry(persist: false);
      var heard = 0;
      reg.addListener(() => heard++);
      await reg.install('---\nname: notes\ndescription: Take notes.\n---\nWrite it down.');
      await reg.uninstall('notes');
      expect(heard, 2);
    });

    test('long third-party descriptions are capped in the prompt', () async {
      final reg = SkillRegistry(persist: false);
      await reg.add(Skill(name: 'long', description: 'x' * 2000, content: 'body'));
      final prompt = (await reg.prompt())!;
      expect(prompt.length, lessThan(SkillRegistry.maxPromptDescription + 300));
    });
  });

  test('previewing a catalog hit reads only the folder its SKILL.md is in', () async {
    final requested = <String>[];
    final reg = SkillRegistry(
      persist: false,
      httpClient: MockClient((r) async {
        requested.add(r.url.toString());
        if (r.url.host == 'api.github.com') {
          return http.Response(
              jsonEncode({
                'tree': [
                  for (final p in ['skills/pdf/SKILL.md', 'skills/pdf/forms.md', 'skills/pdf/scripts/fill.py', 'skills/docx/SKILL.md', 'skills/docx/ooxml.md'])
                    {'type': 'blob', 'path': p}
                ]
              }),
              200);
        }
        final path = r.url.path;
        if (path.endsWith('pdf/SKILL.md')) return http.Response('---\nname: pdf\ndescription: PDFs.\n---\nUse forms.md.', 200);
        if (path.endsWith('forms.md')) return http.Response('# Forms', 200);
        if (path.endsWith('fill.py')) return http.Response('print(1)', 200);
        return http.Response('nope', 404);
      }),
    );
    const hit = SkillHit(
      id: 'anthropics/skills/pdf',
      name: 'pdf',
      source: 'anthropics/skills',
      skillId: 'pdf',
      rawUrl: 'https://raw.githubusercontent.com/anthropics/skills/main/skills/pdf/SKILL.md',
    );
    final found = await reg.previewHit(hit);
    expect(found.single.name, 'pdf');
    expect(found.single.files.keys.toSet(), {'forms.md', 'scripts/fill.py'});
    expect(requested.where((u) => u.contains('docx')), isEmpty);
    expect(requested.first, contains('/git/trees/main'));
    expect(reg.all, isEmpty, reason: 'preview installs nothing');
  });
}
