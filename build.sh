#!/usr/bin/env bash
# Builds Dictate.app into ./build and (with --install) copies it to /Applications.
#
# Optional settings (environment variables):
#   SIGN_IDENTITY  name of a code signing certificate in your login keychain.
#                  Signing with the same certificate every time lets macOS keep the
#                  Accessibility and Keychain permissions across rebuilds.
#                  Empty (the default) means ad hoc signing.
# The bundle id is read from Info.plist (CFBundleIdentifier).
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Dictate.app
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Info.plist)
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -o "$APP/Contents/MacOS/Dictate" Sources/main.swift \
  -framework AppKit -framework AVFoundation -framework Security -framework ServiceManagement 2>&1 | grep -v "^$" || true
[ -x "$APP/Contents/MacOS/Dictate" ] || { echo "build failed"; exit 1; }
cp Info.plist "$APP/Contents/Info.plist"
if [ -n "$SIGN_IDENTITY" ] && security find-identity -p codesigning | grep -qF "$SIGN_IDENTITY"; then
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  [ -n "$SIGN_IDENTITY" ] && echo "certificate \"$SIGN_IDENTITY\" not found, signing ad hoc"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
echo "built $APP ($BUNDLE_ID)"
if [ "${1:-}" = "--install" ]; then
  pkill -x Dictate || true
  rm -rf /Applications/Dictate.app
  cp -R "$APP" /Applications/
  echo "installed /Applications/Dictate.app"
fi
