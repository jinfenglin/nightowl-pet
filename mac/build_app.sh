#!/bin/bash
# Build DeskPet.app (release) using only Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

# The macOS 27 CLT SDK turns @State into a macro whose plugin only ships with full Xcode,
# so build against the newest older SDK when Xcode isn't installed.
if [[ -z "${SDKROOT:-}" ]] && ! xcode-select -p | grep -q Xcode.app; then
  SDKROOT=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)
  export SDKROOT
fi

swift build -c release --disable-sandbox
BIN=$(swift build -c release --disable-sandbox --show-bin-path)/DeskPet

APP=DeskPet.app
VERSION="${VERSION:-0.1.0}"     # CI passes the release tag's version
BUILD="${BUILD_NUMBER:-1}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DeskPet"
# Built-in art, installed into the asset library on first launch (see AssetLibrary.installDefaults).
cp -R ../assets/defaults "$APP/Contents/Resources/Defaults"  # shared with the Windows version
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DeskPet</string>
  <key>CFBundleDisplayName</key><string>DeskPet</string>
  <key>CFBundleIdentifier</key><string>com.deskpet.app</string>
  <key>CFBundleExecutable</key><string>DeskPet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $(pwd)/$APP"
