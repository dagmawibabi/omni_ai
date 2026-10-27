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
  Skill({required this.name, required this.description, required this.content, this.deferred = false, this.files = const {}})
      : assert(RegExp(r'^[A-Za-z0-9][A-Za-z0-9_\-]{0,63}$').hasMatch(name), 'Skill names use letters, digits, _ and -.');

  /// Reads a `SKILL.md` (with `---` frontmatter) or plain markdown. Without
  /// a description, the first line of the body is used.
  factory Skill.parse(String name, String markdown, {Map<String, String> files = const {}}) {
    var body = markdown.trim();
    final meta = <String, String>{};
    if (body.startsWith('---')) {
      final end = body.indexOf('\n---', 3);
      if (end > 0) {
        for (final line in body.substring(3, end).split('\n')) {
          final colon = line.indexOf(':');
          if (colon > 0) {
            meta[line.substring(0, colon).trim()] = line.substring(colon + 1).trim().replaceAll(RegExp(r'''^["']|["']$'''), '');
          }
        }
        body = body.substring(end + 4).trim();
      }
    }
    final firstLine = body.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => name).replaceAll(RegExp(r'^#+\s*'), '');
    return Skill(
      name: meta['name'] ?? name,
      description: meta['description'] ?? firstLine,
      content: body,
      deferred: meta['deferred'] == 'true',
      files: files,
    );
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
}
