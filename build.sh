#!/bin/zsh
# Builds MacTouch.app with the command-line Swift toolchain (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)}"
BUILD="$(date +%Y%m%d%H%M)"
OUT=build
APP="$OUT/MacTouch.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework IOKit -framework Carbon -framework ServiceManagement \
  Sources/MacTouch/*.swift -o "$APP/Contents/MacOS/MacTouch.arm64"
swiftc -O -swift-version 5 -target x86_64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework IOKit -framework Carbon -framework ServiceManagement \
  Sources/MacTouch/*.swift -o "$APP/Contents/MacOS/MacTouch.x86_64" 2>/dev/null || { echo "x86_64 slice skipped"; rm -f "$APP/Contents/MacOS/MacTouch.x86_64"; }
if [ -f "$APP/Contents/MacOS/MacTouch.x86_64" ]; then
  lipo -create "$APP/Contents/MacOS/MacTouch.arm64" "$APP/Contents/MacOS/MacTouch.x86_64" -output "$APP/Contents/MacOS/MacTouch"
  rm "$APP/Contents/MacOS/MacTouch.arm64" "$APP/Contents/MacOS/MacTouch.x86_64"
else
  mv "$APP/Contents/MacOS/MacTouch.arm64" "$APP/Contents/MacOS/MacTouch"
fi
echo 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - --identifier ca.lukasbaxter.mactouch "$APP"
echo "built $APP ($VERSION, $BUILD)"
