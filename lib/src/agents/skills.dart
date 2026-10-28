import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaml/yaml.dart';

import '../core/cancel.dart';
import '../core/errors.dart';
import '../core/http.dart';
import '../core/tools.dart';
import 'toolkit.dart';

/// A procedure an agent loads when a task calls for it, like an Agent
/// Skill (`SKILL.md`): only its name and description sit in the prompt;
/// the agent reads the full [content] with `load_skill` when it needs it.
///
/// ```dart
/// Skill(
///   name: 'release_notes',
///   description: 'Use when the user wants release notes or a changelog.',
///   content: '1. List merged changes…\n2. Group by feature…',
/// )
/// ```
class Skill {
  Skill({
    required String name,
    required this.description,
    required this.content,
    this.deferred = false,
    this.files = const {},
    this.source,
  }) : name = sanitizeName(name);

  /// Reads a `SKILL.md` (with `---` frontmatter) or plain markdown. Without
  /// a description, the first line of the body is used.
  factory Skill.parse(String name, String markdown, {Map<String, String> files = const {}, String? source}) {
    var body = markdown.trim();
    final meta = <String, String>{};
    if (body.startsWith('---')) {
      final rest = body.substring(3);
      final close = RegExp(r'\r?\n---[ \t]*\r?\n').firstMatch(rest);
      if (close != null) {
        final parsed = loadYaml(rest.substring(0, close.start));
        if (parsed is Map) {
          for (final entry in parsed.entries) {
            meta['${entry.key}'] = '${entry.value}'.trim();
          }
        }
        body = rest.substring(close.end).trim();
      }
    }
    final firstLine = body.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => name).replaceAll(RegExp(r'^#+\s*'), '');
    return Skill(
      name: meta['name'] ?? name,
      description: meta['description'] ?? firstLine,
      content: body,
      deferred: meta['deferred'] == 'true',
      files: files,
      source: source,
    );
  }

  factory Skill.fromJson(Map j) => Skill(
        name: '${j['name']}',
        description: '${j['description'] ?? ''}',
        content: '${j['content'] ?? ''}',
        deferred: j['deferred'] == true,
        files: {
          if (j['files'] is Map)
            for (final e in (j['files'] as Map).entries) '${e.key}': '${e.value}'
        },
        source: j['source'] as String?,
      );

  /// Letters, digits, `_` and `-`, 1–64 chars, for tool enums and folders.
  static String sanitizeName(String name) {
    var s = name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_\-]+'), '-').replaceAll(RegExp(r'-+'), '-');
    s = s.replaceAll(RegExp(r'^-+|-+$'), '');
    if (s.isEmpty) s = 'skill';
    if (s.length > 64) s = s.substring(0, 64);
    if (!RegExp(r'^[a-z0-9]').hasMatch(s)) s = 's$s';
    return s;
  }

  final String name;

  /// When to use it, written for the model: "Use when…".
  final String description;

  /// The full instructions.
  final String content;

  /// Kept out of the prompt; the agent finds it with `find_skills`.
  final bool deferred;

  /// Extra reference files (`references/checklist.md` → text) the agent
  /// can read with `read_skill_file`.
  final Map<String, String> files;

  /// Where it was installed from (`owner/repo`, a URL, or `inline`).
  final String? source;

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'content': content,
        if (deferred) 'deferred': true,
        if (files.isNotEmpty) 'files': files,
        if (source != null) 'source': source,
      };
}

/// A skill from the [skills.sh](https://skills.sh) catalog (`npx skills find`).
class SkillHit {
  const SkillHit({
    required this.id,
    required this.name,
    required this.source,
    this.skillId,
    this.installs = 0,
    this.url,
    this.description = '',
    this.rawUrl,
  });

  /// A result from Skyll (`api.skyll.app/search`), which also says what the
  /// skill does and where its SKILL.md is.
  factory SkillHit.fromSkyll(Map j) {
    final source = '${j['source'] ?? ''}';
    final skillId = '${j['id'] ?? j['title'] ?? ''}';
    final refs = j['refs'] is Map ? j['refs'] as Map : const {};
    return SkillHit(
      id: '$source/$skillId',
      name: '${j['title'] ?? skillId}',
      source: source,
      skillId: skillId,
      installs: (j['install_count'] as num?)?.toInt() ?? 0,
      url: refs['skills_sh'] as String? ?? 'https://skills.sh/$source/$skillId',
      description: '${j['description'] ?? ''}',
      rawUrl: refs['raw'] as String?,
    );
  }

  factory SkillHit.fromJson(Map j) {
    final source = '${j['source'] ?? ''}';
    final skillId = (j['skillId'] ?? j['slug'] ?? j['name'])?.toString();
    return SkillHit(
      id: '${j['id'] ?? (skillId == null ? source : '$source/$skillId')}',
      name: '${j['name'] ?? skillId ?? source}',
      source: source,
      skillId: skillId,
      installs: (j['installs'] as num?)?.toInt() ?? 0,
      url: j['url'] as String? ?? (source.isEmpty ? null : 'https://skills.sh/$source${skillId == null ? '' : '/$skillId'}'),
      description: '${j['description'] ?? ''}',
    );
  }

  /// Catalog id, usually `owner/repo/skill`.
  final String id;
  final String name;

  /// GitHub `owner/repo` (what [SkillRegistry.install] takes).
  final String source;

  /// Skill name inside that repo (`npx skills add source --skill skillId`).
  final String? skillId;
  final int installs;
  final String? url;

  /// What it is for, when the catalog says.
  final String description;

  /// Its SKILL.md on raw.githubusercontent.com, when known.
  final String? rawUrl;

  /// Source string for [SkillRegistry.install]: `owner/repo@skill`.
  String get installSource => skillId == null || skillId!.isEmpty ? source : '$source@$skillId';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'source': source,
        if (skillId != null) 'skill': skillId,
        'installs': installs,
        if (description.isNotEmpty) 'description': description,
        if (url != null) 'url': url,
        'install': installSource,
      };
}

/// Install, list and use Agent Skills (`SKILL.md`), the way the AI SDK
/// cookbook and `npx skills add` do: discover name + description, load
/// the body on demand.
///
/// Sources [install] accepts:
/// - markdown (a `SKILL.md` string)
/// - `https://…/SKILL.md`
/// - GitHub `owner/repo`, `owner/repo@skill-name`, or a github.com URL
///
/// Search the public [skills.sh](https://skills.sh) catalog (the same API
/// as `npx skills find`), then install a hit:
///
/// ```dart
/// final hits = await ai.skills.search('pdf');
/// await ai.skills.installHit(hits.first);
/// ```
class SkillRegistry extends Toolkit implements Listenable {
  SkillRegistry({
    this.storeKey = 'omni_ai.skills',
    http.Client? httpClient,
    this.persist = true,
    this.catalogUrl = 'https://skills.sh',
    this.searchUrl = 'https://api.skyll.app',
  }) : _net = AiHttp(provider: 'skills', client: httpClient);

  final _changes = _SkillChanges();
  @override
  void addListener(VoidCallback listener) => _changes.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => _changes.removeListener(listener);

  /// Tells listeners (settings screens) that installed skills changed.
  void notifyListeners() => _changes.notify();

  /// Skyll's search, which returns descriptions; skills.sh is the fallback.
  /// Empty to search skills.sh only.
  final String searchUrl;

  /// Largest SKILL.md or bundled file read, and the most a skill may bundle.
  static const maxFileBytes = 512 * 1024;
  static const maxBundleBytes = 2 * 1024 * 1024;
  static const maxBundledFiles = 40;

  /// The longest description put in an agent's prompt; the rest is in
  /// `load_skill`.
  static const maxPromptDescription = 300;

  /// Origin of the skills.sh catalog (no trailing slash).
  final String catalogUrl;

  final String storeKey;
  final bool persist;
  final AiHttp _net;
  final _skills = <String, Skill>{};
  bool _loaded = false;
  Future<void>? _loading;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    if (_loaded || !persist) {
      _loaded = true;
      return;
    }
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storeKey);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final x in list) {
        if (x is Map) {
          final s = Skill.fromJson(x);
          _skills[s.name] = s;
        }
      }
    } catch (e) {
      if (!'$e'.contains('Binding has not yet been initialized')) debugPrint('[omni_ai] could not load skills: $e');
    }
  }

  Future<void> _save() async {
    if (!persist) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storeKey, jsonEncode([for (final s in _skills.values) s.toJson()]));
  }

  /// Installed skills, for `Agent(skills: …)`.
  List<Skill> get all => _skills.values.toList();

  Skill? operator [](String name) => _skills[name];

  Future<bool> isInstalled(String name) async {
    await load();
    return _skills.containsKey(Skill.sanitizeName(name));
  }

  /// Installed skills (loads from disk first).
  Future<List<Skill>> list() async {
    await load();
    return all;
  }

  /// Adds a skill you already have. Saves it.
  Future<Skill> add(Skill skill) async {
    await load();
    _skills[skill.name] = skill;
    await _save();
    notifyListeners();
    return skill;
  }

  /// Removes an installed skill.
  Future<bool> uninstall(String name) async {
    await load();
    final gone = _skills.remove(Skill.sanitizeName(name)) != null;
    if (gone) {
      await _save();
      notifyListeners();
    }
    return gone;
  }

  /// Installs from markdown, a SKILL.md URL, or a GitHub `owner/repo`
  /// (optionally `@skill-name`). Returns every skill that was added.
  ///
  /// [skill] keeps only that named skill from a multi-skill repo (the
  /// `--skill` flag of `npx skills add`).
  Future<List<Skill>> install(String source, {String? skill, String? name}) async {
    await load();
    final trimmed = source.trim();
    final added = <Skill>[];
    if (trimmed.startsWith('---') || trimmed.contains('\n')) {
      added.add(await add(Skill.parse(name ?? 'skill', trimmed, source: 'inline')));
      return added;
    }
    if (trimmed.startsWith('http://')) throw AiException('Skills install over https:// only.');
    if (trimmed.startsWith('https://')) {
      if (trimmed.toLowerCase().endsWith('.md') || trimmed.contains('SKILL.md')) {
        added.add(await add(await _fetchMarkdown(trimmed, name: name, source: trimmed)));
        return added;
      }
      added.addAll(await _installGithub(trimmed, skill: skill));
      return added;
    }
    added.addAll(await _installGithub(trimmed, skill: skill));
    return added;
  }

  /// Skills in [source] without installing them (`npx skills add --list`).
  Future<List<Skill>> listRemote(String source, {String? skill}) async {
    final trimmed = source.trim();
    if (trimmed.startsWith('http://')) throw AiException('Skills install over https:// only.');
    if (trimmed.startsWith('https://')) {
      if (trimmed.toLowerCase().endsWith('.md') || trimmed.contains('SKILL.md')) {
        return [await _fetchMarkdown(trimmed, source: trimmed)];
      }
    }
    return _discoverGithub(trimmed, skill: skill);
  }

  /// Use: the installed [Skill] objects, ready for an [Agent].
  List<Skill> use({Iterable<String>? names}) {
    if (names == null) return all;
    final want = names.map(Skill.sanitizeName).toSet();
    return [
      for (final s in all)
        if (want.contains(s.name)) s
    ];
  }

  /// Searches [skills.sh](https://skills.sh) (same public API as
  /// `npx skills find`). No API key. [query] must be at least 2 characters.
  Future<List<SkillHit>> search(String query, {int limit = 20, CancelToken? cancelToken}) async {
    final q = query.trim();
    if (q.length < 2) throw ArgumentError('Search needs at least 2 characters.');
    if (searchUrl.isNotEmpty) {
      try {
        final r = await _net.get(
          Uri.parse('$searchUrl/search').replace(queryParameters: {'q': q, 'limit': '${limit.clamp(1, 50)}'}),
          headers: {'User-Agent': 'omni_ai', 'Accept': 'application/json'},
          timeout: const Duration(seconds: 20),
          cancelToken: cancelToken,
        );
        if (r.statusCode < 400) {
          final j = jsonDecode(utf8.decode(r.bodyBytes));
          final list = j is Map ? j['skills'] : null;
          if (list is List && list.isNotEmpty) {
            return [
              for (final x in list)
                if (x is Map && '${x['source'] ?? ''}'.isNotEmpty) SkillHit.fromSkyll(x),
            ];
          }
        }
      } on AiCancelledException {
        rethrow;
      } catch (_) {
        // Fall through to skills.sh.
      }
    }
    final url = Uri.parse('$catalogUrl/api/search').replace(queryParameters: {
      'q': q,
      'limit': '${limit.clamp(1, 200)}',
    });
    final r = await _net.get(url, headers: {'User-Agent': 'omni_ai', 'Accept': 'application/json'}, cancelToken: cancelToken);
    if (r.statusCode >= 400) {
      throw AiException('skills.sh search failed (${r.statusCode}).',
          statusCode: r.statusCode, body: utf8.decode(r.bodyBytes, allowMalformed: true));
    }
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    final list = j is Map ? (j['skills'] ?? j['data'] ?? j['results']) : j;
    return [
      for (final x in (list as List? ?? const []))
        if (x is Map) SkillHit.fromJson(x)
    ];
  }

  /// Installs a catalog hit from [search].
  Future<List<Skill>> installHit(SkillHit hit) async {
    await load();
    final found = await previewHit(hit);
    if (found.isEmpty) throw AiException('No SKILL.md found for "${hit.name}".');
    return [for (final s in found) await add(s)];
  }

  /// [hit]'s skills without installing them, for a review before install.
  /// When the catalog says where its SKILL.md is, only that folder is read.
  Future<List<Skill>> previewHit(SkillHit hit) async {
    final spec = hit.rawUrl == null ? null : _GithubSpec.fromRaw(hit.rawUrl!);
    if (spec != null) {
      final found = await _discoverSpec(spec);
      if (found.isNotEmpty) return found;
    }
    return listRemote(hit.source, skill: hit.skillId);
  }

  Future<Skill> _fetchMarkdown(String url, {String? name, String? source}) async {
    var fetchUrl = url;
    final uri = Uri.parse(url);
    if (['github.com', 'www.github.com'].contains(uri.host) && uri.pathSegments.contains('blob')) {
      final spec = _GithubSpec.parse(url);
      fetchUrl = spec.rawUrl(spec.path);
    }
    final r = await _net.get(Uri.parse(fetchUrl), headers: {'User-Agent': 'omni_ai', 'Accept': 'text/plain, text/markdown, */*'});
    if (r.statusCode >= 400) throw AiException('Could not fetch skill at $url (${r.statusCode}).', statusCode: r.statusCode);
    if (r.bodyBytes.length > maxFileBytes) throw AiException('That SKILL.md is over ${maxFileBytes ~/ 1024} KB.');
    final text = utf8.decode(r.bodyBytes, allowMalformed: true);
    final fallback = name ?? Uri.parse(url).pathSegments.where((p) => p.isNotEmpty && p != 'SKILL.md').lastOrNull ?? 'skill';
    return Skill.parse(fallback, text, source: source ?? url);
  }

  Future<List<Skill>> _installGithub(String source, {String? skill}) async {
    final found = await _discoverGithub(source, skill: skill);
    if (found.isEmpty) throw AiException('No SKILL.md found in "$source".');
    return [for (final s in found) await add(s)];
  }

  Future<List<Skill>> _discoverGithub(String source, {String? skill}) => _discoverSpec(_GithubSpec.parse(source), skill: skill);

  /// Runs [tasks] at most [width] at a time, keeping their order.
  static Future<List<T>> _pooled<T>(List<Future<T> Function()> tasks, {int width = 6}) async {
    final out = List<T?>.filled(tasks.length, null);
    var next = 0;
    Future<void> worker() async {
      while (next < tasks.length) {
        final i = next++;
        out[i] = await tasks[i]();
      }
    }

    await Future.wait([for (var i = 0; i < width && i < tasks.length; i++) worker()]);
    return out.cast<T>();
  }

  Future<List<Skill>> _discoverSpec(_GithubSpec spec, {String? skill}) async {
    skill ??= spec.skillHint;
    var paths = await _githubSkillPaths(spec);
    if (spec.path.isNotEmpty) {
      paths = paths.where((p) => p == spec.path || p.startsWith('${spec.path}/')).toList();
    }
    if (skill != null) {
      final want = Skill.sanitizeName(skill);
      final byFolder = [
        for (final p in paths)
          if (Skill.sanitizeName(_folderName(p)) == want || p.toLowerCase().contains('/$want/')) p
      ];
      // Catalog names may come from frontmatter rather than the folder name.
      if (byFolder.isNotEmpty) paths = byFolder;
    }
    if (paths.isEmpty) {
      // One-skill repo: try SKILL.md at the root.
      try {
        final path = spec.path.isEmpty
            ? 'SKILL.md'
            : spec.path.endsWith('.md')
                ? spec.path
                : '${spec.path}/SKILL.md';
        final s = await _fetchMarkdown(spec.rawUrl(path), name: spec.skillHint, source: spec.display);
        if (skill == null || s.name == Skill.sanitizeName(skill)) return [s];
      } catch (_) {}
      return const [];
    }
    final texts = await _pooled([for (final path in paths) () => _getText(spec.rawUrl(path))]);
    final out = <Skill>[];
    for (final (i, path) in paths.indexed) {
      final dir = path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
      final md = texts[i];
      if (md == null) continue;
      final metadata = Skill.parse(_folderName(path), md);
      if (skill != null &&
          metadata.name != Skill.sanitizeName(skill) &&
          Skill.sanitizeName(_folderName(path)) != Skill.sanitizeName(skill)) {
        continue;
      }
      final extras = [
        for (final extra in await _githubFilesUnder(spec, dir))
          if (extra != path && !extra.toLowerCase().endsWith('skill.md') && !_looksBinary(extra)) extra
      ].take(maxBundledFiles).toList();
      final bodies = await _pooled([for (final extra in extras) () => _getText(spec.rawUrl(extra))]);
      final files = <String, String>{};
      var bundled = 0;
      for (final (j, extra) in extras.indexed) {
        final text = bodies[j];
        if (text == null || text.length > maxFileBytes || bundled + text.length > maxBundleBytes) continue;
        final rel = dir.isEmpty ? extra : extra.substring(dir.length + 1);
        bundled += text.length;
        files[rel.replaceAll('\\', '/')] = text;
      }
      out.add(Skill.parse(_folderName(path), md, files: files, source: spec.display));
    }
    return out;
  }

  Future<List<String>> _githubSkillPaths(_GithubSpec spec) async {
    final tree = await _githubTree(spec);
    return [
      for (final p in tree)
        if (p.toLowerCase().endsWith('/skill.md') || p.toLowerCase() == 'skill.md') p,
    ];
  }

  Future<List<String>> _githubFilesUnder(_GithubSpec spec, String dir) async {
    final tree = await _githubTree(spec);
    return [
      for (final p in tree)
        if (dir.isEmpty || p.startsWith('$dir/')) p
    ];
  }

  List<String>? _treeCache;
  String? _treeKey;

  Future<List<String>> _githubTree(_GithubSpec spec) async {
    final key = '${spec.owner}/${spec.repo}@${spec.ref}';
    if (_treeCache != null && _treeKey == key) return _treeCache!;
    final urls = [
      'https://api.github.com/repos/${spec.owner}/${spec.repo}/git/trees/${spec.ref}?recursive=1',
      'https://data.jsdelivr.com/v1/packages/gh/${spec.owner}/${spec.repo}@${spec.ref}',
    ];
    for (final u in urls) {
      try {
        final r = await _net.get(Uri.parse(u),
            headers: {'User-Agent': 'omni_ai', 'Accept': 'application/json'}, timeout: const Duration(seconds: 20));
        if (r.statusCode >= 400) continue;
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        final paths = _parseTree(j);
        if (paths.isNotEmpty) {
          _treeKey = key;
          _treeCache = paths;
          return paths;
        }
      } catch (_) {}
    }
    return const [];
  }

  List<String> _parseTree(Object? j) {
    if (j is Map && j['tree'] is List) {
      return [
        for (final e in j['tree'] as List)
          if (e is Map && e['type'] == 'blob') '${e['path']}',
      ];
    }
    if (j is Map && j['files'] is List) {
      return _walkJsdelivr(j['files'] as List, '');
    }
    return const [];
  }

  List<String> _walkJsdelivr(List files, String prefix) {
    final out = <String>[];
    for (final f in files) {
      if (f is! Map) continue;
      final name = '${f['name'] ?? f['path'] ?? ''}';
      if (name.isEmpty) continue;
      final path = prefix.isEmpty ? name : '$prefix/$name';
      if (f['files'] is List) {
        out.addAll(_walkJsdelivr(f['files'] as List, path));
      } else {
        out.add(path);
      }
    }
    return out;
  }

  Future<String?> _getText(String url) async {
    try {
      final r = await _net.get(Uri.parse(url), headers: {'User-Agent': 'omni_ai'}, timeout: const Duration(seconds: 20));
      if (r.statusCode >= 400 || r.bodyBytes.length > maxFileBytes) return null;
      return utf8.decode(r.bodyBytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  static String _folderName(String path) {
    final parts = path.replaceAll('\\', '/').split('/');
    if (parts.length >= 2 && parts.last.toLowerCase() == 'skill.md') return parts[parts.length - 2];
    return parts.isEmpty ? 'skill' : parts.first;
  }

  static bool _looksBinary(String path) {
    const bin = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.pdf', '.zip', '.woff', '.woff2', '.ttf', '.mp3', '.mp4', '.wasm'];
    final lower = path.toLowerCase();
    return bin.any(lower.endsWith);
  }

  // ---------------------------------------------------------------- toolkit

  @override
  String get id => 'skills';
  @override
  String get name => 'Skills';
  @override
  bool get needsApiKey => false;
  @override
  bool get isConfigured => true;
  @override
  Future<String?> verify() async => null;

  @override
  Future<String?> prompt() async {
    await load();
    if (_skills.isEmpty) {
      return 'search_skills finds skills on skills.sh. install_skill adds one from GitHub (`owner/repo` or `owner/repo@name`) or a URL. list_skills shows installed skills. load_skill reads one.';
    }
    return 'When a task matches a skill, call load_skill first and follow it.\n'
        '${_skills.values.map((s) => '- ${s.name}: ${_short(s.description)}').join('\n')}\n'
        'search_skills finds more on skills.sh.';
  }

  static String _short(String text) {
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= maxPromptDescription ? one : '${one.substring(0, maxPromptDescription)}…';
  }

  @override
  Future<List<Tool>> tools() async {
    await load();
    return [
      Tool(
        name: 'is_skill_installed',
        label: 'Checking a skill installation',
        description: 'Checks whether a named skill is installed locally.',
        parameters: Schema.object({'name': Schema.string()}, required: ['name']),
        execute: (i) async => {'name': i['name'], 'installed': await isInstalled(i['name'] as String)},
      ),
      Tool(
        name: 'preview_skill',
        label: 'Previewing a skill source',
        description: 'Lists and reads skills and their bundled text files from a GitHub source or SKILL.md URL without installing them.',
        parameters: Schema.object({'source': Schema.string(), 'skill': Schema.string()}, required: ['source']),
        execute: (i) async => {
          'skills': [for (final s in await listRemote(i['source'] as String, skill: i['skill'] as String?)) s.toJson()]
        },
      ),
      Tool(
        name: 'list_skills',
        label: 'Listing skills',
        description: 'Lists installed skills (name and description). Pass query to search.',
        parameters: Schema.object({'query': Schema.string(description: 'Optional search.')}, required: []),
        execute: (i) async {
          await load();
          final q = '${i['query'] ?? ''}'.toLowerCase().trim();
          return {
            'skills': [
              for (final s in _skills.values)
                if (q.isEmpty || '${s.name} ${s.description}'.toLowerCase().contains(q))
                  {'name': s.name, 'description': s.description, if (s.source != null) 'source': s.source, 'files': s.files.keys.toList()},
            ],
          };
        },
      ),
      Tool(
        name: 'load_skill',
        label: 'Loading a skill',
        description: 'Loads a skill\'s full instructions. Call this before following a skill.',
        parameters: Schema.object({'name': Schema.string(description: 'Installed skill name from list_skills.')}, required: ['name']),
        execute: (i) async {
          await load();
          final s = _skills[Skill.sanitizeName('${i['name']}')];
          if (s == null) return {'error': 'No skill "${i['name']}". Call list_skills.'};
          return {
            'skill': s.name,
            'instructions': s.content,
            if (s.files.isNotEmpty) 'files': s.files.keys.toList(),
          };
        },
      ),
      Tool(
        name: 'read_skill_file',
        label: 'Reading a skill file',
        description: 'Reads a reference file that belongs to an installed skill.',
        parameters: Schema.object({
          'skill': Schema.string(description: 'Installed skill name.'),
          'path': Schema.string(description: 'File path as load_skill lists it.'),
        }, required: ['skill', 'path']),
        execute: (i) async {
          await load();
          final s = _skills[Skill.sanitizeName('${i['skill']}')];
          if (s == null) return {'error': 'No skill "${i['skill']}".'};
          final path = '${i['path']}';
          return s.files[path] ?? {'error': 'No file "$path" in ${s.name}. Files: ${s.files.keys.join(', ')}'};
        },
      ),
      Tool(
        name: 'search_skills',
        label: 'Searching skills.sh',
        description:
            'Searches public skill catalogs (Skyll and skills.sh). Returns name, what it does, source, installs, and the install string for install_skill.',
        parameters: Schema.object({
          'query': Schema.string(description: 'What the skill should help with, at least 2 characters.'),
          'limit': Schema.integer(minimum: 1, maximum: 50),
        }, required: [
          'query'
        ]),
        execute: (i) async {
          final hits = await search('${i['query']}', limit: (i['limit'] as num?)?.toInt() ?? 10);
          return {
            'skills': [for (final h in hits) h.toJson()],
          };
        },
      ),
      Tool(
        name: 'install_skill',
        label: 'Installing a skill',
        description: 'Installs a skill from GitHub (`owner/repo` or `owner/repo@skill-name`) or a SKILL.md URL.',
        parameters: Schema.object({
          'source': Schema.string(description: 'owner/repo, owner/repo@name, or https URL to SKILL.md'),
          'skill': Schema.string(description: 'When the repo has several skills, the one to install.'),
        }, required: [
          'source'
        ]),
        approval: ApprovalPolicy.always,
        execute: (i) async {
          final added = await install('${i['source']}', skill: i['skill'] as String?);
          return {
            'installed': [
              for (final s in added) {'name': s.name, 'description': s.description, if (s.source != null) 'source': s.source}
            ],
          };
        },
      ),
      Tool(
        name: 'uninstall_skill',
        label: 'Removing a skill',
        description: 'Removes an installed skill by name.',
        parameters: Schema.object({'name': Schema.string(description: 'Installed skill name.')}, required: ['name']),
        approval: ApprovalPolicy.always,
        execute: (i) async {
          final name = '${i['name']}';
          final ok = await uninstall(name);
          return ok ? {'removed': Skill.sanitizeName(name)} : {'error': 'No skill "$name".'};
        },
      ),
    ];
  }
}

class _SkillChanges extends ChangeNotifier {
  void notify() => notifyListeners();
}

class _GithubSpec {
  _GithubSpec({required this.owner, required this.repo, this.ref = 'HEAD', this.path = '', this.skillHint});

  final String owner;
  final String repo;
  final String ref;
  final String path;
  final String? skillHint;

  String get display =>
      ref == 'HEAD' && path.isEmpty ? '$owner/$repo' : 'https://github.com/$owner/$repo/tree/$ref${path.isEmpty ? '' : '/$path'}';

  String rawUrl(String file) {
    final p = file.startsWith('/') ? file.substring(1) : file;
    final branch = ref == 'HEAD' ? 'HEAD' : ref;
    return 'https://raw.githubusercontent.com/$owner/$repo/$branch/$p';
  }

  /// The folder of a `raw.githubusercontent.com/OWNER/REPO/REF/PATH/SKILL.md`
  /// URL, or null for any other address.
  static _GithubSpec? fromRaw(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host != 'raw.githubusercontent.com') return null;
    final p = uri.pathSegments.where((x) => x.isNotEmpty).toList();
    if (p.length < 4 || p.last.toLowerCase() != 'skill.md') return null;
    return _GithubSpec(owner: p[0], repo: p[1], ref: p[2], path: p.sublist(3, p.length - 1).join('/'));
  }

  /// `owner/repo`, `owner/repo@skill`, github.com URLs, gitlab-style https.
  static _GithubSpec parse(String source) {
    var s = source.trim();
    if (s.startsWith('http')) {
      final uri = Uri.parse(s);
      if (!['github.com', 'www.github.com'].contains(uri.host)) {
        throw ArgumentError('Expected a GitHub URL or a direct SKILL.md URL.');
      }
    }
    String? skill;
    final at = s.lastIndexOf('@');
    if (at > 0 && !s.startsWith('http') && !s.substring(at + 1).contains('/')) {
      skill = s.substring(at + 1);
      s = s.substring(0, at);
    }
    s = s.replaceFirst(RegExp(r'^https?://(www\.)?github\.com/'), '');
    s = s.replaceFirst(RegExp(r'\.git$'), '');
    s = s.replaceFirst(RegExp(r'^/+|/+$'), '');
    // tree/REF/path
    final tree = RegExp(r'^([^/]+)/([^/]+)/tree/([^/]+)(?:/(.+))?$').firstMatch(s);
    if (tree != null) {
      return _GithubSpec(owner: tree[1]!, repo: tree[2]!, ref: tree[3]!, path: tree[4] ?? '', skillHint: skill);
    }
    final blob = RegExp(r'^([^/]+)/([^/]+)/blob/([^/]+)/(.+)$').firstMatch(s);
    if (blob != null) {
      return _GithubSpec(owner: blob[1]!, repo: blob[2]!, ref: blob[3]!, path: blob[4]!, skillHint: skill);
    }
    final parts = s.split('/');
    if (parts.length >= 2 && RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(parts[0]) && RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(parts[1])) {
      return _GithubSpec(
        owner: parts[0],
        repo: parts[1],
        path: parts.length > 2 ? parts.sublist(2).join('/') : '',
        skillHint: skill,
      );
    }
    throw AiException('Skill source "$source" is not markdown, a URL, or GitHub owner/repo.');
  }
}
