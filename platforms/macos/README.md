# macOS Native Shell

This folder contains the first native macOS implementation slice.

- `VibeMeasureMac` is a SwiftUI menu-bar utility using `MenuBarExtra`.
- During local development, `swift run VibeMeasureMac` also opens a normal Usage Monitor window so the app is visible even when the menu-bar icon is missed or hidden by macOS menu-bar spacing.
- `Widget` contains the WidgetKit source intended for an Xcode widget extension target.
- Real provider data must come from verified local adapters, official APIs, official documentation, or user-entered manual data. Unknown tariffs, quota windows, or schemas must stay unknown/manual rather than guessed.

Validation on macOS:

```bash
cd platforms/macos
swift build
swift run VibeMeasureMac
```

Widget validation requires creating/attaching the WidgetKit extension in Xcode because Swift Package Manager does not package macOS widgets by itself.
