#!/bin/bash
# Builds "NullMoth Updater.app" next to this script (or into $1).
set -euo pipefail
cd "$(dirname "$0")"
OUT=${1:-build}; APP="$OUT/NullMoth Updater.app"
SDK=$(xcrun --sdk macosx --show-sdk-path)
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -parse-as-library -swift-version 5 -target x86_64-apple-macos15.0 -sdk "$SDK" \
  -framework SwiftUI -framework AppKit -framework CryptoKit \
  Sources/*.swift -o "$APP/Contents/MacOS/NullMothUpdater"
# the patched Metal plugin rides inside the app, for "Install patched plugin (built in)", with the licence it
# is distributed under (PolyForm Noncommercial: copies must carry the terms and the Required Notice line)
if [ -f driver-patch/NVMTLDriver ]; then
  cp driver-patch/NVMTLDriver "$APP/Contents/Resources/NVMTLDriver-fixed"
  cp driver-patch/LICENSE-PolyForm-Noncommercial.md driver-patch/NOTICE "$APP/Contents/Resources/"
fi
IS=$(mktemp -d)/u.iconset; mkdir -p "$IS"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$IS/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$IS/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$IS" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>ru</string>
<key>CFBundleExecutable</key><string>NullMothUpdater</string>
<key>CFBundleIdentifier</key><string>io.github.bananan11ss.nullmoth-updater</string>
<key>CFBundleName</key><string>NullMoth Updater</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Нужно для запроса пароля администратора при установке драйвера.</string>
</dict></plist>
PL
codesign --force --deep -s - "$APP"
echo "$APP"
