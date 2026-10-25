#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
INTERVAL_SCRATCH="${INTERVAL_SCRATCH:-${TMPDIR:-/tmp}/interval-spm-$UID}"
INTERVAL_VERSION="${INTERVAL_VERSION:-1.0.0}"
INTERVAL_OUTPUT="$PWD/build"
INTERVAL_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/interval-package.XXXXXX")"
INTERVAL_APP="$INTERVAL_STAGE/Interval.app"
mkdir -p "$INTERVAL_OUTPUT"
swift build --scratch-path "$INTERVAL_SCRATCH" -c release --arch arm64
INTERVAL_BIN="$(swift build --scratch-path "$INTERVAL_SCRATCH" -c release --arch arm64 --show-bin-path)"
mkdir -p "$INTERVAL_APP/Contents/MacOS" "$INTERVAL_APP/Contents/Resources"
cp "$INTERVAL_BIN/Interval" "$INTERVAL_APP/Contents/MacOS/Interval"
cp Resources/Info.plist "$INTERVAL_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $INTERVAL_VERSION" "$INTERVAL_APP/Contents/Info.plist"
INTERVAL_ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$INTERVAL_ICONSET"
iconutil -c icns "$INTERVAL_ICONSET" -o "$INTERVAL_APP/Contents/Resources/AppIcon.icns"
xattr -cr "$INTERVAL_APP"
codesign --force --options runtime --sign "${INTERVAL_SIGN_IDENTITY:--}" "$INTERVAL_APP"
codesign --verify --deep --strict "$INTERVAL_APP"
lipo "$INTERVAL_APP/Contents/MacOS/Interval" -verify_arch arm64
ditto -c -k --keepParent "$INTERVAL_APP" "$INTERVAL_OUTPUT/Interval-$INTERVAL_VERSION-arm64.zip"
ln -s /Applications "$INTERVAL_STAGE/Applications"
hdiutil create -volname "Interval" -srcfolder "$INTERVAL_STAGE" -ov -format UDZO "$INTERVAL_OUTPUT/Interval-$INTERVAL_VERSION-arm64.dmg" >/dev/null
(cd "$INTERVAL_OUTPUT" && shasum -a 256 "Interval-$INTERVAL_VERSION-arm64.zip" "Interval-$INTERVAL_VERSION-arm64.dmg" > SHA256SUMS.txt)
printf 'Packaged: %s\n' "$INTERVAL_APP"
