# Architecture

SpaceKeeper is a menu-bar (`LSUIElement`) app written in Swift with AppKit + a little SwiftUI. It uses only system
frameworks. No Xcode project is needed — it builds with Swift Package Manager and the Command Line Tools.

| File | Responsibility |
|---|---|
| `main.swift`, `AppDelegate.swift` | App bootstrap, menu-bar menu, permissions, hotkeys, first-run prompt |
| `Spaces.swift` | Reads desktops per display and which desktop(s) a window is on |
| `Windows.swift` | Accessibility helpers: list/minimize/raise/close windows, find "New Window" menu items |
| `WindowMover.swift` | Moves a window to another desktop (see below) |
| `HotKeys.swift` | Global hotkeys via Carbon `RegisterEventHotKey` (needs no extra permission) |
| `DockInspector.swift` | Asks the Dock process (via Accessibility) which app icon is under a point |
| `DockPreview.swift`, `Thumbnails.swift` | Hover card UI and ScreenCaptureKit thumbnails |
| `DockClickMinimizer.swift` | Event tap that turns Dock clicks into minimize / restore / raise / new window |
| `AboutWindow.swift`, `AppInfo.swift` | About window, author/contact info, feedback links |
| `DebugControl.swift` | Opt-in shell-driven test channel |

## Which windows are "on this desktop"?

`CGSCopyManagedDisplaySpaces` gives each display's desktops and the current one; `CGSCopySpacesForWindows` tells which
desktops a window lives on. A window is on the current desktop if the two intersect. Minimized windows keep the desktop
they were minimized from, so they are included. Accessibility (`_AXUIElementGetWindow`) maps AX windows to window IDs.

## Moving a window

macOS 14.5+ ignores `CGSMoveWindowsToManagedSpace` for normal apps, so `WindowMover`:

1. waits for the hotkey's modifiers to be released,
2. raises the window and checks it is topmost at the grab point,
3. picks a draggable point on the title bar by hit-testing Accessibility elements (avoids buttons, tabs, fields),
4. presses the mouse down and drags a little, aborting if the window doesn't follow,
5. presses `⌃←`/`⌃→` once per desktop to cross, keeping the mouse held,
6. releases, verifies the window's desktop, and (unless *Follow window* is on) travels back.

Synthetic keys are sent from a private event source and the modifier state is explicitly cleared afterwards.

## Dock clicks

An active (`.defaultTap`) session event tap sees left clicks. If the click lands on a running app's Dock icon (resolved
through the Dock's Accessibility tree) SpaceKeeper decides: minimize / restore / raise-here / new-window. It swallows the
click and acts itself so macOS never goes looking for the app's windows on other desktops. A drag past 5 px replays the
original press so reordering Dock icons keeps working.

## Private APIs used

| Symbol | Use |
|---|---|
| `CGSMainConnectionID` | connection handle for the calls below |
| `CGSCopyManagedDisplaySpaces` | list desktops per display (read-only) |
| `CGSCopySpacesForWindows` | which desktop(s) a window is on (read-only) |
| `_AXUIElementGetWindow` | AX element → `CGWindowID` |

Everything else is public API (Accessibility, CoreGraphics event taps, ScreenCaptureKit, Carbon hotkeys).
