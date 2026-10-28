import 'dart:convert';

import 'package:flutter/material.dart';

import '../agents/skills.dart';
import '../mcp/mcp.dart';
import '../omni_ai.dart';

/// Search catalogs, review configuration, and manage installed capabilities.
/// Installed skills and MCP tools are available through [OmniAI.allToolkits].
class ExtensionsView extends StatefulWidget {
  const ExtensionsView({super.key, required this.ai, this.mcp, this.toolsSettings, this.installedHint});
  final OmniAI ai;

  /// When set, fixes the catalog and omits the built-in tab selector.
  final bool? mcp;
  final Widget? toolsSettings;
  final String? installedHint;

  @override
  State<ExtensionsView> createState() => _ExtensionsViewState();
}

class _ExtensionsViewState extends State<ExtensionsView> {
  final _query = TextEditingController();
  late bool _mcp = widget.mcp ?? false;
  bool _busy = false;
  bool _searched = false;
  String? _error;
  List<SkillHit> _skills = [];
  List<McpCatalogHit> _servers = [];
  List<Skill> _installedSkills = [];
  List<McpServer> _installedServers = [];

  @override
  void initState() {
    super.initState();
    _run(_refresh);
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final skills = await widget.ai.skills.list();
    final servers = await widget.ai.mcp.list();
    if (!mounted) return;
    setState(() {
      _installedSkills = skills;
      _installedServers = servers;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _search() => _run(() async {
        if (_mcp) {
          final hits = await widget.ai.mcp.search(_query.text);
          if (mounted) setState(() => _servers = hits);
        } else {
          final hits = await widget.ai.skills.search(_query.text);
          if (mounted) setState(() => _skills = hits);
        }
        if (mounted) setState(() => _searched = true);
      });

  Future<void> _previewSkill(SkillHit hit) => _run(() async {
        final skills = await widget.ai.skills.listRemote(hit.source, skill: hit.skillId);
        if (skills.isEmpty) throw StateError('No matching SKILL.md in ${hit.source}.');
        if (!mounted) return;
        final install = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                  title: Text(hit.name),
                  content: SizedBox(
                      width: 650,
                      child: SingleChildScrollView(
                          child: SelectableText(
                              '${hit.source}\n\n${skills.map((s) => '${s.name}\n${s.description}\n\n${s.content}\n\nFiles: ${s.files.keys.join(', ')}').join('\n\n')}'))),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Install skill')),
                  ],
                ));
        if (install == true) {
          for (final skill in skills) {
            await widget.ai.skills.add(skill);
          }
          await _refresh();
        }
      });

  Future<void> _editServer({McpCatalogHit? hit, McpServer? installed}) async {
    await _run(() async {
      McpServer draftFrom(McpCatalogHit h) {
        try {
          return h.toServer();
        } on McpException {
          // It needs keys: start from its address and let the form ask.
          final remote = h.remotes.where((r) => r.url.isNotEmpty).firstOrNull;
          if (remote == null) rethrow;
          return remote.type.contains('sse') ? McpServer.sse(h.suggestedId, url: remote.url) : McpServer.http(h.suggestedId, url: remote.url);
        }
      }

      final draft = installed ?? (hit == null ? null : draftFrom(hit)) ?? McpServer.http('my-server', url: 'https://example.com/mcp');
      if (!mounted) return;
      final config = await _configDialog(draft, hit: hit);
      if (config == null) return;
      await widget.ai.mcp.install(config);
      await _refresh();
    });
  }

  Future<McpServer?> _configDialog(McpServer server, {McpCatalogHit? hit}) async {
    final editor = TextEditingController(text: const JsonEncoder.withIndent('  ').convert(server.toJson()));
    final id = TextEditingController(text: server.id);
    final endpoint = TextEditingController(text: server.url ?? '');
    final authorization =
        TextEditingController(text: server.headers.entries.where((e) => e.key.toLowerCase() == 'authorization').firstOrNull?.value ?? '');
    var advanced = server.transport == McpTransportKind.stdio;
    var transport = server.transport;
    var baseConfig = server.toJson();
    Map<String, dynamic> formConfig() {
      var url = endpoint.text.trim();
      if (url.isNotEmpty && !url.contains('://')) url = 'https://$url';
      return {
        ...baseConfig,
        'id': id.text.trim(),
        'transport': transport.name,
        'url': url,
        'headers': {
          for (final entry in (baseConfig['headers'] as Map? ?? const {}).entries)
            if ('${entry.key}'.toLowerCase() != 'authorization') '${entry.key}': '${entry.value}',
          if (authorization.text.trim().isNotEmpty) 'Authorization': authorization.text.trim(),
        },
      };
    }

    String? error;
    try {
      final route = DialogRoute<McpServer>(
          context: context,
          builder: (context) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                    title: const Text('Configure MCP server'),
                    content: SizedBox(
                        width: 650,
                        child: SingleChildScrollView(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if (hit != null) ...[
                            Text('${hit.name} • ${hit.version}\n${hit.description}'),
                            if (hit.requiredEnv.isNotEmpty) Text('Required environment: ${hit.requiredEnv.join(', ')}'),
                          ],
                          const Text(
                              'Review the endpoint or command and add required headers, environment values, and arguments. Stdio needs a local runtime. Connecting starts the command. Configuration is stored on this device.'),
                          const SizedBox(height: 12),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Advanced JSON configuration'),
                            subtitle: const Text('For local commands, custom headers, and protocol options.'),
                            value: advanced,
                            onChanged: (value) {
                              try {
                                if (value) {
                                  editor.text = const JsonEncoder.withIndent('  ').convert(formConfig());
                                } else {
                                  final draft = McpServer.fromJson(jsonDecode(editor.text) as Map);
                                  if (draft.transport == McpTransportKind.stdio) {
                                    throw const FormatException('Use advanced JSON for local stdio servers.');
                                  }
                                  id.text = draft.id;
                                  endpoint.text = draft.url ?? '';
                                  authorization.text =
                                      draft.headers.entries.where((e) => e.key.toLowerCase() == 'authorization').firstOrNull?.value ?? '';
                                  transport = draft.transport;
                                  baseConfig = draft.toJson();
                                }
                                update(() {
                                  advanced = value;
                                  error = null;
                                });
                              } catch (e) {
                                update(() => error = '$e');
                              }
                            },
                          ),
                          if (!advanced) ...[
                            TextField(
                                controller: id, decoration: const InputDecoration(labelText: 'Server id', border: OutlineInputBorder())),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<McpTransportKind>(
                              isExpanded: true,
                              initialValue: transport,
                              decoration: const InputDecoration(labelText: 'Transport', border: OutlineInputBorder()),
                              items: const [
                                DropdownMenuItem(value: McpTransportKind.http, child: Text('Streamable HTTP')),
                                DropdownMenuItem(value: McpTransportKind.sse, child: Text('Legacy SSE'))
                              ],
                              onChanged: (value) {
                                if (value != null) update(() => transport = value);
                              },
                            ),
                            const SizedBox(height: 12),
                            TextField(
                                controller: endpoint,
                                keyboardType: TextInputType.url,
                                autocorrect: false,
                                decoration: const InputDecoration(
                                    labelText: 'MCP endpoint URL', hintText: 'https://example.com/mcp', border: OutlineInputBorder())),
                            const SizedBox(height: 12),
                            TextField(
                                controller: authorization,
                                obscureText: true,
                                enableSuggestions: false,
                                autocorrect: false,
                                decoration: const InputDecoration(
                                    labelText: 'Authorization header (optional)',
                                    hintText: 'Bearer <API key>',
                                    helperText: 'For API keys, enter Bearer followed by the key. Saved in secure device storage.',
                                    border: OutlineInputBorder())),
                          ],
                          if (advanced)
                            TextField(
                                controller: editor,
                                minLines: 8,
                                maxLines: 18,
                                decoration: const InputDecoration(labelText: 'Server JSON', border: OutlineInputBorder())),
                          if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                        ]))),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () {
                            try {
                              final config = McpServer.fromJson(advanced ? jsonDecode(editor.text) as Map : formConfig());
                              if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$').hasMatch(config.id)) {
                                throw const FormatException('Invalid server id.');
                              }
                              if (config.transport == McpTransportKind.stdio) {
                                if (config.command?.trim().isNotEmpty != true) throw const FormatException('A command is required.');
                              } else {
                                final uri = Uri.tryParse(config.url ?? '');
                                if (uri == null || !uri.hasAuthority || !['https', 'http'].contains(uri.scheme)) {
                                  throw const FormatException('An HTTP(S) endpoint is required.');
                                }
                              }
                              Navigator.pop(context, config);
                            } catch (e) {
                              update(() => error = '$e');
                            }
                          },
                          child: const Text('Save server')),
                    ],
                  )));
      final result = await Navigator.of(context, rootNavigator: true).push(route);
      await route.completed;
      return result;
    } finally {
      editor.dispose();
      id.dispose();
      endpoint.dispose();
      authorization.dispose();
    }
  }

  Future<void> _inspectServer(McpServer server) => _run(() async {
        final client = await widget.ai.mcp.connect(server.id);
        final tools = await client.listTools();
        if (!mounted) return;
        await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
                  title: Text('${server.id}: ${tools.length} tools'),
                  content: SizedBox(
                      width: 600,
                      child: SingleChildScrollView(
                          child: SelectableText(tools.isEmpty
                              ? 'This server exposes no tools.'
                              : tools.map((t) => '${t.name}\n${t.description}\n${jsonEncode(t.inputSchema)}').join('\n\n')))),
                  actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
                ));
      });

  Future<void> _manualSkill() => _run(() async {
        final editor = TextEditingController();
        String? source;
        try {
          if (!mounted) return;
          source = await showDialog<String>(
              context: context,
              builder: (context) => AlertDialog(
                    title: const Text('Install a skill'),
                    content: SizedBox(
                        width: 600,
                        child: TextField(
                            controller: editor,
                            minLines: 3,
                            maxLines: 12,
                            decoration: const InputDecoration(labelText: 'GitHub owner/repo@skill, SKILL.md URL, or markdown'))),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(context, editor.text), child: const Text('Install'))
                    ],
                  ));
        } finally {
          editor.dispose();
        }
        if (source == null || source.trim().isEmpty) return;
        await widget.ai.skills.install(source);
        await _refresh();
      });

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
        if (widget.mcp == null)
          SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Skills'), icon: Icon(Icons.menu_book)),
                ButtonSegment(value: true, label: Text('MCP servers'), icon: Icon(Icons.extension))
              ],
              selected: {
                _mcp
              },
              onSelectionChanged: _busy
                  ? null
                  : (value) => setState(() {
                        _mcp = value.single;
                        _searched = false;
                        _error = null;
                      })),
        const SizedBox(height: 16),
        if (widget.toolsSettings != null) widget.toolsSettings!,
        Text(_mcp ? 'Discover servers in the official MCP Registry' : 'Discover skills from skills.sh',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
            controller: _query,
            onSubmitted: _busy ? null : (_) => _search(),
            decoration: InputDecoration(
                labelText: _mcp ? 'Search servers (3+ characters, empty to browse)' : 'Search skills (2+ characters)',
                suffixIcon: IconButton(tooltip: 'Search', onPressed: _busy ? null : _search, icon: const Icon(Icons.search)),
                border: const OutlineInputBorder())),
        const SizedBox(height: 8),
        Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                onPressed: _busy
                    ? null
                    : _mcp
                        ? () => _editServer()
                        : _manualSkill,
                icon: const Icon(Icons.add),
                label: Text(_mcp ? 'Add server manually' : 'Install from source'))),
        if (_busy) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Working…')),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: SelectableText(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        if (_searched) ...[
          Text('Search results', style: Theme.of(context).textTheme.titleMedium),
          if ((_mcp ? _servers.isEmpty : _skills.isEmpty)) const Padding(padding: EdgeInsets.all(16), child: Text('No results found.')),
          if (!_mcp)
            for (final hit in _skills)
              Card(
                  child: ListTile(
                      title: Text(hit.name),
                      subtitle: Text('${hit.source} • ${hit.installs} installs'),
                      trailing: TextButton(onPressed: _busy ? null : () => _previewSkill(hit), child: const Text('Review')))),
          if (_mcp)
            for (final hit in _servers)
              Card(
                  child: ListTile(
                      title: Text(hit.name),
                      subtitle: Text('${hit.description}\n${hit.version} • ${hit.hasRemote ? 'Remote' : 'Local runtime'}'),
                      isThreeLine: true,
                      trailing: TextButton(onPressed: _busy ? null : () => _editServer(hit: hit), child: const Text('Configure')))),
        ],
        const SizedBox(height: 20),
        Text('Installed ${_mcp ? 'servers' : 'skills'}', style: Theme.of(context).textTheme.titleMedium),
        Text(widget.installedHint ?? 'Available to Chat and Agent. Start a new chat after changing capabilities.'),
        if ((_mcp ? _installedServers.isEmpty : _installedSkills.isEmpty))
          const Padding(padding: EdgeInsets.all(16), child: Text('Nothing installed yet.')),
        if (!_mcp)
          for (final skill in _installedSkills)
            Card(
                child: ExpansionTile(title: Text(skill.name), subtitle: Text(skill.description), children: [
              Padding(padding: const EdgeInsets.all(16), child: SelectableText(skill.content)),
              for (final file in skill.files.entries)
                ExpansionTile(
                    title: Text(file.key), children: [Padding(padding: const EdgeInsets.all(16), child: SelectableText(file.value))]),
              TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                            await widget.ai.skills.uninstall(skill.name);
                            await _refresh();
                          }),
                  child: const Text('Remove skill')),
            ])),
        if (_mcp)
          for (final server in _installedServers)
            Card(
                child: ListTile(
                    title: Text(server.id),
                    subtitle: Text(server.url ?? '${server.command} ${server.args.join(' ')}'),
                    onTap: _busy ? null : () => _editServer(installed: server),
                    trailing: Wrap(children: [
                      IconButton(
                          tooltip: 'Connect and list tools',
                          onPressed: _busy ? null : () => _inspectServer(server),
                          icon: const Icon(Icons.electrical_services)),
                      IconButton(
                          tooltip: 'Remove server',
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                    await widget.ai.mcp.uninstall(server.id);
                                    await _refresh();
                                  }),
                          icon: const Icon(Icons.delete_outline)),
                    ]))),
      ]);
}
