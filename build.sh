#!/bin/bash
# Builds build/AgentTray.app: release binary, Info.plist with LSUIElement, ad hoc signature.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product AgentTray
BIN_DIR="$(swift build -c release --show-bin-path)"

APP=build/AgentTray.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/AgentTray" "$APP/Contents/MacOS/AgentTray"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>local.agenttray</string>
    <key>CFBundleName</key>
    <string>AgentTray</string>
    <key>CFBundleDisplayName</key>
    <string>AgentTray</string>
    <key>CFBundleExecutable</key>
    <string>AgentTray</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
