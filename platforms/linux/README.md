# Linux usage displays

The GNOME Shell menu and KDE Plasma 6 plasmoid read the same SQLite database using `vibemeasure-cli snapshot --mode provider-cycles --text`. They display imported usage and active quota windows. An empty period or a missing database produces an explanation.

Install the CLI in the desktop session’s PATH and import data into the database you want to display. The default path is `$XDG_DATA_HOME/vibemeasure/vibemeasure.sqlite`, or `~/.local/share/vibemeasure/vibemeasure.sqlite` when `XDG_DATA_HOME` is unset. Set `VIBEMEASURE_DB` in the desktop session environment to use an existing database elsewhere.

```bash
cargo install --path apps/vibemeasure-cli --locked
db="${XDG_DATA_HOME:-$HOME/.local/share}/vibemeasure/vibemeasure.sqlite"
mkdir -p "$(dirname "$db")"
vibemeasure-cli import-codex --db "$db" --jsonl /path/to/rollout.jsonl
vibemeasure-cli snapshot --db "$db" --mode provider-cycles --text
```

## Notification settings

Install `notify-send` (Debian/Ubuntu package `libnotify-bin`) for desktop delivery and Python 3 with Tk (`python3-tk`) for the graphical editor. Select **Notification settings** in either widget. Enter the provider's subscription end date and the number of days to warn in advance, a quota usage percentage, or both. A blank threshold disables that warning.

You can also configure the same settings from the CLI. This example enables a reminder seven days before the supplied end date and a warning at 90% usage. Each save replaces the selected provider's settings.

```bash
vibemeasure-cli set-alert --db "$db" --tool codex --end-date 2027-01-31 --days-before 7 --used-percent 90
vibemeasure-cli alert-settings --db "$db"
```

## Install the widgets

For GNOME, pack and install the extension for a supported Shell version. Enable it from Extensions. Opening the menu refreshes its contents, with another read each minute while open.

```bash
gnome-extensions pack --extra-source=pegelbot-symbolic.svg platforms/linux/gnome/vibemeasure@chardonnay.example
gnome-extensions install --force vibemeasure@chardonnay.example.shell-extension.zip
```

For Plasma 6, install the plasmoid and add VibeMeasure from the widget picker. The plasmoid uses the Plasma5Support executable data engine to query the CLI once per minute.

```bash
kpackagetool6 --type Plasma/Applet --install platforms/linux/kde/org.vibemeasure.plasmoid
```
