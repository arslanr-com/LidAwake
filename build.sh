#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) LidAwake.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"

APP=LidAwake.app
BUILD=.build
rm -rf "$APP" "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$BUILD"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macosx13.0" \
    -o "$BUILD/LidAwake-$arch" Sources/main.swift
done
lipo -create -output "$APP/Contents/MacOS/LidAwake" "$BUILD"/LidAwake-*

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.arslanr.lidawake</string>
  <key>CFBundleName</key><string>LidAwake</string>
  <key>CFBundleExecutable</key><string>LidAwake</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built: $(pwd)/$APP"
