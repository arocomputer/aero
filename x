#!/bin/sh
# Shared commands for contributors and CI.
set -eu
cd "$(dirname "$0")"

# The product name lives here and nowhere else: it names the bundle and fills Info.plist, and the code
# reads it back from the bundle. BUNDLE_ID also names the browser data folder.
NAME=Aero
BUNDLE_ID=com.fschrhunt.aero
APP=build/$NAME.app
SOURCES="Sources Tests Package.swift"
MIN_MACOS=15.4

# Links against the selected SDK's real version. Swift's Command Line Tools otherwise stamp the
# deployment target as the SDK version, which makes AppKit use compatibility-era appearances.
swift_with_selected_sdk() {
  sdk_version=$(xcrun --sdk macosx --show-sdk-version)
  swift "$@" -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_MACOS" -Xlinker "$sdk_version"
}

command=${1:-check}
if [ "$#" -gt 0 ]; then shift; fi
case "$command" in
  check)
    ./x quality
    ./x test
    ./x website check
    ;;
  quality)
    ./x lint
    ./x guard
    ;;
  fmt) swift format --in-place --recursive $SOURCES ;;
  lint)
    swift format lint --strict --recursive $SOURCES
    swift_with_selected_sdk build -Xswiftc -warnings-as-errors
    ;;
  test)
    # With only the Command Line Tools installed, SwiftPM does not always find the Swift Testing macro
    # plugin. Naming its folder is harmless when Xcode is present.
    swift_with_selected_sdk test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing" "$@"
    ;;
  guard)
    python3 Scripts/guard.py
    python3 -m unittest discover -s Scripts/hooks -p 'test_*.py'
    ;;
  hooks) python3 Scripts/hooks/install.py ;;
  website)
    website_command=${1:-check}
    if [ "$#" -gt 0 ]; then shift; fi
    (cd Website && npm run "$website_command" -- "$@")
    ;;
  app)
    swift_with_selected_sdk build -c release
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS"
    cp .build/release/Browser "$APP/Contents/MacOS/$NAME"
    mkdir -p "$APP/Contents/Resources"
    cp -R .build/release/Browser_Browser.bundle "$APP/Contents/Resources/"
    sed -e "s/__NAME__/$NAME/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" Info.plist > "$APP/Contents/Info.plist"
    Scripts/icon.sh Assets/app.icon "$APP/Contents/Resources"
    codesign --force --sign - "$APP"
    ;;
  signed-app)
    : "${AERO_SIGNING_IDENTITY:?set AERO_SIGNING_IDENTITY to the certificate name from security find-identity}"
    : "${AERO_PROVISIONING_PROFILE:?set AERO_PROVISIONING_PROFILE to the downloaded provisioning profile}"
    test -f "$AERO_PROVISIONING_PROFILE"
    ./x app
    cp "$AERO_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
    codesign --force --options runtime --timestamp --entitlements Aero.entitlements \
      --sign "$AERO_SIGNING_IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"
    ;;
  run)
    ./x app
    open "$APP"
    ;;
  clean) rm -rf .build build Website/.astro Website/.wrangler Website/dist ;;
  *) echo 'usage: ./x [hooks|check|quality|fmt|lint|test|guard|website|app|signed-app|run|clean]' >&2; exit 2 ;;
esac
