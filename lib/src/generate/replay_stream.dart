import 'dart:async';

/// A stream every listener can read from the start, even after events
/// have arrived. Lets `result.textStream`, `result.fullStream` and
/// `result.text` all work on one generation.
class ReplayStream<T> {
  final _events = <T>[];
  final _listeners = <StreamController<T>>{};
  Object? _error;
  StackTrace? _stack;
  bool _closed = false;

  bool get isClosed => _closed;
  List<T> get events => List.unmodifiable(_events);

  void add(T event) {
    if (_closed) return;
    _events.add(event);
    for (final l in _listeners) {
      l.add(event);
    }
  }

  void addError(Object error, [StackTrace? stack]) {
    if (_closed) return;
    _error = error;
    _stack = stack;
    for (final l in _listeners) {
      l.addError(error, stack);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final l in List.of(_listeners)) {
      l.close();
    }
    _listeners.clear();
  }

  Stream<T> get stream {
    late StreamController<T> c;
    c = StreamController<T>(
      onListen: () {
        for (final e in _events) {
          c.add(e);
        }
        if (_error != null) c.addError(_error!, _stack);
        if (_closed) {
          c.close();
        } else {
          _listeners.add(c);
        }
      },
      onCancel: () => _listeners.remove(c),
    );
    return c.stream;
  }
}
