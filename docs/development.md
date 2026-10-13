# Development

How Ilan Voice works inside, the source layout, and the tests.

[← Back to the README](../README.md)

## How it works

```
hold key → microphone → 24 kHz PCM → input_audio_buffer.append ─┐
release  → input_audio_buffer.commit + response.create          │  WebSocket
                                                                 ▼
             GPT-Realtime ── function_call → MCP server → function_call_output
                  │
                  ├─ output_audio.delta → speaker (real-time) or WAV only (cached)
                  └─ transcripts → transcript.md / conversation.json
```

- **No voice detection.** It's turned off (`turn_detection: null`), so your message is exactly what you recorded while the key was held.
- **Sessions.** Each conversation gets its own Realtime session. Reopening an old one adds its earlier turns to the instructions.

## Source layout and tests

| Path | Role |
| --- | --- |
| `Sources/IlanVoice/Core/VoiceSession.swift` | push-to-talk flow, Realtime events, tool loop, playback modes |
| `Sources/IlanVoice/Core/RealtimeClient.swift` | WebSocket client |
| `Sources/IlanVoice/Core/MCP.swift` | MCP client (HTTP and stdio) |
| `Sources/IlanVoice/Core/ConversationStore.swift` | transcripts on disk |
| `Sources/IlanVoice/Audio/Audio.swift` | microphone capture, streaming playback, WAV |
| `Sources/IlanVoice/Views/` | SwiftUI interface |
| `scripts/build-app.sh` | builds the `.app` bundle |
| `scripts/test.sh` | builds and runs the unit tests in `Tests/IlanVoiceTests` |

**Tests.** `scripts/test.sh` compiles the app's code as a library, links the tests in `Tests/IlanVoiceTests` against it and runs them in a few seconds. The same script runs on every pull request.
- **Isolation:** the tests run with a throwaway home folder and no API keys, so they never touch your data or call OpenAI. The iPhone web server starts on a spare local port, and Tailscale is never involved.
- **Node.js:** the JavaScript check of the iPhone page needs it and is skipped without it.
- **Harness:** the Command Line Tools include neither XCTest nor Swift Testing's macro plugin, so the tests use a small built-in harness. Group them with `suite("…") { test in test("…") { … } }` and check with `expect(…)` / `expectEqual(…, …)`. A new test file needs a `register…Tests()` function called from `Tests/IlanVoiceTests/main.swift`.
