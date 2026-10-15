#!/bin/bash
# Builds the app, then "build/NullMoth-Updater-<version>.dmg": the app, an Applications link, the install guide
# and the first-launch (Gatekeeper) helper.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh >/dev/null
APP="build/NullMoth Updater.app"
VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
VOL="NullMoth Updater"; OUT="build/NullMoth-Updater-$VER.dmg"
W=$(mktemp -d); ST="$W/stage"; mkdir -p "$ST"
ditto "$APP" "$ST/NullMoth Updater.app"
ln -s /Applications "$ST/Applications"
cp "dmg/Как установить.txt" "$ST/"
cp "dmg/Если не открывается.command" "$ST/"; chmod 755 "$ST/Если не открывается.command"
hdiutil create -quiet -volname "$VOL" -srcfolder "$ST" -fs HFS+ -format UDRW -ov "$W/rw.dmg"
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$W/rw.dmg" | awk '/Apple_HFS/{print $1}')
MNT="/Volumes/$VOL"
# Finder layout: app on the left, Applications on the right, the guide and helper below. Needs Finder automation;
# without it the disk still works, just with default icon places.
osascript >/dev/null 2>&1 <<AS || echo "note: Finder layout skipped (no automation permission)"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 840, 560}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set position of item "NullMoth Updater.app" of container window to {160, 140}
    set position of item "Applications" of container window to {480, 140}
    set position of item "Как установить.txt" of container window to {160, 320}
    set position of item "Если не открывается.command" of container window to {480, 320}
    close
  end tell
end tell
AS
sync
hdiutil detach -quiet "$DEV" || hdiutil detach -quiet -force "$DEV"
rm -f "$OUT"
hdiutil convert -quiet "$W/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT"
rm -rf "$W"
shasum -a 256 "$OUT"
echo "$OUT"
