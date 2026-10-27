## 0.1.0

First release.

- `OmniAI`: one object with keys and providers; model ids like `google:gemini-2.5-flash`.
- Providers: Vercel AI Gateway, Google Gemini (native), OpenRouter, LM Studio, ElevenLabs, Addis AI, any OpenAI-compatible API, and on-device speech.
- Text: `generateText`, `streamText` (text, reasoning, tool and file streams), multi-step tool loops with approval, `generateObject`, `streamObject`, `classify`.
- Media: `generateImage` (with references), `generateSpeech`, `speak`, `transcribe`, live and cloud dictation, `generateVideo`, `embed`, `embedMany`, ElevenLabs sound effects and music.
- Catalog: every provider's models merged with models.dev (prices, context, modalities, logos), cached on device.
- Widgets: `AiChatView`, `AiChatController`, `ModelPicker`, `VoicePicker` with previews, `ApiKeySettings`, `DictationButton`, `AiAudio` player.
- `UiMessageStreamClient` for Vercel AI SDK backends.
