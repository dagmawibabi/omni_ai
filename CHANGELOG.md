## 0.6.1

- Fixed: calling `ModelCatalog.load()` when the catalog was already fresh left it marked as loading for good, so `isLoading` stayed true and every later `load` and `refresh()` did nothing, including the refresh that follows `setApiKey`. A newly added key's models then never appeared until the app restarted.
- Fixed: `refresh()` during a load now does fetch again when that load ends. 0.6.0 listed this but still returned the same load.
- Raised the minimum `speech_to_text` to 7.4.0 and `flutter_svg` to 2.0.17, the first versions this package compiles against, and shortened the package description.

## 0.6.0

- **Addis AI**: batch generation. `ai.addis.batches` sends up to 10,000 text to speech requests at once (off-peak, within 24 hours, half price): `createFromRequests`, `create`, `retrieve`, `list` and `requests` (paged streams), `cancel`, `results`, `audio` and `waitFor` (with `onProgress`; rides out dropped connections and busy answers, and resumes by id after a restart). `ai.addis.files` has `upload` (one request up to 25 MB, signed upload up to 100 MB), `retrieve`, `delete`, `contentUrl` and `content`. Requests are checked before upload; creating a batch sends an `Idempotency-Key`, reused across retries, so a retry can't start a second batch; downloads never send the API key to the storage host. Adds a direct dependency on `http_parser`, already used through `http`.
- **Jev**: pictures and JSON state in every tool. `jev_decide`, `jev_batch` (per item), `jev_noul`, `jev_choice`, `jev_score` and `jev_box` take `images` ({placeholder: file or link}), turned into bytes by the app's `JevToolkit.resolveImage`; `JevImage.detect` reads PNG/JPEG from the bytes. Each picture is sent under a unique id (`JevPictures`): Jev swaps a placeholder wherever it appears, so the call's own names are replaced as whole words only, and a picture state doesn't mention is added under `images`. Requests with pictures use `visionModel` (`jev-preview`). `state` written as JSON text is sent as JSON (`JevToolkit.stateOf`). `jev_noul` / `jev_choice` / `jev_score` now pass the app's `images` too (they dropped them before), and `decideEach` takes per-state images, so batches can include box questions.
- **Fix, Jev**: `JevQuestion.fromJson` accepts options the way models send them: under `options`, `choices` or `levels` as well as `criteria`; as a map, a list (of names or `{name, description}`), a JSON string or a comma-separated string. A choice or score with no options now says what shape it expects instead of only "A choice takes 1 to 255 options".
- **Jev**: batches. `JevClient.decideEach` asks the same questions about many states (one request each, since the API has no batch endpoint; four at a time, order kept, a failed state holds its error). The `jev_batch` tool takes up to 100 `items` (strings or `{id, state}`) and returns compact answers per item plus totals (choice counts, yes/no counts, mean score), so an agent judges a list in one call instead of one per item.
- **Fix, Skills**: `previewHit` / `installHit` use the catalog's SKILL.md address (Skyll `refs.raw`) to read only that skill's folder, instead of scanning every skill in the repository when names differ. SKILL.md and bundled files are fetched six at a time, and each GitHub request gives up after 20 s, so a preview no longer appears to hang.
- **Fix, MCP**: servers that reject the `2026-07-28` discovery probe as an unsupported protocol version, while listing older ones ("supported versions: 2025-11-25, …"), now fall back to `initialize` instead of failing to connect. A rejection that lists no older version still does not downgrade.
- **Security, MCP**: a registry server's header templates (`Bearer {api_key}`) are filled from the values given (`McpCatalogHit.inputs`, `McpInput`); a required one still holding a placeholder throws instead of being saved as if it were a key, and `install` refuses unfilled `{placeholders}`. Plain `http://` endpoints are only accepted on localhost or the local network (`McpRegistry.isLocalHost`). The agent's `mcp_install` / `mcp_install_catalog` no longer save local command (stdio) servers unless `allowAgentStdio` is set: connecting runs that command.
- **Security, Jev**: the key is only sent over `https://` (plain `http` for localhost). Retried decisions carry one generated `Idempotency-Key`, so a retry is billed once. Every `jev_*` tool passes the run's cancel token.
- **Security, skills**: remote skills install over `https://` only; a SKILL.md or bundled file is at most 512 KB and a skill bundles at most 40 files / 2 MB. Descriptions put in the agent prompt are capped at 300 characters (the full text is in `load_skill`).
- **Skills**: `SkillRegistry` is `Listenable` (installs and removals notify). `search` asks Skyll first, so hits carry a `description` and the SKILL.md `rawUrl`, and falls back to skills.sh (`searchUrl: ''` for skills.sh only). `previewHit` reviews a hit without installing. `load_skill`, `read_skill_file` and `uninstall_skill` declare their required inputs.
- Fixed: a provider whose key was set while the model catalog was loading (e.g. keys restored at app start) never got its models listed, and `refresh()` during a load returned that same load. A forced refresh mid-load now fetches again when it ends, `setApiKey` refreshes a catalog that is loading, and `ModelCatalog.isLoading` says whether one is under way.

## 0.5.0

- Fixed misleading MCP response-id errors for redirected endpoints: show the final URL and HTTP status. Manual remote setup adds endpoint/authorization fields, keeps advanced JSON, and fixes controller disposal while the dialog closes.

- Added on-demand MCP install/configure, installation checks, removal, tool-schema inspection, resource and prompt tools; `managementTools()` avoids eager connections. Skills add remote previews and installation checks. Host apps can opt out of automatic installed-skill exposure when enforcing tool permissions.

- Added reusable `ExtensionsView` with catalog search, skill review/installation/removal, MCP configuration editing, and tool inspection; the example app adds Extensions and a fully editable Jev playground.
- Jev preserves structured JSON criteria, validates score/type/image requirements, supports boolean naming and normalized API base URLs, and cancels during retry backoff.
- MCP negotiates stateless `2026-07-28` or legacy initialization, reads HTTP SSE results without waiting for connection closure, supports immediate `mcp_call_tool` after installation, preserves catalog configuration, and migrates credentials to secure storage.
- Fixed skill selectors, GitHub folder filtering, multiline YAML descriptions, root/deep reference files, and concurrent registry loading. Added protocol, persistence, subprocess, cancellation, and UI regression coverage.

- **Jev (TypeSafe System One)**: `JevClient` / `JevToolkit` / `ai.jev` / `ai.decide()`. Full control of the System One API — noul (yes/no), choice, score and box questions, images, long context, retries, idempotency keys, custom base URL/headers, and one-shot helpers (`noul`, `choice`, `score`, `box`). Agent tools: `jev_decide`, `jev_noul`, `jev_choice`, `jev_score`, `jev_box`, `jev_models`. Same decision contract as the Vercel AI SDK `experimental_decide`.
- **MCP**: `createMcpClient` (HTTP, SSE, stdio on desktop) lists tools/resources/prompts and turns tools into omni_ai `Tool`s, following `@ai-sdk/mcp`. `McpRegistry` / `ai.mcp` **installs**, **lists** and **uses** servers (`install`, `list`, `connect`, `tools`, `toolkits`). **Search** the official MCP Registry (`ai.mcp.search`, `installHit`, `installFromCatalog`) — no API key.
- **Skills**: `SkillRegistry` / `ai.skills` **installs** from markdown, a SKILL.md URL, or GitHub (`owner/repo`, `owner/repo@name`), **lists** and **uses** them (`load_skill`). **Search** [skills.sh](https://skills.sh) (`ai.skills.search`, `installHit`) — the same public catalog as `npx skills find`. Installed skills are available to agents on that `OmniAI`.

## 0.4.1

- Fixed: Addis AI speech failed with a `FormatException` when the audio came as a `data:` URL. `GeneratedFile.fromBase64` (and `fromDataUrl`) now take data URLs, line breaks, URL-safe base64 and missing padding; `decodeBase64` does the same for any string.
- Fixed: restricted ElevenLabs keys (without `user_read`) failed `verify()` though they work; `ElevenLabsProvider.isMissingPermission` tells the two apart.

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
