import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct SpectrumApp: App {
    @StateObject private var model = WorkspaceModel()

    var body: some Scene {
        Window("火眼光谱", id: "spectrum") {
            SpectrumWorkspace(model: model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 830, minHeight: 640)
                .background { InstrumentWindowBackdrop() }
        }
        .defaultSize(width: 1050, height: 740)

        Window("P32 测量详情", id: "p32-details") {
            Group {
                if let frame = model.measurement, frame.device.protocolProfile == .legacyP32 {
                    P32MeasurementDetails(measurement: frame, isLive: model.activity == .repeating) { csv, suffix in
                        model.saveCSV(csv, capturedAt: frame.capturedAt, suffix: suffix)
                    }
                } else {
                    Label("连接 P32 后开始测量，详情会显示在这里。", systemImage: "viewfinder")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .preferredColorScheme(.dark)
            .tint(InstrumentColor.teal)
            .frame(minWidth: 600, minHeight: 460)
            .background { InstrumentWindowBackdrop() }
        }
        .defaultSize(width: 670, height: 565)
        .defaultPosition(.trailing)

        Window("片基 RGB 校准", id: "rgb-calibration") {
            RGBCalibrationWindow(device: model.device, isBusy: model.activity != nil,
                                 measurement: model.device?.protocolProfile == .legacyP32 ? model.measurement : nil,
                                 isLive: model.activity == .repeating && model.device?.protocolProfile == .legacyP32,
                                 captureStartedAt: model.captureStartedAt,
                                 liveIssue: model.issue,
                                 toggleLive: {
                                     if model.activity == .repeating {
                                         model.stop()
                                     } else {
                                         model.capture(repeatCapture: true)
                                     }
                                 },
                                 capture: model.captureFilmBase)
                .preferredColorScheme(.dark)
                .tint(InstrumentColor.teal)
                .frame(minWidth: 720, minHeight: 510)
                .background { InstrumentWindowBackdrop() }
        }
        .defaultSize(width: 810, height: 665)
    }
}

@MainActor
private final class WorkspaceModel: ObservableObject {
    enum Activity: Equatable {
        case connecting, single, repeating, stopping, calibrating
    }

    @Published private(set) var ports: [String] = []
    @Published var selectedPort = ""
    @Published private(set) var device: Device?
    @Published private(set) var measurement: Measurement?
    @Published private(set) var activity: Activity?
    @Published private(set) var issue: String?
    private var operation: Task<Void, Never>?
    private(set) var captureStartedAt: Date?

    var isWaitingForCaptureFrame: Bool {
        guard let captureStartedAt, activity == .single || activity == .repeating else { return false }
        return measurement.map { $0.capturedAt < captureStartedAt } ?? true
    }

    func refreshPorts() {
        ports = Spectrometer.ports()
        if !ports.contains(selectedPort) {
            selectedPort = ports.first ?? ""
        }
        if let device, !ports.contains(device.port) {
            operation?.cancel()
            self.device = nil
            issue = "设备已拔出，请重新连接后刷新串口。"
        } else {
            issue = ports.isEmpty ? "未发现 USB 串口。连接设备后点击刷新。" : nil
        }
    }

    func connect() {
        guard activity == nil, device == nil, !selectedPort.isEmpty else { return }
        let port = selectedPort
        issue = nil
        activity = .connecting
        operation = Task {
            defer { finishOperation() }
            do {
                let result = try await Spectrometer.connect(port: port)
                try Task.checkCancellation()
                device = result
                measurement = nil
            } catch is CancellationError {
                return
            } catch {
                issue = error.localizedDescription
            }
        }
    }

    func disconnect() {
        guard activity == nil else { return }
        device = nil
        issue = nil
    }

    func capture(repeatCapture: Bool) {
        guard let device, activity == nil else { return }
        issue = nil
        captureStartedAt = Date()
        activity = repeatCapture ? .repeating : .single
        operation = Task {
            defer { finishOperation() }
            do {
                if repeatCapture, device.protocolProfile == .legacyP32 {
                    for try await frame in Spectrometer.streamP32(device: device) {
                        try Task.checkCancellation()
                        measurement = frame
                    }
                    return
                }
                repeat {
                    try Task.checkCancellation()
                    let frame = try await Spectrometer.measure(device: device, settleExposure: !repeatCapture)
                    try Task.checkCancellation()
                    measurement = frame
                    if repeatCapture {
                        try await Task.sleep(nanoseconds: 400_000_000)
                    }
                } while repeatCapture
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    issue = error.localizedDescription
                    if !Spectrometer.ports().contains(device.port) {
                        self.device = nil
                        ports = Spectrometer.ports()
                        selectedPort = ports.first ?? ""
                    }
                }
            }
        }
    }

    func stop() {
        guard activity == .repeating else { return }
        activity = .stopping
        operation?.cancel()
    }

    func captureFilmBase(exposureUS: UInt32?) async throws -> [Measurement] {
        guard let device, device.protocolProfile == .legacyP32, activity == nil else {
            throw FilmBaseError.message("请先连接 P32，并停止其他测量。")
        }
        issue = nil
        activity = .single
        defer { activity = nil }
        let frames = try await Spectrometer.measureFilmBase(device: device, exposureUS: exposureUS)
        guard self.device == device else { throw CalibrationError.deviceChanged }
        measurement = frames.last
        return frames
    }

    func changeCalibration(_ change: Spectrometer.CalibrationChange, device: Device) async throws {
        guard activity == nil, self.device == device else { throw CalibrationError.deviceChanged }
        issue = nil
        activity = .calibrating
        defer { activity = nil }

        do {
            try await Spectrometer.changeCalibration(change, device: device)
        } catch {
            switch error as? CalibrationError {
            case .unconfirmed:
                measurement = nil
                self.device = nil
            case .deviceChanged:
                self.device = nil
            default:
                if !Spectrometer.ports().contains(device.port) { self.device = nil }
            }
            if self.device == nil { refreshPorts() }
            throw error
        }

        measurement = nil
        for _ in 0..<4 {
            // Some units restart after changing the stored curve. Only retry read commands.
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let connected = try? await Spectrometer.connect(port: device.port) {
                if connected == device { return }
                break
            }
        }
        self.device = nil
        refreshPorts()
        issue = "设备已确认\(change.title)。请重新连接 USB 串口后复测。"
    }

    func exportCSV(correction: WavelengthCorrection?) {
        guard let measurement else { return }
        let csv = correction.map { measurement.correctedCSV(using: $0) } ?? measurement.csv
        let suffix = correction == nil ? "" : "-wavelength-corrected"
        saveCSV(csv, capturedAt: measurement.capturedAt, suffix: suffix)
    }

    func saveCSV(_ csv: String, capturedAt: Date, suffix: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let timestamp = capturedAt.formatted(
            .iso8601.year().month().day().time(includingFractionalSeconds: false)
        ).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "Flameeye-\(timestamp)\(suffix).csv"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                issue = "保存 CSV 失败。\(error.localizedDescription)"
            }
        }
    }

    private func finishOperation() {
        operation = nil
        captureStartedAt = nil
        activity = nil
    }
}

enum InstrumentColor {
    static let background = Color(red: 0.044, green: 0.063, blue: 0.086)
    static let surface = Color(red: 0.12, green: 0.17, blue: 0.22)
    static let text = Color(red: 0.94, green: 0.97, blue: 0.99)
    static let secondary = Color(red: 0.72, green: 0.78, blue: 0.84)
    static let teal = Color(red: 0.48, green: 0.91, blue: 0.82)
    static let amber = Color(red: 1.00, green: 0.72, blue: 0.38)
}

private struct InstrumentWindowBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            WindowVisualEffect()
            InstrumentColor.background.opacity(reduceTransparency ? 1 : 0.40)
            if !reduceTransparency {
                RadialGradient(
                    colors: [Color(red: 0.22, green: 0.48, blue: 0.52).opacity(0.24), .clear],
                    center: .topLeading, startRadius: 10, endRadius: 520
                )
                RadialGradient(
                    colors: [Color(red: 0.28, green: 0.29, blue: 0.56).opacity(0.18), .clear],
                    center: .bottomTrailing, startRadius: 10, endRadius: 480
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WindowVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: BackdropView, context: Context) {}

    final class BackdropView: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
        }
    }
}

@MainActor
private struct SpectrumWorkspace: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.openWindow) private var openWindow
    @State private var didRefresh = false
    @State private var calibrationDevice: Device?
    @State private var showsTemporaryWavelengthCorrection = false

    private var availableWavelengthCorrection: WavelengthCorrection? {
        model.device.flatMap(WavelengthCorrection.forDevice)
    }

    private var activeWavelengthCorrection: WavelengthCorrection? {
        showsTemporaryWavelengthCorrection ? availableWavelengthCorrection : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            connection
            metricRow
            SpectrumPanel(
                measurement: model.measurement,
                device: model.device,
                activity: model.activity,
                correction: activeWavelengthCorrection
            )
            footer
        }
        .padding(.horizontal, 23)
        .padding(.vertical, 18)
        .foregroundStyle(InstrumentColor.text)
        .tint(InstrumentColor.teal)
        .task {
            guard !didRefresh else { return }
            didRefresh = true
            model.refreshPorts()
        }
        .onDisappear { model.stop() }
        .onChange(of: model.device) { _ in showsTemporaryWavelengthCorrection = false }
        .sheet(item: $calibrationDevice) { device in
            CalibrationSheet(
                device: device,
                onWrite: { try await model.changeCalibration(.write($0), device: device) },
                onRestore: { try await model.changeCalibration(.restoreFactory, device: device) }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "waveform")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(InstrumentColor.teal)
                .frame(width: 46, height: 46)
                .instrumentPanel(cornerRadius: 14)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("火眼光谱")
                    .font(.system(size: 24, weight: .semibold))
                Text("FLAMEEYE  /  USB SPECTROMETER")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(InstrumentColor.secondary)
            }

            Spacer()

            if let measurement = model.measurement {
                let timestamp = measurement.capturedAt.formatted(date: .omitted, time: .standard)
                Label(model.device == nil ? "上次测量 \(timestamp)" : timestamp, systemImage: "clock")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(InstrumentColor.secondary)
                    .help("上次测量时间")
                    .accessibilityLabel("上次测量时间 \(timestamp)")
            }

            if (model.measurement?.device ?? model.device)?.protocolProfile == .legacyP32 {
                Button {
                    openWindow(id: "p32-details")
                } label: {
                    Label("测量详情", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.bordered)
            }

            Button {
                openWindow(id: "rgb-calibration")
            } label: {
                Label("RGB 校准", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)

            Button {
                model.exportCSV(correction: activeWavelengthCorrection)
            } label: {
                Label(activeWavelengthCorrection == nil ? "导出 CSV" : "导出修正 CSV",
                      systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .help(activeWavelengthCorrection == nil
                  ? "导出原始波长和光谱值。"
                  : "导出全部原始波长和光谱值，并为修正范围内的采样点附上修正波长。")
            .keyboardShortcut("e", modifiers: .command)
            .disabled(model.measurement == nil)
        }
        .controlSize(.large)
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                let statusColor = model.device == nil ? InstrumentColor.secondary : InstrumentColor.teal
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .padding(4)
                    .background(statusColor.opacity(0.16), in: Circle())
                    .accessibilityHidden(true)
                if let device = model.device {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.model)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text("固件 \(device.firmware)  ·  序列号 \(device.serial)")
                            .font(.system(size: 11))
                            .foregroundStyle(InstrumentColor.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Button("断开") { model.disconnect() }
                        .disabled(model.activity != nil)
                    if device.supportsHardwareCalibration {
                        Button("光谱校准…") { calibrationDevice = device }
                            .disabled(model.activity != nil)
                    }
                } else {
                    Picker("USB 串口", selection: $model.selectedPort) {
                        if model.ports.isEmpty {
                            Text("未发现 USB 串口").tag("")
                        }
                        ForEach(model.ports, id: \.self) { port in
                            Text(URL(fileURLWithPath: port).lastPathComponent).tag(port)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 225)
                    .disabled(model.ports.isEmpty || model.activity != nil)

                    Button {
                        model.refreshPorts()
                    } label: {
                        Label("刷新串口", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .help("刷新串口")
                    .disabled(model.activity != nil)

                    Button(model.activity == .connecting ? "连接中…" : "连接") { model.connect() }
                        .disabled(model.selectedPort.isEmpty || model.activity != nil)
                }

                Spacer(minLength: 12)

                if model.activity == .repeating || model.activity == .stopping {
                    Button(model.activity == .stopping ? "停止中…" : "停止连续测量") {
                        model.stop()
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(model.activity == .stopping)
                } else {
                    Button {
                        model.capture(repeatCapture: true)
                    } label: {
                        Label("连续测量", systemImage: "repeat")
                    }
                    .disabled(model.device == nil || model.activity != nil)
                }

                Button {
                    model.capture(repeatCapture: false)
                } label: {
                    Label(model.activity == .single ? "测量中…" : "单次测量", systemImage: "viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.device == nil || model.activity != nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            if availableWavelengthCorrection != nil {
                HStack(spacing: 12) {
                    Toggle("临时波长修正", isOn: $showsTemporaryWavelengthCorrection)
                        .toggleStyle(.checkbox)
                        .help("根据本机配置中的实测波长和参考波长拟合波长轴。")
                    if showsTemporaryWavelengthCorrection {
                        Text("已应用本机波长修正配置。CSV 保留原始波长和强度，附上范围内的修正波长。光度指标沿用设备读数。")
                            .foregroundStyle(InstrumentColor.secondary)
                    }
                }
                .font(.system(size: 12))
            }

            if let issue = model.issue {
                Label(issue, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(InstrumentColor.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .instrumentPanel()
    }

    private var metricRow: some View {
        HStack(spacing: 10) {
            metricCard("照度", symbol: "sun.max", key: "lux", digits: 1, unit: "lx")
            metricCard("相关色温", symbol: "thermometer.medium", key: "CCT", digits: 0, unit: "K")
            metricCard("显色指数", symbol: "paintpalette", key: "Ra", digits: 1, unit: "Ra")
            metricCard("黑体轨迹偏差", symbol: "scope", key: "DUV", digits: 5, unit: "Duv", signed: true)
        }
    }

    private func metricCard(
        _ title: String,
        symbol: String,
        key: String,
        digits: Int,
        unit: String,
        signed: Bool = false
    ) -> some View {
        let value = model.measurement?.metrics[key]
        let display: String?
        if let value, value.isFinite, key != "CCT" || value > 0 {
            display = String(format: signed ? "%+.\(digits)f" : "%.\(digits)f", value)
        } else {
            display = nil
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(InstrumentColor.secondary)
                Spacer()
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(InstrumentColor.teal)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(display ?? "—")
                    .font(.system(size: 30, weight: .medium, design: .monospaced))
                    .foregroundStyle(display == nil ? InstrumentColor.secondary : InstrumentColor.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(unit)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(InstrumentColor.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .instrumentPanel()
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            if model.isWaitingForCaptureFrame {
                ProgressView().controlSize(.small)
                Text(model.activity == .single ? "正在测量并检查曝光…" : "等待仪器返回首帧…")
                    .foregroundStyle(InstrumentColor.teal)
                Spacer()
            } else if let measurement = model.measurement {
                let metrics = measurement.metrics
                Label(measurement.exposure.label, systemImage: "camera.aperture")
                    .foregroundStyle(exposureColor(measurement.exposure))
                footerValue("曝光时间", String(format: "%.2f ms", Double(measurement.exposureUS) / 1000))
                footerValue("R9", metric(metrics["R9"], digits: 1))
                footerValue("色度 xy", "\(metric(metrics["x"], digits: 4)) / \(metric(metrics["y"], digits: 4))")
                Spacer()
                Text("\(measurement.points.count) 个波长采样点")
            } else {
                Label(model.device == nil ? "等待 USB 设备" : "设备就绪", systemImage: "dot.radiowaves.left.and.right")
                Spacer()
                if let device = model.device {
                    Text("USB 串口  /  \(device.baud) bps")
                } else {
                    Text("USB 串口")
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(InstrumentColor.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .instrumentPanel(cornerRadius: 10)
        .accessibilityElement(children: .combine)
    }

    private func footerValue(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
            Text(value).foregroundStyle(InstrumentColor.text)
        }
    }

    private func exposureColor(_ exposure: Exposure) -> Color {
        switch exposure {
        case .normal: InstrumentColor.teal
        default: InstrumentColor.amber
        }
    }

    private func metric(_ value: Double?, digits: Int) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.\(digits)f", value)
    }
}

private struct SpectrumPanel: View {
    let measurement: Measurement?
    let device: Device?
    let activity: WorkspaceModel.Activity?
    let correction: WavelengthCorrection?
    @State private var hoverLocation: CGPoint?

    var body: some View {
        let domain = displayedDomain
        let rangeText = "\(axisValue(domain.lowerBound))–\(axisValue(domain.upperBound)) nm"
        let allSamples = measurement?.points ?? []
        let samples = correction.map { profile in
            allSamples.filter { (profile.startNM...profile.endNM).contains($0.wavelength) }
        } ?? allSamples
        let peak = allSamples.map(\.value).max() ?? 0

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("光谱分布")
                    .font(.system(size: 16, weight: .semibold))
                Text(correction == nil ? "相对强度 (%)" : "相对强度（全谱峰值 = 100%）")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(InstrumentColor.secondary)
                Spacer()
                if correction != nil {
                    Text("临时修正  \(rangeText)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(InstrumentColor.amber)
                } else if measurement != nil || device != nil {
                    Text(rangeText)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(InstrumentColor.secondary)
                }
            }

            GeometryReader { geometry in
                let plot = CGRect(
                    x: 35, y: 10,
                    width: max(1, geometry.size.width - 57),
                    height: max(1, geometry.size.height - 39)
                )
                let hovered = hoveredPoint(samples: samples, plot: plot, domain: domain)
                Canvas { context, _ in
                    drawGrid(context, in: plot, domain: domain)
                    drawSpectrum(context, in: plot, samples: samples, peak: peak, domain: domain)
                    if let hovered {
                        drawCursor(context, in: plot, point: hovered, peak: peak, domain: domain)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let hovered {
                        Text(hoverLabel(hovered, peak: peak))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .instrumentPanel(cornerRadius: 7)
                            .padding(.trailing, 30)
                            .padding(.top, 15)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .overlay {
                    if samples.isEmpty {
                        emptyChart
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hoverLocation = point
                    case .ended: hoverLocation = nil
                    }
                }
                .accessibilityLabel(correction == nil ? "光谱曲线" : "临时修正后的光谱曲线")
                .accessibilityValue(samples.isEmpty ? emptyMessage : "\(rangeText)，\(samples.count) 个采样点"
                    + (hovered.map { "，" + hoverLabel($0, peak: peak) } ?? ""))
            }
            .frame(minHeight: 235)
        }
        .padding(15)
        .instrumentPanel()
    }

    private var emptyMessage: String {
        if activity == .connecting { return "正在读取设备信息…" }
        if activity == .calibrating { return "正在更新设备的光谱曲线…" }
        if activity != nil { return "正在采集光谱…" }
        if correction != nil, measurement != nil { return "这次测量没有覆盖临时修正范围" }
        return device == nil ? "连接设备后即可测量" : "点击「单次测量」采集光谱"
    }

    private var emptyChart: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(InstrumentColor.teal.opacity(0.7))
                .accessibilityHidden(true)
            Text(emptyMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(InstrumentColor.secondary)
        }
        .padding(13)
        .instrumentPanel(cornerRadius: 12)
        .allowsHitTesting(false)
    }

    private var displayedDomain: ClosedRange<Double> {
        if let correction {
            return correction.wavelength(for: correction.startNM)...correction.wavelength(for: correction.endNM)
        }
        let chartDevice = measurement?.device ?? device
        return Double(chartDevice?.startNM ?? 380)...Double(chartDevice?.endNM ?? 780)
    }

    private func displayedWavelength(_ rawNM: Int) -> Double {
        correction?.wavelength(for: rawNM) ?? Double(rawNM)
    }

    private func axisValue(_ wavelength: Double) -> String {
        String(format: correction == nil ? "%.0f" : "%.1f", wavelength)
    }

    private func hoverLabel(_ point: SpectrumPoint, peak: Double) -> String {
        let wavelength = axisValue(displayedWavelength(point.wavelength)) + " nm"
        let original = correction == nil ? "" : "（原始 \(point.wavelength) nm）"
        let percent = peak > 0 ? point.value / peak * 100 : 0
        return wavelength + original + String(format: "  ·  %.1f%%", percent)
    }

    private func hoveredPoint(samples: [SpectrumPoint], plot: CGRect, domain: ClosedRange<Double>) -> SpectrumPoint? {
        guard let hoverLocation, plot.contains(hoverLocation), !samples.isEmpty else { return nil }
        let fraction = Double((hoverLocation.x - plot.minX) / plot.width)
        let wavelength = domain.lowerBound + fraction * (domain.upperBound - domain.lowerBound)
        return samples.min {
            abs(displayedWavelength($0.wavelength) - wavelength)
                < abs(displayedWavelength($1.wavelength) - wavelength)
        }
    }

    private func drawGrid(_ context: GraphicsContext, in plot: CGRect, domain: ClosedRange<Double>) {
        context.fill(Path(roundedRect: plot, cornerRadius: 8), with: .color(InstrumentColor.background.opacity(0.58)))
        let labels = [0, 25, 50, 75, 100]
        for value in labels {
            let y = plot.maxY - plot.height * CGFloat(value) / 100
            drawLine(context, CGPoint(x: plot.minX, y: y), CGPoint(x: plot.maxX, y: y))
            context.draw(axisLabel(String(value)), at: CGPoint(x: plot.minX - 8, y: y), anchor: .trailing)
        }

        let minNM = domain.lowerBound
        let maxNM = domain.upperBound
        let stepSize = correction == nil ? 50.0 : 25.0
        let step = max(stepSize, ceil((maxNM - minNM) / (8 * stepSize)) * stepSize)
        let interior = stride(from: (floor(minNM / step) + 1) * step, to: maxNM, by: step)
            .filter { $0 - minNM >= step / 2 && maxNM - $0 >= step / 2 }
        for value in [minNM] + interior + [maxNM] {
            let x = xPosition(value, domain: domain, plot: plot)
            drawLine(context, CGPoint(x: x, y: plot.minY), CGPoint(x: x, y: plot.maxY))
            let label = value == minNM || value == maxNM ? axisValue(value) : String(format: "%.0f", value)
            context.draw(axisLabel(label), at: CGPoint(x: x, y: plot.maxY + 11), anchor: .top)
        }
    }

    private func axisLabel(_ label: String) -> Text {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(InstrumentColor.secondary)
    }

    private func drawLine(_ context: GraphicsContext, _ start: CGPoint, _ end: CGPoint) {
        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        context.stroke(line, with: .color(.white.opacity(0.11)), lineWidth: 1)
    }

    private func drawSpectrum(
        _ context: GraphicsContext,
        in plot: CGRect,
        samples: [SpectrumPoint],
        peak: Double,
        domain: ClosedRange<Double>
    ) {
        guard let first = samples.first, let last = samples.last else { return }
        var line = Path()
        line.move(to: pointPosition(first, in: plot, peak: peak, domain: domain))
        for sample in samples.dropFirst() {
            line.addLine(to: pointPosition(sample, in: plot, peak: peak, domain: domain))
        }

        var fill = line
        fill.addLine(to: CGPoint(x: xPosition(displayedWavelength(last.wavelength), domain: domain, plot: plot), y: plot.maxY))
        fill.addLine(to: CGPoint(x: xPosition(displayedWavelength(first.wavelength), domain: domain, plot: plot), y: plot.maxY))
        fill.closeSubpath()

        let start = CGPoint(x: plot.minX, y: plot.midY)
        let end = CGPoint(x: plot.maxX, y: plot.midY)
        let stops = wavelengthStops(domain: domain)
        let fillStops = stops.map { Gradient.Stop(color: $0.color.opacity(0.22), location: $0.location) }
        context.fill(fill, with: .linearGradient(Gradient(stops: fillStops), startPoint: start, endPoint: end))
        context.stroke(
            line,
            with: .linearGradient(Gradient(stops: stops), startPoint: start, endPoint: end),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawCursor(
        _ context: GraphicsContext,
        in plot: CGRect,
        point: SpectrumPoint,
        peak: Double,
        domain: ClosedRange<Double>
    ) {
        let position = pointPosition(point, in: plot, peak: peak, domain: domain)
        var line = Path()
        line.move(to: CGPoint(x: position.x, y: plot.minY))
        line.addLine(to: CGPoint(x: position.x, y: plot.maxY))
        context.stroke(
            line,
            with: .color(InstrumentColor.secondary.opacity(0.7)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 4])
        )
        let circle = CGRect(x: position.x - 3, y: position.y - 3, width: 6, height: 6)
        context.fill(Path(ellipseIn: circle), with: .color(InstrumentColor.text))
    }

    private func pointPosition(_ point: SpectrumPoint, in plot: CGRect, peak: Double, domain: ClosedRange<Double>) -> CGPoint {
        CGPoint(
            x: xPosition(displayedWavelength(point.wavelength), domain: domain, plot: plot),
            y: plot.maxY - plot.height * (peak > 0 ? point.value / peak : 0)
        )
    }

    private func xPosition(_ wavelength: Double, domain: ClosedRange<Double>, plot: CGRect) -> CGFloat {
        let fraction = CGFloat((wavelength - domain.lowerBound) / (domain.upperBound - domain.lowerBound))
        return plot.minX + plot.width * fraction
    }

    private func wavelengthStops(domain: ClosedRange<Double>) -> [Gradient.Stop] {
        let colors: [(Double, Color)] = [
            (380, Color(red: 0.66, green: 0.45, blue: 1.00)),
            (455, Color(red: 0.35, green: 0.58, blue: 1.00)),
            (495, Color(red: 0.30, green: 0.84, blue: 0.96)),
            (540, Color(red: 0.40, green: 0.90, blue: 0.58)),
            (580, Color(red: 0.95, green: 0.88, blue: 0.39)),
            (625, Color(red: 1.00, green: 0.58, blue: 0.32)),
            (700, Color(red: 0.98, green: 0.36, blue: 0.44))
        ]
        let stops = colors.compactMap { wavelength, color -> Gradient.Stop? in
            guard domain.contains(wavelength) else { return nil }
            let fraction = (wavelength - domain.lowerBound) / (domain.upperBound - domain.lowerBound)
            return Gradient.Stop(color: color, location: CGFloat(fraction))
        }
        if stops.isEmpty {
            return [Gradient.Stop(color: InstrumentColor.teal, location: 0),
                    Gradient.Stop(color: InstrumentColor.teal, location: 1)]
        }
        return stops
    }
}

private extension Measurement {
    func correctedCSV(using correction: WavelengthCorrection) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        let range = correction.startNM...correction.endNM
        return "wavelength_nm,spectral_value,corrected_wavelength_nm\r\n" + points.map { point in
            let corrected = range.contains(point.wavelength)
                ? String(format: "%.3f", locale: locale, correction.wavelength(for: point.wavelength))
                : ""
            return "\(point.wavelength),\(point.value),\(corrected)\r\n"
        }.joined()
    }
}

extension View {
    func instrumentPanel(cornerRadius: CGFloat = 16) -> some View {
        modifier(InstrumentGlassPanel(cornerRadius: cornerRadius))
    }
}

private struct InstrumentGlassPanel: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    shape.fill(InstrumentColor.surface)
                } else {
                    shape.fill(.thinMaterial)
                    shape.fill(
                        LinearGradient(colors: [.white.opacity(0.08), InstrumentColor.surface.opacity(0.20)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.07)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .allowsHitTesting(false)
            }
    }
}
