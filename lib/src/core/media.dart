import 'dart:convert';
import 'dart:typed_data';

/// Bytes a model made: an image, a clip of speech, a video.
class GeneratedFile {
  const GeneratedFile(this.bytes, {required this.mediaType, this.url});

  /// Decodes a `data:` URL.
  factory GeneratedFile.fromDataUrl(String dataUrl) {
    final comma = dataUrl.indexOf(',');
    final header = dataUrl.substring(5, comma);
    final mediaType = header.split(';').first;
    return GeneratedFile(
      base64Decode(dataUrl.substring(comma + 1)),
      mediaType: mediaType.isEmpty ? 'application/octet-stream' : mediaType,
    );
  }

  factory GeneratedFile.fromBase64(String data, {String? mediaType}) {
    final bytes = base64Decode(data);
    return GeneratedFile(bytes, mediaType: mediaType ?? sniffMediaType(bytes));
  }

  final Uint8List bytes;

  /// e.g. `image/png`, `audio/mpeg`, `video/mp4`.
  final String mediaType;

  /// Where the provider hosted it, when it said.
  final String? url;

  String get base64 => base64Encode(bytes);
  String get dataUrl => 'data:$mediaType;base64,$base64';
  bool get isImage => mediaType.startsWith('image/');
  bool get isAudio => mediaType.startsWith('audio/');
  bool get isVideo => mediaType.startsWith('video/');

  /// A file extension for [mediaType], without the dot.
  String get extension => extensionFor(mediaType);

  static String extensionFor(String mediaType) => switch (mediaType) {
        'image/png' => 'png',
        'image/jpeg' || 'image/jpg' => 'jpg',
        'image/webp' => 'webp',
        'image/gif' => 'gif',
        'audio/mpeg' || 'audio/mp3' => 'mp3',
        'audio/wav' || 'audio/x-wav' || 'audio/wave' => 'wav',
        'audio/ogg' => 'ogg',
        'audio/flac' => 'flac',
        'audio/aac' => 'aac',
        'audio/webm' => 'webm',
        'video/mp4' => 'mp4',
        'video/webm' => 'webm',
        'video/quicktime' => 'mov',
        'application/pdf' => 'pdf',
        _ => 'bin',
      };

  @override
  String toString() => 'GeneratedFile($mediaType, ${bytes.length} bytes)';
}

/// Guesses a media type from the first bytes of a file.
String sniffMediaType(Uint8List b, {String fallback = 'application/octet-stream'}) {
  bool at(int i, List<int> sig) {
    if (b.length < i + sig.length) return false;
    for (var k = 0; k < sig.length; k++) {
      if (b[i + k] != sig[k]) return false;
    }
    return true;
  }

  if (at(0, [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (at(0, [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (at(0, [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50])) return 'image/webp';
  if (at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x41, 0x56, 0x45])) return 'audio/wav';
  if (at(0, [0x4F, 0x67, 0x67, 0x53])) return 'audio/ogg';
  if (at(0, [0x66, 0x4C, 0x61, 0x43])) return 'audio/flac';
  if (at(0, [0x49, 0x44, 0x33]) || at(0, [0xFF, 0xFB]) || at(0, [0xFF, 0xF3]) || at(0, [0xFF, 0xF2])) {
    return 'audio/mpeg';
  }
  if (at(4, [0x66, 0x74, 0x79, 0x70])) {
    // ISO media: m4a is audio, the rest video.
    if (at(8, [0x4D, 0x34, 0x41])) return 'audio/mp4';
    if (at(8, [0x71, 0x74])) return 'video/quicktime';
    return 'video/mp4';
  }
  if (at(0, [0x1A, 0x45, 0xDF, 0xA3])) return 'video/webm';
  if (at(0, [0x25, 0x50, 0x44, 0x46])) return 'application/pdf';
  return fallback;
}

/// Wraps raw 16-bit little-endian PCM (what Gemini speech returns) in a WAV
/// header so any player can open it.
Uint8List pcmToWav(Uint8List pcm, {int sampleRate = 24000, int channels = 1, int bitsPerSample = 16}) {
  final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  final blockAlign = channels * bitsPerSample ~/ 8;
  final header = ByteData(44)
    ..setUint32(0, 0x52494646) // RIFF
    ..setUint32(4, 36 + pcm.length, Endian.little)
    ..setUint32(8, 0x57415645) // WAVE
    ..setUint32(12, 0x666d7420) // fmt
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, channels, Endian.little)
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, byteRate, Endian.little)
    ..setUint16(32, blockAlign, Endian.little)
    ..setUint16(34, bitsPerSample, Endian.little)
    ..setUint32(36, 0x64617461) // data
    ..setUint32(40, pcm.length, Endian.little);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...pcm]);
}
