# Changelog

## 1.1.0

**New**
- **Desktop switcher** (`⌃⌥⌘ Space`): every desktop with its apps and windows. Number keys or a click go there; `⇧`+number
  brings the front window along, `⌥`+number sends all of that app's windows.
- **Named desktops**: rename from the menu or Settings; names show in menus, the switcher and optionally the menu bar.
- **Home desktops per app**: new windows of the app are carried to its home desktop; clicking it in the Dock from another
  desktop goes there.
- **Send all windows**: all of the front app's windows (`⇧⌃⌥⌘ 1–9`, `⇧⌃⌥⌘ ←/→`), or every window on this desktop (menu).
- **Saved layouts**: save which desktop each window is on, restore later or automatically at launch; missing apps open first.
- **Multiple displays**: send a window to any desktop on any display, or to the next display (`⌃⌥⌘ ↓`).
- **Custom shortcuts**: Settings › Shortcuts lets you change or clear every shortcut and flags ones another app holds.
- **Auto-hidden Dock** support for previews and Dock clicks.
- **Update check**: Check for Updates… asks GitHub for the latest release; optional daily check (off unless you turn it on).

## 1.0.2

**Fixes**
- A failed or partly interrupted window move no longer leaves you on another desktop: SpaceKeeper returns to where you
  were, counting from the desktop actually showing instead of the planned number of steps.
- Multiple displays: the trip back after a move now happens on the window's display (the pointer stays there until
  the end), not on whichever display the pointer started on.
- Full-screen and minimized windows get a clear message instead of "That desktop doesn't exist" / "covered".
- Dock clicks on Terminal (and other apps whose "New Window" is a submenu) open a window here instead of waiting two
  seconds and jumping away. Xcode's File › New submenu is no longer mistaken for a new-window command.
- Apps with non-English menus now open a window here too (falls back to the app's plain ⌘N item).
- Invisible (zero-alpha) windows no longer count as "covering" the window or as a window on this desktop.
- Before the Dock's frame is known, the top-left corner of the screen is no longer treated as the Dock.
- Dock settings are read once a second instead of on every poll and click.
- The preview card stays clear of the menu bar, and refreshes until a closed window is really gone.
- Menu items that should be disabled (current desktop, granted permissions) are disabled.
- A second move warning in the menu bar is no longer cleared early by the first one's timer.
- Debug channel: no crash on a window without bounds; non-finite drag distances are rejected.

## 1.0.1

**Fixes**
- Hover previews no longer miss: the pointer is now polled instead of relying on mouse-moved events (the last event
  before the pointer stopped could be dropped), a single failed Dock lookup no longer cancels a pending card, and the
  hover region now covers magnified Dock icons.
- Dock clicks that should open a window on the current desktop no longer fall through to the jump: slow Accessibility
  work moved out of the event tap (macOS disables a slow tap), clicks SpaceKeeper can't improve are handed back to the
  Dock, and the app is only activated once its new window exists.
- A desktop where an app has no windows now shows a "No windows on this desktop" card instead of nothing.
- The preview card is dismissed when SpaceKeeper handles a Dock click, and stays quiet until the pointer moves.

**New**
- In-app **Send Feedback** form (message, type, optional reply email, screenshot capture or attach) delivered to the
  author's inbox.
- TextEdit-style apps whose menu says "New" (not "New Window") now open a window on the current desktop.

## 1.0.0

First public release.

- Send the front window to another desktop with hotkeys (`⌃⌥⌘ 1–9`, `⌃⌥⌘ ←/→`) or the menu bar.
- Dock hover previews showing live thumbnails of only the current desktop's windows (including minimized ones),
  with close and minimize buttons.
- Click a Dock icon to minimize, restore or open a window on the current desktop, without jumping to other desktops.
- Menu-bar app with toggles, permission status, About window and feedback links.
- Universal binary (Apple Silicon + Intel).
