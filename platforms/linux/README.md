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

For GNOME, pack and install the extension for a supported Shell version. Enable it from Extensions. Opening the menu refreshes its contents, with another read each minute while open.

```bash
gnome-extensions pack --extra-source=pegelbot-symbolic.svg platforms/linux/gnome/vibemeasure@chardonnay.example
gnome-extensions install --force vibemeasure@chardonnay.example.shell-extension.zip
```

For Plasma 6, install the plasmoid and add VibeMeasure from the widget picker. The plasmoid uses the Plasma5Support executable data engine to query the CLI once per minute.

```bash
kpackagetool6 --type Plasma/Applet --install platforms/linux/kde/org.vibemeasure.plasmoid
```
