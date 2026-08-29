import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "logic.js" as Logic

Item {
    id: root

    property var shell: null
    property var manifest: null

    property bool open: false
    property bool openedViaKeyboard: false
    property var groups: []
    property var flat: []
    property int selected: 0

    // In-memory icon path cache for instant O(1) lookups
    property var iconCache: ({})

    // Multi-colour variants for org.omarchy.agent (Buuf robot)
    readonly property int agentVariantCount: 8

    function agentIconUrlFor(addr) {
        let h = 0;
        const s = String(addr || "");
        for (let i = 0; i < s.length; i++) h = ((h * 31 + s.charCodeAt(i)) >>> 0);
        return Qt.resolvedUrl("assets/omarchy-agent-" + (h % agentVariantCount) + ".png");
    }

    // Comprehensive icon lookup cascade with memoization
    function iconPathFor(cls, title, addr) {
        if (!cls) return Quickshell.iconPath("application-x-executable");
        if (cls.toLowerCase() === "org.omarchy.agent") {
            return agentIconUrlFor(addr);
        }

        const cacheKey = cls + "::" + (title || "");
        if (root.iconCache[cacheKey]) {
            return root.iconCache[cacheKey];
        }

        let resolved = "";
        const clsLower = cls.toLowerCase();

        for (const v of [cls, clsLower, cls.replace(/-/g, ""), cls.split(".")[0]]) {
            if (!v) continue;
            const e = DesktopEntries.byId(v);
            if (e && e.icon) {
                resolved = Quickshell.iconPath(e.icon, "application-x-executable");
                break;
            }
        }

        if (!resolved) {
            const all = DesktopEntries.applications.values;
            for (const e of all) {
                if (e.startupClass && e.startupClass.toLowerCase() === clsLower && e.icon) {
                    resolved = Quickshell.iconPath(e.icon, "application-x-executable");
                    break;
                }
            }
            if (!resolved) {
                const titleLower = (title || "").toLowerCase();
                if (titleLower) {
                    for (const e of all) {
                        const n = (e.name || "").toLowerCase();
                        if (n && titleLower.includes(n) && e.icon) {
                            resolved = Quickshell.iconPath(e.icon, "application-x-executable");
                            break;
                        }
                    }
                }
            }
        }

        if (!resolved) {
            for (const v of [cls, clsLower, cls.split("-")[0], cls.split(".").pop()]) {
                if (!v) continue;
                const p = Quickshell.iconPath(v, true);
                if (p) {
                    resolved = p;
                    break;
                }
            }
        }

        if (!resolved) {
            resolved = Quickshell.iconPath("application-x-executable");
        }

        root.iconCache[cacheKey] = resolved;
        return resolved;
    }

    function next() {
        if (flat.length) selected = (selected + 1) % flat.length;
    }

    function prev() {
        if (flat.length) selected = (selected + flat.length - 1) % flat.length;
    }

    function requestOpen() {
        if (root.open || clientsProc.running) {
            hideTimer.stop();
            return;
        }
        hideTimer.stop();
        clientsProc.running = true;
    }

    function scheduleClose() {
        if (!root.openedViaKeyboard) {
            hideTimer.restart();
        }
    }

    function focusWindow(addr, groupIdx) {
        hideTimer.stop();
        root.open = false;
        root.openedViaKeyboard = false;
        if (!addr) return;
        if (groupIdx > 0) {
            Hyprland.dispatch('hl.dsp.group.active({ window = "address:' + addr + '", index = ' + groupIdx + ' })');
        }
        Hyprland.dispatch('hl.dsp.focus({ window = "address:' + addr + '" })');
    }

    // IPC handler for external control and screenshot capture
    IpcHandler {
        target: "bottom-launcher"
        function open(): string {
            root.openedViaKeyboard = false;
            root.requestOpen();
            return "ok";
        }
        function close(): string {
            root.open = false;
            return "ok";
        }
        function toggle(): string {
            if (root.open) root.open = false;
            else {
                root.openedViaKeyboard = false;
                root.requestOpen();
            }
            return "ok";
        }
        function ping(): string {
            return "ok";
        }
    }

    // Global Shortcuts for Alt+Tab / Alt+Shift+Tab
    GlobalShortcut {
        appid: "omarchy-bottom-launcher"
        name: "next"
        onPressed: {
            if (root.open) {
                root.next();
                if (root.openedViaKeyboard) modCheckTimer.restart();
            } else {
                root.openedViaKeyboard = true;
                root.requestOpen();
            }
        }
    }

    GlobalShortcut {
        appid: "omarchy-bottom-launcher"
        name: "prev"
        onPressed: {
            if (root.open) {
                root.prev();
                if (root.openedViaKeyboard) modCheckTimer.restart();
            } else {
                root.openedViaKeyboard = true;
                root.requestOpen();
            }
        }
    }

    // Active modifier polling to detect when Alt/Super is released
    Timer {
        id: modCheckTimer
        interval: 100
        repeat: true
        running: root.open && root.openedViaKeyboard
        onTriggered: {
            modCheck.running = true;
        }
    }

    Process {
        id: modCheck
        command: ["hyprctl", "eval",
            'error(tostring(hl.is_key_down("Alt_L") or hl.is_key_down("Alt_R") or hl.is_key_down("Super_L") or hl.is_key_down("Super_R")))']
        stdout: StdioCollector {
            onStreamFinished: {
                if (!root.open || !root.openedViaKeyboard) return;
                if (!text.trim().endsWith("true")) {
                    if (root.flat.length > 0 && root.selected < root.flat.length) {
                        const target = root.flat[root.selected];
                        root.focusWindow(target.addr, target.groupIdx);
                    } else {
                        root.open = false;
                        root.openedViaKeyboard = false;
                    }
                }
            }
        }
    }

    Timer {
        id: hideTimer
        interval: 400
        repeat: false
        onTriggered: {
            root.open = false;
            root.openedViaKeyboard = false;
        }
    }

    Process {
        id: clientsProc
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector {
            onStreamFinished: {
                let clients = [];
                try { clients = JSON.parse(text); } catch (e) {
                    return;
                }
                const activeWs = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1;
                const groups = Logic.groupClients(clients, activeWs);
                const flat = Logic.flatten(groups);
                if (!flat.length) {
                    root.open = false;
                    root.openedViaKeyboard = false;
                    return;
                }
                root.groups = groups;
                root.flat = flat;
                if (root.openedViaKeyboard) {
                    root.selected = Logic.initialSelection(flat);
                } else if (root.selected >= flat.length) {
                    root.selected = 0;
                }
                root.open = true;
            }
        }
    }

    PanelWindow {
        id: panelWindow
        visible: true

        WlrLayershell.namespace: "omarchy-bottom-launcher"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        // Keep surface click-through everywhere except over container
        mask: Region {
            item: container
        }

        // --- Master Container ---
        Item {
            id: container
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            width: root.open
                ? Math.max(card.width + Style.space(32), Math.round(parent.width / 3))
                : Math.round(parent.width / 3)
            height: root.open
                ? (card.height + Style.space(36))
                : Style.space(16)

            HoverHandler {
                id: containerHover
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onHoveredChanged: {
                    if (hovered) {
                        hideTimer.stop();
                        if (!root.open) {
                            root.openedViaKeyboard = false;
                            root.requestOpen();
                        }
                    } else {
                        root.scheduleClose();
                    }
                }
            }

            // --- Rising Floating Launcher Card ---
            Rectangle {
                id: card
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: root.open ? Style.space(16) : -height - Style.space(32)
                opacity: root.open ? 1.0 : 0.0

                Behavior on anchors.bottomMargin {
                    NumberAnimation {
                        duration: 220
                        easing.type: Easing.OutCubic
                    }
                }

                Behavior on opacity {
                    NumberAnimation {
                        duration: 180
                    }
                }

                width: Math.max(column.implicitWidth + Style.space(32), Style.space(320))
                height: column.implicitHeight + Style.space(24)

                color: Util.alpha(Color.background, 0.96)
                border.color: Color.accent
                border.width: Style.space(2)
                radius: 0

                Column {
                    id: column
                    anchors.centerIn: parent
                    spacing: Style.space(8)

                    Row {
                        id: groupsRow
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Style.space(4)

                        Repeater {
                            model: root.groups

                            Row {
                                id: wsRow
                                required property var modelData
                                required property int index
                                spacing: Style.space(4)

                                // Workspace separator line
                                Rectangle {
                                    visible: index > 0
                                    width: 1
                                    height: wsCol.height - Style.space(12)
                                    color: Qt.alpha(Color.foreground, 0.2)
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Column {
                                    id: wsCol
                                    spacing: Style.space(4)
                                    leftPadding: index > 0 ? Style.space(12) : Style.space(4)
                                    rightPadding: Style.space(8)

                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: modelData.name || ""
                                        color: Qt.alpha(Color.foreground, 0.5)
                                        font.family: Style.font.family
                                        font.pixelSize: Style.font.caption
                                        font.bold: true
                                    }

                                    Row {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        spacing: Style.space(6)

                                        Repeater {
                                            model: modelData.entries

                                            Rectangle {
                                                id: tile
                                                required property var modelData

                                                property bool isSelected: root.selected === modelData.flatIdx

                                                width: Style.space(72)
                                                height: Style.space(72)
                                                radius: 0
                                                color: isSelected
                                                    ? Qt.alpha(Color.accent, tileHover.hovered ? 0.35 : 0.2)
                                                    : (tileHover.hovered ? Qt.alpha(Color.foreground, 0.1) : "transparent")
                                                border.width: isSelected ? 1 : 0
                                                border.color: Qt.alpha(Color.accent, 0.6)

                                                Image {
                                                    id: icon
                                                    anchors.centerIn: parent
                                                    width: Style.space(48)
                                                    height: Style.space(48)
                                                    sourceSize.width: Style.space(48)
                                                    sourceSize.height: Style.space(48)
                                                    fillMode: Image.PreserveAspectFit
                                                    source: root.iconPathFor(tile.modelData.cls, tile.modelData.title, tile.modelData.addr)
                                                }

                                                HoverHandler {
                                                    id: tileHover
                                                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                                    onHoveredChanged: {
                                                        if (hovered) {
                                                            hideTimer.stop();
                                                            root.selected = tile.modelData.flatIdx;
                                                        }
                                                    }
                                                }

                                                TapHandler {
                                                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                                    onTapped: {
                                                        root.focusWindow(tile.modelData.addr, tile.modelData.groupIdx);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Window Title / Description readout
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.min(Math.max(groupsRow.width, Style.space(300)), Style.space(700))
                        height: Style.space(24)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        text: (root.flat.length > 0 && root.selected < root.flat.length)
                            ? (root.flat[root.selected].title && root.flat[root.selected].title !== "-" ? root.flat[root.selected].title : root.flat[root.selected].cls)
                            : ""
                        color: Color.foreground
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }
}
