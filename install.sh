#!/bin/zsh
# MacTouch one-line installer:  curl -fsSL https://raw.githubusercontent.com/lukasbaxter/mactouch/main/install.sh | zsh
set -euo pipefail
REPO="lukasbaxter/mactouch"
APP="/Applications/MacTouch.app"
TMP="$(mktemp -d)"
echo "MacTouch installer"
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep browser_download_url | grep -i 'MacTouch.*\.zip' | head -1 | sed -E 's/.*"(https[^"]+)".*/\1/')
[ -n "$URL" ] || { echo "could not find a release zip for $REPO"; exit 1; }
echo "downloading $URL"
curl -fsSL "$URL" -o "$TMP/MacTouch.zip"
ditto -x -k "$TMP/MacTouch.zip" "$TMP/out"
SRC=$(find "$TMP/out" -maxdepth 2 -name 'MacTouch.app' | head -1)
[ -n "$SRC" ] || { echo "zip did not contain MacTouch.app"; exit 1; }
if pgrep -x MacTouch >/dev/null; then osascript -e 'tell application "MacTouch" to quit' >/dev/null 2>&1 || pkill -x MacTouch || true; sleep 1; fi
rm -rf "$APP"
ditto "$SRC" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
rm -rf "$TMP"
open "$APP"
cat <<'MSG'

Installed /Applications/MacTouch.app and launched it (menu bar icon: a tapping hand).

Finish the setup in System Settings → Privacy & Security — MacTouch will open the right panes:
  1. Input Monitoring  → enable MacTouch   (reads the touchscreen)
  2. Accessibility     → enable MacTouch   (injects clicks, scrolls, keys)
Then touch the screen. The app maps the touchscreen to the only external display automatically;
pick another display in MacTouch → Settings → Devices if you have several.

grandMA3 onPC users: MacTouch → Settings → grandMA3 → "Install plugin", then import and run the
MacTouch plugin in onPC for real multi-point touch.
MSG
