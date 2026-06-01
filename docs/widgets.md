# Widgets

Widgets show a compact snapshot of selected provider windows. They must not perform privileged parsing or API calls directly. Native apps or background services write sanitized snapshots; widgets read those snapshots.

## User Configuration

The user can choose what appears in the widget:

- Providers.
- Display mode.
- Window types.
- Cost visibility.
- Currency.
- Theme mode: system, light, or dark.

## Platform Notes

- macOS: WidgetKit supports system widgets but requires an Xcode extension target.
- Windows: Widgets use Windows App SDK provider packaging or PWA-backed widgets.
- GNOME: Shell extensions provide panel/status UI; distribution varies by GNOME version.
- KDE: Plasma widgets are packaged as plasmoids.

The widget design should remain visually similar across platforms, but each platform uses its native widget API.

