<p align="center"><img src="Resources/icon-512.png" width="128" alt="Ilan Voice icon"></p>

# Ilan Voice

A native macOS voice assistant built on OpenAI's **GPT-Realtime** (`gpt-realtime-2.1` by default). It works like ChatGPT Voice, with three differences:

- **Push to talk.** Hold a key or mouse button, speak, and let go. Right ⌥ is the default; to change it, click **Change…** in Settings → General and press the key or mouse button you want. Releasing the key ends your message, so the assistant never cuts in while you pause. While you talk, a small floating pill near the bottom of the screen shows live voice bars, over any app.
- **Your own agent.** Its instructions come from an `agent.md` file you write.
- **Your MCP tools.** It can call any MCP server you configure. It reads the same `mcpServers` format as Claude Code and can import that config in one click.

Apple Silicon only. Requires macOS 14 or later.

Conversations name themselves: after every reply, a small text model (GPT-6 Luna by default; change it under Settings → General → Title model) reads the 10 latest messages and picks a title of at most 30 characters. Renaming a conversation yourself turns this off for that conversation.

**Shell commands (optional).** Turn on Settings → Shell and Ilan can run bash commands on your Mac via a built-in `run_shell` tool. It never asks for permission: commands on your allow-list run straight away and everything else is refused (Ilan then tells you what to add). The default list contains only read-only commands (`ls`, `cat`, `grep`, `git status`, `git log`, `kubectl get`, …) and you can edit it freely. Each line is either a command prefix (whole words: `ls` does not allow `lsof`) or a regular expression wrapped in slashes that must match the whole command, e.g. `/kubectl -n [a-z-]+ (get|describe) .*/`. Pipes, `&&` and `;` work when every part is allowed; writing to files (`>`), `$( )`, backticks and background `&` are always refused, as are writing flags such as `find -delete` or `git branch -D`. Commands run with `bash -lc` in the directory you choose, are stopped after the timeout (60 s by default), and appear in the transcript with their output.

**Dictionary.** Settings → Dictionary holds your own words (names, jargon, acronyms), one per line. They are sent to the transcription model as a hint and to Ilan as a vocabulary list, so both recognise and spell them your way. Stored in `dictionary.txt` next to `agent.md`.

## Two ways to hear replies

| Mode | What happens |
| --- | --- |
| **Real-time** | The reply plays while it is still being generated. Hold the talk key to cut it off. |
| **Cached** | The reply is saved and marked **NEW**. Play it when you're ready with its ▶ button, **Play new** (Space), or ⇧⌘P. |

Both modes save everything: the full transcript (your speech, the replies, and every tool call with its input and output) plus a WAV file for each voice message.

## Build and run

You only need the Xcode Command Line Tools; full Xcode isn't required.

```fish
git clone git@github.com:Shi-Dong/ilan-voice.git
cd ilan-voice
scripts/build-app.sh --install   # builds dist/Ilan Voice.app and copies it to /Applications
open "/Applications/Ilan Voice.app"
```

On first launch:

1. Open **Settings (⌘, or the Settings button at the bottom of the sidebar) → General** and paste your OpenAI API key. It is stored in the macOS login Keychain.
2. Allow microphone access when macOS asks.
3. Click **Allow Accessibility** at the bottom of the window. Without it, the talk key only works while Ilan Voice is the active app. The first build creates a private self-signed certificate on your Mac (in `~/Library/Application Support/Ilan Voice/signing/`) and signs every later build with it, so macOS keeps the permission across rebuilds and updates. If you are upgrading from a build made before this, remove the old Ilan Voice entry under Privacy & Security → Accessibility and allow it once more.

## Updating

Click **Check for Updates** in Settings → General (or use **Ilan Voice → Check for Updates…**). The app also checks once each time it starts, and shows an orange **Update** button at the top of the window when GitHub has a newer version. **Install & Relaunch** downloads the latest `main` into `~/Library/Application Support/Ilan Voice/source`, builds it on this Mac, replaces the installed app, and reopens it. The build log is saved to `update.log` in the same folder. Your settings, `agent.md`, `mcp.json` and conversations are not touched.

Because the app is built on your Mac rather than downloaded, macOS has nothing to block. The only requirement is the Command Line Tools (`xcode-select --install`).

## Configuration

Everything lives in `~/Library/Application Support/Ilan Voice/`:

```
agent.md                      the agent's instructions (also editable in Settings → Agent)
mcp.json                      MCP servers (Settings → MCP Tools)
dictionary.txt                your words, one per line (Settings → Dictionary)
Conversations/<id>/
    conversation.json         the full record
    transcript.md             the same record, easy to read
    audio/<item>.wav          every voice message, yours and the assistant's
```

`mcp.json` example:

```json
{
  "mcpServers": {
    "memory": { "type": "http", "url": "https://example.com/mcp", "headers": { "Authorization": "Bearer …" } },
    "files":  { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/notes"] }
  }
}
```

Both remote servers (Streamable HTTP) and local servers (stdio) are supported. Each tool is shown to the model as `<server>__<tool>`.

Settings → General also covers the microphone (the Mac's built-in one by default, so Bluetooth headphones stay in high-quality mode), the model, the voice (female or male), reasoning effort, transcription model, talk key, and output mode.

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

Server voice detection is turned off (`turn_detection: null`), so your message is exactly what you recorded while the key was held. Each conversation gets its own Realtime session. When you reopen an old conversation, its earlier turns are added to the instructions so the assistant has the context.

## Source layout

| Path | Role |
| --- | --- |
| `Sources/IlanVoice/Core/VoiceSession.swift` | push-to-talk flow, Realtime events, tool loop, playback modes |
| `Sources/IlanVoice/Core/RealtimeClient.swift` | WebSocket client |
| `Sources/IlanVoice/Core/MCP.swift` | MCP client (HTTP and stdio) |
| `Sources/IlanVoice/Core/ConversationStore.swift` | transcripts on disk |
| `Sources/IlanVoice/Audio/Audio.swift` | microphone capture, streaming playback, WAV |
| `Sources/IlanVoice/Views/` | SwiftUI interface |
| `scripts/build-app.sh` | builds the `.app` bundle |
