#!/bin/zsh
# Builds a release binary and assembles build/Metrolist+.app (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release 2>&1 | grep -E "error|Build complete" || true
BINARY=".build/release/Metrolist"
[[ -x "$BINARY" ]] || { echo "Build failed"; exit 1; }

APP="build/Metrolist+.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Metrolist+"

if [[ ! -f build/AppIcon.icns ]]; then
  swift Scripts/make-icon.swift build/AppIcon.iconset Resources/AppIcon-source.png >/dev/null 2>&1 && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns || echo "warning: icon generation failed"
fi
[[ -f build/AppIcon.icns ]] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Metrolist+</string>
  <key>CFBundleDisplayName</key><string>Metrolist+</string>
  <key>CFBundleIdentifier</key><string>app.metrolist.mac.automix</string>
  <key>CFBundleExecutable</key><string>Metrolist+</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>Lets a paired Android phone find and control Metrolist+ on your Wi-Fi when you switch on Device Connect.</string>
  <key>NSBonjourServices</key><array><string>_metrolist-connect._tcp</string></array>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>Unofficial macOS client for YouTube Music, with AutoMix. GPL-3.0.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc signing failed"
echo "Built $APP"
