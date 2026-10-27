import 'dart:async';

/// Stops a request in flight. Pass one to any call, then call [cancel].
///
/// ```dart
/// final token = CancelToken();
/// final result = ai.streamText(model: 'google:gemini-2.5-flash', prompt: 'Hi', cancelToken: token);
/// token.cancel(); // stops the stream
/// ```
class CancelToken {
  final _completer = Completer<void>();
  final _listeners = <void Function()>[];

  bool get isCancelled => _completer.isCompleted;

  /// Completes when [cancel] is called.
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (_completer.isCompleted) return;
    _completer.complete();
    for (final l in List.of(_listeners)) {
      try {
        l();
      } catch (_) {}
    }
    _listeners.clear();
  }

  /// Runs [listener] on cancel (at once if already cancelled). Returns a
  /// function that removes it.
  void Function() onCancel(void Function() listener) {
    if (isCancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}
