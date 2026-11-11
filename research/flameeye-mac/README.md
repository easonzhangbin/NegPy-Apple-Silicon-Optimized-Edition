# Flameeye P32 for macOS · 火眼 P32 光谱

[中文操作说明](#中文操作说明)

Flameeye reads a P32 spectrometer over USB. On one page, measure film-base transmittance, estimate the mixed light from the three single-lamp captures, and compare the estimate with a live measurement.

![P32 film-base transmittance and lighting reference workflow](assets/film-scan-workflow.svg)

## Build and run

Use macOS 13 or later on Apple Silicon with the Xcode command line tools. Build Flameeye from the repository root.

```sh
./research/flameeye-mac/build-app.sh
```

Open `research/flameeye-mac/dist/Flameeye Mac.app`. Connect the P32 and select it in the main window. Open **RGB 校准** for the film-base workflow.

Flameeye uses LG1055 Regular and Light for Latin text and digits when these fonts are available. Otherwise, it uses the system font.

During continuous measurement, the spectrum line and fill move between successive frames. The transition follows the measurement cadence and stops at the latest frame. Hover values show the latest measured sample. The app honors the macOS Reduce Motion setting. Measurement values and CSV exports retain the instrument readings.

## i1Display measurements

Click **i1Display** to open the colorimeter window. This window uses the separately installed [ArgyllCMS](https://www.argyllcms.com/) `spotread` tool. Flameeye searches common installation folders, including an Argyll folder in Downloads. Use the tool picker if the tool is elsewhere. ArgyllCMS is an external AGPL-licensed dependency and is not included in this app.

1. Connect one i1Display3-family instrument over USB, such as an i1Display Pro. Close another measurement application if it holds the instrument.
2. Select **发光测量** for a display or light panel. Move the diffuser away from the lens. Select **环境光测量** for illuminance, with the diffuser covering the lens.
3. Keep the target and instrument still. Start a single reading or continuous measurement. Emissive Y is luminance in cd/m². Ambient Y is illuminance in lx. Export CSV to save the displayed reading.
4. In emissive mode, select a matching CCSS or CCMX correction when available. The default uses the instrument's generic correction. Absolute accuracy for a narrowband source needs a suitable correction. Ambient mode uses the instrument's diffuser calibration.

The window shows XYZ and xy chromaticity. CCT and Duv come from ArgyllCMS and apply to near-white light. An i1Display cannot supply a spectrum, peak wavelengths, band integrals, or CRI. Its readings do not establish camera-channel exposure balance or replace the P32 film-base reference.

## ① Capture film-base transmittance

1. Set each lamp to the level you plan to use. Fix the light and probe positions. Block stray light.
2. Turn on one RGB lamp at a time. For each lamp, record **无片基（首测）**, **有片基**, and **无片基（复测）**. Keep that lamp on at the same level throughout its three captures. Cover the entire probe opening with the clear film base for the middle capture.
3. Complete all nine captures at the P32 exposure set by the first no-film capture. For each lamp, the app divides the through-film band integral by the average of its two no-film integrals. Use **无片基前后变化** to check for drift during the sequence.

## ② Compare the lighting in 片基配平

After all nine captures, **单色合成参考** shows the estimated mixed light. For each through-film capture, Flameeye sums the signal in the same three nonoverlapping bands used for live readings. It adds the contributions from all three lamps in each band and calculates their shares of the combined total. The estimate assumes the lamps give the same output at those settings when they run together.

1. Turn on all three lamps at the same working levels. Keep the film base and probe in place. Click **开始连续测量** to compare the mixed light with the estimate.
2. When the live readings are stable, click **保存片基光谱参考** and name the record. The record stores the measured mixed-light band shares and total, with the device and exposure details.
3. In the next session, use the same P32, film base, light mode, and placement. Select the record in **已保存参考** and compare the live readings with **已保存混光参考**. Compare integrated totals at the same P32 exposure.

The band shares describe the P32 signal integrated over three wavelength ranges for your setup.

![Illustrative band shares in a saved P32 reference](assets/film-balance-example.svg)

## 中文操作说明

火眼通过 USB 读取 P32。在同一页先测片基透过率，再根据三路单色实测估算混光，并用实时混光测量对照。连接 P32 后，在主窗口打开「RGB 校准」。

连续测量时，光谱线和填充在相邻帧之间平滑过渡，过渡速度随采样间隔调整。停止测量后显示最后一帧。悬浮数值显示最新实测采样。软件遵循 macOS 的「减少动态效果」设置，测量数值和 CSV 导出保留仪器实测值。

### i1Display 色度与亮度

点主窗口的「i1Display」打开独立测量窗口。此功能调用单独安装的 [ArgyllCMS](https://www.argyllcms.com/) `spotread` 工具。软件会搜索常见目录，包括「下载」中的 Argyll 文件夹。工具位于其他位置时，可手动选择。应用不附带 ArgyllCMS 可执行文件。

1. 通过 USB 连接一台 i1Display3 系列仪器，例如 i1Display Pro。如果其他测量软件占用仪器，请先结束其测量。
2. 测显示器或灯板时选「发光测量」，移开镜头前的扩散盖。测环境照度时选「环境光测量」，让扩散盖覆盖镜头。
3. 固定目标和仪器，进行单次或连续测量。发光模式的 Y 是亮度，单位 cd/m²；环境光模式的 Y 是照度，单位 lx。用「导出 CSV」保存当前读数。
4. 发光模式下，有匹配的 CCSS 或 CCMX 校正文件时，可选择文件。默认采用仪器通用校正。窄带光源的绝对精度需要匹配的校正。环境光模式使用仪器扩散罩校正。

窗口显示 XYZ、xy 色度，以及 ArgyllCMS 给出的色温和 Duv。色温只适合接近白光的目标。i1Display 不提供光谱、峰位、波段积分或显色指数。这些读数不能直接判定相机三通道的曝光配平，也不替代 P32 的片基光谱参考。

### ① 片基透过率采集

1. 将各路灯设到准备实际使用的档位。固定灯和探头的位置，并遮挡杂光。
2. 每次只开一路灯。每色按「无片基（首测）」「有片基」「无片基（复测）」的顺序采集。三次都保持该路灯亮、灯档和摆位一致。有片基时用透明片基完全覆盖探头入光口。
3. 九次采集均使用首次无片基测量锁定的 P32 曝光。软件以每色的透片波段积分除以两次无片基积分的平均值，得到透过率。查看「无片基前后变化」判断该路采集期间是否有漂移。

### ② 片基配平

九次采集完成后，「单色合成参考」显示混光估算。软件对三路单色透片光谱分别按实时读数的三个互不重叠波段求和，再把每个波段内的三路贡献相加，计算各波段占合计信号的份额。估算以三路灯同开时仍保持各自输出为前提。

1. 按采集时各自的工作档位，同时打开三路灯，保持片基和探头摆位。点「开始连续测量」，将实测混光和估算对照。
2. 等混光实测稳定后，点「保存片基光谱参考」并命名。记录包含实测波段份额、积分合计、仪器和曝光信息。
3. 下次使用同一台 P32、同一片基、灯光模式和摆位。在「已保存参考」选择记录，将实时读数和「已保存混光参考」对照。在相同 P32 曝光时间下对照积分合计。

## Local wavelength correction

Put the optional device configuration in `~/Library/Application Support/Flameeye/WavelengthCorrection.json`. Supply `model`, `serial`, `firmware`, and an `anchors` array with increasing `rawNM` and `referenceNM` values. Restart Flameeye after changing the file.
