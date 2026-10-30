# omni_ai

**One easy Flutter API for every AI provider.** Chat, stream, call tools, build agents, make images, speech, video and embeddings, list models with prices, pick voices with previews, and dictate — with the same few calls, whichever provider you use.

| Provider | Chat & tools | Images | Speech | Dictation | Video | Embeddings | Model list |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **Vercel AI Gateway** (`gateway`) — hundreds of models, one key | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ with prices |
| **Google Gemini** (`google`) | ✅ | ✅ | ✅ 30 voices | ✅ | ✅ | ✅ | ✅ |
| **OpenRouter** (`openrouter`) — free models too | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ with prices |
| **LM Studio** (`lmstudio`) — local, private, free | ✅ | | | | | ✅ | ✅ loaded/unloaded |
| **ElevenLabs** (`elevenlabs`) | | | ✅ + streaming | ✅ Scribe | | | ✅ voices with previews |
| **Addis AI** (`addis`) — Amharic, Afaan Oromo, Tigrinya | ✅ | | ✅ | ✅ | | | ✅ voices |
| **This device** (`device`) — offline, free | | | ✅ | ✅ live | | | ✅ voices |
| **Cloudflare Workers AI** (`workersai`) — open models on Cloudflare | ✅ | | | | | ✅ | ✅ |
| **Any OpenAI-compatible API** (OpenAI, Groq, Ollama, Together…) | ✅ | ✅ | ✅ | ✅ | | ✅ | ✅ |

Plus:

- An **[agent builder](#agents)** (modelled on [eve](https://eve.dev)) with skills, memory, helper agents, approvals, limits and hooks.
- Ready-made **[toolkits](#toolkits)** for agents *and* plain calls: **Exa** web search, **E2B** cloud sandboxes, an **[on-device sandbox](#on-device-sandbox)** (Python and JavaScript, free), a **[browser you can watch live](#browser)**, **Composio** apps (Gmail, Slack, GitHub, Calendar…), **Cloudflare** (a real browser, DNS, Workers, KV, R2), **[TypeSafe Jev](#jev)** decisions, **[MCP servers](#mcp)** (install, list, use), basic tools, and **[two kinds of memory](#memory)** (teleai-style facts, and a file memory in the format of Claude's native memory tool).
- **[Skills](#skills)** you can **search** on skills.sh, **install** (GitHub `owner/repo`, a SKILL.md URL, or markdown), **list**, and **use** (`load_skill`), the way the AI SDK and `npx skills add` do.
- **[models.dev](https://models.dev)** metadata for every model (prices, context, modalities, release dates, logos).
- Ready-made **widgets**: chat screen, model picker, voice picker with previews, API key settings (providers and toolkits), dictation button, tool approval and question dialogs, a live browser view, and **[ExtensionsView](#search-and-management-ui)** for searching and managing skills and MCP servers.
- A client for **Vercel AI SDK backends** (`useChat` for Flutter).

The API follows the [Vercel AI SDK](https://ai-sdk.dev): `generateText`, `streamText`, tools with multi-step loops, `generateObject`, `generateImage`, `generateSpeech`, `transcribe`, `embed`.

---

## Install

```bash
flutter pub add omni_ai
```

<details>
<summary><b>Platform setup</b> (microphone, speech, network)</summary>

**Android** — `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<queries>
  <intent><action android:name="android.speech.RecognitionService"/></intent>
  <intent><action android:name="android.intent.action.TTS_SERVICE"/></intent>
</queries>
```

**iOS** — `ios/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key><string>Dictation uses the microphone.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Dictation turns your speech into text.</string>
```

**macOS** — the two keys above in `macos/Runner/Info.plist`, and in both `*.entitlements`:

```xml
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.device.audio-input</key><true/>
```

Only needed if you use dictation or the device voice. The on-device sandbox and browser use the system web view (`webview_flutter`) on Android, iOS and macOS and need no setup; on other platforms they are left out of `ai.allToolkits`. Everything else is plain HTTPS.
</details>

## Quick start

```dart
import 'package:omni_ai/omni_ai.dart';

final ai = OmniAI(googleKey: 'AIza...');           // or gatewayKey:, openRouterKey:, ...

final answer = await ai.ask('Why is the sky blue?');
print(answer);
```

Stream it into your UI:

```dart
final result = ai.streamText(model: 'google:gemini-2.5-flash', prompt: 'Write a haiku about Flutter');

StreamBuilder<String>(
  stream: result.accumulatedText,                  // the text so far
  builder: (context, snap) => Text(snap.data ?? ''),
);
```

A whole chat screen, with streaming, tools, thinking and dictation, in one line:

```dart
Scaffold(body: AiChatView(controller: ai.chat(model: 'gateway:anthropic/claude-sonnet-4.5')));
```

An agent that searches the web, runs code, remembers you and asks before acting:

```dart
final agent = ai.agent(
  instructions: 'You are a careful research assistant.',
  onToolApproval: (call) => showToolApprovalDialog(context, call),
);
Scaffold(body: AiChatView(controller: agent.chat()));
```

## Model ids

Every call takes a `model` string: **`provider:model`**.

```dart
'gateway:openai/gpt-5'              // Vercel AI Gateway (also the default: 'openai/gpt-5' works)
'google:gemini-2.5-flash'           // Google AI Studio
'openrouter:meta-llama/llama-3.3-70b-instruct:free'
'lmstudio:qwen/qwen3-8b'            // a model loaded in LM Studio
'elevenlabs:eleven_v3'              // speech
'addis:addis-chat'                  // Amharic / Afaan Oromo chat
'workersai:@cf/meta/llama-3.3-70b-instruct-fp8-fast'   // after ai.register(CloudflareWorkersAiProvider(...))
```

Leave `model` out and omni_ai uses `ai.defaultModels[type]`, or the default of the first provider you set up a key for.

## API keys

Pass keys in code, or let people paste them in your app. Keys set with `setApiKey` are stored in the platform keychain (`flutter_secure_storage`) and loaded on the next launch. Provider ids and toolkit ids work the same way.

```dart
final ai = OmniAI(gatewayKey: '...', exaKey: '...', e2bKey: '...', composioKey: 'ak_...', cloudflareToken: '...', jevKey: 'ts_...');

await ai.setApiKey('elevenlabs', 'sk_...');
await ai.setApiKey('exa', '...');                  // toolkits too: exa, e2b, composio, cloudflare
final problem = await ai.verifyKey('exa');         // null = works
```

Drop-in settings section (a field per provider and toolkit, show/hide, check button, "Get a key" link):

```dart
ListView(children: [ApiKeySettings(ai: ai, onOpenUrl: (url) => launchUrlString(url))]);
```

> **Security:** a key inside a shipped app can be extracted. For apps you publish, keep keys on your server — e.g. build your backend with the Vercel AI SDK and talk to it with [`UiMessageStreamClient`](#vercel-ai-sdk-backends-usechat-for-flutter) — or let each user bring their own key.

Where to get keys: [Vercel AI Gateway](https://vercel.com/ai-gateway) · [Google AI Studio](https://aistudio.google.com/apikey) · [OpenRouter](https://openrouter.ai/settings/keys) · [ElevenLabs](https://elevenlabs.io/app/settings/api-keys) · [Addis AI](https://platform.addisassistant.com) · [Exa](https://dashboard.exa.ai/api-keys) · [E2B](https://e2b.dev/dashboard?tab=keys) · [Composio](https://platform.composio.dev) · [Cloudflare](https://dash.cloudflare.com/profile/api-tokens) · [TypeSafe Jev](https://console.typesafe.ai). LM Studio, memory, skill installation, and public catalog search need no key. Individual MCP servers may require credentials supplied through headers or environment values.

## Text

```dart
// The answer only
final text = await ai.ask('Summarize this', model: 'google:gemini-2.5-flash');

// Everything: text, reasoning, usage, steps, finish reason
final r = await ai.generateText(
  model: 'gateway:openai/gpt-5',
  system: 'You are terse.',
  prompt: 'Explain recursion',
  temperature: 0.7,
  maxOutputTokens: 500,
);
print('${r.text}\n${r.usage}');                     // Usage(in: 21, out: 87, $0.0009)

// Multi-turn
final r2 = await ai.generateText(messages: [
  Message.user('My name is Abebe.'),
  Message.assistant('Nice to meet you, Abebe!'),
  Message.user('What is my name?'),
]);
```

### Streaming

```dart
final s = ai.streamText(prompt: 'Tell me a story');

await for (final words in s.textStream) { /* append */ }

// Or every event: text, thinking, tool calls, tool results, images, steps
await for (final part in s.fullStream) {
  switch (part) {
    case TextDelta(:final text):       print(text);
    case ReasoningDelta(:final text):  print('[thinking] $text');
    case ToolCall(:final call):        print('calling ${call.name}');
    case ToolResult(:final result):    print('got ${result.output}');
    case FileOutput(:final file):      showImage(file.bytes);
    case Finish(:final usage):         print(usage);
    default:
  }
}

final full = await s.result;                        // also available after streaming
```

Any of `textStream`, `fullStream`, `accumulatedText`, `text`, `result` can be read, in any order, as many times as you like.

### Thinking

```dart
final r = await ai.generateText(prompt: 'Hard puzzle…', reasoning: ReasoningEffort.high);
print(r.reasoning);                                 // what it thought
// ReasoningEffort.none turns thinking off where the model allows it.
```

### Images, PDFs and audio as input

```dart
await ai.generateText(
  model: 'google:gemini-2.5-flash',
  prompt: 'What is in this photo?',
  files: [FilePart.image(bytes)],                   // also FilePart.pdf(), FilePart.audio(), FilePart.imageUrl()
);
```

### Cancel

```dart
final token = CancelToken();
final s = ai.streamText(prompt: 'Long essay', cancelToken: token);
token.cancel();                                     // stops the request; works on every call
```

## Tools

Give the model functions. omni_ai runs them and sends the results back until the model answers (up to `maxSteps`, default 12 when tools or toolkits are given).

```dart
final weather = Tool(
  name: 'get_weather',
  description: 'Current weather for a city',
  parameters: Schema.object({
    'city': Schema.string(description: 'City name'),
    'unit': Schema.enumOf(['celsius', 'fahrenheit']),
  }, required: ['city']),
  execute: (input) async => {'city': input['city'], 'temp': 22, 'sky': 'sunny'},
);

final r = await ai.generateText(
  model: 'gateway:openai/gpt-5-mini',
  prompt: 'Should I bring an umbrella in Addis Ababa?',
  tools: [weather],
  onStepFinish: (step) => print('step ${step.stepNumber}: ${step.toolCalls}'),
);
print(r.text);
```

- **Ask first** — `Tool(approval: ApprovalPolicy.always, ...)` (or `.once`, or `ApprovalPolicy.when((input) => ...)`) and `onToolApproval: (call) => showToolApprovalDialog(context, call)`.
- **Edit before running** — `onToolApproval` may return `ToolApprovalDecision.approve(input: {...})` to run with changed input (an edited message draft), or `ToolApprovalDecision.deny('why')` to tell the model why; `true` / `false` still work.
- **Hand files to the app** — return `ToolOutput(value, files: [...])`; the files arrive as `FileOutput` parts and show in the chat.
- **Show the model a picture** — `ToolOutput(value, modelFiles: [FilePart.image(bytes)])` (a screenshot, a photo a tool fetched); tool results can't carry images, so they follow as a user message.
- **Know which call is running** — `ToolContext.current` inside `execute` has the `call` (its id, for per-call progress) and the `cancelToken`.
- **One at a time** — `parallelToolCalls: false` runs a step's tools in order instead of together (shared rate limits, approvals asked one by one).
- **Run tools yourself** — leave out `execute`; the loop stops and the calls are in `r.toolCalls`. Send results back with `Message.toolResults([...])`.
- **Force a tool** — `toolChoice: ToolChoice.tool('get_weather')`, or `ToolChoice.required` / `.none`.
- **Stop early** — `stopWhen: (step) => step.toolCalls.any((c) => c.name == 'finish')`.
- **Keep the conversation** — add `r.responseMessages` to your history.
- Errors thrown by `execute`, refused approvals, and calls to tools that don't exist go back to the model as `{error: ...}` so it can recover.
- Tools that need approval are refused when no `onToolApproval` is given.

Works the same on the Gateway, OpenRouter, Google (native function calling, thought signatures handled), LM Studio and any OpenAI-compatible API.

### Toolkits on any call

Every [toolkit](#toolkits) (web search, code sandbox, apps, Cloudflare, memory) works on plain calls and chats too, not only agents:

```dart
await ai.ask('What changed in the latest Flutter release?', toolkits: [ai.exa]);

ai.generateText(prompt: 'Plot y = x² from -5 to 5', toolkits: [ai.e2b]);   // the chart arrives as a FileOutput

ai.chat(model: 'google:gemini-2.5-flash', toolkits: ai.allToolkits);       // basic tools + memory + every toolkit with a key
```

## Agents

An agent is instructions + a model + tools, run in a loop until the job is done. The design follows [eve](https://eve.dev): typed tools with approval policies, skills loaded on demand, memory, and helper agents the agent can delegate to.

```dart
final agent = ai.agent(
  instructions: 'You are a research assistant. Cite every source.',
  model: 'gateway:anthropic/claude-sonnet-4.5',
  // Without `toolkits:`, it gets ai.allToolkits: basic tools, memory, and every toolkit you set a key for.
  toolkits: [BasicToolkit(), ai.exa, ai.e2b],
  onToolApproval: (call) => showToolApprovalDialog(context, call),
);

print(await agent.ask('Compare the three most popular Flutter state libraries, with a chart of pub.dev likes.'));
```

Put it on screen — streaming, tool activity, approvals and helper progress included:

```dart
Scaffold(body: AiChatView(controller: agent.chat()));
```

Or stream it yourself:

```dart
final session = agent.session();                    // keeps history, "once" approvals and helper threads
final run = session.send('Find this week’s Flutter news');
await for (final part in run.fullStream) {
  switch (part) {
    case TextDelta(:final text):              print(text);
    case ToolCall(:final call):               print('→ ${call.name}');
    case ToolApprovalRequest(:final call):    print('waiting for OK: ${call.name}');
    case SubagentUpdate(:final agent, :final part): print('[$agent] $part');
    case FileOutput(:final file):             showImage(file.bytes);   // e.g. a chart from the sandbox
    default:
  }
}
final saved = session.toJson();                     // restore with AgentSession.fromJson(agent, saved)
```

More on runs and sessions:

```dart
final run = agent.run('One-off task');              // no history
run.cancel();                                       // stop it
final r = await run.result;                         // text, steps, tool calls, usage

session.respond();                                  // answer again on the history as it stands
session.submitToolResults([...]);                   // continue after tools without `execute` that you ran yourself
print(session.usage);                               // tokens and cost over the whole session
await agent.dispose();                              // shut down sandboxes the toolkits opened
```

You can also build an `Agent` directly, without `OmniAI`, from a typed model: `Agent(name: 'a', languageModel: GoogleProvider(apiKey: '...').languageModel('gemini-2.5-flash'), toolkits: [...])`.

### Toolkits

Set keys once (`ai.setApiKey('exa', ...)`, or the `ApiKeySettings` widget, which now lists toolkits too):

| Toolkit | Tools the agent gets | Key |
|---|---|---|
| `BasicToolkit()` | `current_time`, `calculate`, `fetch_url` | none |
| `ai.memory` / `AgentMemory` | `remember`, `update_memory`, `forget_memory`, `list_memories` | none |
| `ai.memoryFiles` / `MemoryFilesToolkit` | `memory` (view/create/str_replace/insert/delete/rename under /memories) | none |
| `ai.deviceSandbox` / `DeviceSandboxToolkit` | `run_code_on_device` (Python via Pyodide with numpy, pandas, matplotlib…; JavaScript), files in and out | none (Android, iOS, macOS) |
| `ai.browser` / `BrowserToolkit` | `browser_open`, `browser_read`, `browser_type`, `browser_click`, `browser_back`, `browser_run_js`, `browser_close` — watch it live with `BrowserView` | none (Android, iOS, macOS) |
| `ai.exa` / `ExaToolkit` | `web_search` (categories, domains, dates), `read_pages`, `find_similar_pages`, `web_answer` (with citations) | [Exa](https://dashboard.exa.ai/api-keys) |
| `ai.e2b` / `E2BToolkit` | `run_code` (Python, JS, bash, R, Java; charts come back as images), `run_command`, `sandbox_write_file`, `sandbox_read_file`, `sandbox_list_files` — one sandbox kept alive per toolkit | [E2B](https://e2b.dev/dashboard?tab=keys) |
| `ai.composio` / `ComposioToolkit` | `list_connected_apps`, `connect_app` (sign-in link), `find_app_actions`, `run_app_action`, plus any actions you name (`actions: ['GMAIL_SEND_EMAIL']`) as typed tools | [Composio](https://platform.composio.dev) project key (`ak_…`) |
| `ai.cloudflare` / `CloudflareToolkit` | `browse_page` (real browser → Markdown), `screenshot_page`, zones, DNS read/write, cache purge, Workers, KV, R2 files and share links, and a raw `cloudflare_api` call | [API token](https://dash.cloudflare.com/profile/api-tokens) |
| `ai.jev` / `JevToolkit` | `jev_decide`, `jev_noul`, `jev_choice`, `jev_score`, `jev_box`, `jev_models` — typed decisions with probabilities | [TypeSafe](https://console.typesafe.ai) |
| `ai.mcp` / `McpRegistry` | Search the official MCP Registry, then `mcp_search` / `mcp_install_catalog` / `mcp_list_servers` / `mcp_call_tool` plus each server's tools | catalog needs no key; server credentials vary; stdio needs a local runtime |
| `ai.skills` / `SkillRegistry` | Search skills.sh, then `search_skills`, `list_skills`, `load_skill`, `install_skill`, `uninstall_skill`, `read_skill_file` | none |

```dart
ai.composio.userId = currentUser.id;                // whose Gmail/Slack the agent uses
ComposioToolkit(apiKey: '...', apps: ['gmail', 'googlecalendar'], onConnectLink: (app, url) => launchUrlString(url));

await ai.setCloudflareAccount(accountId: '...', r2: R2Credentials(accountId: '...', accessKeyId: '...', secretAccessKey: '...'));
E2BToolkit(apiKey: '...', approval: ApprovalPolicy.once);   // ask before the first run in a session
```

Changes are guarded by default: Cloudflare writes and Composio actions that send, create or delete ask for approval (reads don't). Without an `onToolApproval`, guarded tools are refused and the model is told so. Call `agent.dispose()` to shut down the E2B sandbox.

Write your own toolkit by extending `Toolkit`, and register it with `ai.registerToolkit(...)` so its key is saved and shown in `ApiKeySettings`:

```dart
class WeatherToolkit extends Toolkit {
  WeatherToolkit({this.apiKey});
  String? apiKey;

  @override String get id => 'weather';
  @override String get name => 'Weather';
  @override bool get isConfigured => apiKey != null;
  @override String get instructions => 'Use get_weather for weather questions.';
  @override Future<String?> verify() async => null;

  @override
  Future<List<Tool>> tools() async => [
    Tool(name: 'get_weather', description: 'Weather for a city', parameters: Schema.object({'city': Schema.string()}),
        execute: (i) => fetchWeather(i['city'], apiKey!)),
  ];
}
```
 Cloudflare's models are also available as a provider: `ai.register(CloudflareWorkersAiProvider(token: ..., accountId: ...))`, then `model: 'workersai:@cf/meta/llama-3.3-70b-instruct-fp8-fast'`.

### On-device sandbox

`ai.deviceSandbox` runs code on the phone itself, in a hidden page cut off from your app: JavaScript straight away, Python through [Pyodide](https://pyodide.org) (downloaded once, about 10 MB, then cached), with numpy, pandas, matplotlib, pillow and more loaded from the code's imports. Free, private, no key. It works like teleai's `run_code`.

```dart
ai.deviceSandbox.addFile('sales.csv', csvBytes);    // the model can pass it to the code by name
await ai.ask('Chart monthly totals from sales.csv', toolkits: [ai.deviceSandbox]);
// Python writes outputs to out/ (plt.savefig('out/chart.png')); they arrive as FileOutput parts.
```

Use `ai.e2b` instead for heavy work, network access, other languages or `pip install` of anything.

### Browser

`ai.browser` is a real browser the AI drives: one web view that runs pages' JavaScript, so it can use sites that are apps (search boxes, forms, logins). It reads a page as text plus numbered elements, then clicks and types by number. Clicking, submitting and scripts ask for approval by default (`BrowserToolkit(actionApproval: ApprovalPolicy.never)` to change it).

Watch it live, and take over when it needs you (to sign in or solve a check), then hand back:

```dart
BrowserView(session: ai.browser.session)            // address, what the AI is doing, back / reload / close
await showBrowser(context, ai.browser.session);     // the same, full screen
```

`AiChatView` adds a **Watch the browser** button to any reply that used browser tools.

### Skills

Procedures the agent loads only when a task calls for them — their names and descriptions sit in the prompt, the body is read with `load_skill`. That is the AI SDK agent-skills pattern (progressive disclosure). `Skill.parse` reads the `SKILL.md` format:

```dart
skills: [
  Skill(name: 'release_notes', description: 'Use when asked for release notes.', content: '1. List merged PRs…'),
  Skill.parse('data_analysis', await rootBundle.loadString('assets/skills/data_analysis/SKILL.md')),
]
```

Install, list and use skills at runtime (GitHub `owner/repo` like `npx skills add`, a SKILL.md URL, or markdown):

```dart
await ai.skills.install('owner/repo@pdf-processing');   // or a https://…/SKILL.md URL
print(await ai.skills.list());                          // name + description
final agent = ai.agent(skills: ai.skills.use());        // installed skills; load_skill reads the body
await ai.skills.uninstall('pdf-processing');
```

Search the public [skills.sh](https://skills.sh) catalog (the same API as `npx skills find`, no key):

```dart
final hits = await ai.skills.search('react native');    // SkillHit: name, source, installs
await ai.skills.installHit(hits.first);                 // fetches SKILL.md from GitHub
```

`ai.skills` is also a toolkit: `search_skills`, `preview_skill`, `list_skills`, `is_skill_installed`, `load_skill`, `read_skill_file`, `install_skill`, and `uninstall_skill`. Installation and removal ask for approval. The same resolved tool list can install a skill, check it, load instructions or references, and remove it during one agent run. Skills are saved on the device and picked up by agents on this `OmniAI`.

GitHub folder URLs and `owner/repo@skill` select only matching skills. YAML frontmatter supports folded and multiline descriptions; bundled text references and scripts are available through `read_skill_file`. Installation stores instructions and files; script execution requires a sandbox toolkit supplied by the host app. Binary assets and provider-hosted skill uploads are not included.

### Jev

[TypeSafe Jev](https://docs.typesafe.ai) is a decision model, not a chat model. You send **state** plus typed **questions**; it returns noul (yes/no probability), choice, score or box answers with calibrated probabilities — the same contract as the Vercel AI SDK `experimental_decide`.

```dart
final ai = OmniAI(jevKey: 'ts_…');                      // https://console.typesafe.ai

final d = await ai.decide(
  state: 'I was charged twice. Please refund the extra charge.',
  questions: {
    'billing': JevQuestion.noul('Is this about billing?'),
    'team': JevQuestion.choice('Which team?', {'billing': 'Payments', 'other': 'Anything else'}),
    'urgency': JevQuestion.score('How urgent?', ['Can wait', 'This week', 'Today']),
  },
);
if (d['billing']!.isTrue(0.8)) routeToBilling();        // your code keeps the threshold

// One-shot helpers
final angry = await ai.jev.client.noul(message, 'Is the customer angry?');
```

Full control on the client: pin `jev-1.14.0`, custom `baseUrl` / headers, image assets, `longContext` (262k), `idempotencyKey`, retries on 429/5xx, multipart image upload. Agent tools: `jev_decide` (several questions at once), `jev_noul`, `jev_choice`, `jev_score`, `jev_box`, `jev_models`.

`JevQuestion.boolean` aliases `noul`. Instructions and criteria can contain structured JSON; choices take 1–255 options, scores take 2–10 ordered levels. Box questions require an image and Jev 1.14+. Set `ai.jev.images` to make app-supplied images available to agent decision/box tools. `JevClient` accepts an origin or a base ending in `/v1`, configurable `timeout` / `maxRetries`, and cancellation tokens. This integration calls TypeSafe directly or a TypeSafe-compatible proxy.

```dart
ai.agent(toolkits: [ai.jev]);                           // or allToolkits once the key is set
```

### MCP

Connect to [Model Context Protocol](https://modelcontextprotocol.io) servers the way the AI SDK `createMCPClient` does, then **install**, **list** and **use** them.

```dart
// One-off client (HTTP is the portable default)
final mcp = await createMcpClient(McpServer.http(
  'linear',
  url: 'https://mcp.linear.app/mcp',
  headers: {'Authorization': 'Bearer …'},
));
final tools = await mcp.tools();                        // omni_ai Tool list
await ai.generateText(prompt: 'List my issues', tools: tools);
await mcp.close();

// Install on the device, list, use with agents
await ai.mcp.install(McpServer.http('linear', url: 'https://mcp.linear.app/mcp', headers: {'Authorization': 'Bearer …'}));
await ai.mcp.install(McpServer.stdio('github', command: 'npx', args: ['-y', '@modelcontextprotocol/server-github'])); // desktop
print(await ai.mcp.list());
ai.agent(toolkits: await ai.mcp.toolkits());            // or ai.mcp.asToolkit() for every server at once
await ai.mcp.uninstall('linear');
```

Search the [official MCP Registry](https://registry.modelcontextprotocol.io) (no key; query at least 3 characters):

```dart
final hits = await ai.mcp.search('filesystem');         // McpCatalogHit: name, description, remote or npm/pypi
await ai.mcp.installHit(hits.first);                    // HTTP remote, or stdio `npx -y …` on desktop
await ai.mcp.installFromCatalog('io.github.user/weather');
```

HTTP and legacy SSE are available across platforms, subject to server CORS rules on web. Stdio needs a platform that allows spawning processes and an installed runtime (`npx` / `uvx`); use remote HTTP on mobile and web. Saving a stdio configuration does not download packages: the runtime resolves them when connecting. Catalog configurations retain package versions, arguments, environment defaults, and remote headers. Replace `{placeholders}` and supply required credentials before connecting.

The client supports stateless MCP `2026-07-28` discovery and falls back to legacy initialization. For servers requiring initialization first, use `McpServer(id: 'legacy', url: 'https://example.com/mcp', protocolVersionDiscovery: false)`. It also lists resources and prompts (`listResources`, `readResource`, `listPrompts`, `getPrompt`). OAuth login, elicitation, sampling, and subscriptions are not implemented; supply authorization headers explicitly.

MCP agent tools support the whole lifecycle on demand:

- `mcp_search`: find catalog entries; `mcp_list_servers` and `mcp_is_installed`: check saved installations without connecting.
- `mcp_install_catalog`: install a registry entry with optional headers/environment; `mcp_install`: save explicit HTTP/SSE/stdio configuration; `mcp_uninstall`: remove configuration and close its client. These changes require approval.
- `mcp_list_tools`: connect and inspect tool names, descriptions, and input schemas; `mcp_call_tool`: invoke one, including immediately after installation in the same run. Tool invocation requires approval.
- `mcp_list_resources`, `mcp_read_resource`, `mcp_list_prompts`, `mcp_get_prompt`: discover and use server resources and prompt templates.

For hosts with their own tool permissions, `await ai.mcp.managementTools()` returns these tools without eagerly connecting to servers. Supply them explicitly with `ai.agent(tools: tools, toolkits: [], useInstalledSkills: false)`, alongside the allowed skill/Jev tools. `useInstalledSkills: false` prevents automatic skill tools from bypassing the host's tool switches; explicit `skills:` are still supported.

`ai.mcp.asToolkit()` also connects on demand by default. Use `asToolkit(includeServerTools: true)` or `await ai.mcp.tools()` to eagerly resolve individual server tools when that is useful.

MCP configurations, including headers and environment values, use the device's secure key store by default (`McpRegistry(store: myKeyStore)` overrides it). Existing configurations in preferences migrate on load. Skills use preferences. Both registries support `persist: false`.

### Search and management UI

```dart
Scaffold(body: ExtensionsView(ai: ai));
```

`ExtensionsView` searches skills.sh and the official MCP Registry, previews skills and their files, edits MCP configuration JSON, lists installed capabilities, connects to inspect server tools, and removes installations. The example app exposes this under **Extensions**, plus a **Jev** request playground with model, question, image, transport, and retry controls. Open the navigation drawer to switch screens; set the TypeSafe key under **Keys**. Chat and Agent use installed capabilities through `ai.allToolkits`.

Hosts can use `ExtensionsView(ai: ai, mcp: true)` or `mcp: false` in their own MCP/Skills tabs, and supply `toolsSettings` and `installedHint` to embed their permission controls and instructions.

Manual remote setup has fields for server id, transport, endpoint URL, and an optional Authorization header (`Bearer <API key>`). A URL without a scheme uses HTTPS. Advanced JSON remains available for stdio commands, other headers, and protocol options. If a server redirects, the connection error shows the final endpoint to save; authorization is never automatically forwarded to a different host.

Implementation references: [AI SDK TypeSafe decisions](https://ai-sdk.dev/providers/ai-sdk-providers/typesafe-ai), [TypeSafe HTTP API](https://docs.typesafe.ai/api/system-one), [AI SDK MCP](https://ai-sdk.dev/docs/ai-sdk-core/mcp-tools), [AI SDK Agent Skills](https://ai-sdk.dev/cookbook/guides/agent-skills), [MCP Registry API](https://github.com/modelcontextprotocol/registry/blob/main/docs/reference/api/openapi.yaml), and the [skills CLI search source](https://github.com/vercel-labs/skills/blob/main/src/find.ts). Skill search uses the CLI's public `/api/search` endpoint, distinct from skills.sh's authenticated `/api/v1` API; a custom `catalogUrl` can point to your proxy if needed.

### Memory

Two kinds, both on the device by default and both usable by agents, chats and plain calls:

**Facts** (`ai.memory` / `AgentMemory`), the way teleai does it: every memory is in the prompt as `id: content`, and the AI keeps them with `remember` (content + tags), `update_memory`, `forget_memory` and `list_memories`. Nothing is saved unless it decides to.

```dart
ai.memory.scope = currentUser.id;                   // whose memories
ai.chat(toolkits: [ai.memory]);                     // or agent(memory: AgentMemory(scope: ..., store: MyDbStore()))
final remembered = await ai.memory.all();           // for a "what I remember" screen
```

**Files** (`ai.memoryFiles` / `MemoryFilesToolkit`): one `memory` tool with the commands of Claude's native memory tool — `view`, `create`, `str_replace`, `insert`, `delete`, `rename` — over files under `/memories`. The AI reads them when it needs them, so it suits longer notes (project progress, decisions). Claude models know this tool well; other models use it like any tool. Paths outside `/memories` are refused.

```dart
final agent = ai.agent(toolkits: [...ai.allToolkits, ai.memoryFiles]);
```

Store either anywhere by implementing `MemoryStore` / `MemoryFileStore`. `ai.memory` is a `Listenable`: screens can `addListener` and edit with `save`, `update` and `remove`.

Give an agent only some of a toolkit's tools with `where`, e.g. the ones your user turned on: `toolkits: [ai.memory.where((t) => enabled.contains(t.name))]`.

### Helper agents

```dart
final researcher = ai.agent(name: 'researcher', description: 'Researches a question on the web.', toolkits: [ai.exa]);
final coder = ai.agent(name: 'coder', description: 'Writes and runs code to answer data questions.', toolkits: [ai.e2b]);
final lead = ai.agent(name: 'lead', instructions: 'Plan, delegate, then write the final answer.', subagents: [researcher, coder]);
```

Each helper becomes a tool (`agent_researcher`) that takes a self-contained `message` and returns its answer plus a `task_id` to continue that thread. Its progress streams into the parent as `SubagentUpdate` parts.

### Limits, hooks and questions

```dart
limits: const AgentLimits(maxSteps: 25, maxTokens: 200000, maxCostUsd: 1.5, timeout: Duration(minutes: 5), maxHistoryMessages: 60),
hooks: AgentHooks(
  beforeToolCall: (call) => cache[call.name],       // return a value to skip the tool
  afterToolCall: (call, result) => null,            // or a replacement result
),
onAskUser: (question, options) => showAskUserDialog(context, question, options),   // adds an ask_user tool
```

## Structured output

```dart
final r = await ai.generateObject(
  schema: Schema.object({
    'name': Schema.string(),
    'ingredients': Schema.array(Schema.string()),
    'minutes': Schema.integer(),
  }),
  prompt: 'A quick Ethiopian breakfast recipe',
  fromJson: Recipe.fromJson,                        // optional
);
print(r.object.name);

// Watch it fill in
await for (final partial in ai.streamObject(schema: schema, prompt: '...')) {
  setState(() => recipe = partial);                 // {'name': 'Fit', 'ingredients': ['bre…
}

// Classify
final mood = await ai.classify('I love this!', ['positive', 'neutral', 'negative']);
```

## Images

```dart
final r = await ai.generateImage(
  model: 'google:gemini-3.1-flash-image',           // or 'gateway:openai/gpt-image-1', 'openrouter:…'
  prompt: 'A watercolor fox reading under a tree',
  aspectRatio: '16:9',
  n: 2,
);
Image.memory(r.image.bytes);

// Edit, or use references
await ai.generateImage(prompt: 'Make it night time', referenceImages: [photoBytes]);
```

Chat models can also draw mid-conversation: `ai.streamText(..., outputImages: true)` emits `FileOutput` parts.

## Speech

```dart
// Bytes (mp3/wav) you can save or play
final audio = await ai.generateSpeech(
  model: 'elevenlabs:eleven_v3',
  text: 'Hello there!',
  voice: '21m00Tcm4TlvDq8ikWAM',
  instructions: 'excited',                          // style, where the model supports it
);
await AiAudio.instance.play(audio);

// Or just say it: long text is split, cloud voice falls back to the device voice
await ai.speak('Welcome back!', model: 'google:gemini-3.8-flash-tts', voice: 'Kore');
await ai.speak('Offline and free', model: 'device');
await ai.stopSpeaking();
```

### Voices with previews

```dart
final voices = await ai.listVoices('elevenlabs');     // or 'google', 'addis', 'device', 'gateway:openai/gpt-4o-mini-tts'
await AiAudio.instance.playUrl(voices.first.previewUrl!);

// Or a ready-made picker: search, play-to-preview, returns the choice
final v = await showVoicePicker(context, ai: ai, source: 'elevenlabs:eleven_flash_v2_5');
```

### ElevenLabs extras

```dart
ai.elevenLabs.streamSpeech(text: longText, voice: voiceId);       // Stream<Uint8List>, starts sooner
await ai.generateSoundEffect('door creaking open in a storm');
await ai.generateMusic('lo-fi beat for studying', length: Duration(seconds: 45));
await ai.elevenLabs.subscription();                                // characters left
```

### Addis AI (Amharic, Afaan Oromo, Tigrinya)

```dart
ai.addis.language = 'am';
await ai.ask('ሰላም! ስለ ኢትዮጵያ ንገረኝ', model: 'addis:addis-chat');
final voices = await ai.listVoices('addis', language: 'am');
await ai.speak('እንኳን ደህና መጣህ', model: 'addis:voices-2', voice: voices.first.id);
```

**Batches.** Up to 10,000 clips in one go: they run off-peak, finish within 24 hours and cost half the list price (2.5 ETB a generated minute), and only finished requests are billed. The account needs at least one paid top-up.

```dart
final batch = await ai.addis.batches.createFromRequests(
  [
    for (final (i, text) in chapters.indexed)
      AddisBatchRequest(customId: 'chapter-${i + 1}', text: text, voiceId: 'ti-berhane', language: 'ti'),
  ],
  metadata: {'project': 'audiobook'},
);
saveForLater(batch.id); // a batch outlives the app; waitFor and results pick it up by id

final done = await ai.addis.batches.waitFor(
  batch.id,
  onProgress: (b) => print('${b.counts.finished}/${b.counts.total}'),
);
await for (final result in ai.addis.batches.results(done.id)) {
  if (result.isSucceeded) {
    final clip = await ai.addis.batches.audio(result); // GeneratedFile
    save(result.customId, clip.bytes);
  } else {
    print('${result.customId}: ${result.error}');
  }
}
```

Also `batches.retrieve`, `list`, `cancel` (queued requests stop; running ones finish and are billed), `requests` (each request's state while the batch runs), and `create` for a JSONL file you uploaded with `files.upload` (up to 100 MB). `files` also has `retrieve`, `delete`, `contentUrl` and `content`. Downloads read Addis's signed link so your API key never reaches the storage host; browsers can't do that, so on web fetch batch files from your server.

## Dictation (speech to text)

```dart
// A mic button for any TextField: device recognizer, live words, free
TextField(controller: c, decoration: InputDecoration(suffixIcon: DictationButton(controller: c)));

// Cloud transcription instead (records, then transcribes on stop)
DictationButton(controller: c, dictation: ai.dictation(model: 'elevenlabs:scribe_v1'));

// Or drive it yourself
final d = ai.dictation();                           // device; ai.dictation(model: 'google:gemini-2.5-flash') for cloud
await d.start(onText: (words, done) => print(words));
await d.stop();

// Transcribe a file
final t = await ai.transcribe(model: 'addis:stt-v2', audio: wavBytes, language: 'am');
print(t.text);
```

## Video

```dart
final video = await ai.generateVideo(
  model: 'gateway:google/veo-3.1-fast-generate-001',  // or 'google:gemini-omni-1.1-flash', 'openrouter:…'
  prompt: 'A paper boat drifting down a rainy street',
  duration: 4,
  aspectRatio: '16:9',
  resolution: '720p',
  onStatus: print,                                  // Queued… Rendering…
);
await File('boat.${video.extension}').writeAsBytes(video.bytes);
```

## Embeddings

```dart
final a = await ai.embed('cat', model: 'gateway:openai/text-embedding-3-small');
final b = await ai.embed('kitten', model: 'gateway:openai/text-embedding-3-small');
print(cosineSimilarity(a, b));                      // 0.8…

final many = await ai.embedMany(documents, model: 'google:gemini-embedding-001');
```

## Models, prices and pickers

```dart
await ai.catalog.load();                            // every provider you use + models.dev, cached 3 days

final chatModels  = ai.catalog.ofType(ModelType.text);
final cheapVision = ai.catalog.search('', type: ModelType.text).where((m) => m.vision && (m.inputPrice ?? 9) < 1);

final m = ai.catalog.byId('gateway:openai/gpt-5')!;
print('${m.name} · ${m.priceLabel} per 1M · ${m.contextLabel} context · thinks: ${m.reasoning}');
print(m.logoUrl);                                   // lab logo from models.dev

// A searchable bottom sheet with logos, prices, context sizes and badges
final picked = await showModelPicker(context, ai: ai, type: ModelType.image);
```

`ModelInfo` has: name, lab, description, types, context window, max output, prices (input/output/cache/image), input & output modalities, reasoning, tool calling, structured output, open weights, release date, knowledge cutoff, voices, and for LM Studio whether it's loaded.

Direct lists without the cache: `await ai.listModels(provider: 'openrouter', type: ModelType.image)`. Raw models.dev: `await ModelsDev.fetch()`.

## LM Studio (local models)

1. In LM Studio: **Developer → Start server**. To use it from a phone, turn on **Serve on Local Network**.
2. Point omni_ai at it:

```dart
final ai = OmniAI(lmStudioUrl: '192.168.1.20:1234');      // or ai.setApiKey('lmstudio', '...')
print(await ai.lmStudio.isReachable());
final models = await ai.listModels(provider: 'lmstudio'); // shows which are loaded
await ai.ask('Hello', model: 'lmstudio:qwen/qwen3-8b');
```

## More providers

Anything that speaks the OpenAI Chat Completions API:

```dart
ai.register(OpenAICompatibleProvider(id: 'openai', name: 'OpenAI', baseUrl: 'https://api.openai.com/v1', apiKey: '...'));
ai.register(OpenAICompatibleProvider(id: 'groq',   name: 'Groq',   baseUrl: 'https://api.groq.com/openai/v1', apiKey: '...'));
ai.register(OpenAICompatibleProvider(id: 'ollama', name: 'Ollama', baseUrl: 'http://localhost:11434/v1'));

await ai.ask('Hi', model: 'groq:llama-3.3-70b-versatile');
```

Or subclass `AiProvider` for a different API.

## Vercel AI SDK backends (`useChat` for Flutter)

If your server uses the AI SDK (`streamText(...).toUIMessageStreamResponse()`), talk to it directly — keys stay on the server:

```dart
final client = UiMessageStreamClient(Uri.parse('https://my.app/api/chat'), headers: {'Authorization': 'Bearer $session'});

await for (final message in client.send([UiMessage.user('Hi')], onData: (part) => print(part.type))) {
  setState(() => reply = message);                  // text, reasoning, tool parts with state, sources, files, data-* parts
}
```

## Errors, usage and cost

```dart
try {
  await ai.ask('Hi', model: 'gateway:openai/gpt-5');
} on MissingApiKeyException {
  // show the keys screen
} on AiException catch (e) {
  print('${e.provider} ${e.statusCode}: ${e.message}');   // readable message from any provider
  if (e.isAuthError) ...; if (e.isRateLimited) ...;
}

final r = await ai.generateText(prompt: '...');
print(r.usage.inputTokens + r.usage.outputTokens);
print(r.usage.cost ?? ai.estimateCost('gateway:openai/gpt-5', r.usage));   // reported, or from catalog prices
```

## Lower level: AI SDK-style functions

`OmniAI` is a convenience. Every feature is also a plain function that takes a typed model, mirroring the Vercel AI SDK:

```dart
final google = GoogleProvider(apiKey: '...');

final r = await generateText(model: google.languageModel('gemini-2.5-flash'), prompt: 'Hi');
final s = streamText(model: google.languageModel('gemini-2.5-pro'), messages: [...], tools: [...], maxSteps: 5);
final o = await generateObject(model: ..., schema: ..., prompt: ...);
final i = await generateImage(model: google.imageModel('gemini-3.1-flash-image'), prompt: '...');
final a = await generateSpeech(model: ElevenLabsProvider(apiKey: '...').speechModel('eleven_v3'), text: '...');
final t = await transcribe(model: ..., audio: bytes);
final v = await generateVideo(model: ..., prompt: '...');
final e = await embedMany(model: ..., values: [...]);
```

| Vercel AI SDK | omni_ai |
|---|---|
| `generateText`, `streamText` | same, plus `ai.ask` |
| `result.textStream`, `fullStream` | same, plus `accumulatedText` |
| `tool({ inputSchema, execute })` | `Tool(parameters: Schema..., execute:)` |
| `stopWhen: stepCountIs(n)` | `maxSteps: n`, `stopWhen:` |
| `generateObject`, `streamObject` | same |
| `experimental_generateImage`, `generateSpeech`, `transcribe` | `generateImage`, `generateSpeech`, `transcribe` |
| `embed`, `embedMany`, `cosineSimilarity` | same |
| `useChat` | `AiChatController` / `AiChatView`, or `UiMessageStreamClient` for AI SDK servers |
| `AbortSignal` | `CancelToken` |
| `tool({ needsApproval })` | `Tool(approval: ApprovalPolicy.always / .once / .when(...))` |
| `Agent` | `Agent` / `ai.agent()` (plus eve-style skills, memory, helper agents, limits, hooks) |

## Example app

[`example/`](example) has a chat with tools and every toolkit you add a key for, an agent (with a skill, memory and a research helper), a live view of the AI's browser, images, voices with previews and dictation, video, and a keys screen for providers and toolkits:

```bash
cd example && flutter run
```

## License

MIT
