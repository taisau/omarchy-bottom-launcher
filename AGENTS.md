# Omarchy Bottom Launcher - Project Memory

## Overview
A native Quickshell / Omarchy-shell plugin providing a mouse-activated rising popup window switcher and launcher.

- **Plugin ID**: `io.github.taisau.bottom-launcher`
- **Location**: `~/.config/omarchy/plugins/io.github.taisau.bottom-launcher/` (symlinked from `~/sync/5 computadors/53 devices/53.01 framework/bottom-launcher`)
- **GitHub**: `https://github.com/taisau/omarchy-bottom-launcher` (public)
- **Marketplace Submission**: Issue [#3214](https://github.com/HANCORE-linux/omarchy-plugin-marketplace/issues/3214) on `HANCORE-linux/omarchy-plugin-marketplace`
- **Plugin Type**: `service` (`keepLoaded: true`)
- **Target Platform**: Framework Laptop 13 running Fedora 44 + Hyprland + Omarchy Quattro


## Architecture & Implementation Details

- **Direct Layer-Shell Mapping**: Declared directly as a fullscreen `PanelWindow` (without wrapper `Variants`) allowing Quickshell to map it to the primary screen.
- **Trigger Mechanisms**:
  - **Mouse Hover**: Positioned at screen bottom center: `width: parent.width / 3`, `height: Style.space(16)`.
  - **Keyboard Shortcut**: `GlobalShortcut` bindings for `omarchy-bottom-launcher:next` (`Alt+Tab`) and `omarchy-bottom-launcher:prev` (`Alt+Shift+Tab`).
- **Dynamic Input Masking & Hover**:
  - `mask: Region { item: container }`
  - While idle/closed, only the 16px bottom trigger strip intercepts pointer events; the entire surrounding screen is click-through.
  - While open, `container` expands to cover the floating card and all space below it to the screen bottom edge.
- **Keyboard MRU & Release Handling**:
  - Initial selection on `Alt+Tab` selects the second MRU window (`Logic.initialSelection(flat)`).
  - Subsequent `Tab` / `Shift+Tab` presses advance/reverse selection.
  - Active modifier monitoring (`modCheckTimer`) detects when `Alt` is released, instantly focusing the highlighted window and closing the drawer.
- **Client & Workspace Integration**:
  - Fetches running windows asynchronously via `hyprctl -j clients`.
  - Groups clients by workspace using `logic.js`.
  - Desktop entry, WMClass, and PWA name resolution via `Quickshell.iconPath` and `DesktopEntries`.
  - Supports custom multi-color Buuf robot variants for `org.omarchy.agent` (`assets/omarchy-agent-{0..7}.png`).
- **Smooth Animation & Dismissal**:
  - Rises up from the bottom edge using `NumberAnimation` on `anchors.bottomMargin` with `Easing.OutCubic`.
  - Auto-hides via a 400ms debounced timer when cursor leaves the card area during mouse mode.
  - Tapping any window icon focuses that window via `Hyprland.dispatch('hl.dsp.focus(...)')` and immediately dismisses the popup.

## Historical Log
- **2026-08-28**:
  - Initial implementation with mouse hover hotspot on bottom-middle third of the primary monitor.
  - Updated styling with square corners (`radius: 0`) and removed `"WS "` prefix from workspace headers.
  - Switched from nested `Variants` to direct `PanelWindow` overlay so Hyprland maps the Wayland layer-shell surface immediately.
  - Fixed re-triggering loop during hover by adding an open guard on `requestOpen()`.
  - Updated window readout to display only the window title (without application class prefix).
  - Added title sanitizer (`cleanTitle`) in `logic.js` to strip OpenCode terminal prefixes (`OC | `) and browser/app suffixes.
  - Replaced `vbrosseau.alttab`: wired `Alt+Tab` / `Alt+Shift+Tab` keyboard navigation and modifier-release window switching into `bottom-launcher`. Uninstalled `vbrosseau.alttab`.





