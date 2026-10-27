import 'package:flutter/material.dart';

import '../device/dictation.dart';

/// A microphone button for a text field. Tap to talk, tap again to stop;
/// the words go into [controller] after what was typed.
///
/// ```dart
/// TextField(
///   controller: c,
///   decoration: InputDecoration(suffixIcon: DictationButton(controller: c)),
/// )
/// ```
class DictationButton extends StatefulWidget {
  const DictationButton({super.key, required this.controller, this.dictation, this.onDone});

  final TextEditingController controller;

  /// Defaults to the device recognizer. Pass `ai.dictation(model: …)` for
  /// a cloud model.
  final Dictation? dictation;

  /// Called with the final text when listening ends.
  final ValueChanged<String>? onDone;

  @override
  State<DictationButton> createState() => _DictationButtonState();
}

class _DictationButtonState extends State<DictationButton> {
  late Dictation _d = widget.dictation ?? Dictation();
  String _before = '';

  @override
  void didUpdateWidget(DictationButton old) {
    super.didUpdateWidget(old);
    if (widget.dictation != null && widget.dictation != _d) _d = widget.dictation!;
  }

  @override
  void dispose() {
    if (widget.dictation == null) _d.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_d.listening) return _d.stop();
    _before = widget.controller.text;
    await _d.start(onText: (words, done) {
      final text = joinDictation(_before, words);
      widget.controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
      if (done) {
        widget.onDone?.call(text);
        if (_d.error != null && mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(_d.error!)));
        }
      }
    });
    if (_d.error != null && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(_d.error!)));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _d,
        builder: (context, _) {
          final scheme = Theme.of(context).colorScheme;
          if (_d.transcribing) {
            return const Padding(
                padding: EdgeInsets.all(12), child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)));
          }
          return IconButton(
            tooltip: _d.listening ? 'Stop' : 'Dictate',
            onPressed: _toggle,
            icon: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: EdgeInsets.all(2 + 6 * _d.level),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _d.listening ? scheme.primary.withValues(alpha: 0.18) : Colors.transparent,
              ),
              child: Icon(_d.listening ? Icons.stop : Icons.mic_none, color: _d.listening ? scheme.primary : null),
            ),
          );
        },
      );
}
