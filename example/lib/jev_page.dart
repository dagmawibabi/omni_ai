import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:omni_ai/omni_ai.dart';

class JevPage extends StatefulWidget {
  const JevPage({super.key, required this.ai});
  final OmniAI ai;
  @override
  State<JevPage> createState() => _JevPageState();
}

class _JevPageState extends State<JevPage> {
  final _request = TextEditingController(
    text: const JsonEncoder.withIndent('  ').convert({
      'model': 'jev-latest',
      'state': 'My card was charged twice. Please refund the duplicate.',
      'questions': {
        'refund': {'type': 'boolean', 'instructions': 'Is a refund requested?'},
        'team': {
          'type': 'choice',
          'instructions': 'Which team should respond?',
          'criteria': {'billing': 'Payments and refunds', 'support': 'Technical issues'},
        },
        'severity': {
          'type': 'score',
          'instructions': 'How severe is the issue?',
          'criteria': ['Minor', 'Moderate', 'Urgent'],
        },
      },
      'assets': <String, Object?>{},
      'base_url': 'https://api.typesafe.ai',
      'headers': <String, String>{},
      'max_retries': 2,
      'timeout_seconds': 120,
      'long_context': false,
      'multipart': false,
    }),
  );
  CancelToken? _cancel;
  String? _result;

  @override
  void dispose() {
    _cancel?.cancel();
    _request.dispose();
    super.dispose();
  }

  Future<void> _decide() async {
    final token = CancelToken();
    setState(() {
      _cancel = token;
      _result = null;
    });
    try {
      final j = jsonDecode(_request.text) as Map;
      final client = JevClient(
        apiKey: widget.ai.apiKey('jev'),
        baseUrl: j['base_url'] as String? ?? 'https://api.typesafe.ai',
        headers: Map<String, String>.from(j['headers'] as Map? ?? {}),
        maxRetries: (j['max_retries'] as num?)?.toInt() ?? 2,
        timeout: Duration(seconds: (j['timeout_seconds'] as num?)?.toInt() ?? 120),
      );
      final d = await client.decide(
        state: j['state'] as Object,
        questions: {for (final e in (j['questions'] as Map).entries) '${e.key}': JevQuestion.fromJson(e.value as Map)},
        model: j['model'] as String? ?? 'jev-latest',
        images: {
          for (final e in (j['assets'] as Map? ?? {}).entries)
            '${e.key}': JevImage(
              base64Decode((e.value as Map)['data_base64'] as String),
              format: (e.value as Map)['format'] as String? ?? 'png',
            ),
        },
        longContext: j['long_context'] == true,
        multipart: j['multipart'] == true,
        idempotencyKey: j['idempotency_key'] as String?,
        cancelToken: token,
      );
      if (mounted) {
        setState(() => _result = const JsonEncoder.withIndent('  ').convert(d.toJson()));
      }
    } catch (e) {
      if (mounted) setState(() => _result = '$e');
    } finally {
      if (mounted) setState(() => _cancel = null);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text('Jev decisions', style: Theme.of(context).textTheme.headlineSmall),
      const Text(
        'Set your TypeSafe Jev key on the Keys screen. Edit state and named boolean/noul, choice, score, or box questions. Answers include probabilities and confidence.',
      ),
      const SizedBox(height: 12),
      const Text(
        'For images, add assets keyed by a unique reference: {"[photo]": {"format": "png", "data_base64": "…"}} and include that reference in state or instructions. Box questions require Jev 1.14+. Advanced fields control the endpoint, headers, retries, timeout, long context, multipart, and optional idempotency_key.',
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _request,
        enabled: _cancel == null,
        minLines: 16,
        maxLines: 28,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: const InputDecoration(labelText: 'Decision request JSON', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        children: [
          FilledButton.icon(onPressed: _cancel == null ? _decide : null, icon: const Icon(Icons.rule), label: const Text('Decide')),
          if (_cancel != null) TextButton(onPressed: () => _cancel?.cancel(), child: const Text('Cancel')),
        ],
      ),
      if (_cancel != null) const LinearProgressIndicator(),
      if (_result != null) Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: SelectableText(_result!)),
    ],
  );
}
