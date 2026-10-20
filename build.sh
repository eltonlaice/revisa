#!/bin/sh
# Builds build/Revisa.app (ad-hoc signed).
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Revisa.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Brand/AppIcon.icns "$APP/Contents/Resources/"
cp .build/release/Revisa "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "OK: $APP"
