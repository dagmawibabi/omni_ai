import 'dart:convert';

import 'package:flutter/material.dart';

import '../toolkits/browser.dart';
import 'browser_view.dart';
import 'chat_controller.dart';
import 'dictation_button.dart';

/// A complete chat screen body: messages (with thinking, tool calls and
/// generated images) and an input box with dictation. Style it with your
/// theme, or build your own from [AiChatController].
///
/// ```dart
/// Scaffold(body: AiChatView(controller: ai.chat(model: 'google:gemini-2.5-flash')))
/// ```
class AiChatView extends StatefulWidget {
  const AiChatView({
    super.key,
    required this.controller,
    this.hint = 'Message',
    this.emptyState,
    this.showReasoning = true,
    this.showTools = true,
    this.browser,
  });

  final AiChatController controller;
  final String hint;
  final Widget? emptyState;
  final bool showReasoning;
  final bool showTools;

  /// The browser a "Watch" button opens when the AI uses browser tools.
  /// Defaults to `controller.ai.browser.session`.
  final BrowserSession? browser;

  @override
  State<AiChatView> createState() => _AiChatViewState();
}

class _AiChatViewState extends State<AiChatView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_follow);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_follow);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _follow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _send() {
    final t = _input.text;
    if (t.trim().isEmpty) return;
    _input.clear();
    widget.controller.send(t);
  }

  @override
  Widget build(BuildContext context) {
    final chat = widget.controller;
    return ListenableBuilder(
      listenable: chat,
      builder: (context, _) => Column(
        children: [
          Expanded(
            child: chat.messages.isEmpty
                ? (widget.emptyState ?? const Center(child: Text('Ask anything')))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: chat.messages.length,
                    itemBuilder: (context, i) => _Bubble(
                      message: chat.messages[i],
                      showReasoning: widget.showReasoning,
                      showTools: widget.showTools,
                      onRetry: i == chat.messages.length - 1 && !chat.messages[i].isUser ? chat.regenerate : null,
                      onWatchBrowser: chat.messages[i].tools.any((t) => t.name.startsWith('browser_'))
                          ? () => showBrowser(context, widget.browser ?? chat.ai.browser.session)
                          : null,
                    ),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: widget.hint,
                        border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                        isDense: true,
                        suffixIcon: DictationButton(controller: _input),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: chat.isStreaming ? 'Stop' : 'Send',
                    onPressed: chat.isStreaming ? chat.stop : _send,
                    icon: Icon(chat.isStreaming ? Icons.stop : Icons.arrow_upward),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.showReasoning, required this.showTools, this.onRetry, this.onWatchBrowser});
  final ChatMessage message;
  final bool showReasoning;
  final bool showTools;
  final VoidCallback? onRetry;
  final VoidCallback? onWatchBrowser;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final user = message.isUser;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.85),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: user ? scheme.primaryContainer : scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final f in message.files.where((f) => f.isImage && f.bytes != null))
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(f.bytes!, height: 160)),
                ),
              if (showReasoning && message.reasoning.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(message.streaming && message.text.isEmpty ? 'Thinking…' : 'Thoughts', style: theme.textTheme.labelMedium),
                  children: [Text(message.reasoning, style: theme.textTheme.bodySmall)],
                ),
              if (showTools)
                for (final t in message.tools)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    dense: true,
                    leading: t.awaitingApproval
                        ? const Icon(Icons.pan_tool_outlined, size: 18)
                        : t.done
                            ? Icon(t.isError ? Icons.error_outline : Icons.check_circle_outline, size: 18)
                            : const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    title: Text(t.awaitingApproval ? '${t.name} · waiting for your OK' : t.name, style: theme.textTheme.labelMedium),
                    subtitle: t.progress.isEmpty || t.done
                        ? null
                        : Text(t.progress, maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                    children: [
                      SelectableText(
                        'Input: ${const JsonEncoder.withIndent('  ').convert(t.input ?? {})}'
                        '${t.done ? '\nOutput: ${t.output is String ? t.output : const JsonEncoder.withIndent('  ').convert(t.output)}' : ''}',
                        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                      ),
                    ],
                  ),
              if (message.text.isNotEmpty) SelectableText(message.text),
              if (message.streaming && message.text.isEmpty && message.reasoning.isEmpty && message.tools.isEmpty)
                const SizedBox(width: 24, child: LinearProgressIndicator()),
              for (final g in message.generated.where((g) => g.isImage))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(g.bytes)),
                ),
              if (onWatchBrowser != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                      onPressed: onWatchBrowser, icon: const Icon(Icons.public, size: 18), label: const Text('Watch the browser')),
                ),
              if (message.error != null) ...[
                Text(message.error!, style: TextStyle(color: scheme.error)),
                if (onRetry != null) TextButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Retry')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
