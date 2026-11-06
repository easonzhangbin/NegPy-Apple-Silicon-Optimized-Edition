import SwiftUI

@MainActor
struct LiveFilmBalanceView: View {
    let measurement: Measurement?
    let startedAt: Date?
    let captureReference: FilmBaseLiveReference?

    @AppStorage("filmBase.liveRGB.reference") private var referenceData = Data()
    @AppStorage("filmBase.liveRGB.tolerancePercent") private var tolerancePercent = 5
    @AppStorage("filmBase.liveRGB.savedBalances") private var savedBalancesData = Data()
    @AppStorage("filmBase.liveRGB.savedSelectionCaptureTime") private var savedSelectionCaptureTime: Double = 0
    @State private var history = ReadingHistory()
    @State private var pendingSave: PendingBalance?
    @State private var balanceExportIssue: String?

    private let quickCount = 3
    private let referenceCount = 5

    private var savedReference: FilmBaseLiveReference? {
        guard let saved = try? JSONDecoder().decode(FilmBaseLiveReference.self, from: referenceData),
              saved.shares.count == RGBLightChannel.allCases.count,
              saved.shares.allSatisfy({ $0.isFinite && (0.001...1).contains($0) }),
              saved.total.isFinite, saved.total > 0 else { return nil }
        return saved
    }

    private var activeReference: FilmBaseLiveReference? {
        if let captureReference, savedSelectionCaptureTime != captureReference.capturedAt.timeIntervalSinceReferenceDate {
            return captureReference
        }
        return savedReference ?? captureReference
    }

    private var savedBalances: [FilmBaseSavedBalance] {
        guard let stored = try? JSONDecoder().decode([FilmBaseSavedBalance].self, from: savedBalancesData) else { return [] }
        return stored.filter(\.isValid)
    }

    var body: some View {
        let observed = history.observing(measurement, startedAt: startedAt, limit: referenceCount)
        let frames = observed.frames
        let quick = frames.count >= quickCount
            ? FilmBaseLiveReading(readings: Array(frames.suffix(quickCount))) : nil
        let stable = frames.count == referenceCount ? FilmBaseLiveReading(readings: frames) : nil
        let current = quick ?? frames.last
        let active = activeReference
        let comparison = active.flatMap { candidate -> FilmBaseLiveReference? in
            if let device = measurement?.device, candidate.deviceID != device.id { return nil }
            return candidate
        }

        VStack(alignment: .leading, spacing: 11) {
            heading(current: current, frameCount: frames.count, isSmoothed: quick != nil)
            exposureNotice(observed)

            HStack(spacing: 8) {
                ForEach(RGBLightChannel.allCases) { channel in
                    channelCard(channel, reading: current, referenceShare: comparison?.shares[channel.index])
                }
            }
            totalCard(reading: current, reference: comparison)
            referenceControls(active)

            if active != nil, comparison == nil {
                notice("当前设备与光谱参考不同。请选择当前 P32 的参考或重新采集。", systemImage: "exclamationmark.circle")
            }

            savedBalanceControls(reading: stable)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { history = observed }
        .onChange(of: UpdateKey(startedAt: startedAt, frame: measurement.map(FrameStamp.init))) { _ in
            history = observed
        }
        .sheet(item: $pendingSave) { pending in
            BalanceNameSheet(pending: pending) { item, shouldExport in
                guard let encoded = try? JSONEncoder().encode([item] + savedBalances),
                      applySavedBalance(item) else { return false }
                savedBalancesData = encoded
                if shouldExport { balanceExportIssue = exportFilmBaseSavedBalance(item) }
                return true
            }
        }
    }

    private func heading(current: FilmBaseLiveReading?, frameCount: Int, isSmoothed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("实时混光", systemImage: "waveform.path")
                    .font(InstrumentFont.style(.headline))
                    .foregroundStyle(InstrumentColor.teal)
                Spacer()
                if startedAt != nil {
                    Label("连续测量中", systemImage: "dot.radiowaves.left.and.right")
                        .font(InstrumentFont.style(.caption))
                        .foregroundStyle(InstrumentColor.teal)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                } else if current != nil {
                    Label("上次测量 · 已停止更新", systemImage: "clock")
                        .foregroundStyle(InstrumentColor.secondary)
                }
            }
            Text("让混合灯光透过片基。P32 实时显示三波段份额和总量。保持片基和摆位一致，调灯时对照当前光谱参考。")
                .foregroundStyle(InstrumentColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let current {
                let filter = isSmoothed ? "快显 · \(quickCount) 帧中位" : "单帧预览"
                Text("\(filter)  ·  有效帧 \(frameCount)/\(referenceCount)  ·  \(current.exposureUS) µs  ·  \(current.capturedAt.formatted(date: .omitted, time: .standard))")
                    .font(InstrumentFont.style(.caption, light: true))
                    .foregroundStyle(InstrumentColor.secondary)
            }
        }
        .font(InstrumentFont.style(.callout, light: true))
    }

    @ViewBuilder
    private func exposureNotice(_ observed: ReadingHistory) -> some View {
        switch observed.phase {
        case .waiting:
            notice("等待 P32 光谱读数。", systemImage: "info.circle")
        case .settling:
            if let frame = observed.frame {
                notice("曝光正在稳定 · \(frame.status) · \(frame.exposureUS) µs。等待下一帧。", systemImage: "timer")
            }
        case .unavailable:
            if let frame = observed.frame {
                notice("\(frame.status) · \(frame.exposureUS) µs。等待可用的 P32 光谱。", systemImage: "exclamationmark.circle")
            }
        case .reading:
            EmptyView()
        }
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(InstrumentFont.style(.callout))
            .foregroundStyle(InstrumentColor.amber)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func referenceControls(_ reference: FilmBaseLiveReference?) -> some View {
        let isEstimated = reference?.isEstimated == true
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label(reference == nil ? "光谱对照" : isEstimated ? "单色合成参考" : "已保存混光参考",
                      systemImage: "waveform.path")
                    .font(InstrumentFont.style(.callout))
                Spacer(minLength: 5)
                Text("光谱相对容差")
                InstrumentPopup(label: "光谱相对容差", options: [2, 5, 10].map { ("±\($0)%", $0) },
                                selection: $tolerancePercent)
                    .frame(width: 73, height: 24)
                if reference != nil, !isEstimated {
                    Button {
                        referenceData = Data()
                        savedSelectionCaptureTime = 0
                    } label: {
                        InstrumentFont.controlText(captureReference == nil ? "清除对照" : "返回单色合成")
                    }
                    .instrumentButton()
                }
            }
            if let reference {
                let exposure = reference.exposureUS.map { "  ·  \($0) µs" } ?? ""
                Text("P32  \(reference.deviceID)  ·  \(reference.capturedAt.formatted(date: .abbreviated, time: .standard))\(exposure)")
                    .textSelection(.enabled)
                if isEstimated {
                    Text("由红、绿、蓝单色采集合成。请开启混光实测确认，再保存混光光谱。")
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("完成单色采集以生成参考，或从「已保存参考」选择混光记录。")
            }
        }
        .font(InstrumentFont.style(.caption, light: true))
        .foregroundStyle(InstrumentColor.secondary)
        .padding(11)
        .instrumentPanel(cornerRadius: 13)
    }

    private func savedBalanceControls(reading: FilmBaseLiveReading?) -> some View {
        let captureIssue = opticalCaptureIssue(reading)
        let items = savedBalances

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button("保存片基光谱参考") {
                    guard captureIssue == nil, let reading else { return }
                    pendingSave = PendingBalance(reference: FilmBaseLiveReference(reading: reading),
                                                 tolerancePercent: tolerancePercent)
                }
                .instrumentButton(prominent: true)
                .disabled(captureIssue != nil)

                Spacer(minLength: 5)
                Menu {
                    ForEach(items) { item in
                        Button(savedBalanceTitle(item)) { _ = applySavedBalance(item) }
                    }
                    if items.isEmpty {
                        Text("暂无保存记录")
                    } else {
                        Divider()
                        Menu("导出所选参考…") {
                            ForEach(items) { item in
                                Button(savedBalanceTitle(item)) {
                                    balanceExportIssue = exportFilmBaseSavedBalance(item)
                                }
                            }
                        }
                    }
                } label: {
                    Label("已保存参考", systemImage: "bookmark.square")
                }
                .fixedSize()
                .help("选择要用于复现或导出的光谱参考。")
            }
            if let captureIssue {
                Text(captureIssue)
                    .font(InstrumentFont.style(.caption, light: true))
                    .foregroundStyle(InstrumentColor.secondary)
            }
            if let balanceExportIssue {
                notice(balanceExportIssue, systemImage: "exclamationmark.circle")
            }
        }
    }

    private func opticalCaptureIssue(_ reading: FilmBaseLiveReading?) -> String? {
        guard startedAt != nil else { return "开启混光并开始连续测量后，即可保存实测光谱。" }
        guard let reading else { return "等待 \(referenceCount) 帧同曝光有效读数。" }
        guard reading.shares.allSatisfy({ $0 >= 0.001 }) else {
            return "保存时，每个波段的中位份额至少需占 0.1%。"
        }
        return nil
    }

    private func savedBalanceTitle(_ item: FilmBaseSavedBalance) -> String {
        "\(item.name)  ·  \(item.reference.capturedAt.formatted(date: .abbreviated, time: .standard))"
    }

    private func applySavedBalance(_ item: FilmBaseSavedBalance) -> Bool {
        guard item.isValid, let encoded = try? JSONEncoder().encode(item.reference) else { return false }
        referenceData = encoded
        tolerancePercent = item.tolerancePercent
        savedSelectionCaptureTime = captureReference?.capturedAt.timeIntervalSinceReferenceDate ?? 0
        return true
    }

    private func channelCard(
        _ channel: RGBLightChannel,
        reading: FilmBaseLiveReading?,
        referenceShare: Double?
    ) -> some View {
        let index = channel.index
        let value = reading?.shares[index]
        let target = referenceShare.map(targetRange)
        let color = channelColor(channel)
        let status = comparisonStatus(value, target: target)
        let deviation = signedDeviation(value, from: referenceShare)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
                Text("\(channel.title)波段份额")
                    .font(InstrumentFont.style(.callout))
            }
            if FilmBaseLiveReading.bands.indices.contains(index) {
                let band = FilmBaseLiveReading.bands[index]
                Text("\(band.lowerBound)–\(band.upperBound) nm")
                    .font(InstrumentFont.style(.caption2, light: true))
                    .foregroundStyle(InstrumentColor.secondary)
            }

            Text(value.map(percent) ?? "—")
                .font(InstrumentFont.style(.title2))
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            shareBar(value: value, referenceShare: referenceShare, target: target, color: color)
                .accessibilityHidden(true)

            if let referenceShare, let target {
                Text("参考份额 \(percent(referenceShare))")
                    .font(InstrumentFont.style(.caption))
                Text("参考范围 \(percent(target.lowerBound))–\(percent(target.upperBound))")
                    .font(InstrumentFont.style(.caption))
                    .foregroundStyle(InstrumentColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("参考份额 —")
                    .font(InstrumentFont.style(.caption, light: true))
                    .foregroundStyle(InstrumentColor.secondary)
            }
            Text(status.label + deviation)
                .font(InstrumentFont.style(.caption))
                .foregroundStyle(status.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .instrumentPanel(cornerRadius: 12)
        .accessibilityElement(children: .combine)
    }

    private func shareBar(value: Double?, referenceShare: Double?, target: ClosedRange<Double>?, color: Color) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let track = max(0, width - 7)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12)).frame(height: 7)
                if let target {
                    Capsule()
                        .fill(color.opacity(0.40))
                        .frame(width: track * CGFloat(target.upperBound - target.lowerBound), height: 7)
                        .offset(x: 3.5 + track * CGFloat(target.lowerBound))
                }
                if let value {
                    let offset = track * CGFloat(min(1, max(0, value)))
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                        .offset(x: offset)
                }
                if let referenceShare {
                    Capsule()
                        .fill(.white)
                        .frame(width: 2, height: 11)
                        .offset(x: 2.5 + track * CGFloat(referenceShare))
                }
            }
        }
        .frame(height: 11)
    }

    private func totalCard(reading: FilmBaseLiveReading?, reference: FilmBaseLiveReference?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("三波段积分合计")
                    .font(InstrumentFont.style(.callout))
                Text(reading.map { String(format: "%.5g", $0.total) } ?? "—")
                    .font(InstrumentFont.style(.caption))
                    .foregroundStyle(InstrumentColor.secondary)
            }
            Spacer()
            if let reading, let reference {
                if reading.exposureUS == reference.exposureUS {
                    let source = reference.isEstimated == true ? "合成参考总量" : "参考总量"
                    Text("\(source)的 \(percent(reading.total / reference.total))")
                        .font(InstrumentFont.style(.callout))
                        .foregroundStyle(InstrumentColor.teal)
                } else {
                    Text("总量对照需同曝光")
                        .font(InstrumentFont.style(.caption))
                        .foregroundStyle(InstrumentColor.secondary)
                }
            } else {
                Text("相对参考总量 —")
                    .font(InstrumentFont.style(.caption, light: true))
                    .foregroundStyle(InstrumentColor.secondary)
            }
        }
        .padding(11)
        .instrumentPanel(cornerRadius: 12)
        .accessibilityElement(children: .combine)
    }

    private func targetRange(for share: Double) -> ClosedRange<Double> {
        let fraction = Double([2, 5, 10].contains(tolerancePercent) ? tolerancePercent : 5) / 100
        return max(0, share * (1 - fraction))...min(1, share * (1 + fraction))
    }

    private func comparisonStatus(
        _ value: Double?,
        target: ClosedRange<Double>?
    ) -> (label: String, color: Color) {
        guard let value, let target else { return ("等待对照", InstrumentColor.secondary) }
        if target.contains(value) { return ("参考范围内", InstrumentColor.teal) }
        return (value < target.lowerBound ? "低于参考范围" : "高于参考范围", InstrumentColor.amber)
    }

    private func signedDeviation(_ value: Double?, from reference: Double?) -> String {
        guard let value, let reference, reference > 0 else { return "" }
        return String(format: " · %+.1f%%", (value / reference - 1) * 100)
    }

    private func percent(_ value: Double) -> String {
        let scaled = value * 100
        return scaled.isFinite ? String(format: "%.1f%%", scaled) : "—"
    }

    private func channelColor(_ channel: RGBLightChannel) -> Color {
        switch channel {
        case .red: return Color(red: 1, green: 0.52, blue: 0.55)
        case .green: return Color(red: 0.53, green: 0.91, blue: 0.60)
        case .blue: return Color(red: 0.53, green: 0.70, blue: 1)
        }
    }

    private struct PendingBalance: Identifiable {
        let id = UUID()
        let reference: FilmBaseLiveReference
        let tolerancePercent: Int
    }

    @MainActor
    private struct BalanceNameSheet: View {
        let pending: PendingBalance
        let onSave: (FilmBaseSavedBalance, Bool) -> Bool

        @Environment(\.dismiss) private var dismiss
        @State private var name: String
        @State private var saveFailed = false

        init(pending: PendingBalance, onSave: @escaping (FilmBaseSavedBalance, Bool) -> Bool) {
            self.pending = pending
            self.onSave = onSave
            let date = pending.reference.capturedAt.formatted(date: .numeric, time: .standard)
            _name = State(initialValue: "片基参考 \(date)")
        }

        var body: some View {
            let item = FilmBaseSavedBalance(name: name, reference: pending.reference,
                                            tolerancePercent: pending.tolerancePercent)
            VStack(alignment: .leading, spacing: 12) {
                Text("保存片基光谱参考")
                    .font(InstrumentFont.style(.title3))
                Text("确认当前灯光为混光。保存的是本次五帧实测的光谱参考。")
                    .font(InstrumentFont.style(.callout, light: true))
                    .foregroundStyle(InstrumentColor.secondary)
                TextField("参考名称", text: $name)
                    .font(InstrumentFont.style(.body))
                    .textFieldStyle(.roundedBorder)
                Text("\(pending.reference.deviceID)  ·  \(pending.reference.capturedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(InstrumentFont.style(.caption, light: true))
                    .foregroundStyle(InstrumentColor.secondary)
                Text("波段份额  \(sharesText)  ·  总量 \(String(format: "%.5g", pending.reference.total))  ·  容差 ±\(pending.tolerancePercent)%")
                    .font(InstrumentFont.style(.caption))
                    .foregroundStyle(InstrumentColor.secondary)
                if item == nil || saveFailed {
                    Text(saveFailed ? "保存失败，请重试。" : "请输入有效的参考名称。")
                        .font(InstrumentFont.style(.caption))
                        .foregroundStyle(InstrumentColor.amber)
                }
                HStack {
                    Spacer()
                    Button("取消") { dismiss() }
                        .instrumentButton()
                        .keyboardShortcut(.cancelAction)
                    Button("保存并导出…") { save(item, export: true) }
                        .instrumentButton()
                        .disabled(item == nil)
                    Button("保存") {
                        save(item, export: false)
                    }
                    .instrumentButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(item == nil)
                }
            }
            .font(InstrumentFont.style(.body))
            .padding(20)
            .frame(width: 520)
            .background(.regularMaterial)
        }

        private func save(_ item: FilmBaseSavedBalance?, export: Bool) {
            guard let item else { return }
            if onSave(item, export) { dismiss() } else { saveFailed = true }
        }

        private var sharesText: String {
            zip(RGBLightChannel.allCases, pending.reference.shares).map { channel, share in
                "\(channel.title) \(String(format: "%.1f%%", share * 100))"
            }.joined(separator: "  ")
        }
    }

    private struct UpdateKey: Equatable {
        let startedAt: Date?
        let frame: FrameStamp?
    }

    private struct FrameStamp: Equatable {
        let deviceID: String
        let timestamp: Date
        let exposureUS: UInt32
        let status: String
        let revision: UInt64?

        init(_ measurement: Measurement) {
            deviceID = measurement.device.id
            timestamp = measurement.capturedAt
            exposureUS = measurement.exposureUS
            status = measurement.exposure.label
            revision = measurement.exposureRevision
        }

        func matchesExposure(of other: Self) -> Bool {
            deviceID == other.deviceID && exposureUS == other.exposureUS
                && status == other.status && revision == other.revision
        }
    }

    private struct ReadingHistory {
        enum Phase { case waiting, settling, unavailable, reading }

        private(set) var frames: [FilmBaseLiveReading] = []
        private(set) var frame: FrameStamp?
        private(set) var phase: Phase = .waiting
        private var startedAt: Date?

        func observing(_ measurement: Measurement?, startedAt: Date?, limit: Int) -> Self {
            var next = startedAt != nil && startedAt != self.startedAt ? Self() : self
            next.startedAt = startedAt

            guard let measurement else {
                var waiting = Self()
                waiting.startedAt = startedAt
                return waiting
            }
            let stamp = FrameStamp(measurement)
            if let startedAt, stamp.timestamp < startedAt { return next }
            if stamp == next.frame { return next }

            let changed = next.frame.map { !stamp.matchesExposure(of: $0) } ?? true
            next.frame = stamp
            if changed || stamp.revision == nil {
                next.frames = []
            }
            guard let reading = FilmBaseLiveReading(measurement: measurement) else {
                next.frames = []
                next.phase = .unavailable
                return next
            }
            // The first stream frame with new exposure metadata can still carry the preceding spectrum.
            if changed && stamp.revision != nil {
                next.phase = .settling
                return next
            }
            next.frames = Array(next.frames.suffix(limit - 1)) + [reading]
            next.phase = .reading
            return next
        }
    }
}
