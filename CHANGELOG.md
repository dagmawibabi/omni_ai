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
