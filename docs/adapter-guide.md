# Adapter Guide

The macOS app reads enabled providers directly. Its reports can also read a database populated by the Rust CLI. The Windows, GNOME and KDE clients display snapshots from that database.

## Implemented sources

| Tool | macOS input | Measurements |
|---|---|---|
| Claude Code | Assistant usage records in local project transcripts, `claude auth status`, weekly status-line metadata | Recorded tokens, reported plan, overall and available model-specific weekly quotas |
| Codex CLI | Session JSONL files in `sessions` and `archived_sessions` beneath `CODEX_HOME` (default `~/.codex`) | Per-session token increments, plan and reported quota windows |
| Gemini CLI | Local chat JSONL events and messages in JSON session documents | Recorded tokens and the latest reported model |
| MiniMAX | `mmx quota show --output json` | Current interval and weekly quota by reported category. The adapter reconciles the count with the reported remaining percentage. |

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

### Existing Codex databases

The importer commits each log atomically and associates identified data with its session. Unchanged or appended logs can be imported again. It reconciles attributable records written by older versions. Historical duplicates without sufficient session identity may remain. To reconstruct exact historical totals in that case, import the original logs into a **new database** and retain the previous database, including its settings and price rules. Anonymous logs use their canonical file path as a fallback identity.

### Catalog entries without automatic readers

Devin for Terminal, OpenCode, Hermes, Kimi CLI, Cursor Agent, Qwen Code, Qoder CLI, GitHub Copilot CLI, Pi, Kiro CLI, Kilo, Mistral Vibe CLI, and DeepSeek TUI are available for manual configuration. The app identifies manually supplied readings as manual. Available upstream commands and APIs require a VibeMeasure integration before their data appears automatically.

## Test Double Rule

Mocks and fakes are only allowed in test code and must be clearly marked as test doubles. Sanitized fixtures live under `tests/fixtures/`.

## Adding An Adapter

1. Verify the source format from local evidence or official documentation.
2. Add a parser that returns `UsageEvent` and optional `LimitWindow` values.
3. Preserve source metadata for every emitted value.
4. Add sanitized fixtures and parser tests.
5. Update docs with exactly what is verified and what remains manual.
