#!/bin/zsh
# Builds MessengerBar.app into ./build. Usage: ./build.sh [--install] [--run]
#   --install  copy the app to /Applications, or ~/Applications if you're not an admin
#   --run      launch the app after building
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MessengerBar"
BUNDLE_ID="app.messengerbar.MessengerBar"
APP="build/${APP_NAME}.app"

# Use Xcode's toolchain directly so a stale swiftly toolchain on PATH can't interfere.
SWIFTC="$(xcrun --toolchain com.apple.dt.toolchain.XcodeDefault --find swiftc)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

"$SWIFTC" -O \
  -sdk "$SDK" \
  -target "$(uname -m)-apple-macos14.0" \
  -swift-version 6 \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  Sources/*.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so WebKit storage, notifications and SMAppService behave.
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"

for arg in "$@"; do
  case "$arg" in
    --install)
      # /Applications needs an admin account; fall back to the per-user ~/Applications.
      DEST="/Applications"
      [[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
      pkill -x "$APP_NAME" 2>/dev/null || true
      rm -rf "$DEST/${APP_NAME}.app"
      cp -R "$APP" "$DEST/"
      APP="$DEST/${APP_NAME}.app"
      echo "Installed to $APP"
      ;;
  esac
done

for arg in "$@"; do
  [[ "$arg" == "--run" ]] && { pkill -x "$APP_NAME" 2>/dev/null || true; open "$APP"; }
done
exit 0
