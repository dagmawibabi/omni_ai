import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../core/media.dart';

/// Plays generated audio and voice previews. One clip at a time.
///
/// ```dart
/// final speech = await ai.generateSpeech(text: 'Hello');
/// await AiAudio.instance.play(speech);
/// ```
class AiAudio extends ChangeNotifier {
  AiAudio._();
  static final instance = AiAudio._();

  AudioPlayer? _player;
  StreamSubscription<void>? _done;
  Completer<void>? _finished;

  /// What is playing: a preview URL or a generated clip's identity.
  Object? playing;
  bool get isPlaying => playing != null;

  AudioPlayer get _p {
    final p = _player ??= AudioPlayer();
    _done ??= p.onPlayerComplete.listen((_) => _complete());
    return p;
  }

  void _complete() {
    playing = null;
    if (!(_finished?.isCompleted ?? true)) _finished!.complete();
    notifyListeners();
  }

  /// Plays [file]. With [wait], completes when it ends.
  Future<void> play(GeneratedFile file, {bool wait = false, double speed = 1}) async {
    await stop();
    playing = file;
    _finished = Completer<void>();
    notifyListeners();
    await _p.setPlaybackRate(speed);
    try {
      await _p.play(BytesSource(file.bytes, mimeType: file.mediaType));
    } catch (_) {
      // Some platforms can't play bytes; a data URL works everywhere.
      await _p.play(UrlSource(file.dataUrl));
    }
    if (wait) await _finished!.future;
  }

  /// Plays a URL (e.g. [Voice.previewUrl]). Calling again with the same
  /// URL while it plays stops it.
  Future<void> playUrl(String url, {bool toggle = true, bool wait = false}) async {
    if (toggle && playing == url) return stop();
    await stop();
    playing = url;
    _finished = Completer<void>();
    notifyListeners();
    await _p.play(UrlSource(url));
    if (wait) await _finished!.future;
  }

  Future<void> pause() async => _player?.pause();
  Future<void> resume() async => _player?.resume();

  Future<void> stop() async {
    await _player?.stop();
    _complete();
  }

  @override
  void dispose() {
    _done?.cancel();
    _player?.dispose();
    super.dispose();
  }
}
