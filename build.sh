#!/bin/bash
# Builds BatteryGraph.app (universal: Apple Silicon + Intel). Requires Xcode or Command Line Tools.
#   xcode-select --install   # if swiftc is missing
set -euo pipefail
cd "$(dirname "$0")"

APP="BatteryGraph.app"
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

for ARCH in arm64 x86_64; do
  echo "Compiling for $ARCH…"
  swiftc -O -parse-as-library -target "$ARCH-apple-macos13.0" \
    -framework IOKit -framework AppKit -framework SwiftUI \
    BatteryGraph.swift -o "build/BatteryGraph-$ARCH"
done
lipo -create build/BatteryGraph-arm64 build/BatteryGraph-x86_64 -output "$APP/Contents/MacOS/BatteryGraph"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BatteryGraph</string>
  <key>CFBundleDisplayName</key><string>Battery Graph</string>
  <key>CFBundleIdentifier</key><string>local.batterygraph</string>
  <key>CFBundleExecutable</key><string>BatteryGraph</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"   # ad-hoc signature so it runs locally
rm -rf build
echo "Built $(pwd)/$APP"
echo "Run it with:  open \"$(pwd)/$APP\"   (or drag it into /Applications)"
