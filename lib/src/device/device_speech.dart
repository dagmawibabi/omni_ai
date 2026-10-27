import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../core/models.dart';

/// Reads text aloud with the phone's or computer's own voice: free,
/// offline, instant. Wraps `flutter_tts`.
///
/// ```dart
/// await DeviceSpeech.instance.speak('Hello!');
/// ```
class DeviceSpeech extends ChangeNotifier {
  DeviceSpeech._();
  static final instance = DeviceSpeech._();

  FlutterTts? _tts;
  bool speaking = false;
  List<Voice> _voices = const [];

  FlutterTts get _engine => _tts ??= FlutterTts()
    ..setCompletionHandler(_done)
    ..setCancelHandler(_done)
    ..setErrorHandler((_) => _done());

  void _done() {
    speaking = false;
    notifyListeners();
  }

  /// Speaks [text]; completes when it has been read (or stopped).
  ///
  /// [rate] is 1 for normal speed; [voice] is a [Voice.id] from [voices].
  Future<void> speak(String text, {String? voice, double rate = 1, double pitch = 1, String? language}) async {
    final tts = _engine;
    await tts.stop();
    await tts.awaitSpeakCompletion(true);
    // Android and iOS treat 0.5 as normal speed.
    final platformRate = (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)
        ? (0.5 * rate).clamp(0.1, 1.0)
        : rate.clamp(0.1, 2.0);
    await tts.setSpeechRate(platformRate.toDouble());
    await tts.setPitch(pitch);
    if (language != null) await tts.setLanguage(language);
    if (voice != null) {
      final v = (_voices.isEmpty ? await voices() : _voices).where((v) => v.id == voice).firstOrNull;
      if (v != null) await tts.setVoice({'name': v.name, 'locale': v.language ?? ''});
    }
    speaking = true;
    notifyListeners();
    try {
      await tts.speak(text);
    } finally {
      _done();
    }
  }

  Future<void> stop() async {
    await _tts?.stop();
    _done();
  }

  Future<void> pause() async => _tts?.pause();

  /// Voices installed on this device.
  Future<List<Voice>> voices({String? language}) async {
    try {
      final raw = await _engine.getVoices;
      _voices = [
        for (final v in (raw as List? ?? const []))
          if (v is Map)
            Voice(
              id: '${v['name']}',
              name: '${v['name']}',
              provider: 'device',
              language: v['locale']?.toString(),
              gender: v['gender']?.toString(),
            ),
      ]..sort((a, b) => '${a.language}${a.name}'.compareTo('${b.language}${b.name}'));
    } catch (e) {
      debugPrint('[omni_ai] device voices unavailable: $e');
    }
    if (language == null) return _voices;
    return _voices.where((v) => v.language?.toLowerCase().startsWith(language.toLowerCase()) ?? false).toList();
  }

  /// Plain words for speaking: no markdown, links, or code blocks.
  static String clean(String text) => text
      .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
      .replaceAll(RegExp(r'[*_`#>|]'), '')
      .replaceAll(RegExp(r'^\s*[-•]\s+', multiLine: true), '')
      .replaceAll(RegExp(r'\n{2,}'), '\n')
      .trim();

  /// Splits long text into parts of about [size] characters at sentence
  /// ends, so cloud voices can start sooner and stay under limits.
  static List<String> chunk(String text, {int size = 380}) {
    final sentences = RegExp(r'[^.!?።\n]+[.!?።]*\s*|\n').allMatches(text).map((m) => m[0]!.trim()).where((s) => s.isNotEmpty);
    final out = <String>[];
    var current = StringBuffer();
    for (final s in sentences) {
      if (current.length + s.length > size && current.isNotEmpty) {
        out.add(current.toString().trim());
        current = StringBuffer();
      }
      current.write('$s ');
    }
    if (current.isNotEmpty) out.add(current.toString().trim());
    return out;
  }
}
