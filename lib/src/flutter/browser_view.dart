import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../toolkits/browser.dart';
import '../toolkits/device_sandbox.dart' show webViewSupported;

/// The AI's browser, live: watch what it does, or take over (sign in,
/// solve a check it can't) and hand back. It is the same page the browser
/// tools drive.
///
/// ```dart
/// BrowserView(session: ai.browser.session)
/// ```
class BrowserView extends StatelessWidget {
  const BrowserView({super.key, required this.session, this.showBar = true, this.emptyText});

  final BrowserSession session;

  /// The address, what the AI is doing, and back / reload / close.
  final bool showBar;
  final String? emptyText;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final c = session.controller;
          final theme = Theme.of(context);
          return Column(
            children: [
              if (showBar)
                Material(
                  color: theme.colorScheme.surfaceContainer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: [
                        Icon(session.activity != null ? Icons.smart_toy_outlined : Icons.public, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(session.title?.isNotEmpty == true ? session.title! : (session.url ?? 'Browser'),
                                  maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelLarge),
                              Text(session.activity ?? session.url ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall
                                      ?.copyWith(color: session.activity != null ? theme.colorScheme.primary : null)),
                            ],
                          ),
                        ),
                        if (c != null) ...[
                          IconButton(
                            tooltip: 'Back',
                            icon: const Icon(Icons.arrow_back, size: 20),
                            onPressed: () async {
                              if (await c.canGoBack()) await c.goBack();
                            },
                          ),
                          IconButton(tooltip: 'Reload', icon: const Icon(Icons.refresh, size: 20), onPressed: session.reload),
                          IconButton(tooltip: 'Close the page', icon: const Icon(Icons.close, size: 20), onPressed: session.close),
                        ],
                      ],
                    ),
                  ),
                ),
              if (session.activity != null) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: c == null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            webViewSupported
                                ? (emptyText ??
                                    'Nothing open. Ask the AI to open a site, e.g. "open Wikipedia and summarise the Moon article".')
                                : 'The browser works on Android, iOS and macOS.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : WebViewWidget(controller: c),
              ),
            ],
          );
        },
      );
}

/// Opens the live browser full screen.
Future<void> showBrowser(BuildContext context, BrowserSession session) => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Browser')),
          body: BrowserView(session: session),
        ),
      ),
    );
