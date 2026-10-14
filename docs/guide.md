# Using Ilan Voice

Everything about talking to Ilan, the iPhone app, cost, settings and updates.

[← Back to the README](../README.md)

## Talking to Ilan

### Push to talk

Hold the talk key, speak, and let go: releasing the key ends your message. Right ⌥ is the default; to change it, click **Change…** in Settings → General and press any key or mouse button.

| Do this | And Ilan… |
| --- | --- |
| **Hold** the talk key | listens until you let go |
| **Tap** it while Ilan talks or works | stops (after a brief wait to see whether a second tap follows) |
| **Double-tap** it | keeps going, and the window comes to the front with the cursor in the message box |

While you talk, a small floating pill near the bottom of the screen shows live voice bars and which microphone is recording, over any app:

<p align="center"><img src="pill.png" width="400" alt="The floating listening pill"></p>

### Typing

The message box is focused whenever you open the window. **Enter** sends, **Shift+Enter** adds a line, ⓧ clears it; Ilan answers out loud as usual.

- An unsent draft is kept across closing the window, switching conversations and restarts.
- Holding the talk key still works while the box has text: only your voice is sent, and the draft stays.
- Select text in the conversation and click **Ask about this** (it appears right under your pointer, or right-click → **Ask about this**) to quote it into the box.

The iPhone web app stays voice-only.

### Hearing replies

| Mode | What happens |
| --- | --- |
| **Real-time** | The reply plays while it is still being generated. Hold the talk key to cut it off. |
| **Cached** | The reply is saved and marked **NEW**. Play it when you're ready with its ▶ button, **Play new**, or ⇧⌘P. |

**Replay key (optional).** Set **Replay last reply** in Settings → General, and pressing it in any app plays Ilan's last reply again from the start, cutting off whatever Ilan is saying. Tapping the talk key stops the replay. Also in the menu bar icon and under Voice → Replay Last Reply (⇧⌘L).

### Your words, spelled right

- **Dictionary.** Settings → Dictionary holds your own words (names, jargon, acronyms): type one to add it, click the trash icon to delete it, or **Import…** a text file with one per line. They are sent to the transcription model as a hint and to Ilan as a vocabulary list. Stored in `dictionary.txt` next to `agent.md`.
- **Transcript repair.** Before each turn, the transcription model is told what Ilan said last. After Ilan answers, a small text model (GPT-6 Luna by default) fixes misheard words using the dictionary, the conversation and Ilan's reply. The original is kept in `conversation.json` as `rawText`.
- **Titles.** After every reply, the same model names the conversation (at most 30 characters). Renaming a conversation yourself turns this off for it. Change the model under Settings → General → Title model.

## iPhone

Settings → General → iPhone → **Start Web Server** lets you talk to Ilan from your iPhone's home screen.

1. Install [Tailscale](https://tailscale.com) on the Mac and the iPhone. The page is published on this Mac's tailnet name over HTTPS (`tailscale serve`, port 8767), reachable only from your own devices.
2. Scan the QR code, open the page, then Share → **Add to Home Screen**.
3. Tap the button to start a conversation, then just talk: Ilan works out from what you say when you have finished, and answers. Speak over Ilan to interrupt it. Tap again to end the conversation.
4. During a conversation nothing is transcribed live (your turns show "Transcribing…"). When it ends, each turn is transcribed from its recording and then repaired by Luna.
5. While an iPhone conversation is live, the Mac can read that conversation but not talk or type in it; every other conversation works as usual.

<details>
<summary>More about the iPhone app</summary>

- **Replies** always play in real time. The Reconnect button at the top starts a fresh session.
- **One conversation per iPhone.** Each iPhone has its own conversation ("iPhone 1", "iPhone 2", …), marked with an iPhone in the sidebar. You can continue it on the Mac, and several iPhones can be used at once.
- **Same setup as the Mac.** It uses the same instructions, tools and settings.
- **After reinstalling.** If you remove the home-screen app and add it again, the page asks "Which iPhone is this?"; pick the old name to carry on with its conversation.
- **Pairing code.** The link carries a pairing code; **New Pairing Code…** makes old links stop working.

</details>

## Cost

Each conversation's cost so far appears in the sidebar. Each reply shows the tokens it used, on the same line as its replay button: input (of which cached) and output. Tool-calling steps are counted with the reply that follows them.

- **What's counted:** only the realtime voice model, including replies you cut off. Transcription, transcript corrections, titles and web search are not included.
- **Prices:** worked out from OpenAI's list prices. A model with no known price is marked with "+" instead of being guessed.
- **Hiding:** turn the numbers off in Settings → General → Cost; they are still recorded.

## Updating

Click **Check for Updates** in Settings → General (or **Ilan Voice → Check for Updates…**).

- **Automatic checks:** the app also checks when it starts, every 10 minutes, and when you switch to it if the last check is over 3 minutes old. An orange **Update** button appears when GitHub has a newer version.
- **Installing:** **Install Update** downloads the latest `main` into `~/Library/Application Support/Ilan Voice/source` and builds it on this Mac, with a progress bar. When it's done, click **Restart Now**, or **Later** to apply it when you next quit. The build log is saved to `update.log`.
- **Your data:** settings, `agent.md`, `mcp.json` and conversations are never touched.

Because the app is built on your Mac rather than downloaded, macOS has nothing to block.
