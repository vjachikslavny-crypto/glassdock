#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
out="$PWD/build"
mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
version=$(cat VERSION)
app="$stage/image/GlassDock.app"
helper="$app/Contents/Helpers/GlassDock Dock.app"
mkdir -p "$app/Contents/"{MacOS,Resources,Helpers,Library/LaunchAgents} "$helper/Contents/MacOS" "$stage/upper"

build_universal() {
    local binary=$1 name=$2
    shift 2
    for arch in arm64 x86_64; do
        xcrun --sdk macosx swiftc -swift-version 5 -O -target "$arch-apple-macos15.0" \
            -module-name "$name" "$@" -o "$stage/$name-$arch"
    done
    xcrun lipo -create "$stage/$name-arm64" "$stage/$name-x86_64" -output "$binary"
}

cp dock/Info.plist "$helper/Contents/"
build_universal "$helper/Contents/MacOS/DockGlass" DockGlass dock/*.swift
codesign --force --sign - "$helper"
bash upper/stage-sheer.sh "$stage/upper"
ditto "$stage/upper/Sheer.app" "$app/Contents/Helpers/Sheer.app"
cp upper/LICENSE.Sheer "$app/Contents/Resources/"

cp app/Info.plist "$app/Contents/"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIconFile -string GlassDock "$app/Contents/Info.plist"
cp app/app.glassdock.restore.plist "$app/Contents/Library/LaunchAgents/"
swift art/MakeIcon.swift "$app/Contents/Resources/GlassDock.icns"
build_universal "$app/Contents/MacOS/GlassDock" GlassDockLauncher -parse-as-library app/*.swift
codesign --force --sign - "$app"
codesign --verify --all-architectures --deep --strict "$app"
ln -s /Applications "$stage/image/Applications"
hdiutil create -quiet -volname GlassDock -fs HFS+ -format UDZO -srcfolder "$stage/image" "$stage/GlassDock.dmg"
hdiutil verify -quiet "$stage/GlassDock.dmg"
mv -f "$stage/GlassDock.dmg" "$out/GlassDock.dmg"
(cd "$out" && shasum -a 256 GlassDock.dmg > GlassDock.dmg.sha256)
printf 'Built GlassDock %s in %s\n' "$version" "$out"
