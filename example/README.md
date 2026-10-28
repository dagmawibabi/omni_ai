# omni_ai example

Chat with tools, image generation, voices with previews and dictation, video generation, Jev decisions, and skill/MCP discovery and management.

```bash
flutter run
```

Use the navigation drawer to open **Keys** and paste a provider key (LM Studio needs only its server address).

- **Jev**: add a TypeSafe Jev key under Keys, then edit and run the decision request JSON. It supports boolean/noul, choice, score, and box questions, image assets, custom endpoint/headers, retries, timeout, multipart, long context, and cancellation.
- **Extensions → Skills**: search skills.sh, review instructions and file names, install, inspect, and remove skills. You can also install directly from GitHub, a SKILL.md URL, or markdown.
- **Extensions → MCP servers**: search the official registry, configure endpoint/command/credentials, save a server, connect to list its tools, edit, or remove it. Local commands need an installed runtime and a platform that permits subprocesses; use HTTP servers on web/mobile.
- **Chat / Agent**: installed capabilities are available through OmniAI's toolkits. Start a new chat after changing capabilities. MCP installation saves configuration; connecting can start the configured process.
