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

// Group clients by workspace: active workspace first then ascending id;
// within a group the focused window (fhid == 0) first, then ascending fhid.
// Pinned windows excluded, empty titles replaced with "-".
// groupIdx: 1-based position in the client's Hyprland group, 0 if ungrouped.
// Returns [{ name, entries: [{ cls, title, addr, hidden, fhid, flatIdx, groupIdx }] }].
function groupClients(clients, activeWsId) {
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

    wsOrder.sort((a, b) => {
        const pa = a === activeWsId ? 0 : 1;
        const pb = b === activeWsId ? 0 : 1;
        return pa !== pb ? pa - pb : a - b;
    });

    let flatIdx = 0;
    const groups = [];
    for (const wsId of wsOrder) {
        const ws = wsMap[wsId];
        ws.clients.sort((a, b) => {
            const ka = a.focusHistoryID === 0 ? -1 : (a.focusHistoryID || 0);
            const kb = b.focusHistoryID === 0 ? -1 : (b.focusHistoryID || 0);
            return ka - kb;
        });
        groups.push({
            name: ws.name,
            entries: ws.clients.map(c => ({
                cls: capStr(c.class || "", MAX_NAME),
                title: capStr(cleanTitle(c.title, c.class), MAX_TITLE),
                rawTitle: capStr(c.title || "-", MAX_TITLE),
                addr: capStr(String(c.address || ""), MAX_ADDR).replace(/[^0-9a-zA-Z]/g, ""),
                hidden: !!c.hidden,
                fhid: c.focusHistoryID || 0,
                flatIdx: flatIdx++,
                groupIdx: (Array.isArray(c.grouped) && c.address) ? c.grouped.indexOf(c.address) + 1 : 0,
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
