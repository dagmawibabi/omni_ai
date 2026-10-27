import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../core/media.dart';
import '../core/models.dart';

/// Speech to text from the microphone.
///
/// With no [model], the device's own recognizer listens live (free,
/// words appear as you speak). With a cloud [TranscriptionModel]
/// (ElevenLabs Scribe, Gemini, Addis AI…) it records, then transcribes when
/// you stop.
///
/// ```dart
/// final dictation = Dictation();
/// await dictation.start(onText: (words, done) => controller.text = words);
/// await dictation.stop();
/// ```
class Dictation extends ChangeNotifier {
  Dictation({this.model, this.language});

  /// Null: the device recognizer.
  TranscriptionModel? model;

  /// e.g. `en_US` for the device, `en` / `am` for cloud models.
  String? language;

  static final _stt = SpeechToText();
  static bool? _sttReady;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _sub;
  StreamSubscription<Amplitude>? _amp;
  final _pcm = BytesBuilder(copy: false);
  void Function(String words, bool done)? _onText;
  String _heard = '';

  bool listening = false;

  /// A recording is being sent to the cloud model.
  bool transcribing = false;

  /// Microphone loudness from 0 to 1, for a level meter.
  double level = 0;

  /// The last problem, in words.
  String? error;

  bool get busy => listening || transcribing;

  /// Whether the device recognizer works here.
  static Future<bool> deviceAvailable() async {
    try {
      return _sttReady ??= await _stt.initialize();
    } catch (_) {
      return _sttReady = false;
    }
  }

  /// Device recognizer languages, e.g. `en_US`.
  static Future<List<LocaleName>> deviceLocales() async => await deviceAvailable() ? _stt.locales() : const [];

  /// Starts listening. [onText] gets the words so far, then once more with
  /// `done: true`.
  Future<void> start({required void Function(String words, bool done) onText}) async {
    if (busy) return;
    error = null;
    _onText = onText;
    _heard = '';
    if (model == null) {
      await _startDevice();
    } else {
      await _startRecording();
    }
  }

  /// Stops listening and delivers the final words.
  Future<void> stop() async {
    if (!listening) return;
    if (_recorder != null && model != null) {
      await _finishRecording();
    } else {
      try {
        await _stt.stop();
      } catch (_) {}
      _finish();
    }
  }

  /// Stops without delivering anything.
  Future<void> cancel() async {
    _onText = null;
    await _sub?.cancel();
    await _amp?.cancel();
    await _recorder?.cancel();
    try {
      await _stt.cancel();
    } catch (_) {}
    listening = false;
    transcribing = false;
    level = 0;
    notifyListeners();
  }

  Future<void> toggle({required void Function(String words, bool done) onText}) => listening ? stop() : start(onText: onText);

  // -------------------------------------------------------------- device

  Future<void> _startDevice() async {
    try {
      _sttReady ??= await _stt.initialize(onError: _onError, onStatus: _onStatus);
    } catch (_) {
      _sttReady = false;
    }
    if (_sttReady != true) {
      error = 'Speech recognition is not available. Allow microphone access, or use a cloud transcription model.';
      notifyListeners();
      return;
    }
    listening = true;
    notifyListeners();
    try {
      await _stt.listen(
        onResult: _onResult,
        onSoundLevelChange: (db) {
          // Android reports about -2..10 dB, iOS 0..1.
          final v = db > 1 ? (db + 2) / 12 : db;
          level = v.clamp(0, 1).toDouble();
          notifyListeners();
        },
        listenOptions: SpeechListenOptions(
          partialResults: true,
          listenMode: ListenMode.dictation,
          cancelOnError: true,
          autoPunctuation: true,
          localeId: language,
          listenFor: const Duration(seconds: 60),
          pauseFor: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      error = 'Could not start listening: $e';
      _finish();
    }
  }

  void _onResult(SpeechRecognitionResult r) {
    _heard = r.recognizedWords;
    _onText?.call(_heard, false);
    if (r.finalResult) _finish();
  }

  void _onStatus(String status) {
    if ((status == SpeechToText.doneStatus || status == SpeechToText.notListeningStatus) && listening) _finish();
  }

  void _onError(SpeechRecognitionError e) {
    error = switch (e.errorMsg) {
      'error_no_match' || 'error_speech_timeout' => 'Didn\'t catch that. Try again.',
      'error_permission' || 'error_insufficient_permissions' => 'Microphone access is off.',
      'error_network' || 'error_network_timeout' || 'error_server' => 'Speech recognition needs a connection.',
      _ => 'Dictation stopped: ${e.errorMsg}',
    };
    _finish();
  }

  void _finish() {
    if (!listening && !transcribing) return;
    final cb = _onText;
    listening = false;
    transcribing = false;
    level = 0;
    _onText = null;
    notifyListeners();
    cb?.call(_heard, true);
  }

  // ----------------------------------------------------------- recording

  static const _rate = 16000;

  Future<void> _startRecording() async {
    final recorder = _recorder ??= AudioRecorder();
    if (!await recorder.hasPermission()) {
      error = 'Microphone access is off.';
      notifyListeners();
      return;
    }
    _pcm.clear();
    final stream = await recorder.startStream(const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: _rate, numChannels: 1));
    _sub = stream.listen(_pcm.add);
    _amp = recorder.onAmplitudeChanged(const Duration(milliseconds: 120)).listen((a) {
      // dBFS: about -60 (quiet) to 0 (loud).
      level = ((a.current + 50) / 50).clamp(0, 1).toDouble();
      notifyListeners();
    });
    listening = true;
    notifyListeners();
  }

  Future<void> _finishRecording() async {
    await _recorder!.stop();
    await _sub?.cancel();
    await _amp?.cancel();
    listening = false;
    transcribing = true;
    level = 0;
    notifyListeners();
    try {
      final pcm = _pcm.takeBytes();
      if (pcm.isEmpty) throw Exception('Nothing was recorded.');
      final wav = pcmToWav(pcm, sampleRate: _rate);
      final r = await model!.transcribe(TranscriptionRequest(audio: wav, mediaType: 'audio/wav', language: language));
      _heard = r.text;
    } catch (e) {
      error = 'Could not transcribe: $e';
      _heard = '';
    }
    _finish();
  }

  /// Records until [stop] and returns WAV bytes, without transcribing.
  static Future<Uint8List?> recordWav(Future<void> until) async {
    final recorder = AudioRecorder();
    try {
      if (!await recorder.hasPermission()) return null;
      final pcm = BytesBuilder(copy: false);
      final stream = await recorder.startStream(const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: _rate, numChannels: 1));
      final sub = stream.listen(pcm.add);
      await until;
      await recorder.stop();
      await sub.cancel();
      return pcmToWav(pcm.takeBytes(), sampleRate: _rate);
    } finally {
      await recorder.dispose();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _amp?.cancel();
    _recorder?.dispose();
    super.dispose();
  }
}

/// Puts dictated words after what was already typed.
String joinDictation(String typed, String spoken) {
  final a = typed.trimRight();
  final b = spoken.trim();
  if (a.isEmpty) return b;
  if (b.isEmpty) return a;
  return '$a $b';
}
