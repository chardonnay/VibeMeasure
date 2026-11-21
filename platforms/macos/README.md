# macOS Native Shell

This folder contains the first native macOS implementation slice.

- `VibeMeasureMac` is a SwiftUI menu-bar utility using `MenuBarExtra`.
- During local development, `swift run VibeMeasureMac` also opens a normal Usage Monitor window so the app is visible even when the menu-bar icon is missed or hidden by macOS menu-bar spacing.
- The Xcode project specification embeds a WidgetKit extension that reads the snapshot published by the app.
- Real provider data must come from verified local adapters, official APIs, official documentation, or user-entered manual data. Unknown tariffs, quota windows, or schemas must stay unknown/manual rather than guessed.

Validation on macOS:

```bash
cd platforms/macos
swift build
swift run VibeMeasureMac
```

## Build the app with its widget

Use XcodeGen to generate the application and embedded WidgetKit extension targets.

```bash
cd platforms/macos
xcodegen generate
open VibeMeasure.xcodeproj
```

Set your development team on both targets. Set the project build setting `VIBEMEASURE_APP_GROUP` to an App Group authorized for both bundle identifiers. The host and extension use this setting in their entitlements and Info.plists. Run the VibeMeasureMac scheme, enable providers in Settings, then add VibeMeasure from the macOS widget gallery. The widget displays the published snapshot time and requests a refresh every five minutes. Launch at Login in the packaged app uses the macOS Login Items service. The standalone Swift Package Manager executable disables this setting.
