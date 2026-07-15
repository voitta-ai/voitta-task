#!/usr/bin/env bash
# Build the Rust engine + Swift bar app and wrap them into VoittaTask.app
# (LSUIElement: menu bar only, no Dock icon).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

(cd "$ROOT/engine" && cargo build --release)
(cd "$HERE" && swift build -c release)

APP="$HERE/VoittaTask.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$HERE/.build/release/VoittaTask" "$APP/Contents/MacOS/VoittaTask"
cp "$ROOT/engine/target/release/voitta-task-engine" "$APP/Contents/MacOS/voitta-task-engine"
# SPM resource bundle (dog logo etc.) — Bundle.module finds it in Resources/.
cp -R "$HERE/.build/release/VoittaTask_VoittaTask.bundle" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>VoittaTask</string>
    <key>CFBundleIdentifier</key><string>ai.voitta.task</string>
    <key>CFBundleName</key><string>VoittaTask</string>
    <key>CFBundleDisplayName</key><string>VoittaTask</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>VoittaTask selects the terminal tab that hosts the Claude Code session you clicked.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/MacOS/voitta-task-engine"
codesign --force --sign - "$APP"
echo "Built: $APP"
