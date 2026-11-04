#!/bin/bash
# Builds Resources/AppIcon.icns from artwork.
#
#   scripts/make-icon.sh --mask logo.png    # logo.png is plain full-bleed square art (e.g. from an AI image tool);
#                                           # a macOS rounded-square mask, margin and shadow are added for you
#   scripts/make-icon.sh icon-1024.png      # the PNG is already a finished icon (transparent margin, rounded corners)
#   scripts/make-icon.sh                    # re-uses Resources/AppIcon-source.png
set -euo pipefail
cd "$(dirname "$0")/.."

MASK=0
if [[ "${1:-}" == "--mask" ]]; then MASK=1; shift; fi
SRC="${1:-Resources/AppIcon-source.png}"
[[ -f "$SRC" ]] || { echo "Missing $SRC"; exit 1; }

if [[ $MASK == 1 ]]; then
    TOOL="$(mktemp -d)/apply-icon-mask"
    swiftc -O scripts/apply-icon-mask.swift -o "$TOOL"
    "$TOOL" "$SRC" Resources/AppIcon-source.png
    SRC="Resources/AppIcon-source.png"
elif [[ "$SRC" != "Resources/AppIcon-source.png" ]]; then
    cp "$SRC" Resources/AppIcon-source.png
    SRC="Resources/AppIcon-source.png"
fi

SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns — now run scripts/build.sh --install"
