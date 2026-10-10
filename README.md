<p align="center"><img src="Resources/icon-512.png" width="128" alt="Ilan Voice icon"></p>

# Ilan Voice

A native macOS voice assistant built on OpenAI's **GPT-Realtime** (`gpt-realtime-2.1` by default). It works like ChatGPT Voice, with three differences:

- **Push to talk.** Hold a key or mouse button, speak, and let go. Right ⌥ is the default; to change it, click **Change…** in Settings → General and press the key or mouse button you want. Releasing the key ends your message, so the assistant never cuts in while you pause. Tapping the key while Ilan is talking stops it immediately. While you talk, a small floating pill near the bottom of the screen shows live voice bars, over any app.
- **Type instead of talking (Mac app).** The message box under the conversation is focused whenever you open the window. Enter sends, Shift+Enter adds a line, ⓧ clears it; Ilan answers out loud as usual. An unsent draft is kept (across closing the window, switching conversations and restarts). Holding the talk key still works while the box has text: only your voice is sent and the draft stays. Select text in the conversation and click the **Add to Message** button that appears on that message (or right-click → **Add to Message**) to quote it into the box. The iPhone web app stays voice-only.
- **Replay key (optional).** Set **Replay last reply** in Settings → General to a key or mouse button, and pressing it in any app plays Ilan's last reply again from the start. It cuts off whatever Ilan is saying at that moment, and tapping the talk key stops the replay. The same action is in the menu bar icon and under Voice → Replay Last Reply (⇧⌘L).
- **Your own agent.** Its instructions come from an `agent.md` file you write.
- **Your MCP tools.** It can call any MCP server you configure. It reads the same `mcpServers` format as Claude Code and can import that config in one click.

Apple Silicon only. Requires macOS 14 or later.

Conversations name themselves: after every reply, a small text model (GPT-6 Luna by default; change it under Settings → General → Title model) reads the 10 latest messages and picks a title of at most 30 characters. Renaming a conversation yourself turns this off for that conversation.

**Shell commands (optional).** Turn on Settings → Shell and Ilan can run bash commands on your Mac via a built-in `run_shell` tool. It never asks for permission: commands on your allow-list run straight away and everything else is refused (Ilan then tells you what to add). The default list contains only read-only commands (`ls`, `cat`, `grep`, `git status`, `git log`, `kubectl get`, …) and you can edit it freely. A red **Bypass all permissions** switch (behind a warning) lets every command run unchecked, lets the file tools change any file (ignoring the block list), and greys out the rest of the Shell tab; use it with care. Each line is either a command prefix (whole words: `ls` does not allow `lsof`) or a regular expression wrapped in slashes that must match the whole command, e.g. `/kubectl -n [a-z-]+ (get|describe) .*/`. Pipes, `&&` and `;` work when every part is allowed; writing to files (`>`), `$( )`, backticks and background `&` are always refused, as are writing flags such as `find -delete` or `git branch -D`. Each conversation gets one persistent bash session (started in the directory you choose), so `cd`, exported variables and activated environments carry over between commands. A command is stopped after the timeout (60 s by default) while the session lives on, and every command appears in the transcript with its output. Ilan can end the session with its `close_shell` tool. Conversations with an open session show a green terminal icon in the sidebar; click it (or right-click the conversation) to close the session yourself. Quitting the app closes them all.

**Files.** Ilan can always read text files with its `read_file` tool. In Settings → Shell → Files one switch also lets it edit files (`edit_file`, which replaces an exact piece of text) and create or overwrite files (`write_file`) anywhere except the files and folders on its block list (macOS's own folders by default). Every change is backed up first to `file-backups/` next to `agent.md`, and SSH/AWS/GnuPG keys, the Keychain and Ilan's own secrets are never read or changed.

**Dock.** Closing the window hides Ilan Voice from the Dock; it keeps running in the menu bar, so the talk key still works. **Show Ilan Voice** in the menu bar icon brings both back. Turn this off in Settings → General → App.

**iPhone.** Settings → General → iPhone → **Start Web Server** lets you talk to Ilan from your iPhone's home screen. It needs [Tailscale](https://tailscale.com) on the Mac and the iPhone: the app publishes a small web page on this Mac's tailnet name over HTTPS (`tailscale serve`, port 8767), reachable only from your own devices. Scan the QR code, open the page, then Share → Add to Home Screen. The page has one button to hold while you talk (slide your finger up while holding to cancel instead of sending), and a Reconnect button at the top for a fresh session; replies always play in real time. Each iPhone has a conversation of its own ("iPhone 1", "iPhone 2", …), marked with an iPhone in the sidebar, which you can also continue on the Mac; several iPhones can be used at the same time. If you remove the home-screen app and add it again, the page asks "Which iPhone is this?"; pick the old name to carry on with its conversation. It uses the same instructions, tools and settings as the Mac. The link carries a pairing code; **New Pairing Code…** makes old links stop working.

**Web search.** Settings → General → Web Search: click **Set API Key…** next to *Gemini API key*, paste the key (it is checked with Google before it is saved), and Ilan gets a built-in `web_search` tool. Gemini (`gemini-3.8-flash` by default) answers each query with Grounding with Google Search, and the answer and its sources appear in the transcript. The key is stored as `GEMINI_API_KEY` with your other API keys (see below); `GEMINI_API_KEY` in the environment also works.

**Dictionary.** Settings → Dictionary is a list of your own words (names, jargon, acronyms): type one to add it, click the trash icon to delete it, or **Import…** a text file with one word or phrase per line (duplicates are skipped). They are sent to the transcription model as a hint and to Ilan as a vocabulary list, so both recognise and spell them your way. Stored in `dictionary.txt` next to `agent.md`.

**Transcripts of what you say.** Before each turn the transcription model is also given what Ilan said last, so it knows the topic. After Ilan answers, a small text model (the title model, GPT-6 Luna by default) fixes misheard words in your transcript using the dictionary, the recent conversation and Ilan's reply; the original transcript is kept in `conversation.json` as `rawText`.

## Two ways to hear replies

| Mode | What happens |
| --- | --- |
| **Real-time** | The reply plays while it is still being generated. Hold the talk key to cut it off. |
| **Cached** | The reply is saved and marked **NEW**. Play it when you're ready with its ▶ button, **Play new**, or ⇧⌘P. |

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

1. Open **Settings (⌘, or Settings at the bottom of the sidebar) → General**, click **Set API Key…** and paste your OpenAI API key. The app checks it with OpenAI before saving it; keys are never shown again, only a short hint such as `sk-…a1b2`. It is stored with your other API keys in `~/Library/Application Support/Ilan Voice/secrets.json`, readable only by your user account.
2. Allow microphone access when macOS asks.
3. Click **Allow Accessibility** at the bottom of the window. Without it, the talk key only works while Ilan Voice is the active app. The first build creates a private self-signed certificate on your Mac (in `~/Library/Application Support/Ilan Voice/signing/`) and signs every later build with it, so macOS keeps the permission across rebuilds and updates. If you are upgrading from a build made before this, remove the old Ilan Voice entry under Privacy & Security → Accessibility and allow it once more.

## Updating

Click **Check for Updates** in Settings → General (or use **Ilan Voice → Check for Updates…**). The app also checks when it starts, every 10 minutes after that, and when you switch to it if the last check is over 3 minutes old, and shows an orange **Update** button at the top of the window when GitHub has a newer version. **Install Update** opens a small window with a progress bar while the latest `main` is downloaded into `~/Library/Application Support/Ilan Voice/source` and built on this Mac. When it is done, click **Restart Now** to switch to the new version, or **Later** to keep working; the update is then applied when you next quit the app. The build log is saved to `update.log` in the same folder. Your settings, `agent.md`, `mcp.json` and conversations are not touched.

Because the app is built on your Mac rather than downloaded, macOS has nothing to block. The only requirement is the Command Line Tools (`xcode-select --install`).

## API keys

Every key the app uses is stored by name (`OPENAI_API_KEY`, `GEMINI_API_KEY`, …) in `~/Library/Application Support/Ilan Voice/secrets.json`, readable only by your user account. The OpenAI key is set in Settings → General and the Gemini key in its Web Search section; other keys can be added to the file by hand. They are deliberately not in the Keychain, which would ask for your password after every update of a self-built app. `mcp.json` can use any of them as `${NAME}`, e.g. `"headers": { "Authorization": "Bearer ${MEMORY_TOKEN}" }`, so tokens don't have to be pasted into it. A name with no stored value falls back to the environment variable of the same name.

## Configuration

Everything lives in `~/Library/Application Support/Ilan Voice/`:

```
agent.md                      the agent's instructions (Settings → Agent reveals or opens it)
mcp.json                      MCP servers (Settings → MCP Tools reveals or opens it)
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

Settings → General also covers the speaking speed (a slider from 0.5× to 1.5× in steps of 0.1, applied from the next reply), the microphone (the Mac's built-in one by default, so Bluetooth headphones stay in high-quality mode), the model, the voice (female or male), reasoning effort, transcription model, talk key, and output mode.

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
| `scripts/test.sh` | builds and runs the unit tests in `Tests/IlanVoiceTests` |

## Tests

```
scripts/test.sh
```

compiles the app's code as a library, links the tests in `Tests/IlanVoiceTests` against it and runs them; the whole thing takes a few seconds. The tests run with a throwaway home folder, so they never touch your real data, and the iPhone web server is started on a spare local port (Tailscale is never involved). The JavaScript check of the iPhone page needs Node.js and is skipped without it. It works with the Command Line Tools alone, which include neither XCTest nor the macro plugin Swift Testing needs, so the tests use a small built-in harness: group them with `suite("…") { test in test("…") { … } }` and check with `expect(…)` / `expectEqual(…, …)`. A new test file needs a `register…Tests()` function, called from `Tests/IlanVoiceTests/main.swift`. The same script runs on every pull request.
