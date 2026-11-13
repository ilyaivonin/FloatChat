#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build-app.sh"

APP="$ROOT/dist/FloatChat.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/App/Info.plist")"
DMG="$ROOT/dist/FloatChat-${VERSION}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/FloatChat.app"
ln -s /Applications "$STAGE/Applications"

# Include README files from the project root (if present)
if [[ -f "$ROOT/README.md" ]]; then
    cp "$ROOT/README.md" "$STAGE/README.md"
fi
if [[ -f "$ROOT/README_RU.md" ]]; then
    cp "$ROOT/README_RU.md" "$STAGE/README_RU.md"
fi

rm -f "$DMG"
hdiutil create \
    -volname "FloatChat" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

echo "Готово: $DMG"
