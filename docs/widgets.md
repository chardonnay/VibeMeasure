# Widgets and desktop displays

## macOS

The signed menu-bar app publishes the providers enabled in Settings to its WidgetKit extension. The app writes `widget.json` atomically in the shared App Group and requests a timeline reload. The widget reads only this snapshot, shows the snapshot age, and requests another refresh after five minutes. All built-in providers start disabled.

The package specification in [platforms/macos/project.yml](../platforms/macos/project.yml) builds the app and embeds the extension. See the [macOS build instructions](../platforms/macos/README.md) for signing and setup.

## GNOME, KDE and Windows

The GNOME Shell menu, Plasma plasmoid and WinUI desktop window call `vibemeasure-cli snapshot --text` against an existing SQLite database. Imported usage and active quota windows appear automatically. Empty periods and read failures have distinct states. The Windows app supports each CLI comparison period, and the Linux widgets use provider cycles. Data refreshes when the database is queried again. Import new usage into that database to update what these surfaces can show.

See the [Linux](../platforms/linux/README.md) and [Windows](../platforms/windows/README.md) instructions for installation and database selection. A packaged Windows Widgets-board provider remains future work.
