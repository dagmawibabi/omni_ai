import 'package:flutter/material.dart';

import '../omni_ai.dart';
import '../providers/provider.dart';

/// A ready-made settings section: one field per provider to paste a key,
/// with a link to get one and a check that it works. Keys are saved in
/// the secure key store.
///
/// ```dart
/// Scaffold(body: ListView(children: [ApiKeySettings(ai: ai)]))
/// ```
class ApiKeySettings extends StatelessWidget {
  const ApiKeySettings({super.key, required this.ai, this.providers, this.onOpenUrl});

  final OmniAI ai;

  /// Provider ids to show, in order. Defaults to all.
  final List<String>? providers;

  /// Opens "Get a key" links (e.g. with url_launcher). Hidden when null.
  final void Function(String url)? onOpenUrl;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: ai,
        builder: (context, _) {
          final list = providers == null ? ai.providers : [for (final id in providers!) ai.provider(id)];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final p in list) ApiKeyField(ai: ai, provider: p, onOpenUrl: onOpenUrl)],
          );
        },
      );
}

/// One provider's key field.
class ApiKeyField extends StatefulWidget {
  const ApiKeyField({super.key, required this.ai, required this.provider, this.onOpenUrl});
  final OmniAI ai;
  final AiProvider provider;
  final void Function(String url)? onOpenUrl;

  @override
  State<ApiKeyField> createState() => _ApiKeyFieldState();
}

class _ApiKeyFieldState extends State<ApiKeyField> {
  late final _c = TextEditingController(text: widget.ai.apiKey(widget.provider.id) ?? '');
  bool _hidden = true;
  bool _checking = false;
  String? _status;
  bool? _ok;

  bool get _isUrl => !widget.provider.needsApiKey;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _checking = true;
      _status = null;
      _ok = null;
    });
    await widget.ai.setApiKey(widget.provider.id, _c.text);
    if (_c.text.trim().isEmpty) {
      setState(() => _checking = false);
      return;
    }
    final err = await widget.ai.verifyKey(widget.provider.id);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _ok = err == null;
      _status = err ?? (_isUrl ? 'Connected' : 'Key works');
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(p.name, style: theme.textTheme.titleSmall)),
              if (p.apiKeyUrl != null && widget.onOpenUrl != null)
                TextButton(onPressed: () => widget.onOpenUrl!(p.apiKeyUrl!), child: Text(_isUrl ? 'Docs' : 'Get a key')),
            ],
          ),
          TextField(
            controller: _c,
            obscureText: _hidden && !_isUrl,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: _isUrl ? TextInputType.url : TextInputType.visiblePassword,
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              hintText: _isUrl ? 'http://192.168.1.20:1234' : 'Paste your ${p.name} API key',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_isUrl)
                    IconButton(
                      tooltip: _hidden ? 'Show' : 'Hide',
                      icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _hidden = !_hidden),
                    ),
                  _checking
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                      : IconButton(tooltip: 'Save and check', icon: const Icon(Icons.check), onPressed: _save),
                ],
              ),
            ),
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _status!,
                style: theme.textTheme.bodySmall?.copyWith(color: _ok == true ? Colors.green.shade700 : theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
