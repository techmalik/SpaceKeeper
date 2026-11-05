#!/bin/bash
# Drives the SpaceKeeper demo scenes with System Events and cliclick.
# Run `media/stage.sh setup` first (Desktop 1 showing, TextEdit in front), then record the screen while this runs.
# Writes scene start times (Unix seconds) to $MARKS (default media/scenes.txt) for captioning.
set -euo pipefail
PAUSE="${PAUSE:-1.5}"
MARKS="${MARKS:-$(dirname "$0")/scenes.txt}"
command -v cliclick >/dev/null || { echo "cliclick missing: brew install cliclick"; exit 1; }

now()   { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
mark()  { echo "$1 $(now)" >>"$MARKS"; }
pause() { sleep "${1:-$PAUSE}"; }
keys()  { osascript -e "tell application \"System Events\" to $1"; }
next_desktop() { keys 'key code 124 using control down'; }   # ⌃→
prev_desktop() { keys 'key code 123 using control down'; }   # ⌃←

# Centre of an app's Dock icon, as "x,y" in points.
dock_icon() {
    osascript -e "tell application \"System Events\" to tell process \"Dock\"
        set {x, y} to position of UI element \"$1\" of list 1
        set {w, h} to size of UI element \"$1\" of list 1
        return ((x + w / 2) as integer as text) & \",\" & ((y + h / 2) as integer as text)
    end tell"
}
glide_to() { cliclick -e 400 "m:$1"; }      # eased pointer move

: >"$MARKS"
SAFARI="$(dock_icon Safari)"
REST="720,420"                              # neutral pointer spot, mid-screen
glide_to "$REST"
mark start
pause

# a. ⌃⌥⌘2 sends the front TextEdit window to Desktop 2, then visit it and come back.
mark a
keys 'tell process "TextEdit" to set frontmost to true'
pause 0.5
keys 'key code 19 using {control down, option down, command down}'   # ⌃⌥⌘2
pause 2.5                                   # SpaceKeeper moves the window and returns here
next_desktop; pause                         # Desktop 2: the window landed here
prev_desktop; pause

# b. Hover Safari in the Dock: preview shows only this desktop's Safari windows.
mark b
glide_to "$SAFARI"
pause 3
glide_to "$REST"; pause 0.8

# c. Desktop 2 has no Safari window: clicking the Dock icon opens one right here.
mark c
next_desktop; pause
cliclick "c:$SAFARI"
pause 2.5

# d. Click the front app's Dock icon to minimize its windows, click again to restore.
mark d
cliclick "c:$SAFARI"; pause 2
cliclick "c:$SAFARI"; pause 2
glide_to "$REST"
mark end
