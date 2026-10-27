#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep generated bundles out of cloud-synced Documents folders with inherited Finder metadata.
INTERVAL_SCRATCH="${INTERVAL_SCRATCH:-${TMPDIR:-/tmp}/interval-spm-$UID}"
source scripts/version.sh

# Version metadata comes only from the committed VERSION and BUILD_NUMBER files;
# no environment override, so packaging cannot drift from the release tag.
INTERVAL_VERSION="$(version_read_field VERSION)"
INTERVAL_BUILD="$(version_read_field BUILD_NUMBER)"
version_validate "$INTERVAL_VERSION"
version_build_validate "$INTERVAL_BUILD"

INTERVAL_OUTPUT="${INTERVAL_OUTPUT:-$PWD/build}"
INTERVAL_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/interval-package.XXXXXX")"
INTERVAL_ICON_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/interval-icon.XXXXXX")"
trap 'rm -rf "$INTERVAL_STAGE" "$INTERVAL_ICON_ROOT"' EXIT
INTERVAL_APP="$INTERVAL_STAGE/Interval.app"
mkdir -p "$INTERVAL_OUTPUT"
# Idempotent re-runs for the same version: clear any stale artifacts first.
rm -f "$INTERVAL_OUTPUT/Interval-$INTERVAL_VERSION-arm64.zip" \
      "$INTERVAL_OUTPUT/Interval-$INTERVAL_VERSION-arm64.dmg" \
      "$INTERVAL_OUTPUT/SHA256SUMS.txt"
swift build --scratch-path "$INTERVAL_SCRATCH" -c release --arch arm64
INTERVAL_BIN="$(swift build --scratch-path "$INTERVAL_SCRATCH" -c release --arch arm64 --show-bin-path)"
mkdir -p "$INTERVAL_APP/Contents/MacOS" "$INTERVAL_APP/Contents/Resources"
cp "$INTERVAL_BIN/Interval" "$INTERVAL_APP/Contents/MacOS/Interval"
cp Resources/Info.plist "$INTERVAL_APP/Contents/Info.plist"
version_set_metadata "$INTERVAL_APP/Contents/Info.plist" "$INTERVAL_VERSION" "$INTERVAL_BUILD"
INTERVAL_ICONSET="$INTERVAL_ICON_ROOT/AppIcon.iconset"
swift scripts/make-icon.swift "$INTERVAL_ICONSET"
iconutil -c icns "$INTERVAL_ICONSET" -o "$INTERVAL_APP/Contents/Resources/AppIcon.icns"
# Built-in soundscapes are synthesized at package time (no binary audio assets in git).
swift scripts/make-sounds.swift "$INTERVAL_APP/Contents/Resources/sounds"
xattr -cr "$INTERVAL_APP"
codesign --force --options runtime --sign "${INTERVAL_SIGN_IDENTITY:--}" "$INTERVAL_APP"
codesign --verify --deep --strict "$INTERVAL_APP"
lipo "$INTERVAL_APP/Contents/MacOS/Interval" -verify_arch arm64
ditto -c -k --keepParent "$INTERVAL_APP" "$INTERVAL_OUTPUT/Interval-$INTERVAL_VERSION-arm64.zip"
ln -s /Applications "$INTERVAL_STAGE/Applications"
hdiutil create -volname "Interval" -srcfolder "$INTERVAL_STAGE" -ov -format UDZO "$INTERVAL_OUTPUT/Interval-$INTERVAL_VERSION-arm64.dmg" >/dev/null
(cd "$INTERVAL_OUTPUT" && shasum -a 256 "Interval-$INTERVAL_VERSION-arm64.zip" "Interval-$INTERVAL_VERSION-arm64.dmg" > SHA256SUMS.txt)
printf 'Packaged: %s (version %s, apple %s, build %s)\n' \
  "$INTERVAL_OUTPUT" "$INTERVAL_VERSION" "$(version_apple_version "$INTERVAL_VERSION")" "$INTERVAL_BUILD"
