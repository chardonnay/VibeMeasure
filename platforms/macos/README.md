# macOS Native Shell

This folder contains the first native macOS implementation slice.

- `VibeMeasureMac` is a SwiftUI menu-bar utility using `MenuBarExtra`.
- `Widget` contains the WidgetKit source intended for an Xcode widget extension target.
- Real provider data must come from the shared core snapshot file or future FFI bridge; the Swift preview values are explicit UI placeholders, not tariff or quota facts.

Validation on macOS:

```bash
cd platforms/macos
swift build
swift run VibeMeasureMac
```

Widget validation requires creating/attaching the WidgetKit extension in Xcode because Swift Package Manager does not package macOS widgets by itself.

