# Windows Native Shell

This folder contains the first WinUI 3 / Windows App SDK implementation slice.

- `VibeMeasure.Windows` is a native Windows desktop shell.
- Tray integration, notifications, autostart, and Windows Widgets provider packaging are planned platform work items after the core snapshot contract is stable.
- The UI text explicitly marks unknown/manual data; no quotas or prices are hardcoded.

Validation on Windows:

```powershell
cd platforms/windows/VibeMeasure.Windows
dotnet restore
dotnet build
dotnet run
```

This repository was initially scaffolded on macOS, where `dotnet` was not installed, so Windows build validation must run on Windows. The project targets .NET 10 LTS and Microsoft.WindowsAppSDK 2.1.3, both selected from current Microsoft/NuGet public release information at scaffold time.
