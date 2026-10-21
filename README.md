# Omarchy Bottom Launcher

A fast, rising window switcher and launcher plugin for Omarchy on Hyprland, built with Quickshell.

![Preview](preview.png)

## Features

- **Dual Activation Triggers**:
  - **Mouse Hover**: Move your cursor down to the bottom-middle third of the focused monitor to reveal the floating launcher.
  - **Keyboard Shortcut**: Native `Alt+Tab` / `Alt+Shift+Tab` integration with MRU (most-recently-used) window cycling.
- **Instant Window Switching**:
  - Releasing `Alt` automatically raises and focuses the highlighted window.
  - Clicking any window tile with the mouse instantly brings it forward.
- **Workspace-Grouped Overview**: Active windows are neatly organized by workspace, with clean window titles and application icons. On Hyprland's scrolling layout, tiles follow the on-screen column order, left to right.
- **Pin Left & Drag to Reorder** (scrolling layout): right-click a tile and choose **Pin** to hold that window at its current column (counted from the nearer screen edge); drag a tile sideways to move its column. Pinning needs the small Hyprland script in `extras/pinleft.lua` (see below).
- **Dynamic Theming**: Automatically adapts to Omarchy's color palette, typography, and square window styling.
- **Pass-Through Passivity**: 100% transparent and click-through when idle; only the subtle bottom trigger zone captures mouse entry.
- **Multi-Monitor Aware**: Follows the Hyprland focused monitor, so it never strands on a disabled output (e.g. laptop lid / internal-monitor toggles).

## Installation

### Via Omarchy Plugin Marketplace
Once published, install via the Omarchy Plugin Manager:
```bash
omarchy plugin add io.github.taisau.bottom-launcher
```

### Manual Installation
Clone the repository into your Omarchy plugins directory:
```bash
git clone https://github.com/taisau/omarchy-bottom-launcher.git ~/.config/omarchy/plugins/io.github.taisau.bottom-launcher
```

Enable the plugin in `~/.config/omarchy/shell.json`:
```json
{
  "plugins": [
    { "id": "io.github.taisau.bottom-launcher" }
  ]
}
```

Add the `Alt+Tab` keybindings in `~/.config/hypr/bindings.lua`:
```lua
hl.unbind("ALT + TAB")
o.bind("ALT + TAB", "Bottom launcher window switcher", function()
  hl.dispatch(hl.dsp.global("omarchy-bottom-launcher:next"))
end, { repeating = true })

hl.unbind("ALT + SHIFT + TAB")
o.bind("ALT + SHIFT + TAB", "Bottom launcher window switcher previous", function()
  hl.dispatch(hl.dsp.global("omarchy-bottom-launcher:prev"))
end, { repeating = true })

hl.layer_rule({ match = { namespace = "omarchy-bottom-launcher" }, no_anim = true })
```

Restart the shell to apply:
```bash
omarchy restart shell
```

## License
MIT © [taisau](https://github.com/taisau)

### Optional: pin windows to their column (scrolling layout)

Copy `extras/pinleft.lua` to `~/.config/hypr/pinleft.lua` and load it after your look'n'feel file in `~/.config/hypr/hyprland.lua`:
```lua
require("hypr.pinleft")
```
Pinning tags the window `pinl<N>` (N-th column from the left) or `pinr<N>` (N-th from the right), whichever edge is nearer. The script keeps pinned columns there as other windows come and go. The launcher's **Pin** / **Unpin** button sets and clears the tag, and dragging a pinned tile re-pins it at its new column.
