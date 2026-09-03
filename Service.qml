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

    // In-memory icon path cache for instant O(1) lookups.
    // Bounded: a stream of uniquely titled windows must not grow shared-shell
    // memory indefinitely (FIFO eviction, see cacheIcon).
    property var iconCache: ({})
    readonly property int iconCacheLimit: 128

    // Multi-colour variants for org.omarchy.agent (Buuf robot)
    readonly property int agentVariantCount: 8

    // High-contrast palette order over the 8 variants. Linear hue indices
    // cluster the three green-family variants (5 olive, 6 forest, 7 teal)
    // adjacently; this order maximizes hue separation between consecutive
    // ranks: blue, crimson, forest, purple, orange, magenta, teal, olive.
    readonly property var agentPalette: [0, 3, 6, 1, 4, 2, 7, 5]

    // Agent family of a window: "opencode", "hermes", or "" (not an agent).
    // Must mirror the branch order of iconPathFor().
    function agentFamily(cls, title) {
        const c = String(cls || "").toLowerCase();
        if (c === "org.omarchy.agent.hermes") return "hermes";
        if (c === "org.omarchy.agent") return "opencode";
        if (String(title || "").toLowerCase().includes("hermes")) return "hermes";
        return "";
    }

    // Collision-free variant selection. Instead of hashing each window's
    // address in isolation (31 ≡ -1 mod 8 collapses the hash to an
    // alternating ASCII sum, which clusters on Hyprland's uniform heap
    // addresses), rank the window among all currently listed windows of the
    // same family by address and walk the high-contrast palette. Ranks are
    // distinct per open window, so with <= 8 agent windows every colour is
    // unique. Sorting by address (stable for a window's lifetime) keeps
    // colours put across focus changes and re-collections. Beyond 8 windows
    // the palette wraps.
    function agentVariantIndex(cls, title, addr) {
        const family = agentFamily(cls, title);
        if (!family) return 0;
        const peers = [];
        for (const e of root.flat) {
            if (e.addr && agentFamily(e.cls, e.title) === family) peers.push(e.addr);
        }
        peers.sort();
        let rank = peers.indexOf(String(addr || ""));
        if (rank < 0) rank = 0;
        return root.agentPalette[rank % root.agentPalette.length];
    }

    function agentIconUrlFor(cls, title, addr) {
        return Qt.resolvedUrl("assets/omarchy-agent-" + agentVariantIndex(cls, title, addr) + ".png");
    }

    // Hermes agent (Nous Research) variants share the same collision-free
    // ranking, scoped to hermes-family windows.
    function hermesIconUrlFor(cls, title, addr) {
        return Qt.resolvedUrl("assets/omarchy-agent-hermes-" + agentVariantIndex(cls, title, addr) + ".png");
    }

    // Bounded cache write with FIFO eviction (keys are class::title pairs;
    // insertion-ordered, so Object.keys() yields oldest-first eviction order)
    function cacheIcon(key, url) {
        const keys = Object.keys(root.iconCache);
        if (keys.length >= root.iconCacheLimit) {
            const evict = Math.max(1, Math.floor(root.iconCacheLimit / 4));
            for (let i = 0; i < evict; i++) delete root.iconCache[keys[i]];
        }
        root.iconCache[key] = url;
    }

    // Comprehensive icon lookup cascade with memoization
    function iconPathFor(cls, title, addr) {
        if (!cls) return Quickshell.iconPath("application-x-executable");
        if (cls.toLowerCase() === "org.omarchy.agent.hermes") {
            return hermesIconUrlFor(cls, title, addr);
        }
        if (cls.toLowerCase() === "org.omarchy.agent") {
            return agentIconUrlFor(cls, title, addr);
        }

        const titleLower = (title || "").toLowerCase();
        if (titleLower.includes("hermes")) {
            return hermesIconUrlFor(cls, title, addr);
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

        root.cacheIcon(cacheKey, resolved);
        return resolved;
    }

    function next() {
        if (flat.length) selected = (selected + 1) % flat.length;
    }

    function prev() {
        if (flat.length) selected = (selected + flat.length - 1) % flat.length;
    }

    function requestOpen() {
        if (root.open) {
            hideTimer.stop();
            return;
        }
        hideTimer.stop();
        if (clientsProc.running) {
            // Supersede an in-flight collection: reap the whole process
            // group (TERM -> KILL), then restart once it has exited.
            root._clientsPending = true;
            root.reapProcessGroup(clientsProc);
            return;
        }
        clientsDeadline.restart();
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
        // Statement-of-intent hardening (upstream review suggestion): only
        // dispatch well-formed Hyprland addresses into Lua.
        if (!/^0x[0-9a-fA-F]+$/.test(addr)) return;
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

    // ------------------------------------------------------------------
    // Bounded process supervision
    //
    // Both external producers (modifier probe and client list) are launched
    // under /usr/bin/setsid, so each tracked child becomes the leader of an
    // isolated process group (PGID == processId). Every binary is referenced
    // by fixed absolute path (no PATH lookup), and each producer runs a
    // pipeline entirely inside the supervised group: coreutils timeout
    // enforces the OS-level deadline with TERM -> KILL escalation (-k), and
    // /usr/bin/head -c enforces the byte cap BEFORE any byte reaches QML,
    // so the parser can never buffer more than the allowance. The limiter
    // allowance is cap + 1: a payload that still exceeds the cap on arrival
    // is EOF-at-limit (truncated) and fails closed. The shared supervisor
    // below reaps the FULL process group (TERM, short grace, then KILL) on
    // deadline, supersession, and component destruction.
    // ------------------------------------------------------------------
    readonly property string exeSh: "/bin/sh"
    readonly property string exeSetsid: "/usr/bin/setsid"
    readonly property string exeTimeout: "/usr/bin/timeout"
    readonly property string exeHyprctl: "/usr/bin/hyprctl"
    readonly property int clientsDeadlineSec: 5
    readonly property int modCheckDeadlineSec: 2

    // Modifier probe expression (contains only double quotes, so it is
    // safe to single-quote inside the sh -c scripts below)
    readonly property string modProbeExpr: 'error(tostring(hl.is_key_down("Alt_L") or hl.is_key_down("Alt_R") or hl.is_key_down("Super_L") or hl.is_key_down("Super_R")))'

    // Process-group leader id of a running producer (0 when not running)
    function groupLeaderId(proc) {
        const pid = proc.processId;
        return (typeof pid === "number" && pid > 0) ? Math.floor(pid) : 0;
    }

    // The one bounded supervisor: TERM -> KILL the whole process group
    function reapProcessGroup(proc) {
        const pgid = root.groupLeaderId(proc);
        proc.running = false;
        if (pgid <= 0) return;
        if (groupReaper.running) {
            // Reaps are short (~0.3 s); queue overlapping requests.
            if (root._reapQueue.length < 4) root._reapQueue.push(pgid);
        } else {
            root.startGroupReap(pgid);
        }
    }

    function startGroupReap(pgid) {
        groupReaper.command = [
            root.exeTimeout, "-k", "1", "2", root.exeSh, "-c",
            "kill -TERM -- -" + pgid + " 2>/dev/null; /bin/sleep 0.3; kill -KILL -- -" + pgid + " 2>/dev/null"
        ];
        groupReaper.running = true;
    }

    // Self-bounded, silent reaper (its own timeout -k backstop)
    Process {
        id: groupReaper
        running: false
        onExited: {
            if (root._reapQueue.length > 0) root.startGroupReap(root._reapQueue.shift());
        }
    }

    // Active modifier polling to detect when Alt/Super is released
    Timer {
        id: modCheckTimer
        interval: 100
        repeat: true
        running: root.open && root.openedViaKeyboard
        onTriggered: {
            if (!modCheck.running) modCheck.running = true; // supersession guard
        }
    }

    // Modifier probe: setsid'd supervised pipeline (timeout -> sh ->
    // hyprctl | head -c). The byte limiter runs inside the same process
    // group before QML receives any data; allowance is cap + 1 so any
    // truncation is detected and fails closed.
    Process {
        id: modCheck
        command: [
            root.exeSetsid, root.exeTimeout, "-k", "1", String(root.modCheckDeadlineSec),
            root.exeSh, "-c",
            "/usr/bin/hyprctl eval '" + root.modProbeExpr + "' 2>/dev/null | /usr/bin/head -c " + (root.modMaxBytes + 1)
        ]
        stdout: SplitParser {
            onRead: function(line) {
                const s = String(line || "");
                const allowance = root.modMaxBytes + 1;
                if (root._modBuffer.length + s.length > allowance) {
                    root._modTruncated = true;
                    root._modBuffer += s.slice(0, Math.max(0, allowance - root._modBuffer.length));
                } else {
                    root._modBuffer += s;
                }
            }
        }
        onStarted: {
            root._modBuffer = "";
            root._modTruncated = false;
            modCheckDeadline.restart();
        }
        onExited: {
            modCheckDeadline.stop();
            const out = root._modBuffer;
            const truncated = root._modTruncated || out.length > root.modMaxBytes;
            root._modBuffer = "";
            root._modTruncated = false;
            if (truncated) return; // fail closed: never act on partial data
            if (!root.open || !root.openedViaKeyboard) return;
            if (!out.trim().endsWith("true")) {
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

    // QML-side deadline backstop for the modifier probe (the OS-level
    // timeout inside the producer is primary; this reaps the group if even
    // that fails to terminate the tree)
    Timer {
        id: modCheckDeadline
        interval: (root.modCheckDeadlineSec + 2) * 1000
        repeat: false
        onTriggered: {
            if (modCheck.running) root.reapProcessGroup(modCheck);
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

    // Security and DoS ceilings for compositor- and client-derived data.
    // The in-group limiters allow cap + 1 bytes; receipt above the cap
    // marks the payload as truncated and it is never parsed.
    readonly property int maxClientsBytes: 1048576 // 1 MiB response cap
    readonly property int modMaxBytes: 512 // hyprctl eval error() wraps the true/false verdict in a verbose "error: [string ...]:N:" message; cap sits well above that fixed-format wrapper
    property string _clientsBuffer: ""
    property bool _clientsTruncated: false
    property bool _clientsPending: false
    property string _modBuffer: ""
    property bool _modTruncated: false
    property var _reapQueue: []

    // Parse a bounded clients payload and open the switcher
    function collectClients(raw) {
        let clients = [];
        try { clients = JSON.parse(String(raw || "").trim()); } catch (e) {
            return;
        }
        if (!Array.isArray(clients)) return;
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

    // Bounded client list: setsid'd supervised pipeline (timeout -> sh ->
    // hyprctl | head -c). The limiter caps the stream at maxClientsBytes + 1
    // inside the supervised group before QML receives it; a payload above
    // the cap is EOF-at-limit (truncated) and fails closed. Concatenated
    // SplitParser lines reconstruct the JSON (newlines are JSON whitespace
    // only ever appear outside strings in hyprctl output).
    Process {
        id: clientsProc
        command: [
            root.exeSetsid, root.exeTimeout, "-k", "1", String(root.clientsDeadlineSec),
            root.exeSh, "-c",
            "/usr/bin/hyprctl -j clients 2>/dev/null | /usr/bin/head -c " + (root.maxClientsBytes + 1)
        ]
        stdout: SplitParser {
            onRead: function(line) {
                const s = String(line || "");
                const allowance = root.maxClientsBytes + 1;
                if (root._clientsBuffer.length + s.length > allowance) {
                    root._clientsTruncated = true;
                    root._clientsBuffer += s.slice(0, Math.max(0, allowance - root._clientsBuffer.length));
                } else {
                    root._clientsBuffer += s;
                }
            }
        }
        onStarted: {
            root._clientsBuffer = "";
            root._clientsTruncated = false;
        }
        onExited: {
            clientsDeadline.stop();
            const out = root._clientsBuffer;
            const truncated = root._clientsTruncated || out.length > root.maxClientsBytes;
            root._clientsBuffer = "";
            root._clientsTruncated = false;
            if (!truncated && out.length > 0) root.collectClients(out);
            if (root._clientsPending) {
                root._clientsPending = false;
                clientsDeadline.restart();
                clientsProc.running = true;
            }
        }
    }

    // QML-side deadline backstop for the client list producer
    Timer {
        id: clientsDeadline
        interval: (root.clientsDeadlineSec + 2) * 1000
        repeat: false
        onTriggered: {
            if (clientsProc.running) root.reapProcessGroup(clientsProc);
        }
    }

    // Reap both producer process groups (TERM -> KILL) when the service is
    // destroyed. Additional backstops: Quickshell SIGTERMs direct children
    // on teardown, and each producer's own OS timeout (-k) escalates to
    // KILL even if this reaper cannot complete during destruction.
    Component.onDestruction: {
        clientsDeadline.stop();
        modCheckDeadline.stop();
        root._clientsPending = false;
        root._reapQueue = [];
        root.reapProcessGroup(clientsProc);
        root.reapProcessGroup(modCheck);
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
                                        textFormat: Text.PlainText
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
                        textFormat: Text.PlainText
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
