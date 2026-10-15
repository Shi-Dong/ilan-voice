# Tools

The tools Ilan can use: your MCP servers, plus optional shell, file and web-search tools.

[← Back to the README](../README.md)


## MCP servers

Ilan can call any MCP server in `mcp.json`, remote (Streamable HTTP) or local (stdio). It reads the same `mcpServers` format as Claude Code, and Settings → MCP Tools can import that config in one click. Each tool is shown to the model as `<server>__<tool>`.

```json
{
  "mcpServers": {
    "memory": { "type": "http", "url": "https://example.com/mcp", "headers": { "Authorization": "Bearer ${MEMORY_TOKEN}" } },
    "files":  { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/notes"] }
  }
}
```

Changed `mcp.json` or a server itself? Press **Reconnect** (↻ at the top of the window, or ⇧⌘R): it restarts every MCP server and starts a fresh session with their tools. The conversation is kept.

## Shell commands (optional)

Turn on Settings → Shell and Ilan can run bash commands on your Mac with its `run_shell` tool. It never asks for permission:
- commands on your allow-list run straight away;
- everything else is refused, and Ilan tells you what to add.

The default list is read-only (`ls`, `cat`, `grep`, `git status`, `git log`, `kubectl get`, …).

<details>
<summary>Allow-list rules, sessions and the bypass switch</summary>

- **Rules.** Each line is either a command prefix (whole words: `ls` does not allow `lsof`) or a regular expression in slashes that must match the whole command, e.g. `/kubectl -n [a-z-]+ (get|describe) .*/`.
- **Always refused.** Pipes, `&&` and `;` work when every part is allowed. Writing to files (`>`), `$( )`, backticks and background `&` are always refused, as are writing flags such as `find -delete` or `git branch -D`.
- **Sessions.** Each conversation gets one persistent bash session, started in the directory you choose, so `cd`, exported variables and activated environments carry over. A command is stopped after the timeout (60 s by default) while the session lives on. Every command appears in the transcript with its output.
- **Closing sessions.** Ilan can end a session with `close_shell`. Conversations with an open session show a light red terminal icon in the sidebar; click it (or right-click the conversation) to close it yourself. Quitting the app closes them all.
- **Bypass all permissions.** A red switch, behind a warning. It lets every command run unchecked, lets the file tools change any file (ignoring the block list), and greys out the rest of the Shell tab. Use it with care.

</details>

## Files

Ilan can always read text files with `read_file`. One switch in Settings → Shell → Files also lets it edit files (`edit_file`, replacing an exact piece of text) and create or overwrite them (`write_file`). This works anywhere except the block list, which covers macOS's own folders by default.
- Every change is first backed up to `file-backups/` next to `agent.md`.
- SSH, AWS and GnuPG keys, the Keychain and Ilan's own secrets are never read or changed.

## Web search

Settings → General → Web Search → **Set API Key…** next to *Gemini API key*. The key is checked with Google before it is saved. Ilan then gets a `web_search` tool: Gemini (`gemini-3.8-flash` by default) answers with Grounding with Google Search, and the answer and its sources appear in the transcript.
