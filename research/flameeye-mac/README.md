# Flameeye P32 and NegPy · 火眼光谱与 NegPy

[中文说明](#中文说明)

Flameeye is a macOS companion for research on RGB film scanning with NegPy 0.67 Metal. Build and run it as a separate application. It uses USB to read the spectrometer. The NegPy reader opens the session database and selected RAW files in read-only mode.

![Bilingual diagram of the Flameeye film scanning workflow](assets/film-scan-workflow.svg)

![Measured example of three spectral shares and their targets](assets/film-balance-example.svg)

This example uses readings from one P32 session. The percentages show each band's share of the measured spectrum. Check the camera exposures with a new RAW triplet.

图中数值来自一次 P32 实测。百分比表示各波段在测量光谱中的份额。用新的三张 RAW 核对相机曝光。

## Build on macOS

Use macOS 13 or later on Apple Silicon with the Xcode command line tools. Swift Package Manager can build the application target directly:

```sh
cd research/flameeye-mac
swift build -c release
```

Use the matching LibRaw 0.22 headers and the rawpy framework from your NegPy Apple Silicon build to package the application. Set the header path to the directory that contains `libraw/libraw.h`. The framework path must contain `libraw_r.25.dylib` and its dependencies in `__dot__dylibs`.

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

The session reader uses the NegPy 0.67 SQLite session schema to find the active red, green and blue files. It checks the `NegPy-AppleSilicon-067` and `NegPy` application support directories. The bundled reader measures Bayer P99.9 in a fixed region at the film border. It reads full-size, unrotated Panasonic S1H RW2 files. Keep a clean film-base patch at that position for comparable readings.

Optional wavelength corrections are local to each instrument. Put your own configuration in `~/Library/Application Support/Flameeye/WavelengthCorrection.json`. Supply `model`, `serial`, `firmware` and an `anchors` array with increasing `rawNM` and `referenceNM` values. Restart Flameeye after changing the file.

## 中文说明

火眼光谱是独立的 macOS 工具，用于研究三色分拍时透过片基的灯光比例。P32 经 USB 采集光谱，
火眼从 NegPy 0.67 的会话中只读识别当前选中的三色组，再读取相应的相机原始文件。
这套流程保留 P32 波段积分和相机通道响应两类数据，方便复测和复用。

1. 固定相机、灯、片基和探头位置。保持快门、ISO、光圈一致，分别拍红、绿、蓝三张。
2. 保持拍摄时三路灯的档位，用 P32 记录同一片基的混光光谱。将这组相机通道响应与 P32 起点配对。
3. 火眼按各路相机响应的倒数调整对应波段的份额，再将三个目标归一化。按实时提示调灯后，用相同相机设置复拍三张，检查通道响应与饱和情况。
4. 在 NegPy 选中新三色组，在火眼点「保存本次配平」并读取当前三色组。确认文件对应关系后保存，或导出为 JSON。以后可用「光谱复现」找回当时的透片光谱比例。

屏幕上的容差用于判断 P32 光谱比例与目标的差异。模型假设三路灯可近似独立调节，
相机响应在线性范围内随光量变化。光谱比例、总光量和相机饱和情况应分别查看。
当前随附的 RAW 读数工具使用 Panasonic S1H 全尺寸、未旋转 RW2 的固定片基采样区域。
若更换灯、片基、相机或摆位，请重新采集配对数据。macOS 构建命令和可选波长修正格式见上文。
