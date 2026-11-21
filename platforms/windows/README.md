# Windows usage monitor

The WinUI 3 desktop app shows imported token totals and active quota windows from a VibeMeasure database. Selecting a display mode, clicking Refresh, or leaving the app open for a minute requests a new snapshot. The app looks for `vibemeasure-cli.exe` beside the executable or on PATH.

The default database is `%LOCALAPPDATA%\VibeMeasure\vibemeasure.sqlite`. Set `VIBEMEASURE_DB` before launching the app to select an existing database. To try a local Codex session from the repository root in PowerShell:

```powershell
cargo install --path apps/vibemeasure-cli --locked
$db = Join-Path $env:LOCALAPPDATA "VibeMeasure\vibemeasure.sqlite"
New-Item -ItemType Directory -Force (Split-Path $db) | Out-Null
vibemeasure-cli import-codex --db $db --jsonl C:\path\to\rollout.jsonl
dotnet run --project platforms/windows/VibeMeasure.Windows
```

Build on Windows with the .NET 10 SDK and the WinUI/Windows App SDK development tools. This project produces an unpackaged desktop application.
