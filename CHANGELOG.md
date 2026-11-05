# Changelog

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
