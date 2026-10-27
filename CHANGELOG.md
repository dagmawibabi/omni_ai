## 0.4.0

Found while moving the teleai app onto omni_ai's agents.

- **Approvals can edit**: `onToolApproval` may return `ToolApprovalDecision.approve(input: …)` (run with an edited input, e.g. a message draft the user changed) or `ToolApprovalDecision.deny('why')`; bools still work.
- **`ToolContext.current`** inside a tool's `execute`: the call (id, name, input) and the cancel token. Agent hooks now get the real call id (it was empty).
- **`parallelToolCalls: false`** on `streamText`, `generateText`, `Agent` and `ai.agent()` runs a step's tools one at a time, in order.
- **`ToolOutput(modelFiles: …)`**: pictures a tool fetched for the model to look at, sent after the results as a user message.
- Tool results stream as each tool finishes, and a tool starts only after listeners have seen its call (UIs can show it running).
- **`Toolkit.where(test)`** keeps only some of a toolkit's tools (its prompt stays).
- **`AgentMemory`** is a `Listenable` with `save`, `update`, `remove` and `clear` for your own screens; `remember` and `update_memory` return the content; memories saved with a `created` date load.
- **`ai.verifyKey(id, key: …)`** checks a typed key without setting it, for settings fields.
- `ai.agent()` takes `temperature`, `providerOptions` and `parallelToolCalls`.
- **Dictation**: `onTranscribed` reports each cloud transcription with the recording's length (usage, cost). Fixed: errors and status from the device recognizer were lost when `deviceAvailable()` ran first.
- **Voices**: `VoicePicker` speaks Addis AI samples in the voice's own language (`VoicePicker.samples`), tries Addis's preview endpoint, and can stop a generated sample; `AiAudio.play(id:)`. `ElevenLabsProvider.speechModels` lists the models every account has.
- **Composio**: a new key or user id gets a new session (the old one was kept); `disconnect` uses the package's HTTP client.
- **E2B**: `E2BExecution.count` and `.text` (the cell's value, results marked `main`), `E2BSandbox.startedAt`, typed `E2BClient.sandboxes()` / `E2BSandboxInfo`, `listFiles` with paths and dates; `kill` treats a gone sandbox as stopped; a blank template uses the default.
- **Cloudflare**: `listObjects(delimiter: false)` lists everything under a prefix; objects carry their ETag.
- **Browser**: `BrowserSession.host` and `stop()`.
- `AiHttp.delete`.

## 0.3.0

- **On-device sandbox**: `DeviceSandboxToolkit` / `ai.deviceSandbox` runs Python (Pyodide) or JavaScript in a hidden web view, with input files and output files/charts. Free, no key.
- **Browser**: `BrowserToolkit` / `ai.browser`, a real browser the AI drives (open, read, type, click, back, run JS, close), with `BrowserView` / `showBrowser` to watch it live or take over. `AiChatView` shows a "Watch the browser" button.
- Both are in `ai.allToolkits` on Android, iOS and macOS. New dependency: `webview_flutter`.
- Toolkits are only offered where `isConfigured` (keyless toolkits included).

## 0.2.0

- **Agents**, modelled on eve: `Agent` / `ai.agent()` with instructions, tools, toolkits, skills (`SKILL.md`), memory, helper agents, limits, hooks, `ask_user`, and sessions you can save and restore. `agent.chat()` plugs into `AiChatView`.
- **Toolkits**: `ExaToolkit` (web search, page reading, similar pages, cited answers), `E2BToolkit` (cloud code sandbox with charts), `ComposioToolkit` (users' apps: connect, find and run actions), `CloudflareToolkit` (browser rendering, DNS, cache, Workers, KV, R2), `BasicToolkit` (time, calculator, fetch). Keys are saved like provider keys and shown in `ApiKeySettings`.
- **Toolkits on any call**: `toolkits:` on `generateText`, `streamText`, `ai.ask`, `ai.chat` and `AiChatController`; `ai.allToolkits` gives the basic tools, memory and every toolkit with a key.
- **Memory**: `AgentMemory` / `ai.memory` with teleai's tools (`remember` with tags, `update_memory`, `forget_memory`, `list_memories`), memories in the prompt as `id: content`; and `MemoryFilesToolkit` / `ai.memoryFiles`, a `memory` tool with the commands of Claude's native memory tool over `/memories` files. Both stored on the device by default, with pluggable stores.
- `CloudflareWorkersAiProvider` (`workersai:`) for Cloudflare's models.
- Tools: `ApprovalPolicy` (`never`, `always`, `once`, `when`), `ToolOutput` to hand files to the app, `label`. Calls to unknown tools now go back to the model as errors instead of stopping.
- Widgets: `showToolApprovalDialog`, `showAskUserDialog`; chat shows tools waiting for approval and helper progress.

## 0.1.0

First release.

- `OmniAI`: one object with keys and providers; model ids like `google:gemini-2.5-flash`.
- Providers: Vercel AI Gateway, Google Gemini (native), OpenRouter, LM Studio, ElevenLabs, Addis AI, any OpenAI-compatible API, and on-device speech.
- Text: `generateText`, `streamText` (text, reasoning, tool and file streams), multi-step tool loops with approval, `generateObject`, `streamObject`, `classify`.
- Media: `generateImage` (with references), `generateSpeech`, `speak`, `transcribe`, live and cloud dictation, `generateVideo`, `embed`, `embedMany`, ElevenLabs sound effects and music.
- Catalog: every provider's models merged with models.dev (prices, context, modalities, logos), cached on device.
- Widgets: `AiChatView`, `AiChatController`, `ModelPicker`, `VoicePicker` with previews, `ApiKeySettings`, `DictationButton`, `AiAudio` player.
- `UiMessageStreamClient` for Vercel AI SDK backends.
