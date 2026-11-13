#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/make-icon.sh"

MIN_MACOS="14.0"

build_slice() {
    local arch="$1"
    local triple="${arch}-apple-macosx${MIN_MACOS}"
    echo "Собираю ${arch}…" >&2
    swift build -c release --product FloatChat --triple "$triple" >/dev/null
    swift build -c release --product FloatChat --triple "$triple" --show-bin-path
}

X86_BIN="$(build_slice x86_64)/FloatChat"
ARM_BIN="$(build_slice arm64)/FloatChat"

UNIVERSAL="$ROOT/.build/universal/FloatChat"
mkdir -p "$(dirname "$UNIVERSAL")"
lipo -create "$X86_BIN" "$ARM_BIN" -output "$UNIVERSAL"
chmod +x "$UNIVERSAL"
lipo -info "$UNIVERSAL"

APP="$ROOT/dist/FloatChat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$UNIVERSAL" "$APP/Contents/MacOS/FloatChat"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/App/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/models.json" "$APP/Contents/Resources/models.json"
if [[ -f "$ROOT/howto.md" ]]; then
    cp "$ROOT/howto.md" "$APP/Contents/Resources/howto.md"
fi
chmod +x "$APP/Contents/MacOS/FloatChat"
codesign --force --deep --sign - "$APP" >/dev/null

echo "Готово: $APP"
