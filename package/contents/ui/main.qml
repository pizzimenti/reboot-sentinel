import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // Panel widget (NOT a system-tray item — the tray's plugin registry
    // refused to place user-installed plasmoids on this box; see README).
    // Sits directly in the panel like the pingmonitor/wifimimo family and
    // collapses to zero width when no reboot is pending. The compact icon
    // is the whole UI: clicking launches the reboot prompt directly.
    preferredRepresentation: compactRepresentation

    // Lines describing why a reboot is pending. Empty array = no reboot
    // needed = the widget collapses to zero width.
    property var pendingItems: []
    readonly property bool rebootNeeded: pendingItems.length > 0

    // Two independent signals, both cleared by an actual reboot:
    //  1. /run/reboot-required — written by the pacman hook (tmpfs, so a
    //     reboot wipes it with no cleanup path).
    //  2. kernel mismatch — the running kernel's modules dir is gone,
    //     which catches kernel swaps the hook's Target list missed.
    // ~/.cache/reboot-sentinel-test is a no-root test hook: echo anything
    // into it to make the icon appear, delete it to make the icon go away.
    readonly property string checkCommand: 'cat /run/reboot-required "$HOME/.cache/reboot-sentinel-test" 2>/dev/null; r="$(uname -r)"; [ -e "/usr/lib/modules/$r/kernel" ] || echo "kernel: modules for running $r are gone"'

    // org.kde.LogoutPrompt is DBus-activatable, so this works even though
    // no prompt process is running beforehand.
    readonly property string promptCommand: "qdbus6 org.kde.LogoutPrompt /LogoutPrompt org.kde.LogoutPrompt.promptReboot"

    Plasmoid.status: rebootNeeded ? PlasmaCore.Types.ActiveStatus
                                  : PlasmaCore.Types.PassiveStatus
    Plasmoid.icon: "system-reboot-symbolic"

    toolTipMainText: i18n("Reboot required")
    toolTipSubText: pendingItems.join("\n")

    Plasma5Support.DataSource {
        id: exec
        engine: "executable"
        interval: 0
        onNewData: (sourceName, sourceData) => {
            if (sourceName === root.checkCommand) {
                const out = (sourceData["stdout"] || "").trim();
                root.pendingItems = out.length ? out.split("\n") : [];
            }
            disconnectSource(sourceName);
        }
    }

    Timer {
        interval: 30000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: exec.connectSource(root.checkCommand)
    }

    compactRepresentation: MouseArea {
        // Sizing mirrors the pingmonitor/wifimimo family pattern, with one
        // twist: every horizontal (or vertical) dimension collapses to 0
        // while no reboot is pending, so the idle widget occupies no panel
        // space at all. Note: Plasmoid.* attached properties are only
        // resolvable in the object's own scope (root.Plasmoid.icon silently
        // evaluates undefined → blank icon).
        readonly property bool verticalPanel: Plasmoid.formFactor === PlasmaCore.Types.Vertical
        readonly property bool shown: root.rebootNeeded
        visible: shown
        acceptedButtons: Qt.LeftButton
        hoverEnabled: true
        Layout.fillWidth: verticalPanel && shown
        Layout.fillHeight: !verticalPanel && shown
        Layout.minimumWidth: !shown ? 0 : (verticalPanel ? Kirigami.Units.iconSizes.small : height)
        Layout.minimumHeight: !shown ? 0 : (verticalPanel ? width : Kirigami.Units.iconSizes.small)
        Layout.preferredWidth: !shown ? 0 : (verticalPanel ? Kirigami.Units.iconSizes.smallMedium : height)
        Layout.preferredHeight: !shown ? 0 : (verticalPanel ? width : Kirigami.Units.iconSizes.smallMedium)
        Layout.maximumWidth: shown || verticalPanel ? Number.POSITIVE_INFINITY : 0
        Layout.maximumHeight: shown || !verticalPanel ? Number.POSITIVE_INFINITY : 0
        onClicked: exec.connectSource(root.promptCommand)

        Kirigami.Icon {
            anchors.fill: parent
            source: "system-reboot-symbolic"
            active: parent.containsMouse
        }
    }

    // Never shown (preferredRepresentation pins the compact icon and clicks
    // bypass expansion), but AppletQuickItem needs a fullRepresentation to
    // exist for its representation setup — without one the compact item is
    // silently never created and the widget renders as empty space.
    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 12
        Layout.minimumHeight: Kirigami.Units.gridUnit * 6

        Column {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            Text {
                text: root.rebootNeeded ? i18n("Reboot required by:") : i18n("No reboot pending")
                color: Kirigami.Theme.textColor
                font.bold: true
            }
            Repeater {
                model: root.pendingItems
                delegate: Text {
                    required property string modelData
                    text: "• " + modelData
                    color: Kirigami.Theme.textColor
                }
            }
        }
    }
}
