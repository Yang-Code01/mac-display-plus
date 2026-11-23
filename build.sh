#!/usr/bin/env bash
# Builds display++.app from source. No Xcode project, no SPM: the Command Line
# Tools toolchain is enough, and an explicit file list keeps the build readable.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="display++"
EXECUTABLE="displaypp"
BUNDLE="build/${APP_NAME}.app"
SDK_TARGET="arm64-apple-macos26.0"

echo "==> Cleaning"
rm -rf "$BUNDLE"
mkdir -p build

echo "==> Compiling"
# shellcheck disable=SC2046
swiftc -O -swift-version 5 \
  -target "$SDK_TARGET" \
  -framework AppKit -framework SwiftUI -framework IOKit \
  -framework CoreGraphics -framework ApplicationServices \
  $(find Sources -name '*.swift') \
  -o "build/${EXECUTABLE}"

echo "==> Assembling bundle"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "build/${EXECUTABLE}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"

echo "==> Localizations"
# Each .lproj becomes a real bundle resource so NSLocalizedString can resolve it.
for lproj in Resources/*.lproj; do
  cp -R "$lproj" "${BUNDLE}/Contents/Resources/"
done
printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"

echo "==> Icon"
if [[ ! -f build/AppIcon.icns ]]; then
  swiftc -O -swift-version 5 Scripts/make-icon.swift -o build/make-icon
  ./build/make-icon build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "${BUNDLE}/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc)"
# Ad-hoc is enough for local use. It is *not* notarised, so Gatekeeper will warn
# if the bundle is ever moved to another Mac.
codesign --force --deep --sign - --timestamp=none "${BUNDLE}" 2>/dev/null

echo "==> Done"
echo "    ${BUNDLE}"
echo "    run:  open '${BUNDLE}'"
echo "    probe: '${BUNDLE}/Contents/MacOS/${APP_NAME}' --probe"
