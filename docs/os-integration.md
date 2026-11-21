# OS Integration

The macOS menu-bar app publishes local measurements to its WidgetKit extension. The Windows desktop window and the GNOME and KDE widgets read snapshots from the CLI database.

## macOS

The macOS app uses SwiftUI `MenuBarExtra`. The XcodeGen specification packages the WidgetKit extension with its host app. Both targets use a configurable shared App Group.

Official references:

- <https://developer.apple.com/documentation/swiftui/menubarextra>
- <https://developer.apple.com/documentation/widgetkit>

## Windows

The WinUI 3 desktop window uses .NET 10 and Windows App SDK. It reads current and historical periods through the Rust CLI. The Windows Widgets board requires a separate packaged provider.

Official reference:

- <https://learn.microsoft.com/en-us/dotnet/core/releases-and-support>
- <https://www.nuget.org/packages/Microsoft.WindowsAppSDK/>
- <https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widget-providers>

## Linux

Linux widgets are desktop-environment specific.

- The GNOME Shell extension queries the database when its menu opens.
- The KDE Plasma widget refreshes its usage snapshot once a minute.
- GTK/libadwaita remains the native shell target for the main Linux app.

Official references:

- <https://help.gnome.org/admin/system-admin-guide/stable/extensions.html.en>
- <https://develop.kde.org/docs/plasma/widget/>
