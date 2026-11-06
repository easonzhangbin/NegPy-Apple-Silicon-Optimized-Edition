#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$project_dir"

swift build -c release --product FlameeyeMac
binary_dir="$(swift build -c release --show-bin-path)"

dist_dir="$project_dir/dist"
app_name="Flameeye Mac.app"
mkdir -p "$dist_dir"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/flameeye-staging.XXXXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

bundle="$staging_dir/$app_name"
iconset="$staging_dir/Spectrum.iconset"
resources="$bundle/Contents/Resources"
mkdir -p "$bundle/Contents/MacOS" "$resources" "$iconset"
cp -X "$binary_dir/FlameeyeMac" "$bundle/Contents/MacOS/FlameeyeMac"
cp -X "$project_dir/Info.plist" "$bundle/Contents/Info.plist"

swift "$project_dir/Tools/GenerateIcon.swift" "$iconset"
iconutil -c icns "$iconset" -o "$resources/Spectrum.icns"
xattr -cr "$bundle"
codesign --force --sign - "$bundle"
codesign --verify --deep --strict "$bundle"

rm -rf "$dist_dir/$app_name"
mv "$bundle" "$dist_dir/$app_name"
printf '\n%s\n' "$dist_dir/$app_name"
