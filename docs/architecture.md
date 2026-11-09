# Architecture

SpaceKeeper is a menu-bar (`LSUIElement`) app written in Swift with AppKit + a little SwiftUI. It uses only system
frameworks. No Xcode project is needed — it builds with Swift Package Manager and the Command Line Tools.

| File | Responsibility |
|---|---|
| `main.swift`, `AppDelegate.swift` | App bootstrap, menu-bar menu, permissions, hotkeys, first-run prompt |
| `Spaces.swift` | Reads desktops per display, which desktop(s) a window is on, display geometry, desktop names, and every window on every desktop (`WindowCatalog`) |
| `Windows.swift` | Accessibility helpers: list/minimize/raise/close windows, find "New Window" menu items |
| `WindowMover.swift` | Moves a window to another desktop (see below) |
| `HotKeys.swift` | Global hotkeys via Carbon `RegisterEventHotKey` (needs no extra permission); the action list, defaults and user bindings |
| `SettingsWindow.swift` | Settings: shortcut recorder, home desktops, desktop names |
| `Switcher.swift` | The `⌃⌥⌘ Space` desktop switcher overlay |
| `HomeDesktops.swift` | Per-app home desktops: an `AXObserver` per app with a rule sends new windows home |
| `Layouts.swift` | Saved layouts and the restore planner (`LayoutPlanner` is pure and unit-tested) |
| `Updates.swift` | GitHub latest-release check |
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

## Other displays, many windows, layouts

- **Another display:** `WindowMover.plan` resolves the target. For another display the window is dragged by its title bar
  onto that display (it lands on the desktop showing there), Ctrl+arrow is pressed with the pointer on that display, and
  the return trip happens on that display too.
- **Several windows:** `moveAll` moves them one by one; every trip but the last returns to the starting desktop so the
  next window can be picked up.
- **Layouts:** a layout stores (app, title, display, desktop) per window. Restoring opens missing apps, matches windows
  (title first, then order), visits each desktop that has a misplaced window, carries those windows away, and finally
  returns every display to the desktop it started on. Accessibility only sees the current desktop's windows, which is
  why the restore has to visit desktops.
- **Auto-hidden Dock:** `DockInspector.track` (12 Hz) notices the pointer pressing the Dock's screen edge, waits the
  Dock's reveal delay, and only then treats the Dock as present until the pointer leaves it.
