#!/bin/bash
# Prepares the screen for recording the demo, and puts it back afterwards.
#   media/stage.sh setup     hide other apps, hide desktop icons, solid wallpaper, open TextEdit + Safari (2 windows each)
#   media/stage.sh restore   undo all of that
# Start `setup` while Desktop 1 is showing. Needs at least 2 desktops.
set -euo pipefail
STATE="${TMPDIR:-/tmp}/spacekeeper-demo-state"
WALL_STORE="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
CLEAN_WALL="/System/Library/Desktop Pictures/Solid Colors/Space Gray.png"
[[ -f "$CLEAN_WALL" ]] || CLEAN_WALL="/System/Library/Desktop Pictures/Solid Colors/Black.png"

osa() { osascript -e "$@"; }

setup() {
    # Remember what to put back (only on the first run, so a second `setup` can't overwrite the originals).
    if [[ ! -f "$STATE/visible-apps" ]]; then
    mkdir -p "$STATE"
    cp "$WALL_STORE" "$STATE/wallpaper-Index.plist"
    defaults read com.apple.finder CreateDesktop >"$STATE/createdesktop" 2>/dev/null || echo "unset" >"$STATE/createdesktop"
    osa 'tell application "System Events" to get name of every application process whose background only is false and visible is true' \
        | tr ',' '\n' | sed 's/^ *//' >"$STATE/visible-apps"

    defaults read com.apple.WindowManager StandardHideWidgets >"$STATE/hidewidgets" 2>/dev/null || echo "unset" >"$STATE/hidewidgets"
    fi

    # Hide desktop icons and widgets.
    defaults write com.apple.WindowManager StandardHideWidgets -bool true
    killall WindowManager || true
    defaults write com.apple.finder CreateDesktop -bool false
    killall Finder

    # Hide every other app so only the demo windows are on screen.
    while IFS= read -r app; do
        [[ -z "$app" || "$app" == "TextEdit" || "$app" == "Safari" ]] && continue
        osa "tell application \"System Events\" to set visible of application process \"$app\" to false" || true
    done <"$STATE/visible-apps"

    # Clean wallpaper on Desktop 1 and Desktop 2 (macOS keeps one per desktop).
    osa "tell application \"System Events\" to set picture of every desktop to POSIX file \"$CLEAN_WALL\""
    osa 'tell application "System Events" to key code 124 using control down'; sleep 1
    osa "tell application \"System Events\" to set picture of every desktop to POSIX file \"$CLEAN_WALL\""
    osa 'tell application "System Events" to key code 123 using control down'; sleep 1

    # TextEdit: two windows.
    osa 'tell application "TextEdit"
        activate
        close every document saving no
        make new document with properties {text:"Meeting notes\n\n• Ship the Spaces fix\n• Record the demo"}
        make new document with properties {text:"Draft\n\nEvery desktop is its own workspace."}
        set bounds of window 1 to {520, 140, 1100, 560}
        set bounds of window 2 to {120, 90, 700, 510}
    end tell'

    # Safari: two windows.
    osa 'tell application "Safari"
        activate
        close every window
        make new document with properties {URL:"https://github.com/techmalik/SpaceKeeper"}
        make new document with properties {URL:"https://www.apple.com/macos/"}
        delay 1
        set bounds of window 1 to {380, 200, 1340, 820}
        set bounds of window 2 to {240, 120, 1200, 740}
    end tell'
    osa 'tell application "TextEdit" to activate'
    echo "Stage ready."
}

restore() {
    osa 'tell application "TextEdit" to close every document saving no' 2>/dev/null || true
    osa 'tell application "Safari" to quit' 2>/dev/null || true

    if [[ -f "$STATE/wallpaper-Index.plist" ]]; then
        cp "$STATE/wallpaper-Index.plist" "$WALL_STORE"
        killall WallpaperAgent 2>/dev/null || true
    fi

    case "$(cat "$STATE/createdesktop" 2>/dev/null || echo unset)" in
        unset) defaults delete com.apple.finder CreateDesktop 2>/dev/null || true ;;
        0) defaults write com.apple.finder CreateDesktop -bool false ;;
        *) defaults write com.apple.finder CreateDesktop -bool true ;;
    esac
    killall Finder

    case "$(cat "$STATE/hidewidgets" 2>/dev/null || echo unset)" in
        unset) defaults delete com.apple.WindowManager StandardHideWidgets 2>/dev/null || true ;;
        0) defaults write com.apple.WindowManager StandardHideWidgets -bool false ;;
        *) defaults write com.apple.WindowManager StandardHideWidgets -bool true ;;
    esac
    killall WindowManager || true

    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        osa "tell application \"System Events\" to set visible of application process \"$app\" to true" 2>/dev/null || true
    done <"$STATE/visible-apps"
    rm -rf "$STATE"
    echo "Restored."
}

case "${1:-}" in
    setup) setup ;;
    restore) restore ;;
    *) echo "usage: $0 setup|restore"; exit 1 ;;
esac
