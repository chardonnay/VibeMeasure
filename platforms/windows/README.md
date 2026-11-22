# Windows usage monitor

The WinUI 3 desktop app refreshes local Codex sessions and the six providers below at startup, every minute while running, and when you click Refresh. It updates token counts, quota windows, plan labels, and cost estimates as the sources report them. Changing the display mode or currency reads a fresh snapshot from the database. The app looks for `vibemeasure-cli.exe` beside the executable or on PATH.

The importer checks new or changed rollout files modified in the last 31 days under `sessions` and `archived_sessions`. It uses `CODEX_HOME` when set, or `%USERPROFILE%\.codex` by default. Complete entries from an open log can be imported while an unfinished final entry is retried on the next refresh. The importer remembers unchanged files and deduplicates sessions by their Codex session ID, including sessions moved to the archive or imported manually.

The default database is `%LOCALAPPDATA%\VibeMeasure\vibemeasure.sqlite`. The app creates it when a supported source provides usage. Set `VIBEMEASURE_DB` before launch to choose a different database. To run from the repository root in PowerShell:

```powershell
cargo install --path apps/vibemeasure-cli --locked
dotnet run --project platforms/windows/VibeMeasure.Windows
```

Build on Windows with the .NET 10 SDK and the WinUI/Windows App SDK development tools. This project produces an unpackaged desktop application.

## Additional provider sources

| Provider | Automatic discovery | Custom path environment variable |
| --- | --- | --- |
| Google Antigravity CLI | `%USERPROFILE%\.gemini\antigravity-cli\vibemeasure-usage.json` from the status-line hook | `VIBEMEASURE_ANTIGRAVITY_PATH` |
| Factory Droid | `%USERPROFILE%\.factory\sessions` for session settings and an optional `factory-limits.json` | `VIBEMEASURE_FACTORY_DROID_PATH` |
| Cline | `%USERPROFILE%\.cline\data` for CLI sessions and task history, plus the VS Code, VS Code Insiders and VSCodium task history under `%APPDATA%` | `VIBEMEASURE_CLINE_PATH` |
| Augment Code / Auggie | `%USERPROFILE%\.augment\sessions` or `AUGMENT_HOME\sessions` and authenticated `auggie account status` | `VIBEMEASURE_AUGGIE_PATH` |
| Amp | `AMP_DATA_DIR\threads`, or `%USERPROFILE%\.local\share\amp\threads` and `%LOCALAPPDATA%\amp\threads`, plus authenticated `amp usage` | `VIBEMEASURE_AMP_PATH` |
| OpenHands | `%USERPROFILE%\.openhands\conversations` for SDK conversation state | `VIBEMEASURE_OPENHANDS_PATH` |

For Antigravity, register the bundled hook in the Antigravity CLI with `/statusline py -3 "C:\path\to\VibeMeasure\Tools\capture-antigravity-statusline.py"`. The hook requires Python 3. A custom path can point to an Antigravity `stream-json` log or another compatible provider export. Set custom paths before launching VibeMeasure and restart it from the notification area after changing them.

The Amp and Auggie commands are discovered on PATH and in the user npm bin directory. `VIBEMEASURE_AMP_COMMAND` and `VIBEMEASURE_AUGGIE_COMMAND` accept full executable paths. To fetch Factory account quotas, provide `VIBEMEASURE_FACTORY_ACCESS_TOKEN` in the app's environment or place a current `factory-limits.json` in the session tree. See the [adapter guide](../../docs/adapter-guide.md) for details on each source.

Dated records feed the selected period. Provider-native token totals, spent credits, and source estimates retain the scope of the original records and appear separately below the quota rows. Source estimates keep their original USD amounts, and any unavailable account quota is shown as unavailable.

## Notification area and autostart

Closing the window hides it while VibeMeasure continues importing. Double-click the VibeMeasure icon in the Windows notification area or select **Open VibeMeasure** from its menu to restore the window. If the icon is in the notification overflow, first open **Show hidden icons**. Starting VibeMeasure again for the same database also restores the running window. Select **Exit** from the icon's menu to stop imports and quit.

Select **Start with Windows** from the icon's menu to opt in to launching VibeMeasure in the background when you sign in. The setting applies to your Windows account and can be switched off from the same menu. Keep the executable at the registered location.

## Plan labels and estimates

A Codex session that records a plan supplies its badge automatically. The latest recorded plan takes precedence over the manual label set by `vibemeasure-cli set-plan --db $db --tool codex --name "Your plan"`, where `$db` is the path to your VibeMeasure database. Hover over a badge for its source and observation time.

The dashboard uses the same stored [pricing and conversion rules](../../docs/pricing-currency.md) as the CLI reports. Store prices for the actual models in your usage with `set-price` and use `refresh-ecb-rates --db $db` or `set-rate` for EUR. The configured rates are a reference for API-equivalent estimates. Quota rows price recorded tokens in each active cycle. The provider total covers the selected display period and does not add overlapping quota windows. When that total is unavailable, the wide view can show a separately labeled active cycle. Hover over an estimate to see its sources or why a value is unavailable.
