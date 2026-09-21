#!/bin/sh
# Shared commands for contributors and CI.
set -eu
cd "$(dirname "$0")"

# The product name lives here and nowhere else: it names the bundle and fills Info.plist, and the code
# reads it back from the bundle. BUNDLE_ID also names the browser data folder.
NAME=Aero
BUNDLE_ID=com.fschrhunt.aero
APP=build/$NAME.app
# The debug build is a separate product with its own identity, so its history, site icons, pins and
# settings are never the ones you browse with. Nothing it does can touch the real app's data.
DEV_NAME=${NAME}Dev
DEV_APP=build/$DEV_NAME.app
DEV_BUNDLE_ID=$BUNDLE_ID.dev
SOURCES="Sources Tests Package.swift"
MIN_MACOS=15.4

# Links against the selected SDK's real version. Swift's Command Line Tools otherwise stamp the
# deployment target as the SDK version, which makes AppKit use compatibility-era appearances.
swift_with_selected_sdk() {
  sdk_version=$(xcrun --sdk macosx --show-sdk-version)
  swift "$@" -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_MACOS" -Xlinker "$sdk_version"
}

# Lays out a bundle with Sparkle: $1 build directory, $2 bundle path, $3 product name,
# $4 bundle identifier, $5 update public key. Callers add icons and sign the finished bundle.
assemble() {
  rm -rf "$2"
  mkdir -p "$2/Contents/MacOS" "$2/Contents/Resources"
  cp "$1/Browser" "$2/Contents/MacOS/$3"
  cp -R "$1/Browser_Browser.bundle" "$2/Contents/Resources/"
  cp container-migration.plist "$2/Contents/Resources/"
  sed -e "s/__NAME__/$3/g" -e "s/__BUNDLE_ID__/$4/g" -e "s|__UPDATE_PUBLIC_KEY__|$5|g" Info.plist > "$2/Contents/Info.plist"
  python3 Scripts/sparkle.py "$2" -
}

# Signs a local bundle: $1 bundle path, $2 sandbox identity, $3 entitlement output directory.
# Ad hoc signatures have no team to share with Sparkle, so local builds allow its library.
sign_local() {
  sed "s/__BUNDLE_ID__/$2/g" Sandbox.entitlements > "$3/sandbox.entitlements"
  python3 -c 'import plistlib, sys; from pathlib import Path; root = Path(sys.argv[1]); value = plistlib.loads((root / "sandbox.entitlements").read_bytes()); value["com.apple.security.cs.disable-library-validation"] = True; (root / "development.entitlements").write_bytes(plistlib.dumps(value))' "$3"
  codesign --force --options runtime --entitlements "$3/development.entitlements" --sign - "$1"
  codesign --verify --deep --strict "$1"
}

command=${1:-check}
if [ "$#" -gt 0 ]; then shift; fi
case "$command" in
  check)
    ./x quality
    ./x test
    # The bundle too, because a broken Info.plist, a missing resource or an icon that stopped
    # compiling shows up nowhere else, and CI builds it on every pull request.
    ./x app
    # The website is checked when it has its own dependencies installed, as CI does on the paths that
    # touch it. A Swift-only change should not fail on a missing npm install.
    if [ -x Website/node_modules/.bin/astro ]; then
      ./x website check
    else
      echo "website: skipped; run (cd Website && npm ci) to check it too"
    fi
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
    # AppKit tests share the main thread and create WebKit processes. Running them sequentially
    # avoids starving page callbacks when the expanded suite runs on a small CI runner.
    swift_with_selected_sdk test --no-parallel -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing" "$@"
    ;;
  shot)
    # Writes a picture of a real browser window to a file without ever putting one on screen; see
    # Tests/Window/Shot.swift. usage: ./x shot [url] [file.png] [seconds]
    AERO_SHOT_URL=${1:-about:blank} AERO_SHOT_OUTPUT=${2:-build/shot.png} AERO_SHOT_SETTLE=${3:-4} \
      ./x test --filter windowShot --no-parallel
    ;;
  survey)
    # Measures how often the strip names the color real pages show; see Tests/Page/TintSurvey.swift.
    AERO_SURVEY=1 ./x test --filter tintSurvey "$@"
    ;;
  log)
    # Follows what a dev build started with AERO_LOG has to say; see Sources/App/Log.swift.
    file="$HOME/Library/Containers/$DEV_BUNDLE_ID/Data/Library/Application Support/$DEV_BUNDLE_ID/log.txt"
    test -f "$file" || { echo "no log yet: run AERO_LOG=tint,reload,sleep ./x dev" >&2; exit 1; }
    tail -f "$file"
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
    assemble .build/release "$APP" "$NAME" "$BUNDLE_ID" "${AERO_UPDATE_PUBLIC_KEY:-}"
    Scripts/icon.sh Assets/app.icon "$APP/Contents/Resources"
    sign_local "$APP" "$BUNDLE_ID" build
    ;;
  signed-app)
    : "${AERO_SIGNING_IDENTITY:?set AERO_SIGNING_IDENTITY to the certificate name from security find-identity}"
    : "${AERO_PROVISIONING_PROFILE:?set AERO_PROVISIONING_PROFILE to the downloaded provisioning profile}"
    : "${AERO_UPDATE_PUBLIC_KEY:?set AERO_UPDATE_PUBLIC_KEY to the public key from Sparkle generate_keys}"
    python3 -c 'import base64, os; value = base64.b64decode(os.environ["AERO_UPDATE_PUBLIC_KEY"], validate=True); assert len(value) == 32, "The update public key must contain 32 bytes"'
    test -f "$AERO_PROVISIONING_PROFILE"
    ./x app
    cp "$AERO_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
    python3 -c 'import plistlib; from pathlib import Path; values = {}; [values.update(plistlib.loads(Path(p).read_bytes())) for p in ["build/sandbox.entitlements", "Aero.entitlements"]]; Path("build/signing.entitlements").write_bytes(plistlib.dumps(values))'
    python3 Scripts/sparkle.py "$APP" "$AERO_SIGNING_IDENTITY"
    codesign --force --options runtime --timestamp --entitlements build/signing.entitlements \
      --sign "$AERO_SIGNING_IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"
    ;;
  dev)
    # The everyday loop: an unoptimized build, a few seconds against the fourteen `./x app` takes; its
    # own data, so it cannot touch your browsing; the Web Inspector, which a release build compiles
    # out; and the background, so it never takes the screen from you. usage: ./x dev [url]
    swift_with_selected_sdk build
    # No publisher key: the isolated debug app must never install a production update.
    assemble .build/debug "$DEV_APP" "$DEV_NAME" "$DEV_BUNDLE_ID" ""
    # Out of the Dock and the app switcher: a build under test should not take a place among the apps
    # you actually use. macOS drops the menu bar with it; see AGENTS.md for what that costs.
    /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$DEV_APP/Contents/Info.plist" >/dev/null
    mkdir -p build/dev
    sign_local "$DEV_APP" "$DEV_BUNDLE_ID" build/dev
    # `open` reactivates a running copy rather than launching the new build, so the old one goes first.
    if pkill -f "$DEV_APP/Contents/MacOS/$DEV_NAME"; then sleep 0.5; fi
    # An app launched by `open` does not inherit this shell's environment; AERO_LOG is handed over.
    # `open -a` resolves an application by name, so the bundle is named by its full path.
    if [ "$#" -gt 0 ]; then
      open -g --env "AERO_LOG=${AERO_LOG:-}" -a "$PWD/$DEV_APP" "$@"
    else
      open -g --env "AERO_LOG=${AERO_LOG:-}" "$PWD/$DEV_APP"
    fi
    echo "$DEV_APP is running in the background; AERO_LOG=tint,reload,sleep ./x dev then ./x log"
    ;;
  notarize-app)
    : "${AERO_NOTARY_PROFILE:?set AERO_NOTARY_PROFILE to a notarytool keychain profile}"
    ./x signed-app
    ditto -c -k --keepParent "$APP" "build/$NAME-notarization.zip"
    xcrun notarytool submit "build/$NAME-notarization.zip" --keychain-profile "$AERO_NOTARY_PROFILE" --wait --output-format json > build/notarization.json
    python3 -c 'import json; from pathlib import Path; result = json.loads(Path("build/notarization.json").read_text()); assert result.get("status") == "Accepted", "Notarization was not accepted; inspect build/notarization.json"'
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    # Distribution must include the stapled ticket, which the submission ZIP predates.
    ditto -c -k --keepParent "$APP" "build/$NAME.zip"
    ;;
  update-feed)
    : "${1:?pass a directory containing signed release archives}"
    : "${AERO_UPDATE_DOWNLOAD_PREFIX:?set the HTTPS download URL prefix for the archives}"
    test -d "$1"
    .build/artifacts/sparkle/Sparkle/bin/generate_appcast --download-url-prefix "$AERO_UPDATE_DOWNLOAD_PREFIX" "$1"
    ;;
  protection-feed)
    directory=${1:-build/protection}
    mkdir -p "$directory"
    cp Sources/Page/Trackers.txt "$directory/Trackers.txt"
    .build/artifacts/sparkle/Sparkle/bin/sign_update -p "$directory/Trackers.txt" > "$directory/Trackers.txt.sig"
    ;;
  run)
    # Builds Aero as it ships and starts it: optimized, in the Dock, on the menu bar, and browsing
    # the data you actually browse with. The command to try a change as a person would meet it.
    # `./x app` is the same build without the launch, which is what CI and a release use.
    ./x app
    # `open` brings a copy already running forward instead of starting the new build, and this bundle
    # shares its identity with the Aero you browse in, which is not something to close from a script.
    if pgrep -f "/$NAME.app/Contents/MacOS/$NAME" >/dev/null 2>&1; then
      echo "note: $NAME is already running; quit it first or you will be looking at the old build" >&2
    fi
    open "$APP" --args "$@"
    ;;
  clean) rm -rf .build build Website/.astro Website/.wrangler Website/dist ;;
  *)
    echo 'usage: ./x [dev|run|check|test|shot|log|survey|fmt|lint|quality|guard|hooks|website|app|signed-app|notarize-app|update-feed|protection-feed|clean]' >&2
    exit 2
    ;;
esac
