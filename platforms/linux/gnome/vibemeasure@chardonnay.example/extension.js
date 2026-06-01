import Clutter from 'gi://Clutter';
import St from 'gi://St';
import {Extension, gettext as _} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

export default class VibeMeasureExtension extends Extension {
    enable() {
        this._indicator = new PanelMenu.Button(0.0, _('VibeMeasure'));
        const label = new St.Label({
            text: 'VM',
            y_align: Clutter.ActorAlign.CENTER,
        });
        this._indicator.add_child(label);

        this._indicator.menu.addMenuItem(new PopupMenu.PopupMenuItem(_('Usage Monitor')));
        this._indicator.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._indicator.menu.addMenuItem(new PopupMenu.PopupMenuItem(_('Provider cycles: load verified snapshot')));
        this._indicator.menu.addMenuItem(new PopupMenu.PopupMenuItem(_('Unknown limits require manual setup')));

        Main.panel.addToStatusArea(this.uuid, this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
