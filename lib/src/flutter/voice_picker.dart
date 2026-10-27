import 'package:flutter/material.dart';

import '../catalog/model_info.dart';
import '../core/models.dart';
import '../device/device_speech.dart';
import '../omni_ai.dart';
import 'audio.dart';

/// Opens a sheet of voices with play-to-preview, and returns the pick.
///
/// [source] is a speech model id (`elevenlabs:eleven_v3`), a provider id
/// (`google`, `addis`) or `device`.
Future<Voice?> showVoicePicker(BuildContext context, {required OmniAI ai, required String source, String? selected, String? language}) =>
    showModalBottomSheet<Voice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.85,
        child: VoicePicker(ai: ai, source: source, selected: selected, language: language, onSelected: (v) => Navigator.of(context).pop(v)),
      ),
    );

/// A list of voices. Tap play to hear a sample: the provider's preview
/// clip when it has one, or a short line spoken with [sampleText].
class VoicePicker extends StatefulWidget {
  const VoicePicker({
    super.key,
    required this.ai,
    required this.source,
    required this.onSelected,
    this.selected,
    this.language,
    this.sampleText = 'Hello! This is how I sound.',
  });

  final OmniAI ai;
  final String source;
  final String? selected;
  final String? language;
  /// What a voice without a preview clip says, unless [samples] has a
  /// line in the voice's language.
  final String sampleText;
  final ValueChanged<Voice> onSelected;

  /// Sample lines by language, for voices that don't speak English (Addis
  /// AI's Amharic, Afaan Oromo and Tigrinya voices).
  static const samples = {
    'am': 'ሰላም! ይህ ድምጼ ነው። ዛሬ በምን ልርዳዎት?',
    'om': "Akkam jirta! Sagaleen koo kana fakkaata. Har'a maal si gargaaruu danda'a?",
    'ti': 'ሰላም! ድምጸይ ከምዚ እዩ። ሎሚ ብምንታይ ክሕግዘካ?',
  };

  @override
  State<VoicePicker> createState() => _VoicePickerState();
}

class _VoicePickerState extends State<VoicePicker> {
  late Future<List<Voice>> _voices = widget.ai.listVoices(widget.source, language: widget.language);
  final _search = TextEditingController();
  String? _loadingSample;

  @override
  void dispose() {
    _search.dispose();
    AiAudio.instance.stop();
    super.dispose();
  }

  Future<void> _preview(Voice v) async {
    final audio = AiAudio.instance;
    if (v.provider == 'device') {
      await DeviceSpeech.instance.speak(widget.sampleText, voice: v.id);
      return;
    }
    if (audio.playing == v.id || (v.previewUrl != null && audio.playing == v.previewUrl)) return audio.stop();
    if (v.previewUrl != null) {
      await audio.playUrl(v.previewUrl!);
      return;
    }
    setState(() => _loadingSample = v.id);
    try {
      // Addis keeps some samples apart from its voice list.
      final url = v.provider == 'addis' ? await widget.ai.addis.voicePreviewUrl(v.id) : null;
      if (url != null && url.isNotEmpty) {
        await audio.playUrl(url);
        return;
      }
      final model = widget.ai.providers.any((p) => p.id == widget.source) ? null : widget.source;
      final clip = await widget.ai.generateSpeech(
        text: VoicePicker.samples[v.language] ?? widget.sampleText,
        model: model ?? '${v.provider}:${widget.ai.provider(v.provider).defaultModels[ModelType.speech]}',
        voice: v.id,
      );
      await audio.play(clip, id: v.id);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _loadingSample = null);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                  hintText: 'Search voices', prefixIcon: Icon(Icons.search), border: OutlineInputBorder(), isDense: true),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Voice>>(
              future: _voices,
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Padding(padding: const EdgeInsets.all(16), child: Text('${snap.error}', textAlign: TextAlign.center)),
                      TextButton(
                        onPressed: () => setState(() => _voices = widget.ai.listVoices(widget.source, language: widget.language)),
                        child: const Text('Try again'),
                      ),
                    ]),
                  );
                }
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final q = _search.text.toLowerCase();
                final voices = snap.data!.where((v) => q.isEmpty || '${v.name} ${v.traits}'.toLowerCase().contains(q)).toList();
                if (voices.isEmpty) return const Center(child: Text('No voices.'));
                return ListenableBuilder(
                  listenable: AiAudio.instance,
                  builder: (context, _) => ListView.builder(
                    itemCount: voices.length,
                    itemBuilder: (context, i) {
                      final v = voices[i];
                      final now = AiAudio.instance.playing;
                      final playing = now != null && (now == v.id || now == v.previewUrl);
                      return ListTile(
                        selected: v.id == widget.selected,
                        title: Text(v.name),
                        subtitle: v.traits.isEmpty ? null : Text(v.traits, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => widget.onSelected(v),
                        trailing: _loadingSample == v.id
                            ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
                            : IconButton(
                                tooltip: playing ? 'Stop' : 'Preview',
                                icon: Icon(playing ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                                onPressed: () => _preview(v),
                              ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      );
}
