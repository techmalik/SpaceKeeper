# Contributing to SpaceKeeper

Thanks for helping! Bug reports, feature ideas, docs fixes and pull requests are all welcome.

## Quick start

```bash
git clone https://github.com/techmalik/SpaceKeeper.git
cd SpaceKeeper
./scripts/build.sh --install      # needs only the Xcode Command Line Tools
open ~/Applications/SpaceKeeper.app
```

Grant Accessibility (and Screen Recording) once; the build script signs with an identifier-based requirement so the
grants survive rebuilds.

## Project layout

See [docs/architecture.md](docs/architecture.md). In short: `Spaces.swift`/`Windows.swift` model desktops and windows,
`WindowMover.swift` moves windows, `DockInspector.swift` + `DockPreview.swift` + `DockClickMinimizer.swift` implement the
Dock features, `AppDelegate.swift` is the menu bar.

## Testing

There's no GUI test harness, so there is an opt-in debug channel that lets you drive the running app from a shell:

```bash
defaults write com.malikkabir.SpaceKeeper debugControl -bool true     # then relaunch the app
echo status > ~/Library/Logs/SpaceKeeper/cmd.txt && notifyutil -p com.malikkabir.spacekeeper.cmd
cat ~/Library/Logs/SpaceKeeper/result.txt
```

Commands are listed at the top of `Sources/SpaceKeeper/DebugControl.swift` (`status`, `move`, `switch`, `dockscan`,
`hover`, `click`, `showpreview`, …). When you change window moving, Dock clicking or previews, please test on a real
multi-desktop setup and say what you tested in the PR. **Use a throwaway window, not your real work.**

## Guidelines

- Keep it dependency-free (system frameworks only) and small.
- Anything that synthesizes input must leave the system's modifier/mouse state clean — a stuck modifier makes every real
  click behave wrongly.
- Prefer Accessibility APIs over private ones; document any private symbol in `docs/architecture.md`.
- Match the existing style; keep comments for the *why*.
- One topic per pull request, with a short description of the behavior change.

## Good first issues

- A proper Settings window (custom hotkeys, per-feature options).
- Handling of auto-hidden Docks.
- Multi-display polish (per-display desktop numbering in the menu).
- Localization.
- Notarization/CI release pipeline.

## Reporting bugs

Use the bug-report template and include your macOS version, Mac model, and what the menu-bar status shows.
For security issues see [SECURITY.md](SECURITY.md).
