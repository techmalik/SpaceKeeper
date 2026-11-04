#!/bin/bash
# Builds SpaceKeeper.app into ./build.   Pass --install to also copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

ID="com.malikkabir.SpaceKeeper"
APP="build/SpaceKeeper.app"

# Universal binary (Apple Silicon + Intel) when the toolchain supports it, otherwise this Mac's architecture.
if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/SpaceKeeper"
    echo "Built universal binary"
else
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/SpaceKeeper"
    echo "Built for $(uname -m) only"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SpaceKeeper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature with a requirement that depends only on the bundle identifier, so the
# Accessibility / Screen Recording grants survive rebuilds.
codesign --force --sign - --identifier "$ID" -r="designated => identifier \"$ID\"" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    pkill -x SpaceKeeper 2>/dev/null || true
    sleep 0.5
    rm -rf ~/Applications/SpaceKeeper.app
    cp -R "$APP" ~/Applications/SpaceKeeper.app
    echo "Installed ~/Applications/SpaceKeeper.app"
fi
