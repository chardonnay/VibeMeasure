import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root
    preferredRepresentation: compactRepresentation
    property string summary: i18n("Loading usage…")

    // Keep the path in the process environment, including when it contains spaces.
    readonly property string databaseCommand: "db=\"${VIBEMEASURE_DB:-${XDG_DATA_HOME:-$HOME/.local/share}/vibemeasure/vibemeasure.sqlite}\"; "
    readonly property string alertCommand: databaseCommand +
        "[ -f \"$db\" ] || exit 0; exec vibemeasure-cli check-alerts --db \"$db\""
    readonly property string editorCommand: databaseCommand +
        "exec vibemeasure-cli alert-settings --edit --db \"$db\""
    readonly property string snapshotCommand: databaseCommand +
        "[ -f \"$db\" ] || exit 3; exec vibemeasure-cli snapshot --db \"$db\" --mode provider-cycles --text"

    Plasma5Support.DataSource {
        engine: "executable"
        connectedSources: [root.snapshotCommand]
        interval: 60000
        onNewData: function(source, data) {
            if (data["exit code"] === undefined)
                return
            switch (data["exit code"]) {
            case 0: root.summary = data.stdout.trim(); break
            case 3: root.summary = i18n("No usage database. Import usage with vibemeasure-cli."); break
            case 127: root.summary = i18n("Could not start vibemeasure-cli. Check the desktop session PATH."); break
            default: root.summary = i18n("Could not read the usage snapshot.")
            }
        }
    }

    Plasma5Support.DataSource {
        engine: "executable"
        connectedSources: [root.alertCommand]
        interval: 60000
        onNewData: function(source, data) {
            if (data["exit code"]) console.warn("VibeMeasure alerts:", data.stderr)
        }
    }

    Plasma5Support.DataSource {
        id: editor
        engine: "executable"
        onNewData: function(source, data) {
            if (data["exit code"] === undefined) return
            disconnectSource(source)
            if (data["exit code"]) root.summary = i18n("Could not open notification settings. Check that Python 3 and Tk are installed.")
        }
    }

    compactRepresentation: Controls.ToolButton {
        icon.source: Qt.resolvedUrl("../images/pegelbot-symbolic.svg")
        icon.color: palette.buttonText
        Accessible.name: i18n("VibeMeasure usage monitor")
        onClicked: root.expanded = !root.expanded
    }

    fullRepresentation: ColumnLayout {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 23
        Layout.preferredHeight: Kirigami.Units.gridUnit * 15
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Heading { text: i18n("Usage Monitor"); level: 3 }
        Controls.Button {
            text: i18n("Notification settings…")
            onClicked: editor.connectSource(root.editorCommand)
        }
        Controls.ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            Controls.Label {
                width: parent.width
                text: root.summary
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
            }
        }
    }
}
