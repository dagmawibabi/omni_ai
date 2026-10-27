import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/messages.dart';

/// Asks the person whether a tool may run. Use it as an agent's
/// `onToolApproval`:
///
/// ```dart
/// Agent(..., onToolApproval: (call) => showToolApprovalDialog(context, call))
/// ```
Future<bool> showToolApprovalDialog(BuildContext context, ToolCallPart call, {String? title, String? message}) async {
  final pretty = const JsonEncoder.withIndent('  ').convert(call.input);
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.pan_tool_outlined),
      title: Text(title ?? 'Allow ${call.name.replaceAll('_', ' ')}?'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message ?? 'The assistant wants to run this action:'),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(pretty, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Deny')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Allow')),
      ],
    ),
  );
  return ok ?? false;
}

/// Asks the person a question for an agent's `onAskUser`.
Future<String> showAskUserDialog(BuildContext context, String question, List<String>? options) async {
  final c = TextEditingController();
  final answer = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('The assistant asks'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(question),
          const SizedBox(height: 12),
          if (options != null && options.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final o in options) ActionChip(label: Text(o), onPressed: () => Navigator.of(context).pop(o))],
            ),
          TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: 'Your answer')),
        ],
      ),
      actions: [FilledButton(onPressed: () => Navigator.of(context).pop(c.text), child: const Text('Answer'))],
    ),
  );
  c.dispose();
  return answer ?? '';
}
