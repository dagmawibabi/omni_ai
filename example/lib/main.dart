import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:omni_ai/omni_ai.dart';

/// One OmniAI for the whole app. Keys typed on the Keys tab are saved in
/// the device keychain and loaded on the next launch.
final ai = OmniAI(appName: 'omni_ai example');

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'omni_ai',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark, useMaterial3: true),
    home: const Home(),
  );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _tab = 0;

  static const _pages = <(String, IconData, Widget)>[
    ('Chat', Icons.chat_bubble_outline, ChatPage()),
    ('Agent', Icons.smart_toy_outlined, AgentPage()),
    ('Images', Icons.image_outlined, ImagePage()),
    ('Voice', Icons.record_voice_over_outlined, VoicePage()),
    ('Video', Icons.movie_outlined, VideoPage()),
    ('Keys', Icons.key_outlined, KeysPage()),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_pages[_tab].$1)),
    body: IndexedStack(index: _tab, children: [for (final p in _pages) p.$3]),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: (i) => setState(() => _tab = i),
      destinations: [for (final p in _pages) NavigationDestination(icon: Icon(p.$2), label: p.$1)],
    ),
  );
}

/// A button showing the picked model; tap to choose another.
class ModelButton extends StatelessWidget {
  const ModelButton({super.key, required this.type, required this.value, required this.onChanged});
  final ModelType type;
  final String? value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    icon: const Icon(Icons.auto_awesome, size: 18),
    label: Text(value ?? 'Default ${type.label.toLowerCase()} model', overflow: TextOverflow.ellipsis),
    onPressed: () async {
      final m = await showModelPicker(context, ai: ai, type: type, selected: value);
      if (m != null) onChanged(m.id);
    },
  );
}

// ---------------------------------------------------------------- agent

/// An agent with every toolkit you've added a key for (Exa web search, an
/// E2B sandbox, Composio apps, Cloudflare), a skill, memory and a helper.
class AgentPage extends StatefulWidget {
  const AgentPage({super.key});
  @override
  State<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends State<AgentPage> {
  AiChatController? _chat;
  String? _model;

  AiChatController _build() {
    final researcher = ai.agent(
      name: 'researcher',
      description: 'Researches a question on the web and reports findings with sources.',
      instructions: 'You research thoroughly and cite every source URL.',
      model: _model,
      toolkits: [BasicToolkit(), if (ai.exa.isConfigured) ai.exa],
    );
    final agent = ai.agent(
      name: 'assistant',
      instructions:
          'You are a capable assistant. Plan, use your tools, and check your work. '
          'Ask before doing anything you cannot undo.',
      model: _model,
      skills: [
        Skill(
          name: 'data_analysis',
          description: 'Use when the user gives data to analyze or asks for a chart.',
          content:
              '1. Load the data in the sandbox with pandas.\n2. Summarize it (shape, columns, key stats).\n'
              '3. Make one clear matplotlib chart and plt.show().\n4. Explain what it shows in three sentences.',
        ),
      ],
      memory: AgentMemory(scope: 'example-user'),
      subagents: [researcher],
      onToolApproval: (call) => showToolApprovalDialog(context, call),
      onAskUser: (q, options) => showAskUserDialog(context, q, options),
      limits: const AgentLimits(maxSteps: 20, maxCostUsd: 0.5),
    );
    return agent.chat();
  }

  @override
  Widget build(BuildContext context) {
    final chat = _chat ??= _build();
    final kits = [for (final t in ai.configuredToolkits) t.name];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: ModelButton(
                  type: ModelType.text,
                  value: _model,
                  onChanged: (m) => setState(() {
                    _model = m;
                    _chat = null;
                  }),
                ),
              ),
              IconButton(tooltip: 'New agent chat', onPressed: () => setState(() => _chat = null), icon: const Icon(Icons.refresh)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            kits.isEmpty
                ? 'Add Exa, E2B, Composio or Cloudflare keys on the Keys tab to give the agent more tools.'
                : 'Toolkits: ${kits.join(', ')}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: AiChatView(
            key: ObjectKey(chat),
            controller: chat,
            emptyState: const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Try "Research the latest Flutter release and chart its download growth", or "Remember that I prefer short answers".',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- chat

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late final chat = ai.chat(
    system: 'You are a helpful assistant. Use tools when they help.',
    tools: [
      Tool(name: 'get_time', description: 'The current date and time on this device.', execute: (_) => DateTime.now().toIso8601String()),
      Tool(
        name: 'roll_dice',
        description: 'Rolls dice.',
        parameters: Schema.object({'sides': Schema.integer(minimum: 2), 'count': Schema.integer(minimum: 1)}),
        execute: (i) => [
          for (var k = 0; k < (i['count'] as num).toInt(); k++) 1 + (DateTime.now().microsecond * (k + 7)) % (i['sides'] as num).toInt(),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    // Every toolkit with a key (web search, sandbox, apps, Cloudflare) plus
    // memory, picked up again whenever this rebuilds.
    chat.toolkits = ai.allToolkits;
    return _body();
  }

  Widget _body() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: ModelButton(type: ModelType.text, value: chat.model, onChanged: (m) => setState(() => chat.model = m)),
            ),
            IconButton(tooltip: 'New chat', onPressed: chat.clear, icon: const Icon(Icons.add_comment_outlined)),
          ],
        ),
      ),
      Expanded(
        child: AiChatView(
          controller: chat,
          emptyState: const Center(child: Text('Ask anything. Try "roll two dice", "remember I like jazz", or a web question.')),
        ),
      ),
    ],
  );
}

// --------------------------------------------------------------- images

class ImagePage extends StatefulWidget {
  const ImagePage({super.key});
  @override
  State<ImagePage> createState() => _ImagePageState();
}

class _ImagePageState extends State<ImagePage> {
  final _prompt = TextEditingController(text: 'A watercolor fox reading a book under a tree');
  String? _model;
  String _aspect = '1:1';
  Uint8List? _image;
  String? _error;
  bool _busy = false;

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ai.generateImage(model: _model, prompt: _prompt.text, aspectRatio: _aspect);
      setState(() => _image = r.image.bytes);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      ModelButton(type: ModelType.image, value: _model, onChanged: (m) => setState(() => _model = m)),
      const SizedBox(height: 12),
      TextField(
        controller: _prompt,
        maxLines: 3,
        decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Prompt'),
      ),
      const SizedBox(height: 12),
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: '1:1', label: Text('Square')),
          ButtonSegment(value: '16:9', label: Text('Wide')),
          ButtonSegment(value: '9:16', label: Text('Tall')),
        ],
        selected: {_aspect},
        onSelectionChanged: (s) => setState(() => _aspect = s.first),
      ),
      const SizedBox(height: 12),
      FilledButton(onPressed: _busy ? null : _go, child: Text(_busy ? 'Painting…' : 'Generate')),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(_error!, style: const TextStyle(color: Colors.red)),
        ),
      if (_image != null)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(_image!)),
        ),
    ],
  );
}

// ---------------------------------------------------------------- voice

class VoicePage extends StatefulWidget {
  const VoicePage({super.key});
  @override
  State<VoicePage> createState() => _VoicePageState();
}

class _VoicePageState extends State<VoicePage> {
  final _text = TextEditingController(text: 'Hello! I can read anything you write, in many voices.');
  String _source = 'device';
  String? _model;
  Voice? _voice;
  String? _status;

  static const _sources = {
    'device': 'This device',
    'elevenlabs': 'ElevenLabs',
    'google': 'Gemini',
    'gateway': 'AI Gateway',
    'addis': 'Addis AI',
  };

  Future<void> _speak() async {
    setState(() => _status = 'Speaking…');
    try {
      await ai.speak(_text.text, model: _source == 'device' ? 'device' : _model, voice: _voice?.id);
      setState(() => _status = null);
    } catch (e) {
      setState(() => _status = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      DropdownButtonFormField<String>(
        initialValue: _source,
        decoration: const InputDecoration(labelText: 'Voice engine', border: OutlineInputBorder()),
        items: [for (final e in _sources.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
        onChanged: (v) => setState(() {
          _source = v!;
          _voice = null;
          _model = v == 'device' ? null : '$v:${ai.provider(v).defaultModels[ModelType.speech]}';
        }),
      ),
      const SizedBox(height: 12),
      if (_source != 'device') ...[
        ModelButton(type: ModelType.speech, value: _model, onChanged: (m) => setState(() => _model = m)),
        const SizedBox(height: 12),
      ],
      OutlinedButton.icon(
        icon: const Icon(Icons.graphic_eq),
        label: Text(_voice == null ? 'Pick a voice' : 'Voice: ${_voice!.name}'),
        onPressed: () async {
          final v = await showVoicePicker(
            context,
            ai: ai,
            source: _source == 'device' ? 'device' : (_model ?? _source),
            selected: _voice?.id,
          );
          if (v != null) setState(() => _voice = v);
        },
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _text,
        maxLines: 4,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          labelText: 'Text (or dictate)',
          suffixIcon: DictationButton(controller: _text),
        ),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: FilledButton.icon(onPressed: _speak, icon: const Icon(Icons.play_arrow), label: const Text('Speak')),
          ),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: ai.stopSpeaking, child: const Text('Stop')),
        ],
      ),
      if (_status != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_status!)),
    ],
  );
}

// ---------------------------------------------------------------- video

class VideoPage extends StatefulWidget {
  const VideoPage({super.key});
  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  final _prompt = TextEditingController(text: 'A paper boat drifting down a rainy street, cinematic');
  String? _model;
  String? _status;
  GeneratedFile? _video;
  CancelToken? _cancel;

  Future<void> _go() async {
    final token = _cancel = CancelToken();
    setState(() {
      _status = 'Starting…';
      _video = null;
    });
    try {
      final v = await ai.generateVideo(
        model: _model,
        prompt: _prompt.text,
        duration: 4,
        aspectRatio: '16:9',
        onStatus: (s) => setState(() => _status = s),
        cancelToken: token,
      );
      setState(() {
        _video = v;
        _status = 'Done: ${(v.bytes.length / 1e6).toStringAsFixed(1)} MB ${v.mediaType}. Save it or play it with a video player.';
      });
    } catch (e) {
      setState(() => _status = '$e');
    } finally {
      _cancel = null;
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      ModelButton(type: ModelType.video, value: _model, onChanged: (m) => setState(() => _model = m)),
      const SizedBox(height: 12),
      TextField(
        controller: _prompt,
        maxLines: 3,
        decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Prompt'),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: FilledButton(onPressed: _cancel == null ? _go : null, child: const Text('Generate video')),
          ),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: _cancel?.cancel, child: const Text('Cancel')),
        ],
      ),
      if (_status != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_status!)),
      if (_video != null)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Icon(Icons.check_circle, color: Colors.green),
        ),
    ],
  );
}

// ----------------------------------------------------------------- keys

class KeysPage extends StatelessWidget {
  const KeysPage({super.key});

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.symmetric(vertical: 8),
    children: [
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Text('Paste a key for any provider or toolkit you use. Keys stay on this device.'),
      ),
      ApiKeySettings(ai: ai),
    ],
  );
}
