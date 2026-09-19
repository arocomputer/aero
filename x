#!/bin/sh
# Shared commands for contributors and CI.
set -eu
cd "$(dirname "$0")"

# The product name lives here and nowhere else: it names the bundle and fills Info.plist, and the code
# reads it back from the bundle. BUNDLE_ID also names the history folder, so keep it when renaming
# unless a fresh profile is wanted.
NAME=Aro
BUNDLE_ID=com.fschrhunt.aro
APP=build/$NAME.app
SOURCES="Sources Tests Package.swift"

command=${1:-check}
if [ "$#" -gt 0 ]; then shift; fi
case "$command" in
  check)
    ./x quality
    ./x test
    ;;
  quality)
    ./x lint
    ./x guard
    ;;
  fmt) swift format --in-place --recursive $SOURCES ;;
  lint)
    swift format lint --strict --recursive $SOURCES
    swift build -Xswiftc -warnings-as-errors
    ;;
  test)
    # With only the Command Line Tools installed, SwiftPM does not always find the Swift Testing macro
    # plugin. Naming its folder is harmless when Xcode is present.
    swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing" "$@"
    ;;
  guard)
    python3 scripts/guard.py
    python3 -m unittest discover -s scripts/hooks -p 'test_*.py'
    ;;
  hooks) python3 scripts/hooks/install.py ;;
  app)
    swift build -c release
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS"
    cp .build/release/Browser "$APP/Contents/MacOS/$NAME"
    sed -e "s/__NAME__/$NAME/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" Info.plist > "$APP/Contents/Info.plist"
    scripts/icon.sh AppIcon.icon "$APP/Contents/Resources"
    codesign --force --sign - "$APP"
    ;;
  run)
    ./x app
    open "$APP"
    ;;
  clean) rm -rf .build build ;;
  *) echo 'usage: ./x [hooks|check|quality|fmt|lint|test|guard|app|run|clean]' >&2; exit 2 ;;
esac
