import SwiftUI

@MainActor
struct LiveFilmBalanceView: View {
    let measurement: Measurement?
    let startedAt: Date?

    @AppStorage("filmBase.liveRGB.reference") private var referenceData = Data()
    @AppStorage("filmBase.liveRGB.tolerancePercent") private var tolerancePercent = 5
    @AppStorage("filmBase.liveRGB.savedBalances") private var savedBalancesData = Data()
    @State private var history = ReadingHistory()
    @State private var report: FilmBaseNegPyVerification?
    @State private var isReadingReport = false
    @State private var sameSetup = false
    @State private var pendingSave: PendingBalance?
    @State private var balanceExportIssue: String?

    private let quickCount = 3
    private let referenceCount = 5
    private let cameraToleranceEV = 0.2

    private var reference: FilmBaseLiveReference? {
        guard let saved = try? JSONDecoder().decode(FilmBaseLiveReference.self, from: referenceData),
              saved.shares.count == RGBLightChannel.allCases.count,
              saved.shares.allSatisfy({ $0.isFinite && (0.001...1).contains($0) }),
              saved.total.isFinite, saved.total > 0 else { return nil }
        return saved
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
        let saved = reference
        let comparison = saved.flatMap { candidate -> FilmBaseLiveReference? in
            if let device = measurement?.device, candidate.deviceID != device.id { return nil }
            return candidate
        }
        let reportIssue = report?.meteringIssue
        let spread = report?.medianSpreadEV
        let passes = reportIssue == nil && spread.map { $0 <= cameraToleranceEV } == true

        VStack(alignment: .leading, spacing: 11) {
            heading(current: current, frameCount: frames.count, isSmoothed: quick != nil)
            exposureNotice(observed)

            HStack(spacing: 8) {
                ForEach(RGBLightChannel.allCases) { channel in
                    channelCard(channel, reading: current, referenceShare: comparison?.shares[channel.index])
                }
            }
            totalCard(reading: current, reference: comparison)
            referenceControls(saved)

            if saved != nil, comparison == nil {
                notice("当前设备与光谱参考不同。请接回原 P32，或选择当前设备的记录。", systemImage: "exclamationmark.circle")
            }

            cameraControls(qualityIssue: reportIssue, spread: spread, passes: passes)
            savedBalanceControls(reading: stable, passes: passes)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { history = observed }
        .onChange(of: report?.readAt) { _ in sameSetup = false }
        .onChange(of: isReadingReport) { reading in
            if reading { sameSetup = false }
        }
        .onChange(of: measurement?.device.id) { _ in sameSetup = false }
        .onChange(of: startedAt) { _ in sameSetup = false }
        .onChange(of: UpdateKey(startedAt: startedAt, frame: measurement.map(FrameStamp.init))) { _ in
            history = observed
        }
        .sheet(item: $pendingSave) { pending in
            BalanceNameSheet(pending: pending) { item, shouldExport in
                guard let encoded = try? JSONEncoder().encode([item] + savedBalances) else { return false }
                savedBalancesData = encoded
                if shouldExport { balanceExportIssue = exportFilmBaseSavedBalance(item) }
                return true
            }
        }
    }

    private func heading(current: FilmBaseLiveReading?, frameCount: Int, isSmoothed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("片基配平", systemImage: "waveform.path")
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
            Text("P32 实时显示各波段的光谱份额和总量，用于复现已保存的灯光。相机片基配平以 NegPy 的实拍测光为准。")
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

    private func referenceControls(_ saved: FilmBaseLiveReference?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label("光谱复现", systemImage: "waveform.path")
                    .font(InstrumentFont.style(.callout))
                Spacer(minLength: 5)
                Text("光谱相对容差")
                InstrumentPopup(label: "光谱相对容差", options: [2, 5, 10].map { ("±\($0)%", $0) },
                                selection: $tolerancePercent)
                    .frame(width: 73, height: 24)
                if saved != nil {
                    Button("清除对照") { referenceData = Data() }
                        .instrumentButton()
                }
            }
            if let saved {
                Text("P32 参考  \(saved.deviceID)  ·  \(saved.capturedAt.formatted(date: .abbreviated, time: .standard))")
                    .textSelection(.enabled)
            } else {
                Text("从「已保存配平」选择一项，与当时的波段份额和总量对照。")
            }
        }
        .font(InstrumentFont.style(.caption, light: true))
        .foregroundStyle(InstrumentColor.secondary)
        .padding(11)
        .instrumentPanel(cornerRadius: 13)
    }

    private func cameraControls(qualityIssue: String?, spread: Double?, passes: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("相机片基验收", systemImage: "camera.aperture")
                .font(InstrumentFont.style(.headline))
                .foregroundStyle(InstrumentColor.teal)
            NegPyBalanceAttachmentView(verification: $report, isReading: $isReadingReport)
            Text("验收比较三张单色实拍中同一块透明片基的 P50，并检查该区域的计量质量。最大曝光差须在 \(String(format: "%.2f", cameraToleranceEV)) EV 以内。")
                .font(InstrumentFont.style(.caption, light: true))
                .foregroundStyle(InstrumentColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isReadingReport {
                EmptyView()
            } else if let qualityIssue {
                notice(qualityIssue, systemImage: "exclamationmark.circle")
            } else if let report, let spread {
                cameraResiduals(report)
                Label(String(format: "片基 P50 最大差 %.3f EV · %@", spread, passes ? "曝光差达标" : "曝光差超出容差"),
                      systemImage: passes ? "checkmark.circle" : "exclamationmark.circle")
                    .font(InstrumentFont.style(.callout))
                    .foregroundStyle(passes ? InstrumentColor.teal : InstrumentColor.amber)
                if passes {
                    Toggle("确认三色实拍与当前 P32 使用同一片基、同一摆位和对应灯档", isOn: $sameSetup)
                        .toggleStyle(.checkbox)
                        .font(InstrumentFont.style(.callout))
                        .disabled(isReadingReport)
                }
            } else if report != nil {
                notice("报告缺少有效的片基 P50 曝光差。", systemImage: "exclamationmark.circle")
            }
        }
        .padding(11)
        .instrumentPanel(cornerRadius: 13)
    }

    @ViewBuilder
    private func cameraResiduals(_ report: FilmBaseNegPyVerification) -> some View {
        if let levels = report.medianPercent, let red = levels.first, red > 0 {
            HStack(spacing: 12) {
                ForEach(RGBLightChannel.allCases) { channel in
                    let value = levels[channel.index]
                    if value > 0 {
                        Text(String(format: "%@ %+.2f EV", channel.title, log2(red / value)))
                            .foregroundStyle(channelColor(channel))
                    }
                }
            }
            .font(InstrumentFont.style(.caption))
            Text("按本次片基 P50 与红路比较。正值表示需增加对应灯光量，负值表示需减少。调灯后重拍三张再检查。")
                .font(InstrumentFont.style(.caption, light: true))
                .foregroundStyle(InstrumentColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func savedBalanceControls(reading: FilmBaseLiveReading?, passes: Bool) -> some View {
        let captureIssue = opticalCaptureIssue(reading)
        let canValidate = captureIssue == nil && passes && sameSetup && !isReadingReport
        let items = savedBalances

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button("保存已验收配平") {
                    guard canValidate, let reading, let report else { return }
                    pendingSave = PendingBalance(reference: FilmBaseLiveReference(reading: reading),
                                                 tolerancePercent: tolerancePercent, verifiedReport: report,
                                                 verificationToleranceEV: cameraToleranceEV)
                    sameSetup = false
                }
                .instrumentButton(prominent: true)
                .disabled(!canValidate)

                Button("仅保存光谱参考") {
                    guard captureIssue == nil, let reading else { return }
                    pendingSave = PendingBalance(reference: FilmBaseLiveReference(reading: reading),
                                                 tolerancePercent: tolerancePercent, verifiedReport: nil,
                                                 verificationToleranceEV: nil)
                }
                .instrumentButton()
                .disabled(captureIssue != nil)

                Spacer(minLength: 5)
                Menu {
                    ForEach(items) { item in
                        Button(savedBalanceTitle(item)) { applySavedBalance(item) }
                    }
                    if items.isEmpty {
                        Text("暂无保存记录")
                    } else {
                        Divider()
                        Menu("导出所选配平…") {
                            ForEach(items) { item in
                                Button(savedBalanceTitle(item)) {
                                    balanceExportIssue = exportFilmBaseSavedBalance(item)
                                }
                            }
                        }
                    }
                } label: {
                    Label("已保存配平", systemImage: "bookmark.square")
                }
                .fixedSize()
                .help("选择要复现或导出的配平。")
            }
            if let captureIssue {
                Text(captureIssue)
                    .font(InstrumentFont.style(.caption, light: true))
                    .foregroundStyle(InstrumentColor.secondary)
            } else if !canValidate {
                Text(passes ? "确认实拍报告与当前 P32 的片基、摆位和灯档一致后，可保存验收记录。"
                     : "光谱参考可用于复现灯光。通过相机片基验收后可保存验收记录。")
                    .font(InstrumentFont.style(.caption, light: true))
                    .foregroundStyle(InstrumentColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let balanceExportIssue {
                notice(balanceExportIssue, systemImage: "exclamationmark.circle")
            }
        }
    }

    private func opticalCaptureIssue(_ reading: FilmBaseLiveReading?) -> String? {
        guard startedAt != nil else { return "开始连续测量后即可保存当前光谱。" }
        guard let reading else { return "等待 \(referenceCount) 帧同曝光有效读数。" }
        guard reading.shares.allSatisfy({ $0 >= 0.001 }) else {
            return "保存时，每个波段的中位份额至少需占 0.1%。"
        }
        return nil
    }

    private func savedBalanceTitle(_ item: FilmBaseSavedBalance) -> String {
        let kind = item.verifiedByNegPy ? "片基验收" : "仅光谱"
        return "\(item.name)  ·  \(kind)  ·  \(item.reference.capturedAt.formatted(date: .abbreviated, time: .standard))"
    }

    private func applySavedBalance(_ item: FilmBaseSavedBalance) {
        guard item.isValid, let encoded = try? JSONEncoder().encode(item.reference) else { return }
        referenceData = encoded
        tolerancePercent = item.tolerancePercent
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

            shareBar(value: value, target: target, color: color)
                .accessibilityHidden(true)

            if let target {
                Text("参考范围 \(percent(target.lowerBound))–\(percent(target.upperBound))")
                    .font(InstrumentFont.style(.caption))
                    .foregroundStyle(InstrumentColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("参考范围 —")
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

    private func shareBar(value: Double?, target: ClosedRange<Double>?, color: Color) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let track = max(0, width - 7)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                if let target {
                    Capsule()
                        .fill(color.opacity(0.40))
                        .frame(width: track * CGFloat(target.upperBound - target.lowerBound))
                        .offset(x: 3.5 + track * CGFloat(target.lowerBound))
                }
                if let value {
                    let offset = track * CGFloat(min(1, max(0, value)))
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                        .offset(x: offset)
                }
            }
        }
        .frame(height: 7)
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
                Text("参考总量的 \(percent(reading.total / reference.total))")
                    .font(InstrumentFont.style(.callout))
                    .foregroundStyle(InstrumentColor.teal)
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
        let verifiedReport: FilmBaseNegPyVerification?
        let verificationToleranceEV: Double?
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
            _name = State(initialValue: "\(pending.verifiedReport == nil ? "光谱参考" : "配平") \(date)")
        }

        var body: some View {
            let item = FilmBaseSavedBalance(name: name, reference: pending.reference,
                                            tolerancePercent: pending.tolerancePercent, negPy: pending.verifiedReport,
                                            verificationToleranceEV: pending.verificationToleranceEV)
            VStack(alignment: .leading, spacing: 12) {
                Text(pending.verifiedReport == nil ? "仅保存光谱参考" : "保存已验收配平")
                    .font(InstrumentFont.style(.title3))
                TextField("配平名称", text: $name)
                    .font(InstrumentFont.style(.body))
                    .textFieldStyle(.roundedBorder)
                Text("\(pending.reference.deviceID)  ·  \(pending.reference.capturedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(InstrumentFont.style(.caption, light: true))
                    .foregroundStyle(InstrumentColor.secondary)
                Text("波段份额  \(sharesText)  ·  总量 \(String(format: "%.5g", pending.reference.total))  ·  容差 ±\(pending.tolerancePercent)%")
                    .font(InstrumentFont.style(.caption))
                    .foregroundStyle(InstrumentColor.secondary)
                if let spread = pending.verifiedReport?.medianSpreadEV {
                    Text(String(format: "NegPy 片基验收通过 · P50 差 %.3f EV", spread))
                        .font(InstrumentFont.style(.caption))
                        .foregroundStyle(InstrumentColor.teal)
                }
                if item == nil || saveFailed {
                    Text(saveFailed ? "保存失败，请重试。" : "请输入有效的配平名称。")
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
