import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';
import {Extension, gettext as _} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

export default class VibeMeasureExtension extends Extension {
    enable() {
        this._indicator = new PanelMenu.Button(0.0, _('VibeMeasure'));
        this._indicator.add_child(new St.Label({text: 'VM', y_align: Clutter.ActorAlign.CENTER}));
        this._indicator.menu.addMenuItem(new PopupMenu.PopupMenuItem(_('Usage Monitor'), {reactive: false}));
        this._indicator.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._summary = new PopupMenu.PopupMenuItem(_('Loading usage…'), {reactive: false});
        this._summary.label.clutter_text.single_line_mode = false;
        this._indicator.menu.addMenuItem(this._summary);
        this._indicator.menu.connect('open-state-changed', (_menu, open) => {
            if (open)
                this._refresh();
        });
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 60, () => {
            if (this._indicator.menu.isOpen)
                this._refresh();
            return GLib.SOURCE_CONTINUE;
        });
        Main.panel.addToStatusArea(this.uuid, this._indicator);
    }

    _refresh() {
        if (this._process)
            return;
        const db = GLib.getenv('VIBEMEASURE_DB') ||
            GLib.build_filenamev([GLib.get_user_data_dir(), 'vibemeasure', 'vibemeasure.sqlite']);
        if (!GLib.file_test(db, GLib.FileTest.IS_REGULAR)) {
            this._summary.label.text = _('No usage database. Import usage with vibemeasure-cli.');
            return;
        }
        try {
            const process = Gio.Subprocess.new(
                ['vibemeasure-cli', 'snapshot', '--db', db, '--mode', 'provider-cycles', '--text'],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
            this._process = process;
            process.communicate_utf8_async(null, null, (_source, result) => {
                if (this._process !== process)
                    return;
                this._process = null;
                try {
                    const [, stdout] = process.communicate_utf8_finish(result);
                    this._summary.label.text = process.get_successful()
                        ? stdout.trim() : _('Could not read the usage database.');
                } catch {
                    this._summary.label.text = _('Could not read the usage snapshot.');
                }
            });
        } catch {
            this._summary.label.text = _('Could not start vibemeasure-cli. Check the desktop session PATH.');
        }
    }

    disable() {
        GLib.Source.remove(this._timer);
        this._process?.force_exit();
        this._process = null;
        this._indicator.destroy();
        this._indicator = null;
        this._summary = null;
    }
}
