# Settings and files

Where everything is stored, API keys, and the remaining settings.

[← Back to the README](../README.md)

## First launch, in detail

- **Building:** only the Xcode Command Line Tools are needed; full Xcode isn't required. `scripts/build-app.sh --install` builds `dist/Ilan Voice.app` and copies it to `/Applications`.
- **OpenAI key:** Settings (⌘,) → General → **Set API Key…**. The key is checked with OpenAI before it is saved, and only a short hint such as `sk-…a1b2` is ever shown again.
- **Accessibility:** without it, the talk key only works while Ilan Voice is the active app. The first build creates a private self-signed certificate (in `~/Library/Application Support/Ilan Voice/signing/`) and signs every later build with it, so macOS keeps the permission across updates. Upgrading from an older build? Remove the old Ilan Voice entry under Privacy & Security → Accessibility and allow it once more.


Settings → General also covers:
- **Speaking speed:** 0.5× to 1.5× in steps of 0.1, applied from the next reply.
- **Microphone:** the Mac's built-in one by default, so Bluetooth headphones stay in high-quality mode.
- **Model and voice:** the model, and a female or male voice.
- **Other:** reasoning effort, transcription model, talk key and output mode.

**Dock.** Closing the window hides Ilan Voice from the Dock; it keeps running in the menu bar, so the talk key still works. **Show Ilan Voice** in the menu bar icon brings both back. Turn this off in Settings → General → App.

Everything lives in `~/Library/Application Support/Ilan Voice/`:

```
agent.md                      the agent's instructions (Settings → Agent reveals or opens it)
mcp.json                      MCP servers (Settings → MCP Tools reveals or opens it)
dictionary.txt                your words, one per line (Settings → Dictionary)
secrets.json                  API keys, readable only by your user account
Conversations/<id>/
    conversation.json         the full record
    transcript.md             the same record, easy to read
    audio/<item>.wav          every voice message, yours and the assistant's
```

**API keys.** Every key is stored by name (`OPENAI_API_KEY`, `GEMINI_API_KEY`, …) in `secrets.json`.
- **Why not the Keychain:** it would ask for your password after every update of a self-built app.
- **Using keys in `mcp.json`:** refer to any key as `${NAME}`, so tokens don't have to be pasted into it.
- **Fallback:** a name with no stored value falls back to the environment variable of the same name.
