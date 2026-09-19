#!/bin/sh
# Puts the app icon into a bundle's Resources folder: icon.sh <AppIcon.icon> <Resources dir>
#
# Apple's route is to compile the Icon Composer file with actool, which ships in Xcode. That produces
# Assets.car, from which macOS renders the Default, Dark, Clear and Tinted looks itself, plus an
# AppIcon.icns for older systems. Without Xcode the best available is a plain AppIcon.icns rendered by
# Icon Composer's ictool: it shows the Default look in every appearance.
set -e
icon=$1
resources=$2
mkdir -p "$resources"

if actool=$(xcrun --find actool 2>/dev/null); then
    "$actool" "$icon" --compile "$resources" --app-icon AppIcon --include-all-app-icons \
        --platform macosx --target-device mac --minimum-deployment-target 14.0 \
        --enable-on-demand-resources NO --development-region en \
        --output-partial-info-plist "$(mktemp)" --errors --warnings >/dev/null
    echo "icon: compiled with actool, all appearances"
    exit 0
fi

ictool="/Applications/Icon Composer.app/Contents/Executables/ictool"
if [ ! -x "$ictool" ]; then
    echo "icon: skipped, needs Xcode (actool) or Icon Composer (ictool)"
    exit 0
fi

# The artwork fills 824/1024 of each image; the transparent margin is what keeps a classic .icns the
# same size as its neighbors in the Dock.
iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p "$iconset"
for entry in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
    size=${entry%%:*}
    file="$iconset/icon_${entry#*:}.png"
    art=$((size * 824 / 1024))
    "$ictool" "$icon" --export-image --output-file "$file" --platform macOS --rendition Default \
        --width "$art" --height "$art" --scale 1 >/dev/null
    sips --padToHeightWidth "$size" "$size" "$file" >/dev/null
done
iconutil --convert icns --output "$resources/AppIcon.icns" "$iconset"
echo "icon: Default look only; install Xcode to get the Dark, Clear and Tinted looks"
