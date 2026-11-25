#!/bin/zsh
# Build StickerSend.app: the SwiftUI front end plus the cricut-bt CLI it drives.
# Builds a Universal (arm64 + x86_64) binary when supported by the toolchain.
set -euo pipefail
cd "${0:A:h}"

if swift build -c release --arch arm64 --arch x86_64; then
  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  echo "Universal build unavailable, falling back to native architecture"
  swift build -c release
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi

APP=StickerSend.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/StickerSend" "$BIN_DIR/cricut-bt" "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>StickerSend</string>
  <key>CFBundleIdentifier</key><string>local.stickers.StickerSend</string>
  <key>CFBundleExecutable</key><string>StickerSend</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>StickerSend talks to your Cricut StickerPix Print+Cut over Bluetooth.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "built $PWD/$APP"
