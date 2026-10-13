<p align="center"><img src="Resources/icon-512.png" width="128" alt="Ilan Voice icon"></p>

<h1 align="center">Ilan Voice</h1>

<p align="center">
  A native macOS voice assistant on OpenAI's <b>GPT-Realtime</b>: hold a key, talk, let go.<br>
  Your own agent, your own MCP tools, and every word saved on your Mac.
</p>

<p align="center">
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-black?logo=apple">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-only-black">
  <img alt="Model" src="https://img.shields.io/badge/model-gpt--realtime--2.1-F4A7A3">
</p>

<p align="center"><img src="docs/window.png" width="760" alt="The Ilan Voice window"></p>

## Highlights

- 🎙️ **Push to talk, from any app.** Hold right ⌥, speak, let go. Ilan never cuts in while you pause.
- ⌨️ **Or type.** Ilan still answers out loud.
- 🧠 **Your own agent and tools.** Instructions from an `agent.md`; any MCP server, plus optional shell, file and web-search tools.
- 📱 **iPhone.** Talk to Ilan from your home screen over your own tailnet.
- 📝 **Everything saved.** Transcripts, tool calls and a recording of every voice message.
- 💸 **Cost at a glance.** Tokens per reply, cost per conversation.

## Quick start

You need the Xcode Command Line Tools (`xcode-select --install`).

```fish
git clone git@github.com:Shi-Dong/ilan-voice.git
cd ilan-voice
scripts/build-app.sh --install
open "/Applications/Ilan Voice.app"
```

Then:

1. **Add your OpenAI API key:** Settings (⌘,) → General → **Set API Key…**.
2. **Allow the microphone** when macOS asks.
3. **Click Allow Accessibility** at the bottom of the window, so the talk key works in every app.

## Using it

| Do this | And Ilan… |
| --- | --- |
| **Hold** the talk key (right ⌥) | listens until you let go, then answers |
| **Tap** it while Ilan talks | stops |
| **Double-tap** it | opens the window, and Ilan keeps going |
| **Type** and press Enter | answers out loud |

Updates are built on your Mac: click **Check for Updates** in Settings → General.

## Learn more

| | |
| --- | --- |
| 📖 [Using Ilan Voice](docs/guide.md) | talking, typing, replies, dictionary, iPhone, cost, updates |
| 🔌 [Tools](docs/tools.md) | MCP servers, shell commands, files, web search |
| ⚙️ [Settings and files](docs/configuration.md) | where everything is stored, API keys, settings |
| 🛠️ [Development](docs/development.md) | how it works, source layout, tests |
