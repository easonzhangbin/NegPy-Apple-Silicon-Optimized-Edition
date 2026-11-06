import SwiftUI

@MainActor
struct RGBCalibrationWindow: View {
    let device: Device?
    let isBusy: Bool
    let measurement: Measurement?
    let isLive: Bool
    let captureStartedAt: Date?
    let liveIssue: String?
    let toggleLive: () -> Void
    let capture: (UInt32?) async throws -> [Measurement]

    @AppStorage("filmBase.transmission.captures") private var captureData = Data()
    @State private var spectra: [RGBLightChannel: SpectrumSeries] = [:]
    @State private var pendingCapture: PendingCapture?
    @State private var spectrumIssue: String?

    private var captureExposure: UInt32? {
        guard let device else { return nil }
        return spectra.values.compactMap(\.before).first { $0.deviceID == device.id }?.exposureUS
    }

    private var captureReference: FilmBaseLiveReference? {
        guard let device else { return nil }
        let samples = RGBLightChannel.allCases.compactMap { channel -> FilmBaseSpectrum? in
            guard let series = spectra[channel], let result = series.result, abs(result.drift) <= 0.05,
                  let film = series.film, film.deviceID == device.id else { return nil }
            return film
        }
        return FilmBaseLiveReference(combining: samples)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(InstrumentColor.teal)
                    .frame(width: 40, height: 40)
                    .instrumentPanel(cornerRadius: 12)
                    .accessibilityHidden(true)
                Text("RGB 校准")
                    .font(InstrumentFont.style(.title2))
                Spacer()
                if isLive {
                    Button("停止连续测量", action: toggleLive)
                        .instrumentButton()
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        spectrumWorkspace
                        if captureReference != nil {
                            HStack {
                                Label("单色合成参考已生成", systemImage: "checkmark.circle")
                                    .foregroundStyle(InstrumentColor.teal)
                                Spacer()
                                Button("查看配平参考") { proxy.scrollTo("balance", anchor: .top) }
                                    .instrumentButton(prominent: true)
                            }
                        }

                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("② 片基配平").font(InstrumentFont.style(.headline))
                                Spacer()
                                if !isLive {
                                    Button("开始连续测量", action: toggleLive)
                                        .instrumentButton(prominent: true)
                                        .disabled(isBusy || pendingCapture != nil || device?.protocolProfile != .legacyP32)
                                }
                            }
                            if let liveIssue { issueLabel(liveIssue) }
                            LiveFilmBalanceView(measurement: measurement?.exposureRevision == nil ? nil : measurement,
                                                startedAt: isLive ? captureStartedAt : nil,
                                                captureReference: captureReference)
                        }
                        .id("balance")
                    }
                    .padding(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(20)
        .foregroundStyle(InstrumentColor.text)
        .onAppear {
            spectra = (try? JSONDecoder().decode([RGBLightChannel: SpectrumSeries].self, from: captureData)) ?? [:]
        }
    }

    private var spectrumWorkspace: some View {
        Group {
            HStack {
                Text("① 片基透过率采集").font(InstrumentFont.style(.headline))
                Spacer()
                if !spectra.isEmpty {
                    Button("开始新一组") {
                        spectra = [:]
                        captureData = Data()
                        spectrumIssue = nil
                    }
                    .instrumentButton()
                    .disabled(isBusy || pendingCapture != nil)
                    .help("清除本组采集。下一次无片基首测会重新选择曝光。")
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("按实际工作灯档逐路测红、绿、蓝。每路先测无片基，再放入片基，最后取出复测。全组沿用首次曝光。保持灯档和摆位，让片基覆盖入光口并遮挡杂光。")
                    .fixedSize(horizontal: false, vertical: true)
                if let device, device.protocolProfile == .legacyP32 {
                    let exposure = captureExposure.map { "  ·  全组曝光 \($0) µs" } ?? ""
                    Text("P32  \(device.id)\(exposure)")
                        .font(InstrumentFont.style(.caption, light: true))
                } else {
                    Text("请在主窗口连接 P32。")
                        .foregroundStyle(InstrumentColor.amber)
                }
            }
            .font(InstrumentFont.style(.callout, light: true))
            .foregroundStyle(InstrumentColor.secondary)

            if isLive {
                Text("先停止连续测量，再采集单色光谱。")
                    .font(InstrumentFont.style(.callout, light: true))
                    .foregroundStyle(InstrumentColor.secondary)
            }
            if let spectrumIssue {
                issueLabel(spectrumIssue)
                if captureExposure != nil {
                    Text("若锁定曝光不适用，请开始新一组，从无片基时较亮的一路首测。")
                        .font(InstrumentFont.style(.callout, light: true))
                        .foregroundStyle(InstrumentColor.secondary)
                }
            }

            ForEach(RGBLightChannel.allCases) { channel in
                spectrumCard(channel)
            }
            if captureReference == nil,
               RGBLightChannel.allCases.allSatisfy({ spectra[$0]?.after != nil }) {
                issueLabel("本组无法合成参考。请核对仪器、曝光及无片基前后变化，再重采不合格的光谱。")
            }
        }
    }

    private func spectrumCard(_ channel: RGBLightChannel) -> some View {
        let series = spectra[channel] ?? SpectrumSeries()
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Circle().fill(channelColor(channel)).frame(width: 7, height: 7).accessibilityHidden(true)
                Text("\(channel.title) · \(channel.band.lowerBound)–\(channel.band.upperBound) nm")
                    .font(InstrumentFont.style(.headline))
                Spacer()
                if let before = series.before {
                    Text("\(before.deviceID)  ·  \(before.exposureUS) µs")
                        .font(InstrumentFont.style(.caption, light: true))
                        .foregroundStyle(InstrumentColor.secondary)
                }
            }

            HStack(alignment: .top, spacing: 9) {
                captureStep(.before, channel: channel, series: series)
                captureStep(.film, channel: channel, series: series)
                captureStep(.after, channel: channel, series: series)
            }

            if let result = series.result {
                HStack(spacing: 14) {
                    Text("透过率 \(percent(result.transmission, digits: 2))")
                        .foregroundStyle(InstrumentColor.teal)
                    Text("衰减 \(percent(1 - result.transmission, digits: 2))")
                    Text(String(format: "%.2f 档", -log2(result.transmission)))
                    Text("无片基前后变化 \(percent(result.drift, digits: 2))")
                        .foregroundStyle(InstrumentColor.secondary)
                }
                .font(InstrumentFont.style(.callout))
                .accessibilityElement(children: .combine)
                if abs(result.drift) > 0.05 {
                    issueLabel("无片基的前后积分相差超过 5%，请检查灯光和探头位置后重采。")
                }
            } else if series.after != nil {
                issueLabel("积分无有效透过率，请核对灯档、片基和曝光后重新采集。")
            }
        }
        .padding(11)
        .instrumentPanel(cornerRadius: 13)
    }

    private func captureStep(_ phase: CapturePhase, channel: RGBLightChannel, series: SpectrumSeries) -> some View {
        let sample = series.sample(for: phase)
        let pending = pendingCapture == PendingCapture(channel: channel, phase: phase)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(phase.title).font(InstrumentFont.style(.callout))
                if pending {
                    ProgressView().controlSize(.small)
                }
            }
            Text(sample.map { String(format: "积分 %.6g", $0.area) } ?? "待采集")
                .font(InstrumentFont.style(.caption))
                .foregroundStyle(InstrumentColor.secondary)
            Button {
                captureSpectrum(channel, phase: phase)
            } label: {
                InstrumentFont.controlText(sample == nil ? "采集" : "重采")
            }
            .instrumentButton()
            .disabled(!canCapture(phase, series: series))
            .accessibilityLabel("\(channel.title) \(phase.title) \(sample == nil ? "采集" : "重采")")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func canCapture(_ phase: CapturePhase, series: SpectrumSeries) -> Bool {
        guard let device, device.protocolProfile == .legacyP32, !isBusy, pendingCapture == nil else { return false }
        if phase == .before { return true }
        guard series.before?.deviceID == device.id else { return false }
        return phase == .film || series.film != nil
    }

    private func captureSpectrum(_ channel: RGBLightChannel, phase: CapturePhase) {
        let previous = spectra[channel] ?? SpectrumSeries()
        guard let device, canCapture(phase, series: previous) else { return }
        pendingCapture = PendingCapture(channel: channel, phase: phase)
        spectrumIssue = nil
        let exposure = phase == .before ? captureExposure : previous.before?.exposureUS

        Task {
            defer { pendingCapture = nil }
            do {
                let frames = try await capture(exposure)
                let sample = try FilmBaseSpectrum(channel: channel, frames: frames, requireNormal: phase != .film)
                guard sample.deviceID == device.id, exposure == nil || sample.exposureUS == exposure else {
                    spectrumIssue = "设备或曝光与无片基首测不一致，请重新采集。"
                    return
                }

                if exposure == nil { spectra = [:] }
                switch phase {
                case .before:
                    spectra[channel] = SpectrumSeries(before: sample)
                case .film:
                    spectra[channel] = SpectrumSeries(before: previous.before, film: sample)
                case .after:
                    spectra[channel] = SpectrumSeries(before: previous.before, film: previous.film, after: sample)
                }
                captureData = try JSONEncoder().encode(spectra)
            } catch {
                spectrumIssue = error.localizedDescription
            }
        }
    }

    private func percent(_ fraction: Double, digits: Int = 3) -> String {
        guard fraction.isFinite else { return "—" }
        return String(format: "%.*f%%", digits, fraction * 100)
    }

    private func issueLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(InstrumentFont.style(.callout))
            .foregroundStyle(InstrumentColor.amber)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func channelColor(_ channel: RGBLightChannel) -> Color {
        switch channel {
        case .red: return Color(red: 1, green: 0.52, blue: 0.55)
        case .green: return Color(red: 0.53, green: 0.91, blue: 0.60)
        case .blue: return Color(red: 0.53, green: 0.70, blue: 1)
        }
    }

    private enum CapturePhase: Equatable {
        case before, film, after

        var title: String {
            switch self {
            case .before: return "无片基（首测）"
            case .film: return "有片基"
            case .after: return "无片基（复测）"
            }
        }
    }

    private struct PendingCapture: Equatable {
        let channel: RGBLightChannel
        let phase: CapturePhase
    }

    private struct SpectrumSeries: Codable {
        var before: FilmBaseSpectrum?
        var film: FilmBaseSpectrum?
        var after: FilmBaseSpectrum?

        func sample(for phase: CapturePhase) -> FilmBaseSpectrum? {
            switch phase {
            case .before: return before
            case .film: return film
            case .after: return after
            }
        }

        var result: (transmission: Double, drift: Double)? {
            guard let before, let film, let after, before.area > 0,
                  film.deviceID == before.deviceID, after.deviceID == before.deviceID,
                  film.exposureUS == before.exposureUS, after.exposureUS == before.exposureUS else { return nil }
            let baseline = (before.area + after.area) / 2
            let transmission = film.area / baseline
            let drift = (after.area - before.area) / before.area
            guard baseline > 0, transmission.isFinite, transmission > 0, transmission <= 1,
                  drift.isFinite else { return nil }
            return (transmission, drift)
        }
    }
}
