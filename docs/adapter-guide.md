# Adapter Guide

The macOS app reads enabled providers directly. Its reports can also read a database populated by the Rust CLI. The Windows, GNOME and KDE clients display snapshots from that database.

## Implemented sources

| Tool | macOS input | Measurements |
|---|---|---|
| Claude Code | Assistant usage records in local project transcripts, `claude auth status`, weekly status-line metadata | Recorded tokens, reported plan, overall and available model-specific weekly quotas |
| Codex CLI | Session JSONL files in `sessions` and `archived_sessions` beneath `CODEX_HOME` (default `~/.codex`) | Per-session token increments, plan and reported quota windows |
| Gemini CLI | Local chat JSONL events and messages in JSON session documents | Recorded tokens and the latest reported model |
| MiniMAX | `mmx quota show --output json` | Current interval and weekly quota by reported category. The adapter reconciles the count with the reported remaining percentage. |
| Google Antigravity CLI | Status-line snapshot or headless JSONL | Session tokens, estimated USD and available quota buckets from the status line. JSONL can provide dated per-step tokens. |
| Factory Droid | Local session settings and optional limits JSON | Own-session tokens and Factory credits. The limits response provides Standard and Droid Core windows and the prepaid balance. |
| Cline | CLI session metadata, accompanying message metrics, or the extension's task history JSON | Recorded tokens, reported USD cost estimates and dated message tokens when available. |
| Augment Code / Auggie | Local session JSON and `auggie account status` | Dated token usage when available, reported Augment credits and recognized CLI allowance or balance readings. |
| Amp | Local or exported thread JSON and `amp usage` | Reported tokens, spent credits, subscription usage and remaining balances. |
| OpenHands | Local SDK conversation state | Recorded tokens, estimated USD cost and the latest available configured conversation budget. |

Enable the provider and select **Local adapter** in the macOS settings. Missing readings and quota-only providers can have no dated token history. Unreported quota percentages appear as a dash. The Rust CLI separately imports Codex logs into SQLite using `import-codex`.

### Claude weekly quota capture

Claude Code sends its status-line payload to a command on standard input. To enable weekly quota collection, add the following entry to the **existing** Claude Code settings JSON, using the actual absolute script path. The helper requires Python 3. It writes only reported weekly percentages and reset timestamps, atomically, to `vibemeasure-weekly.json` under `CLAUDE_CONFIG_DIR` (default `~/.claude`). VibeMeasure picks it up on refresh.

```json
{
  "statusLine": {
    "type": "command",
    "command": "python3 '/absolute/path/to/VibeMeasure/platforms/macos/scripts/capture-claude-statusline.py'"
  }
}
```

If an existing status-line script renders your prompt, append its executable and arguments to the capture command. It receives the original JSON on standard input and its output remains visible. For an existing shell pipeline, put that pipeline in an executable script and pass its path. A fresh status-line event is required after enabling capture. Token history and the reported plan can be available independently of quota capture. [Claude Code status line](https://code.claude.com/docs/en/statusline)

### Additional local adapters

Enable the provider in macOS settings and choose **Local adapter**. **Usage source** shows the default path. Use **Choose File or Folder** for a nondefault installation or a provider export. VibeMeasure reads the source again on each refresh. Currency estimates and provider credits use separate rows. Dated comparisons include recorded events with timestamps. Session totals without per-event timestamps appear in **Provider cycles**.

- **Antigravity** can feed the adapter from its status line. In the CLI run `/statusline python3 '/absolute/path/to/VibeMeasure/platforms/macos/scripts/capture-antigravity-statusline.py'`. The script saves only the usage fields to `~/.gemini/antigravity-cli/vibemeasure-usage.json`. To keep a custom status line, append the existing renderer command and its arguments so that it receives the original input. For headless runs, select a recorded `stream-json` file or its folder. [Status line](https://antigravity.google/docs/cli/statusline/) · [Headless mode](https://antigravity.google/docs/cli/headless/)
- **Factory Droid** reads `~/.factory/sessions/**/*.settings.json`. You can select a separate `droid exec -o json` result. For account limits, the macOS process can use an explicit, valid `VIBEMEASURE_FACTORY_ACCESS_TOKEN` from its environment to read the US Factory limits endpoint. It can also read a `factory-limits.json` response placed alongside the sessions. The token is sent only to that HTTPS endpoint and redirects are rejected. [Droid Exec](https://docs.factory.com/droid-exec/overview) · [Factory rate limits](https://docs.factory.com/pricing/individuals)
- **Cline** looks for the CLI's `~/.cline/data/sessions` and known VS Code task history locations. Select the task history JSON directly for a different profile or storage location. Account-wide quota is unavailable from these files. [Cline task usage](https://docs.cline.bot/core-workflows/task-management)
- **Auggie** reads `~/.augment/sessions` and honors `AUGMENT_HOME`. **Command hint** can point to the authenticated `auggie` executable for balance and allowance. Augment credit spend stays in credits. [Session format](https://github.com/augment-solutions/codeburn)
- **Amp** reads `~/.local/share/amp/threads` or the directory under `AMP_DATA_DIR`. Current cloud threads can be exported by their owner as full JSON from Amp. The signed-in `amp usage` command supplies remaining allowance or balance when available. [Threads](https://ampcode.com/docs/threads) · [Pricing](https://ampcode.com/docs/pricing)
- **OpenHands** reads `base_state.json` files under `~/.openhands/conversations` by default. Select the SDK persistence directory if it differs. The conversation budget, if configured, is a USD cap for that conversation. Workspace or API-provider quotas require their respective billing sources. [OpenHands persistence](https://github.com/OpenHands/software-agent-sdk)

### Existing Codex databases

The importer commits each log atomically and associates identified data with its session. Unchanged or appended logs can be imported again. It reconciles attributable records written by older versions. Historical duplicates without sufficient session identity may remain. To reconstruct exact historical totals in that case, import the original logs into a **new database** and retain the previous database, including its settings and price rules. Anonymous logs use their canonical file path as a fallback identity.

### Catalog entries without automatic readers

Devin for Terminal, OpenCode, Hermes, Kimi CLI, Cursor Agent, Qwen Code, Qoder CLI, GitHub Copilot CLI, Pi, Kiro CLI, Kilo, Mistral Vibe CLI, and DeepSeek TUI are available for manual configuration. The app identifies manually supplied readings as manual.

## Test Double Rule

Mocks and fakes are only allowed in test code and must be clearly marked as test doubles. Sanitized fixtures live under `tests/fixtures/`.

## Adding An Adapter

1. Verify the source format from local evidence or official documentation.
2. Add a parser that returns `UsageEvent` and optional `LimitWindow` values.
3. Preserve source metadata for every emitted value.
4. Add sanitized fixtures and parser tests.
5. Update docs with exactly what is verified and what remains manual.
