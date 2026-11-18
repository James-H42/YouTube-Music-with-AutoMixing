#!/bin/zsh
# Builds dist/Metrolist.app as a release build, plus a zip of it.
#
#   Scripts/make-dist.sh [version]              Apple silicon only (default)
#   Scripts/make-dist.sh [version] --universal  also include an Intel slice
#
# The default is Apple silicon only because macOS 28 no longer opens Intel code: an app
# carrying an x86_64 slice triggers the "will not open in macOS 28" warning whenever that
# slice is run. Intel Macs stop at macOS 26, so --universal is only for sharing with them.
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=false
VERSION="1.0"
for argument in "$@"; do
  if [[ "$argument" == "--universal" ]]; then UNIVERSAL=true; else VERSION="$argument"; fi
done

if $UNIVERSAL; then
  swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -E "error:|Build complete" || true
  BINARY=".build/out/Products/Release/Metrolist"
else
  swift build -c release --arch arm64 2>&1 | grep -E "error:|Build complete" || true
  BINARY="$(swift build -c release --arch arm64 --show-bin-path)/Metrolist"
fi
[[ -x "$BINARY" ]] || { echo "Release build failed"; exit 1; }

mkdir -p build dist
if [[ ! -f build/AppIcon.icns ]]; then
  swift Scripts/make-icon.swift build/AppIcon.iconset Resources/AppIcon-source.png >/dev/null 2>&1 && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

APP="dist/Metrolist.app"
[[ -d "$APP" ]] && mv "$APP" "dist/.Metrolist-previous-$(date +%s).app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Metrolist"
strip -x "$APP/Contents/MacOS/Metrolist" 2>/dev/null || true
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Metrolist</string>
  <key>CFBundleDisplayName</key><string>Metrolist</string>
  <key>CFBundleIdentifier</key><string>app.metrolist.mac.automix</string>
  <key>CFBundleExecutable</key><string>Metrolist</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>Lets a paired Android phone find and control Metrolist on your Wi-Fi when you switch on Device Connect.</string>
  <key>NSBonjourServices</key><array><string>_metrolist-connect._tcp</string></array>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>Unofficial macOS client for YouTube Music, with AutoMix. GPL-3.0.</string>
</dict>
</plist>
PLIST

if ! $UNIVERSAL && [[ "$(lipo -archs "$APP/Contents/MacOS/Metrolist")" != "arm64" ]]; then
  echo "error: expected an arm64-only binary"; exit 1
fi
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "Signature OK (ad-hoc)"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "dist/Metrolist.zip"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Metrolist")) and dist/Metrolist.zip"
