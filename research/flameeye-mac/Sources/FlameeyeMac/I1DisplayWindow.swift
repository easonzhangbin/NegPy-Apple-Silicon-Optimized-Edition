import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct I1DisplayWindow: View {
    @StateObject private var model = I1DisplayWindowModel()
    @AppStorage("i1Display.spotreadPath") private var executablePath = ""
    @AppStorage("i1Display.correctionPath") private var correctionPath = ""
    @State private var mode: I1MeasurementMode = .emission

    private var executableURL: URL? {
        executablePath.isEmpty ? model.defaultExecutableURL : URL(fileURLWithPath: executablePath)
    }

    private var correctionURL: URL? {
        mode == .emission && !correctionPath.isEmpty ? URL(fileURLWithPath: correctionPath) : nil
    }

    private var configurationIssue: String? {
        I1DisplayWindowModel.configurationIssue(executableURL: executableURL, correctionURL: correctionURL)
    }

    private var displayedMode: I1MeasurementMode { model.reading?.mode ?? mode }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                heading
                settings
                controls
                if let issue = model.issue {
                    notice(issue)
                }
                measurements
                provenance
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(InstrumentFont.style(.body))
        .foregroundStyle(InstrumentColor.text)
        .tint(InstrumentColor.teal)
        .onAppear { model.findExecutable() }
        .onDisappear { model.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.stop()
        }
        .onChange(of: mode) { _ in model.resetReading() }
        .onChange(of: executableURL) { _ in model.resetReading() }
        .onChange(of: correctionURL) { _ in model.resetReading() }
    }

    private var heading: some View {
        HStack(spacing: 11) {
            Image(systemName: "scope")
                .foregroundStyle(InstrumentColor.teal)
                .frame(width: 40, height: 40)
                .instrumentPanel(cornerRadius: 12)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("i1Display 色度与亮度")
                    .font(InstrumentFont.style(.title2))
                    .accessibilityAddTraits(.isHeader)
                Text("USB 测量 · ArgyllCMS spotread")
                    .font(InstrumentFont.style(.caption, light: true))
                    .foregroundStyle(InstrumentColor.secondary)
            }
            Spacer()
            Button { model.exportReading() } label: {
                InstrumentFont.controlLabel("导出 XYZ CSV…", systemImage: "square.and.arrow.down")
            }
            .instrumentButton()
            .disabled(model.reading == nil)
            .help("导出最近一次实测的 XYZ、色度与采集信息。")
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("测量模式")
                InstrumentPopup(label: "测量模式", options: I1MeasurementMode.allCases.map { ($0.label, $0) },
                                selection: $mode)
                    .frame(width: 155, height: 24)
                Spacer()
            }
            Text(mode.instructions)
                .font(InstrumentFont.style(.callout, light: true))
                .foregroundStyle(InstrumentColor.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack(spacing: 10) {
                Text("测量工具")
                    .frame(width: 64, alignment: .leading)
                Text(executableURL?.lastPathComponent ?? "未找到 spotread")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(executableURL?.path ?? "选择已安装的 ArgyllCMS spotread 可执行文件。")
                Spacer(minLength: 5)
                if !executablePath.isEmpty {
                    Button {
                        executablePath = ""
                        model.findExecutable()
                    } label: {
                        InstrumentFont.controlText("自动查找")
                    }
                    .instrumentButton()
                }
                Button { chooseExecutable() } label: {
                    InstrumentFont.controlText("选择工具…")
                }
                .instrumentButton()
            }
            if mode == .emission {
                HStack(spacing: 10) {
                    Text("光源校正")
                        .frame(width: 64, alignment: .leading)
                    Text(correctionURL?.lastPathComponent ?? "通用校正")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(correctionURL?.path ?? "可选择与当前光源匹配的 CCSS 或 CCMX 文件。")
                    Spacer(minLength: 5)
                    if correctionURL != nil {
                        Button { correctionPath = "" } label: {
                            InstrumentFont.controlText("清除")
                        }
                        .instrumentButton()
                        .accessibilityLabel("清除光源校正")
                    }
                    Button { chooseCorrection() } label: {
                        InstrumentFont.controlText("选择校正…")
                    }
                    .instrumentButton()
                }
            }
            Text(mode == .ambient
                 ? "环境光模式使用仪器扩散罩校正，不使用显示器 CCSS 或 CCMX 校正。"
                 : correctionURL == nil
                 ? "通用校正未与当前光源匹配。读数用于同条件复测。"
                 : "已选择光源校正。请确认文件与当前光源匹配。")
                .font(InstrumentFont.style(.caption, light: true))
                .foregroundStyle(InstrumentColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(InstrumentFont.style(.callout))
        .padding(13)
        .instrumentPanel(cornerRadius: 14)
        .disabled(model.isBusy)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Text(model.activity == .stopping ? "正在停止并释放仪器…" : "正在测量…")
                        .foregroundStyle(InstrumentColor.teal)
                    Spacer()
                    Button { model.stop() } label: {
                        InstrumentFont.controlText(model.activity == .stopping ? "停止中…" : "停止测量")
                    }
                    .instrumentButton()
                    .disabled(model.activity == .stopping)
                } else {
                    Text(model.reading == nil ? "准备测量" : "测量已停止")
                        .foregroundStyle(InstrumentColor.secondary)
                    Spacer()
                    Button { start(continuous: true) } label: {
                        InstrumentFont.controlLabel("连续测量", systemImage: "repeat")
                    }
                    .instrumentButton()
                    .disabled(configurationIssue != nil)
                    Button { start(continuous: false) } label: {
                        InstrumentFont.controlLabel("单次测量", systemImage: "viewfinder")
                    }
                    .instrumentButton(prominent: true)
                    .disabled(configurationIssue != nil)
                }
            }
            if let configurationIssue {
                notice(configurationIssue)
            }
            Text("连续测量逐次读取仪器，采集间隔随测量时间变化。")
                .font(InstrumentFont.style(.caption, light: true))
                .foregroundStyle(InstrumentColor.secondary)
        }
    }

    private var measurements: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("绝对三刺激值 XYZ")
                    .font(InstrumentFont.style(.headline))
                Spacer()
                if let reading = model.reading {
                    Text("最近实测 · \(reading.mode.label) · \(reading.capturedAt.formatted(date: .omitted, time: .standard))")
                        .font(InstrumentFont.style(.caption, light: true))
                        .foregroundStyle(InstrumentColor.secondary)
                }
            }
            HStack(spacing: 9) {
                valueCard("X", value: number(model.reading?.x), unit: "")
                valueCard("Y", value: number(model.reading?.y), unit: displayedMode.unit)
                valueCard("Z", value: number(model.reading?.z), unit: "")
            }
            HStack(alignment: .top, spacing: 9) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("CIE 1931 色度")
                        .font(InstrumentFont.style(.callout))
                    detailRow("x", value: decimal(model.reading?.chromaticityX, digits: 5))
                    detailRow("y", value: decimal(model.reading?.chromaticityY, digits: 5))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .instrumentPanel(cornerRadius: 13)

                VStack(alignment: .leading, spacing: 9) {
                    Text("近白光参考")
                        .font(InstrumentFont.style(.callout))
                    detailRow("色温", value: colorTemperature)
                    detailRow("Duv", value: decimal(model.reading?.duv, digits: 5, signed: true))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .instrumentPanel(cornerRadius: 13)
            }
            Text("Y 为\(displayedMode == .ambient ? "环境照度" : "亮度")。色温与 Duv 沿用工具输出，色温仅在 |Duv| ≤ 0.05 时显示。")
                .font(InstrumentFont.style(.caption, light: true))
                .foregroundStyle(InstrumentColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var provenance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("仪器与采集")
                .font(InstrumentFont.style(.callout))
            if let reading = model.reading {
                detailRow("仪器", value: reading.product.isEmpty ? "—" : reading.product)
                detailRow("序列号", value: reading.serial.isEmpty ? "—" : reading.serial)
                detailRow("固件", value: reading.firmware.isEmpty ? "—" : reading.firmware)
                detailRow("测量引擎", value: "ArgyllCMS \(reading.engineVersion)")
                detailRow("采集时间", value: reading.capturedAt.formatted(date: .abbreviated, time: .standard))
                detailRow("本次校正", value: reading.correctionName)
            } else {
                Text("开始测量后显示仪器信息。")
                    .font(InstrumentFont.style(.caption, light: true))
                    .foregroundStyle(InstrumentColor.secondary)
            }
        }
        .padding(13)
        .instrumentPanel(cornerRadius: 13)
    }

    private var colorTemperature: String {
        guard let reading = model.reading else { return "—" }
        guard let cct = reading.cct, cct.isFinite, cct > 0,
              let duv = reading.duv, duv.isFinite, abs(duv) <= 0.05 else { return "不适用" }
        return decimal(cct, digits: 0) + " K"
    }

    private func valueCard(_ title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(InstrumentFont.style(.callout))
                .foregroundStyle(InstrumentColor.secondary)
            Text(value)
                .font(InstrumentFont.size(28))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit.isEmpty ? "三刺激值" : unit)
                .font(InstrumentFont.style(.caption, light: true))
                .foregroundStyle(InstrumentColor.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .instrumentPanel(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(InstrumentColor.secondary)
            Spacer(minLength: 5)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(InstrumentFont.style(.caption))
        .accessibilityElement(children: .combine)
    }

    private func notice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(InstrumentFont.style(.callout))
            .foregroundStyle(InstrumentColor.amber)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func decimal(_ value: Double?, digits: Int, signed: Bool = false) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: signed ? "%+.\(digits)f" : "%.\(digits)f",
                      locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func start(continuous: Bool) {
        model.start(executableURL: executableURL, mode: mode, correctionURL: correctionURL, continuous: continuous)
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "选择 spotread 可执行文件"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard I1DisplayWindowModel.isExecutable(url) else {
            model.issue = "所选文件无法执行。请选择已安装的 spotread 工具。"
            return
        }
        executablePath = url.path
        model.issue = nil
    }

    private func chooseCorrection() {
        let panel = NSOpenPanel()
        panel.title = "选择光源校正文件"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["ccss", "ccmx"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ["ccss", "ccmx"].contains(url.pathExtension.lowercased()),
              FileManager.default.isReadableFile(atPath: url.path) else {
            model.issue = "无法读取校正文件。请选择 CCSS 或 CCMX 文件。"
            return
        }
        correctionPath = url.path
        model.issue = nil
    }
}

@MainActor
private final class I1DisplayWindowModel: ObservableObject {
    enum Activity { case single, continuous, stopping }

    @Published private(set) var reading: I1DisplayReading?
    @Published private(set) var defaultExecutableURL: URL?
    @Published private(set) var activity: Activity?
    @Published var issue: String?
    private var operation: Task<Void, Never>?

    var isBusy: Bool { activity != nil }

    func findExecutable() {
        defaultExecutableURL = I1DisplayBackend.defaultExecutableURL()
    }

    static func isExecutable(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
    }

    static func configurationIssue(executableURL: URL?, correctionURL: URL?) -> String? {
        guard let executableURL else { return "未找到 spotread。请选择已安装的 ArgyllCMS 工具。" }
        guard isExecutable(executableURL) else { return "测量工具无法执行，请重新选择 spotread。" }
        if let correctionURL,
           !["ccss", "ccmx"].contains(correctionURL.pathExtension.lowercased())
            || !FileManager.default.isReadableFile(atPath: correctionURL.path) {
            return "校正文件不可用，请重新选择或清除。"
        }
        return nil
    }

    func start(executableURL: URL?, mode: I1MeasurementMode, correctionURL: URL?, continuous: Bool) {
        guard !isBusy else { return }
        if let problem = Self.configurationIssue(executableURL: executableURL, correctionURL: correctionURL) {
            issue = problem
            return
        }
        guard let executableURL else { return }
        issue = nil
        activity = continuous ? .continuous : .single
        operation = Task {
            defer {
                operation = nil
                activity = nil
            }
            do {
                repeat {
                    try Task.checkCancellation()
                    let result = try await I1DisplayBackend.measure(executableURL: executableURL, mode: mode,
                                                                    correctionURL: correctionURL)
                    try Task.checkCancellation()
                    reading = result
                    if continuous { try await Task.sleep(nanoseconds: 150_000_000) }
                } while continuous
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }

    func stop() {
        guard isBusy, activity != .stopping else { return }
        activity = .stopping
        operation?.cancel()
    }

    func resetReading() {
        stop()
        reading = nil
        issue = nil
    }

    func exportReading() {
        guard let reading else { return }
        let csv = reading.csv
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let stamp = ISO8601DateFormatter().string(from: reading.capturedAt).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "Flameeye-i1Display-\(stamp).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            issue = "导出失败。\(error.localizedDescription)"
        }
    }
}
