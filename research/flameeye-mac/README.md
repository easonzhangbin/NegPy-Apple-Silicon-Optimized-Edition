# Flameeye P32 and NegPy · 火眼光谱与 NegPy

[中文操作与检测说明](#中文操作与检测说明)

Flameeye is a macOS companion for RGB film scanning with NegPy 0.67. Balance exposure on a clear patch of film base using the camera readings. Use the P32 USB spectrometer to save a measured lighting reference for the next session. An optional JSON report from the separate NegPy film-base meter brings the camera readings into Flameeye.

![Film-base exposure balance and P32 lighting reference workflow](assets/film-scan-workflow.svg)

## Build and run

Use macOS 13 or later on Apple Silicon with the Xcode command line tools. Build Flameeye from the NegPy repository root.

```sh
./research/flameeye-mac/build-app.sh
```

Open `research/flameeye-mac/dist/Flameeye Mac.app`. To export camera measurements from NegPy, start the optional meter from the same repository root.

```sh
uv run --locked python research/flameeye-mac/negpy_report_picker.py
```

The meter opens the `NegPy-AppleSilicon-067` session by default. For another profile, pass `--settings-db` with its `settings.db` path.

Flameeye uses LG1055 Regular and Light for Latin text and digits when you install those fonts on your Mac. Otherwise, it uses the system font.

## Balance the film base

1. Fix the film and camera. Shoot three RAWs with only one RGB lamp on at a time. Keep shutter speed, ISO, and aperture the same.
2. Select the trichrome group in NegPy. In the optional meter, click **Reload current group** and check the three file names. Draw one rectangle inside a clean, clear gap between frames. Check that the rectangle covers the same clear patch in all three exposures.
3. Click **Export report**. Under **相机片基验收** in Flameeye's **片基配平** view, click **读取最新报告**. Use **选择 JSON…** for a specific file. Confirm the report names the current triplet.
4. Adjust the lamps using the camera EV differences. Reshoot all three exposures, use the same camera settings and clear patch, and read the new report. The film base passes when the largest difference between the three P50 readings is at most **0.20 EV** and the patch passes the signal and clipping checks.

P50 is the median linear signal of the matching camera channel in the clear patch. The maximum EV difference is `log₂(highest P50 / lowest P50)`. P99.9 describes the bright end of the same patch. The report also carries the rectangle, camera settings, file names, and a content ID. Flameeye imports the JSON measurements. The separate NegPy meter reads the RAW files.

## Save a measured lighting reference

Turn on all three lamps at the levels used for the camera exposures. Start continuous P32 measurement through the film base. When the reading is stable, click **仅保存光谱参考**. To include a passing camera report, confirm that the film base, placement, and lamp levels match, then click **保存已验收配平**.

To reproduce the light later, select the record in **已保存配平**. Compare the live P32 band shares and integrated total with the reference under **光谱复现**. Keep the film base, light mode, and probe placement consistent.

Camera acceptance covers exposure balance within the clear patch. Assess color in the image area separately.

## 中文操作与检测说明

片基配平以相机在同一块透明片基上的实拍曝光为准。火眼通过 USB 读取 P32，可保存一份实测光谱供下次复现。需要在火眼里查看相机读数时，可用独立的「NegPy 片基测光」工具导出 JSON。原片由 NegPy 测光工具读取，火眼导入测量报告。

1. 固定相机和胶片。红、绿、蓝灯每次只点亮一路，各拍一张 RAW。保持快门、ISO 和光圈一致。
2. 在 NegPy 选中这组三色合成。在测光工具里点 **Reload current group**，核对文件名。在预览框选一块干净的帧间透明片基，避开画格、片边字、灰尘和片夹阴影。核对三张的同一矩形都覆盖这块片基。
3. 点 **Export report**。在火眼的「片基配平」中找到「相机片基验收」，点「读取最新报告」，也可用「选择 JSON…」导入指定报告。核对三张文件名。
4. 按相机读数的 EV 差调灯，用相同相机设置和片基区域再拍三张，读取新报告。三路 P50 最大档差 **不超过 0.20 EV**，且片基通过信号和裁切检查，即通过片基验收。

P50 是透明片基区域内、对应相机通道的线性信号中位数。最大档差为 `log₂(最高 P50 / 最低 P50)`。P99.9 用于查看同一区域的亮端余量。报告还包含取样矩形、拍摄参数、文件名和原片内容标识。

### 保存实测光谱参考

保持相机实拍时的各路灯档，同时点亮三路灯。用 P32 连续测量透过片基的混光，读数稳定后点「仅保存光谱参考」。如需同时保存已通过的相机报告，勾选同片基、同摆位和对应灯档的确认项，再点「保存已验收配平」。

下次保持相同的片基、灯光模式和探头摆位。在「已保存配平」选择记录，在「光谱复现」中对照实测波段份额和积分总量。

片基验收只覆盖取样区域的曝光平衡。画格内的颜色需要单独检查。

## Local wavelength correction

Put the optional per-device configuration in `~/Library/Application Support/Flameeye/WavelengthCorrection.json`. Supply `model`, `serial`, `firmware`, and an `anchors` array with increasing `rawNM` and `referenceNM` values. Restart Flameeye after changing the file.
