#!/bin/bash
# Build "Insta Sync.app" (native SwiftUI app) with SwiftPM. Needs only the Xcode Command Line Tools.
# Usage: scripts/build_app.sh [destination folder]   (default: the project folder)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$ROOT}"
APP="$DEST/Insta Sync.app"

cd "$ROOT"
swift build -c release --product InstaSync
BIN="$(swift build -c release --show-bin-path)/InstaSync"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/InstaSync"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Offer to import the old Python version's data/ folder on first launch.
plutil -replace InstaSyncLegacyDataPath -string "$ROOT/data" "$APP/Contents/Info.plist"

# Ad-hoc signature. macOS asks again for Contacts / Automation access after each rebuild.
codesign --force --sign - "$APP"
echo "Built: $APP"
