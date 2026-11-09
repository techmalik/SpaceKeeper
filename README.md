<p align="center">
  <img src="Resources/AppIcon-source.png" width="128" alt="SpaceKeeper icon">
</p>

<h1 align="center">SpaceKeeper</h1>

<p align="center"><b>Make every macOS desktop its own workspace.</b><br>
A free, open-source menu-bar app for macOS Spaces.</p>

<p align="center">
  <a href="https://github.com/techmalik/SpaceKeeper/actions/workflows/build.yml"><img src="https://github.com/techmalik/SpaceKeeper/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-lightgrey.svg" alt="macOS 14+">
</p>

<p align="center"><img src="media/spacekeeper-demo.gif" width="800" alt="SpaceKeeper demo: send a window to Desktop 2, per-desktop Dock previews, a new window opening on this desktop, Dock-click minimize"></p>

<p align="center"><img src="media/screenshot.png" width="800" alt="Dock preview showing only the Safari windows on this desktop"></p>

<p align="center"><b>Install:</b> download the DMG from the <a href="https://github.com/techmalik/SpaceKeeper/releases/latest">latest release</a> and drag SpaceKeeper to Applications, or build it: <code>git clone https://github.com/techmalik/SpaceKeeper && cd SpaceKeeper && bash scripts/build.sh --install</code></p>

---

macOS lets you have many desktops, but apps don't really *live* on them: click an app in the Dock and you get
yanked to whichever desktop it was last on, Dock previews mix windows from every desktop, and there's no quick way to
park a window on another desktop. SpaceKeeper fixes that.

<p align="center"><img src="docs/preview.png" width="360" alt="Dock hover preview showing only this desktop's windows"></p>

<p align="center">
  <a href="https://github.com/techmalik/SpaceKeeper/releases/download/v1.0.0/SpaceKeeper-demo.mp4">
    <img src="docs/demo-poster.png" width="640" alt="Watch the 90-second SpaceKeeper demo">
  </a><br>
  <b>▶ <a href="https://github.com/techmalik/SpaceKeeper/releases/download/v1.0.0/SpaceKeeper-demo.mp4">Watch the 90-second demo</a></b>
</p>

## Features

| | |
|---|---|
| **Send windows to other desktops** | `⌃⌥⌘ 1–9` sends the front window to Desktop N, `⌃⌥⌘ ←/→` to the previous/next one — or use the menu-bar menu. The window stays there. |
| **Per-desktop Dock previews** | Hover an app in the Dock and see live thumbnails of *only that app's windows on the current desktop* (minimized ones too). Hover a thumbnail for **close** and **minimize** buttons; click it to bring the window forward. |
| **Click the Dock icon to minimize** | Click the icon of the frontmost app and its windows on this desktop minimize. Click again and they come back. |
| **No more desktop-jumping** | Click an app that has no window on this desktop and SpaceKeeper opens a new window *right here* instead of pulling you to another desktop. Minimized windows are restored in place. |
| **Send to another display** | With more than one display, send a window to any desktop on any display from the menu, or to the next display with `⌃⌥⌘ ↓`. |
| **Move many windows at once** | `⇧⌃⌥⌘ 1–9` / `⇧⌃⌥⌘ ←/→` send *all* of the front app's windows on this desktop; the menu can also send every window on this desktop. |
| **Desktop switcher** | `⌃⌥⌘ Space` shows every desktop with the apps and windows on it. Press 1–9 (or click) to go there, `⇧1–9` to bring the front window along, `⌥1–9` to send all of that app's windows. |
| **Named desktops** | Call Desktop 2 "Work". Names appear in the menu and the switcher, and can be shown in the menu bar. They follow the desktop even if you reorder desktops. |
| **Home desktops per app** | "Slack lives on Desktop 3": new Slack windows are carried there as they open, and clicking Slack in the Dock from elsewhere takes you there. |
| **Saved layouts** | Save which desktop every window is on and restore it later (or automatically when SpaceKeeper starts, e.g. after a restart). Missing apps are opened first. |
| **Your shortcuts** | Every shortcut can be changed or turned off in **Settings… › Shortcuts**; SpaceKeeper flags any that another app already uses. |
| **Works with an auto-hidden Dock** | Previews and Dock clicks work whether the Dock is always shown or hides itself. |
| **Stays out of your way** | Lives in the menu bar, no Dock icon, no telemetry. Network use is limited to the optional feedback form (only when you press Send) and, if you turn it on, a daily check of GitHub for new versions. Dragging Dock icons to reorder still works. |

## Install

1. Download **`SpaceKeeper-x.y.z.dmg`** (or the `.zip`) from the [latest release](https://github.com/techmalik/SpaceKeeper/releases/latest).
2. Open it and drag **SpaceKeeper** into **Applications**.
3. **First launch:** SpaceKeeper isn't notarized by Apple (that needs a paid developer account), so macOS will say it
   can't verify the app. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
   Or, from Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/SpaceKeeper.app
   ```
4. Grant the two permissions it asks for (see below). That's it — look for the icon in your menu bar.

Prefer to build it yourself? See [Build from source](#build-from-source).

### Permissions (and why)

| Permission | Why | Where |
|---|---|---|
| **Accessibility** *(required)* | Read and move windows, see which Dock icon is under the pointer, minimize/restore, and post the keystrokes that move a window between desktops. | System Settings → Privacy & Security → Accessibility |
| **Screen Recording** *(for previews)* | Draw the live window thumbnails. Without it you still get previews, just with app icons instead of content. | System Settings → Privacy & Security → Screen Recording |

SpaceKeeper never records, stores or sends your screen. Thumbnails are drawn in memory and discarded.
The feedback form sends your message (and a screenshot, if you attach one) only when you press **Send**.

### Recommended setting

On first launch SpaceKeeper offers to turn off macOS's *"When switching to an application, switch to a Space with
open windows for the application"* option (also in the menu as **Don't jump to other desktops when opening apps**).
SpaceKeeper's Dock handling works either way, but turning this off makes everything feel consistent.

## Using it

- **Move a window:** focus it, press `⌃⌥⌘ 2` (to Desktop 2) — or menu bar → **Send Front Window To**.
  Takes about a second per desktop crossed. Turn on **Follow window to its new desktop** if you'd rather travel with it.
- **Previews:** just hover an app in the Dock.
- **Minimize / restore / new window:** click the app's Dock icon.
- **Switch desktops:** `⌃⌥⌘ Space`, then a number.
- **Name a desktop:** menu bar → **Rename This Desktop…**, or **Settings… › Desktop Names**.
- **Give an app a home:** with the app in front, menu bar → **Home Desktop for <app>**. Manage them all in **Settings… › Home Desktops**.
- **Layouts:** menu bar → **Layouts › Save Current Layout…**, then **Restore** later. Restoring moves windows the same way the hotkeys do, about a second per desktop crossed, so leave the mouse alone until the ↻ in the menu bar goes away.
- **Updates:** **Check for Updates…** asks GitHub for the latest release; turn on **Check for updates automatically** for a daily check.
- Everything can be switched on or off from the menu-bar icon. **About SpaceKeeper** has the version and contact details.
- **Send Feedback…** opens a small form: type your message, optionally take or attach a screenshot, press Send, and it arrives in the author's inbox.

## How moving windows works

macOS 14.5+ silently ignores the private "move window to Space" call for ordinary apps. So SpaceKeeper does what you
would do by hand: it grabs the window's title bar, presses the Mission Control shortcut (`⌃←` / `⌃→`) to travel to the
target desktop while holding the window, and lets go. Before it starts it checks that the window is on top and actually
follows the pointer, and afterwards it verifies where the window ended up. See [docs/architecture.md](docs/architecture.md).

This relies on Mission Control's **Move left/right a space** shortcuts being enabled (they are by default).

## Known limitations

- **Dock "running" dots** are drawn by the Dock itself and can't be made per-desktop.
- **Single-window apps** with no "New Window" menu item (e.g. WhatsApp) can't open a second window; for those the
  normal macOS behavior (jump to the app's window) is kept.
- Windows set to **Assign to: All Desktops** can't be sent to a single desktop.
- With an auto-hidden Dock, a click in the first moment after the Dock slides in is handled by macOS as usual.
- Moving a window to another display needs the target display to show a regular desktop, not a full-screen app.
- Layout restore matches windows by app and title; apps that don't expose window titles without Screen Recording are matched in order.
- Updates are downloaded and installed by hand (the app isn't notarized, so there's no silent auto-install).
- Uses a few **private macOS APIs** (read-only Space lookups), so it can't be distributed on the Mac App Store and a
  future macOS release could break it.
- Developed and tested on **macOS 27 (Apple Silicon)**. The binary is universal and targets macOS 14+, but older macOS
  versions and Intel Macs are untested — reports welcome!

## Troubleshooting

- **Nothing happens / hotkeys do nothing:** check *Accessibility* is on for SpaceKeeper, then quit and reopen it.
- **"⚠︎" appears in the menu bar after a move:** the menu shows the reason (e.g. another window covers the title bar).
- **Hover card doesn't appear:** make sure *Dock hover previews* is ticked in the menu and Accessibility is granted. On a desktop where the app has no windows the card says "No windows on this desktop".
- **Duplicate preview cards:** another Dock-preview tool (iDock, DockDoor…) is running; the menu offers to quit it.
- **Permissions reset after an update:** remove SpaceKeeper from the Accessibility list, add it back, relaunch.

## Build from source

Requires the Xcode Command Line Tools (`xcode-select --install`) — full Xcode is not needed.

```bash
git clone https://github.com/techmalik/SpaceKeeper.git
cd SpaceKeeper
./scripts/build.sh --install     # builds a universal app and copies it to ~/Applications
open ~/Applications/SpaceKeeper.app
```

`./scripts/package.sh` produces the `.zip`/`.dmg` release assets in `dist/`.
To use your own logo see [docs/LOGO_PROMPT.md](docs/LOGO_PROMPT.md).

## Contributing

Bug reports, ideas and pull requests are very welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Author

Made by **Malik Kabir** — questions, feedback or ideas: [techmaleek@gmail.com](mailto:techmaleek@gmail.com).

## License

[MIT](LICENSE) © 2026 Malik Kabir
