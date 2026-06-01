# Linux Native Shell And Widgets

Linux support is split by desktop environment because widgets are not a single cross-desktop API.

- GNOME: `gnome/vibemeasure@chardonnay.example` is a GNOME Shell extension starter.
- KDE Plasma: `kde/org.vibemeasure.plasmoid` is a Plasma widget starter.
- A GTK/libadwaita tray/status app will consume the same shared core snapshot contract.

Validation examples:

```bash
gnome-extensions pack platforms/linux/gnome/vibemeasure@chardonnay.example
kpackagetool6 --type Plasma/Applet --install platforms/linux/kde/org.vibemeasure.plasmoid
```

The initial implementation intentionally displays only verified/local or manual-status text. It does not invent provider quotas, prices, or reset windows.

