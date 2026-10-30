# Screenshots

These are real captures of MeshBar v0.1.0 on the maintainer's home network: a Linksys Pinnacle 2.2 router with three satellites, on a 1x display. They were published deliberately. Everything else in the repo (tests, fixtures, demo mode) uses example values only.

| File | Shows |
| --- | --- |
| `menu-bar.png` | Menu-bar dropdown: health, WAN, nodes and backhaul |
| `dashboard.png` | Dashboard topology, sidebar, collapsed bottom bar |
| `inspector.png` | Node inspector (crop of the dashboard) |
| `spectrum.png` | Spectrum view after a router site survey (2.4 GHz) |
| `client-detail.png` | Client history sheet: connection, signal and link rate |
| `connect.png` | Connect window (password field empty) |
| `settings.png` | Settings |
| `app-icon.png` | App icon, 256 px |

## Retaking them

Build the bundle, then use the launch arguments, so nothing needs clicking:

```bash
scripts/bundle.sh
pkill -x MeshBar; open dist/MeshBar.app --args --dashboard --select-node "Floor 3"
pkill -x MeshBar; open dist/MeshBar.app --args --dashboard --view spectrum --scan router
pkill -x MeshBar; open dist/MeshBar.app --args --dashboard --client-detail "MacBook"
pkill -x MeshBar; open dist/MeshBar.app --args --open-window connect --open-window settings
pkill -x MeshBar; open dist/MeshBar.app --args --open-menu
```

Capture a window with `screencapture -x -l <windowID> file.png`. A sheet is composited into its parent window, so crop it from that capture (or use `screencapture -R x,y,w,h`). For contributions, use **Demo mode** unless you are happy to publish your own network.
