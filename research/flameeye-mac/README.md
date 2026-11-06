# Flameeye P32 and NegPy

Flameeye is a macOS companion for research on RGB film scanning with NegPy 0.67 Metal. Build and run it as a separate application. It uses USB to read the spectrometer. The NegPy reader opens the session database and selected RAW files in read-only mode.

## Build on macOS

Use macOS 13 or later on Apple Silicon with the Xcode command line tools. Swift Package Manager can build the application target directly:

```sh
cd research/flameeye-mac
swift build -c release
```

Use the matching LibRaw 0.22 headers and the rawpy framework from your NegPy Apple Silicon build to package the application. Set the header directory to the directory that contains `libraw/libraw.h`. The framework path must contain `libraw_r.25.dylib` and its dependencies in `__dot__dylibs`.

```sh
FLAMEEYE_LIBRAW_HEADERS="/path/to/LibRaw" \
FLAMEEYE_RAWPY_FRAMEWORK="/Applications/NegPy Apple Silicon.app/Contents/Frameworks/rawpy" \
./build-app.sh
```

Open `dist/Flameeye Mac.app`. The application bundle contains the decoder and its license notices. See [the NegPy Apple Silicon build instructions](../../README.APPLE_SILICON.md) for the matching NegPy build.

## Record and verify a balance

1. Keep the camera, lens, film base and probe position fixed. Use the same shutter, ISO and aperture for all three exposures.
2. Shoot one RAW per primary with the other lamps off. Measure the same clean, unexposed patch of the film base in each shot.
3. With the three primaries at those same lamp levels, take a stable P32 reading. Enter the corresponding RAW responses in **实拍反推** and record this baseline as one pair.
4. Adjust the RGB lights toward the displayed targets. Shoot a new triplet at the adjusted levels and check the RAW responses and clipping before accepting the balance.
5. Select that triplet in NegPy. In Flameeye, open **保存本次配平** and select **读取 NegPy 当前三色组**. Check the three filenames before saving or exporting the record as JSON.

Save a fresh P32 baseline and a fresh triplet together for each correction. Reusing responses from earlier lamp levels applies the earlier correction again. **光谱复现** recalls the measured RGB shares and total from a named record.

The model divides each baseline band share by its corresponding linear RAW response, then normalizes the three results. This assumes each band primarily tracks one LED and that its output scales with the RAW response. The P32 tolerance measures agreement with the spectral target. Check camera exposure and clipping in the new RAW triplet.

## Research scope

The session reader uses the NegPy 0.67 SQLite session schema to find the active red, green and blue files. It checks the `NegPy-AppleSilicon-067` and `NegPy` application support directories. The bundled reader measures Bayer P99.9 in a fixed film-border region of full-size, unrotated Panasonic S1H RW2 files. Keep a clean film-base patch at that position for comparable readings.

Optional wavelength corrections are local to each instrument. Put your own configuration in `~/Library/Application Support/Flameeye/WavelengthCorrection.json`. Supply `model`, `serial`, `firmware` and an `anchors` array with increasing `rawNM` and `referenceNM` values. Restart Flameeye after changing the file.
