import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root
    preferredRepresentation: compactRepresentation

    compactRepresentation: Kirigami.Icon {
        source: "office-chart-bar"
    }

    fullRepresentation: ColumnLayout {
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Heading {
            text: "Usage Monitor"
            level: 3
            Layout.fillWidth: true
        }

        Kirigami.InlineMessage {
            text: "Provider cycles load from verified snapshots. Unknown limits require manual setup."
            visible: true
            Layout.fillWidth: true
        }

        Controls.ProgressBar {
            from: 0
            to: 100
            value: 1
            Layout.fillWidth: true
        }

        Controls.Label {
            text: "Codex CLI · 5-Hour · Local token_count events"
            Layout.fillWidth: true
        }
    }
}
