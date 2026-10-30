/// One easy API for every AI provider: Vercel AI Gateway, Google Gemini,
/// OpenRouter, LM Studio, ElevenLabs, Addis AI and on-device speech.
///
/// ```dart
/// import 'package:omni_ai/omni_ai.dart';
///
/// final ai = OmniAI(googleKey: 'AIza…');
/// final answer = await ai.ask('Why is the sky blue?', model: 'google:gemini-2.5-flash');
/// ```
library;

// Core types.
export 'src/core/cancel.dart';
export 'src/core/errors.dart';
export 'src/core/json_utils.dart' show extractJson, parsePartialJson;
export 'src/core/media.dart';
export 'src/core/messages.dart';
export 'src/core/models.dart';
export 'src/core/stream_parts.dart';
export 'src/core/tools.dart';
export 'src/core/usage.dart';

// Functions, AI SDK style.
export 'src/generate/generate_media.dart';
export 'src/generate/generate_object.dart';
export 'src/generate/generate_text.dart';

// Providers.
export 'src/providers/addis_ai.dart';
export 'src/providers/addis_batches.dart';
export 'src/providers/elevenlabs.dart';
export 'src/providers/google.dart';
export 'src/providers/lm_studio.dart';
export 'src/providers/openai_compatible.dart';
export 'src/providers/openrouter.dart';
export 'src/providers/provider.dart' show AiProvider, parseModelRef;
export 'src/providers/vercel_gateway.dart' show VercelGatewayProvider;

// Agents and their toolkits.
export 'src/agents/agent.dart';
export 'src/agents/memory.dart';
export 'src/agents/memory_files.dart';
export 'src/agents/skills.dart';
export 'src/agents/toolkit.dart';
export 'src/mcp/mcp.dart';
export 'src/toolkits/browser.dart';
export 'src/toolkits/cloudflare.dart';
export 'src/toolkits/composio.dart';
export 'src/toolkits/device_sandbox.dart';
export 'src/toolkits/e2b.dart';
export 'src/toolkits/exa.dart';
export 'src/toolkits/jev.dart';

// Models catalog and keys.
export 'src/catalog/catalog.dart';
export 'src/catalog/model_info.dart';
export 'src/keys/key_store.dart';

// On-device speech.
export 'src/device/device_speech.dart';
export 'src/device/dictation.dart';

// Flutter widgets and controllers.
export 'src/flutter/agent_widgets.dart';
export 'src/flutter/api_key_settings.dart';
export 'src/flutter/audio.dart';
export 'src/flutter/browser_view.dart';
export 'src/flutter/chat_controller.dart';
export 'src/flutter/chat_view.dart';
export 'src/flutter/dictation_button.dart';
export 'src/flutter/extensions_view.dart';
export 'src/flutter/model_picker.dart';
export 'src/flutter/voice_picker.dart';

// Vercel AI SDK backends (useChat for Flutter).
export 'src/ui_stream/ui_message_stream.dart';

// The facade.
export 'src/omni_ai.dart';
