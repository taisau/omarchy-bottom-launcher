// Pure logic for window grouping and layout
.pragma library

// Practical ceilings for compositor- and client-derived data. Titles,
// classes, and workspace names are application-controlled, so every sink
// is bounded before it reaches models or rendering.
const MAX_CLIENTS = 200; // window entries parsed per collection
const MAX_NAME = 100;    // workspace names and application classes
const MAX_TITLE = 200;   // window titles
const MAX_ADDR = 32;     // window addresses

function capStr(v, max) {
    const s = String(v == null ? "" : v);
    return s.length > max ? s.slice(0, max) : s;
}

// Cleans up raw window titles by stripping CLI / shell prefixes and app suffixes
function cleanTitle(title, cls) {
    let t = capStr(String(title || "").trim(), MAX_TITLE);
    if (!t || t === "-") return capStr(cls || "", MAX_NAME);

    // Strip OpenCode terminal prefix "OC | "
    t = t.replace(/^OC\s*\|\s*/i, "");

    // Strip trailing browser suffixes like " — Mozilla Firefox", " - Google Chrome", " - Brave"
    t = t.replace(/\s*[—–-]\s*(Mozilla Firefox|Google Chrome|Chromium|Brave|Microsoft Edge)$/i, "");

    // Strip trailing app suffixes like " - sync - Obsidian 1.13.7"
    t = t.replace(/\s*-\s*Obsidian(\s+[\d\.]+)?$/i, "");

    return t.trim() || capStr(cls || "", MAX_NAME);
}

// The client's pin tag, or "". Pin tags record the column the window is held
// at: "pinl<N>" = N-th column from the left, "pinr<N>" = N-th from the right
// (0-based). The legacy "pinleft" tag counts as "pinl0".
function pinTag(c) {
    if (!c || !Array.isArray(c.tags)) return "";
    const n = Math.min(c.tags.length, 64);
    for (let i = 0; i < n; i++) {
        const t = String(c.tags[i]).replace(/\*$/, "");
        if (t === "pinleft" || /^pin[lr]\d{1,3}$/.test(t)) return t;
    }
    return "";
}

// Group clients by workspace in ascending id order (1, 2, 3, …) regardless
// of which workspace is active. Within a group, entries follow screen order
// on Hyprland's scrolling layout: tiled windows by column x then y (so pinned
// pinned windows keep their recorded column), floating windows last.
// Pinned (sticky) windows excluded, empty titles replaced with "-".
// groupIdx: 1-based position in the client's Hyprland group, 0 if ungrouped.
// col: 0-based column index among the workspace's tiled windows, -1 if floating.
// ncols: number of tiled columns in the workspace.
// pinTag: the window's pin tag ("" if not pinned), see pinTag().
// Returns [{ name, entries: [{ cls, title, addr, hidden, fhid, flatIdx, groupIdx, col, ncols, pinTag }] }].
function groupClients(clients) {
    if (!Array.isArray(clients)) return [];
    if (clients.length > MAX_CLIENTS) clients = clients.slice(0, MAX_CLIENTS);

    const wsOrder = [];
    const wsMap = {};

    for (const c of clients) {
        if (!c || c.pinned) continue;
        const wsId = (c.workspace && c.workspace.id !== undefined) ? c.workspace.id : 0;
        const wsName = capStr((c.workspace && c.workspace.name) ? c.workspace.name : String(wsId), MAX_NAME);
        if (!(wsId in wsMap)) {
            wsOrder.push(wsId);
            wsMap[wsId] = { name: wsName, clients: [] };
        }
        wsMap[wsId].clients.push(c);
    }

    wsOrder.sort((a, b) => a - b);

    let flatIdx = 0;
    const groups = [];
    for (const wsId of wsOrder) {
        const ws = wsMap[wsId];
        const pos = c => (Array.isArray(c.at) && Number.isFinite(c.at[0]) && Number.isFinite(c.at[1])) ? c.at : [0, 0];
        ws.clients.sort((a, b) => {
            if (!!a.floating !== !!b.floating) return a.floating ? 1 : -1;
            const pa = pos(a), pb = pos(b);
            return (pa[0] - pb[0]) || (pa[1] - pb[1]);
        });
        // Column index = rank of distinct x among tiled windows.
        const colOf = {};
        let nCols = 0;
        for (const c of ws.clients) {
            if (c.floating) continue;
            const x = pos(c)[0];
            if (!(x in colOf)) colOf[x] = nCols++;
        }
        groups.push({
            name: ws.name,
            entries: ws.clients.map(c => ({
                cls: capStr(c.class || "", MAX_NAME),
                title: capStr(cleanTitle(c.title, c.class), MAX_TITLE),
                rawTitle: capStr(c.title || "-", MAX_TITLE),
                addr: capStr(String(c.address || ""), MAX_ADDR).replace(/[^0-9a-zA-Z]/g, ""),
                pid: (Number.isInteger(c.pid) && c.pid > 1 && c.pid <= 4194304) ? c.pid : 0,
                hidden: !!c.hidden,
                fhid: c.focusHistoryID || 0,
                flatIdx: flatIdx++,
                groupIdx: (Array.isArray(c.grouped) && c.address) ? c.grouped.indexOf(c.address) + 1 : 0,
                col: c.floating ? -1 : colOf[pos(c)[0]],
                ncols: nCols,
                pinTag: pinTag(c),
            })),
        });
    }
    return groups;
}

function flatten(groups) {
    if (!Array.isArray(groups)) return [];
    const flat = [];
    for (const g of groups) {
        if (!g || !Array.isArray(g.entries)) continue;
        for (const e of g.entries) {
            flat.push(e);
        }
    }
    return flat;
}

// Second-most-recently-used window: smallest fhid > 0, fallback 0.
function initialSelection(flat) {
    if (!Array.isArray(flat) || flat.length === 0) return 0;
    let best = -1, bestFhid = Infinity;
    for (let i = 0; i < flat.length; i++) {
        if (flat[i].fhid > 0 && flat[i].fhid < bestFhid) {
            bestFhid = flat[i].fhid;
            best = i;
        }
    }
    return best >= 0 ? best : 0;
}
