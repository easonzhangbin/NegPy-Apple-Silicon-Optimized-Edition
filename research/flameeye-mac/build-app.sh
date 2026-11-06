#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$project_dir"

libraw_headers="${FLAMEEYE_LIBRAW_HEADERS:-$HOME/.negpy-build/apple-opt/rawpy-src/rawpy-0.27.0/external/LibRaw}"
negpy_rawpy="${FLAMEEYE_RAWPY_FRAMEWORK:-/Applications/NegPy Apple Silicon.app/Contents/Frameworks/rawpy}"
if [[ ! -f "$libraw_headers/libraw/libraw.h" || ! -f "$negpy_rawpy/libraw_r.25.dylib" ]]; then
    printf 'The NegPy attachment reader needs LibRaw 0.22 headers and the NegPy rawpy runtime. Set FLAMEEYE_LIBRAW_HEADERS and FLAMEEYE_RAWPY_FRAMEWORK.\n' >&2
    exit 1
fi

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
frameworks="$bundle/Contents/Frameworks"
mkdir -p "$bundle/Contents/MacOS" "$frameworks" "$resources/LibRawLicenses" "$iconset"
cp -X "$binary_dir/FlameeyeMac" "$bundle/Contents/MacOS/FlameeyeMac"
cp -X "$project_dir/Info.plist" "$bundle/Contents/Info.plist"

# Bundle the read-only decoder used for attaching NegPy's S1H exposures to a record.
cp -LX "$negpy_rawpy/libraw_r.25.dylib" "$frameworks/"
for library in liblcms2.2.dylib libjpeg.8.3.2.dylib libjasper.7.0.0.dylib; do
    cp -LX "$negpy_rawpy/__dot__dylibs/$library" "$frameworks/"
done
cp -X "$libraw_headers/LICENSE.CDDL" "$libraw_headers/LICENSE.LGPL" "$libraw_headers/COPYRIGHT" "$resources/LibRawLicenses/"
xcrun clang++ -std=c++17 -O2 -mmacosx-version-min=13.0 -I "$libraw_headers" \
    "$project_dir/Tools/MeasureNegPyExposure.cpp" "$frameworks/libraw_r.25.dylib" \
    -Wl,-rpath,@executable_path/../Frameworks -o "$bundle/Contents/MacOS/MeasureNegPyExposure"

swift "$project_dir/Tools/GenerateIcon.swift" "$iconset"
iconutil -c icns "$iconset" -o "$resources/Spectrum.icns"
xattr -cr "$bundle"
codesign --force --sign - "$frameworks/"*.dylib "$bundle/Contents/MacOS/MeasureNegPyExposure"
codesign --force --sign - "$bundle"
codesign --verify --deep --strict "$bundle"

rm -rf "$dist_dir/$app_name"
mv "$bundle" "$dist_dir/$app_name"
printf '\n%s\n' "$dist_dir/$app_name"
