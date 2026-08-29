#!/usr/bin/env bash
# Builds Konishi, packages it as a signed .app bundle, and launches it.
# Running as a proper bundle is required for microphone / speech (TCC) permissions —
# a bare `swift run` binary is killed by TCC when it requests those.
set -euo pipefail

CONFIG="debug"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    debug|release) CONFIG="$arg" ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

APP="Konishi.app"

if [[ ! -f Konishi.icns || AppIcon/Konishi-1024.png -nt Konishi.icns ]]; then
  python3 AppIcon/make_icon.py
fi

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Konishi"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Konishi"
cp Info.plist "$APP/Contents/Info.plist"
cp Konishi.icns "$APP/Contents/Resources/Konishi.icns"

# Ad-hoc sign with the microphone entitlement so TCC honors the usage strings.
codesign --force --sign - --entitlements Konishi.entitlements "$APP"

if [[ "$INSTALL" == "1" ]]; then
  DEST="/Applications/$APP"
  # Quit a running copy so we don't overwrite a live binary.
  osascript -e 'quit app "Konishi"' 2>/dev/null || true
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  echo "Installed to $DEST — launching …"
  open "$DEST"
else
  echo "Launching $APP …"
  open "$APP"
fi
