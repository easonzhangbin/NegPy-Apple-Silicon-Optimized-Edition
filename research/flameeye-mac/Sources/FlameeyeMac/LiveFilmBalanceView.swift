import SwiftUI

@MainActor
struct LiveFilmBalanceView: View {
    let measurement: Measurement?
    let startedAt: Date?

    @AppStorage("filmBase.liveRGB.reference") private var referenceData = Data()
    @AppStorage("filmBase.liveRGB.shotTarget") private var shotTargetData = Data()
    @AppStorage("filmBase.liveRGB.tolerancePercent") private var tolerancePercent = 5
    @AppStorage("filmBase.liveRGB.savedBalances") private var savedBalancesData = Data()
    @State private var history = ReadingHistory()
    @State private var mode: Mode = .shot
    @State private var responseInput = ["", "", ""]
    @State private var pendingSave: PendingBalance?
    @State private var balanceExportIssue: String?

    private let quickCount = 3
    private let referenceCount = 5

    private var reference: FilmBaseLiveReference? {
        guard let saved = try? JSONDecoder().decode(FilmBaseLiveReference.self, from: referenceData),
              saved.shares.count == RGBLightChannel.allCases.count,
              saved.shares.allSatisfy({ $0.isFinite && (0.001...1).contains($0) }),
              saved.total.isFinite, saved.total > 0 else { return nil }
        return saved
    }

    private var shotTarget: FilmBaseLightTarget? {
        guard let saved = try? JSONDecoder().decode(FilmBaseLightTarget.self, from: shotTargetData),
              let shares = saved.shares, shares.count == RGBLightChannel.allCases.count,
              shares.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              saved.responsePercent.count == RGBLightChannel.allCases.count else { return nil }
        return saved
    }

    private var responsePercent: [Double]? {
        let values = responseInput.compactMap {
            Double($0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
        }
        guard values.count == RGBLightChannel.allCases.count,
              values.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 100 }) else { return nil }
        return values
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
        let referenceReading = frames.count == referenceCount ? FilmBaseLiveReading(readings: frames) : nil
        let current = quick ?? frames.last
        let saved = reference
        let comparison = saved.flatMap { candidate -> FilmBaseLiveReference? in
            if let device = measurement?.device, candidate.deviceID != device.id { return nil }
            return candidate
        }
        let derived = shotTarget
        let applicableTarget = derived.flatMap { candidate -> FilmBaseLightTarget? in
            if let device = measurement?.device, candidate.deviceID != device.id { return nil }
            return candidate
        }
        let targetShares = mode == .shot ? applicableTarget?.shares : comparison?.shares

        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label(mode == .shot ? "P32 实拍反推" : "P32 灯光复现", systemImage: "waveform.path")
                        .font(.headline)
                        .foregroundStyle(InstrumentColor.teal)
                    Spacer()
                    if startedAt != nil {
                        Label("连续测量中", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(InstrumentColor.teal)
                    } else if current != nil {
                        Label("上次测量 · 已停止更新", systemImage: "clock")
                            .foregroundStyle(InstrumentColor.secondary)
                    }
                }
                Picker("对照方式", selection: $mode) {
                    Text("实拍反推").tag(Mode.shot)
                    Text("光谱复现").tag(Mode.spectrum)
                }
                .pickerStyle(.segmented)
                Text(mode == .shot
                     ? "填入同快门、ISO 和光圈下三张单色实拍的同色通道百分比。保持同一片基和摆位，把 CuteNew 三个原色灯都调回各自拍摄时的档位，关闭白光及宽谱模式，再用 P32 记录起点。"
                     : "可记录当前 P32 光谱。日后用同一片基、灯光模式和摆位测量，对照各波段的积分份额与总量来复现灯光。")
                    .foregroundStyle(InstrumentColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let current {
                    let filter = quick == nil ? "单帧预览" : "快显 · \(quickCount) 帧中位"
                    Text("\(filter)  ·  参考有效帧 \(frames.count)/\(referenceCount)  ·  \(current.exposureUS) µs  ·  \(current.capturedAt.formatted(date: .omitted, time: .standard))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(InstrumentColor.secondary)
                }
            }
            .font(.callout)

            exposureNotice(observed)
            savedBalanceControls(reading: referenceReading, frames: frames, targetShares: targetShares)

            if mode == .shot {
                shotControls(reading: startedAt == nil ? nil : referenceReading, saved: derived)
                if derived != nil, applicableTarget == nil {
                    notice("当前设备与起点不同。请换回原 P32，或重新记录起点。", systemImage: "exclamationmark.circle")
                }
            } else {
                referenceControls(reading: referenceReading, reference: saved)
                if saved != nil, comparison == nil {
                    notice("当前设备与参考不同。请换回原 P32 或用当前设备更新参考。", systemImage: "exclamationmark.circle")
                }
            }

            HStack(spacing: 8) {
                ForEach(RGBLightChannel.allCases) { channel in
                    channelCard(channel, reading: current, referenceShare: targetShares?[channel.index])
                }
            }

            totalCard(reading: current, reference: mode == .spectrum ? comparison : nil)

            Text(mode == .shot
                 ? "箭头表示各波段相对份额的调整方向。调好比例后，用相机快门另行设定整体曝光，再用同一组相机设置实拍三张核对。"
                 : "本页对照已保存的 P32 光谱，容差相对参考波段份额计算。相机通道曝光以实拍读数为准。")
                .font(.caption)
                .foregroundStyle(InstrumentColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            history = observed
            if let derived, responseInput.allSatisfy(\.isEmpty) {
                responseInput = derived.responsePercent.map { String($0) }
            }
        }
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
            .font(.callout)
            .foregroundStyle(InstrumentColor.amber)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func savedBalanceControls(
        reading: FilmBaseLiveReading?,
        frames: [FilmBaseLiveReading],
        targetShares: [Double]?
    ) -> some View {
        let disabledReason = saveDisabledReason(reading: reading, frames: frames, targetShares: targetShares)
        let items = savedBalances
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button {
                    guard disabledReason == nil, let reading else { return }
                    pendingSave = PendingBalance(reference: FilmBaseLiveReference(reading: reading),
                                                 tolerancePercent: tolerancePercent)
                } label: {
                    Label("保存本次配平", systemImage: "bookmark")
                }
                .disabled(disabledReason != nil)
                .help(disabledReason ?? "把最近五帧的实际配平保存为可复用的光谱参考。")

                Menu {
                    ForEach(items) { item in
                        Button {
                            applySavedBalance(item)
                        } label: {
                            Text(savedBalanceTitle(item))
                        }
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
                Spacer(minLength: 0)
            }
            if let disabledReason {
                Text(disabledReason)
                    .font(.caption)
                    .foregroundStyle(InstrumentColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let balanceExportIssue {
                notice(balanceExportIssue, systemImage: "exclamationmark.circle")
            }
        }
    }

    private func savedBalanceTitle(_ item: FilmBaseSavedBalance) -> String {
        "\(item.name)  ·  \(item.reference.capturedAt.formatted(date: .abbreviated, time: .standard))"
    }

    private func saveDisabledReason(
        reading: FilmBaseLiveReading?,
        frames: [FilmBaseLiveReading],
        targetShares: [Double]?
    ) -> String? {
        guard startedAt != nil else { return "开始连续测量后，可保存达标的配平。" }
        guard let targetShares else {
            return mode == .shot ? "请先记录实拍反推的起点。" : "请先选择或记录用于复现的光谱参考。"
        }
        guard let reading, frames.count == referenceCount else {
            return "等待 \(referenceCount) 帧同曝光有效读数。"
        }
        let ranges = targetShares.map(targetRange)
        guard frames.allSatisfy({ frame in
            frame.shares.count == ranges.count &&
                zip(frame.shares, ranges).allSatisfy { value, range in range.contains(value) }
        }) else {
            return "最近 \(referenceCount) 帧的三个波段都落在当前容差内时，即可保存。"
        }
        guard reading.shares.allSatisfy({ $0 >= 0.001 }) else {
            return "保存配平时，每个波段的中位份额至少需占 0.1%。"
        }
        return nil
    }

    private func applySavedBalance(_ item: FilmBaseSavedBalance) {
        guard item.isValid, let encoded = try? JSONEncoder().encode(item.reference) else { return }
        referenceData = encoded
        tolerancePercent = item.tolerancePercent
        mode = .spectrum
    }

    private func shotControls(reading: FilmBaseLiveReading?, saved: FilmBaseLightTarget?) -> some View {
        let values = responsePercent
        let candidate = reading.flatMap { reading in
            values.flatMap { FilmBaseLightTarget(reading: reading, responsePercent: $0) }
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("三张单色实拍的通道响应").font(.callout.weight(.medium))
                Spacer()
                if let saved {
                    Button("填入已存实拍值") {
                        responseInput = saved.responsePercent.map { String($0) }
                    }
                }
            }
            HStack(spacing: 12) {
                ForEach(RGBLightChannel.allCases) { channel in
                    HStack(spacing: 4) {
                        Text(channel.title).foregroundStyle(channelColor(channel))
                        TextField("百分比", text: $responseInput[channel.index])
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("\(channel.title)光实拍百分比")
                        Text("%").foregroundStyle(InstrumentColor.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                tolerancePicker
                Spacer(minLength: 5)
                if saved != nil {
                    Button("清除反推目标") { shotTargetData = Data() }
                }
                Button(saved == nil ? "记录起点并反推目标" : "重采起点并反推") {
                    guard let candidate, let encoded = try? JSONEncoder().encode(candidate) else { return }
                    shotTargetData = encoded
                }
                .buttonStyle(.borderedProminent)
                .disabled(candidate == nil)
            }
            if let saved {
                let labels = zip(RGBLightChannel.allCases, saved.responsePercent).map { channel, value in
                    "\(channel.title) \(percent(value / 100))"
                }
                Text("已存起点  \(saved.deviceID)  ·  \(saved.capturedAt.formatted(date: .abbreviated, time: .standard))  ·  \(labels.joined(separator: "  "))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(InstrumentColor.secondary)
                    .textSelection(.enabled)
            }
            if values == nil {
                Text("请填入大于 0 且小于 100 的实拍百分比。")
                    .font(.caption)
                    .foregroundStyle(InstrumentColor.secondary)
            } else if reading == nil {
                Text("用连续测量采满 \(referenceCount) 帧同曝光有效读数后即可记录起点。")
                    .font(.caption)
                    .foregroundStyle(InstrumentColor.secondary)
            } else if candidate == nil {
                notice("当前读数无法反推目标。请检查三个原色灯的设置和片基位置。", systemImage: "exclamationmark.circle")
            } else if let saved, values != saved.responsePercent {
                Text("输入已改动。重采起点后会更新反推目标。")
                    .font(.caption)
                    .foregroundStyle(InstrumentColor.secondary)
            }
        }
        .padding(11)
        .instrumentPanel(cornerRadius: 13)
    }

    private var tolerancePicker: some View {
        Picker("相对容差", selection: $tolerancePercent) {
            Text("±2%").tag(2)
            Text("±5%").tag(5)
            Text("±10%").tag(10)
        }
        .fixedSize()
    }

    private func referenceControls(reading: FilmBaseLiveReading?, reference: FilmBaseLiveReference?) -> some View {
        let eligible = reading?.shares.allSatisfy { $0 >= 0.001 } == true
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                tolerancePicker

                Spacer(minLength: 5)
                if reference != nil {
                    Button("清除参考") { referenceData = Data() }
                }

                Button(reference == nil ? "记录 P32 光谱参考" : "更新 P32 光谱参考") {
                    guard eligible, let reading,
                          let encoded = try? JSONEncoder().encode(FilmBaseLiveReference(reading: reading)) else { return }
                    referenceData = encoded
                }
                .buttonStyle(.borderedProminent)
                .disabled(!eligible)
            }

            if let reference {
                Text("P32 参考  \(reference.deviceID)  ·  \(reference.capturedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(InstrumentColor.secondary)
                    .textSelection(.enabled)
            } else {
                Text("记录 P32 光谱参考后显示各波段的参考范围。参考会保存在本机。")
                    .font(.caption)
                    .foregroundStyle(InstrumentColor.secondary)
            }
            if reading == nil {
                Text("采满 \(referenceCount) 帧同曝光有效读数后，可用其中位结果记录参考。")
                    .font(.caption)
                    .foregroundStyle(InstrumentColor.secondary)
            } else if !eligible {
                Text("记录参考时，每个波段至少需占 0.1%。")
                    .font(.caption)
                    .foregroundStyle(InstrumentColor.amber)
            }
        }
        .padding(11)
        .instrumentPanel(cornerRadius: 13)
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
        let status = comparisonStatus(value, target: target, channel: channel)
        let deviation = signedDeviation(value, from: referenceShare)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
                Text("\(channel.title)波段份额")
                    .font(.callout.weight(.medium))
            }
            if FilmBaseLiveReading.bands.indices.contains(index) {
                let band = FilmBaseLiveReading.bands[index]
                Text("\(band.lowerBound)–\(band.upperBound) nm")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(InstrumentColor.secondary)
            }

            Text(value.map(percent) ?? "—")
                .font(.system(.title2, design: .monospaced).weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            shareBar(value: value, target: target, center: referenceShare, color: color)
                .accessibilityHidden(true)

            if let target, let referenceShare {
                Text(mode == .shot
                     ? "目标 \(percent(referenceShare)) · \(percent(target.lowerBound))–\(percent(target.upperBound))"
                     : "参考范围 \(percent(target.lowerBound))–\(percent(target.upperBound))")
                    .font(.caption)
                    .foregroundStyle(InstrumentColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(mode == .shot ? "反推目标 —" : "参考范围 —")
                    .font(.caption)
                    .foregroundStyle(InstrumentColor.secondary)
            }
            Text(status.label + deviation)
                .font(.caption.weight(.medium))
                .foregroundStyle(status.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .instrumentPanel(cornerRadius: 12)
        .accessibilityElement(children: .combine)
    }

    private func shareBar(value: Double?, target: ClosedRange<Double>?, center: Double?, color: Color) -> some View {
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
                if mode == .shot, let center {
                    Rectangle()
                        .fill(.white.opacity(0.76))
                        .frame(width: 1, height: 7)
                        .offset(x: 3 + track * CGFloat(center))
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
                    .font(.callout.weight(.medium))
                Text(reading.map { String(format: "%.5g", $0.total) } ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(InstrumentColor.secondary)
            }
            Spacer()
            if let reading, let reference {
                Text("参考总量的 \(percent(reading.total / reference.total))")
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .foregroundStyle(InstrumentColor.teal)
            } else if mode == .spectrum {
                Text("相对参考总量 —")
                    .font(.caption)
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
        target: ClosedRange<Double>?,
        channel: RGBLightChannel
    ) -> (label: String, color: Color) {
        guard let value, let target else { return ("等待对照", InstrumentColor.secondary) }
        if mode == .shot {
            if target.contains(value) { return ("目标范围内", InstrumentColor.teal) }
            return (value < target.lowerBound ? "↑ 增加\(channel.title)波段份额" : "↓ 减少\(channel.title)波段份额",
                    InstrumentColor.amber)
        }
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

    private enum Mode { case shot, spectrum }

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
        @State private var draftNegPy: FilmBaseNegPyVerification?
        @State private var isReadingNegPy = false

        init(pending: PendingBalance, onSave: @escaping (FilmBaseSavedBalance, Bool) -> Bool) {
            self.pending = pending
            self.onSave = onSave
            let date = pending.reference.capturedAt.formatted(date: .numeric, time: .standard)
            _name = State(initialValue: "配平 \(date)")
        }

        var body: some View {
            let item = FilmBaseSavedBalance(name: name, reference: pending.reference,
                                            tolerancePercent: pending.tolerancePercent, negPy: draftNegPy)
            VStack(alignment: .leading, spacing: 12) {
                Text("保存本次配平").font(.title3.weight(.semibold))
                TextField("配平名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("\(pending.reference.deviceID)  ·  \(pending.reference.capturedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(InstrumentColor.secondary)
                Text("波段份额  \(sharesText)  ·  总量 \(String(format: "%.5g", pending.reference.total))  ·  容差 ±\(pending.tolerancePercent)%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(InstrumentColor.secondary)
                NegPyBalanceAttachmentView(verification: $draftNegPy, isReading: $isReadingNegPy)
                if item == nil || saveFailed {
                    Text(saveFailed ? "保存失败，请重试。" : "请输入有效的配平名称。")
                        .font(.caption)
                        .foregroundStyle(InstrumentColor.amber)
                }
                HStack {
                    Spacer()
                    Button("取消") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("保存并导出…") { save(item, export: true) }
                        .disabled(item == nil || isReadingNegPy)
                    Button("保存") {
                        save(item, export: false)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(item == nil || isReadingNegPy)
                }
            }
            .padding(20)
            .frame(width: 520)
        }

        private func save(_ item: FilmBaseSavedBalance?, export: Bool) {
            guard let item, !isReadingNegPy else { return }
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
