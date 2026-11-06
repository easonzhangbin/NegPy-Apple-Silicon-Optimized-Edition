import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct CalibrationSheet: View {
    let device: Device
    let onWrite: (SpectralCalibration) async throws -> Void
    let onRestore: () async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var source: URL?
    @State private var reference: URL?
    @State private var calibration: SpectralCalibration?
    @State private var inputIssue: String?
    @State private var feedback: Feedback?
    @State private var confirmation: Action?
    @State private var operation: Action?

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            heading
            inputs
            preview
            factoryRestore
            footer
        }
        .font(InstrumentFont.style(.body))
        .padding(24)
        .frame(width: 630)
        .background(.regularMaterial)
        .interactiveDismissDisabled(operation != nil)
        .alert(item: $confirmation, content: confirmationAlert)
    }

    private var heading: some View {
        HStack(spacing: 11) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(InstrumentColor.teal)
                .frame(width: 40, height: 40)
                .instrumentPanel(cornerRadius: 12)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("光谱校准")
                    .font(InstrumentFont.style(.title2))
                    .accessibilityAddTraits(.isHeader)
                Text("\(device.model)  ·  序列号 \(device.serial)  ·  \(device.startNM)–\(device.endNM) nm")
                    .font(InstrumentFont.style(.caption, light: true))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("在相同条件下测量同一稳定光源，实测与参考光谱使用相同单位。两份 UTF-8 CSV 均须包含波长和正的光谱值，覆盖 \(device.startNM)–\(device.endNM) nm，每 1 nm 一行。")
                .font(InstrumentFont.style(.callout, light: true))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            fileRow("实测光谱", file: source) { chooseFile(.source) }
            fileRow("参考光谱", file: reference) { chooseFile(.reference) }
        }
        .padding(13)
        .instrumentPanel(cornerRadius: 14)
        .disabled(operation != nil)
    }

    private func fileRow(_ title: String, file: URL?, choose: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .fontWeight(.medium)
                .frame(width: 64, alignment: .leading)
            Text(file?.lastPathComponent ?? "选择 CSV 文件")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(file == nil ? .secondary : .primary)
                .help(file?.path ?? title)
            Spacer(minLength: 8)
            Button(file == nil ? "导入 CSV…" : "更换 CSV…", action: choose)
                .instrumentButton()
                .accessibilityLabel("导入\(title) CSV")
        }
        .font(InstrumentFont.style(.callout))
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("光谱效率修正系数").font(InstrumentFont.style(.headline))
                Spacer()
                Text("实测光谱 ÷ 参考光谱")
                    .font(InstrumentFont.style(.caption, light: true))
                    .foregroundStyle(.secondary)
            }

            if let inputIssue {
                Label(inputIssue, systemImage: "exclamationmark.circle")
                    .font(InstrumentFont.style(.callout))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 83, alignment: .topLeading)
            } else if let calibration {
                CalibrationRatioPreview(points: calibration.points)
            } else {
                Text("导入两份 CSV 后即可预览将写入设备的修正系数。")
                    .font(InstrumentFont.style(.callout, light: true))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 83, alignment: .topLeading)
            }

            HStack {
                Spacer()
                Button("写入校准曲线…") { confirmation = .write }
                    .instrumentButton(prominent: true)
                    .disabled(calibration == nil || operation != nil)
            }
        }
        .padding(13)
        .instrumentPanel(cornerRadius: 14)
    }

    private var factoryRestore: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("恢复出厂光谱曲线")
                    .font(InstrumentFont.style(.headline))
                Text("出厂曲线会覆盖设备中现有的光谱修正。")
                    .font(InstrumentFont.style(.callout, light: true))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("恢复出厂曲线…") { confirmation = .restore }
                .instrumentButton()
                .disabled(operation != nil)
        }
        .padding(13)
        .instrumentPanel(cornerRadius: 14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let operation {
                ProgressView().controlSize(.small)
                Text(operation == .write ? "正在写入校准曲线并检查连接…" : "正在恢复出厂曲线并检查连接…")
                    .font(InstrumentFont.style(.callout, light: true))
                    .foregroundStyle(.secondary)
            } else if let feedback {
                Label(feedback.message, systemImage: feedback.isError ? "exclamationmark.circle" : "checkmark.circle")
                    .font(InstrumentFont.style(.callout))
                    .foregroundStyle(feedback.isError ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("关闭") { dismiss() }
                .instrumentButton()
                .keyboardShortcut(.cancelAction)
                .disabled(operation != nil)
        }
        .frame(minHeight: 30)
    }

    private func chooseFile(_ kind: Input) {
        let panel = NSOpenPanel()
        panel.title = kind == .source ? "导入实测光谱" : "导入参考光谱"
        panel.prompt = "导入"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        switch kind {
        case .source: source = url
        case .reference: reference = url
        }
        calibration = nil
        inputIssue = nil
        feedback = nil
        guard let source, let reference else { return }
        do {
            calibration = try SpectralCalibration(
                source: source,
                reference: reference,
                startNM: device.startNM,
                endNM: device.endNM
            )
        } catch {
            inputIssue = error.localizedDescription
        }
    }

    private func confirmationAlert(_ action: Action) -> Alert {
        let text: String
        let label: String
        switch action {
        case .write:
            let count = calibration?.points.count ?? 0
            label = "写入校准"
            text = "将把预览中的 \(count) 个修正系数写入 \(device.model)。写入期间请保持 USB 连接，完成后设备可能短暂重连。"
        case .restore:
            label = "恢复出厂曲线"
            text = "将用出厂光谱曲线覆盖 \(device.model) 当前的光谱修正。恢复期间请保持 USB 连接，完成后设备可能短暂重连。"
        }
        return Alert(
            title: Text(label + "？"),
            message: Text(text),
            primaryButton: .destructive(Text(label)) { perform(action) },
            secondaryButton: .cancel(Text("取消"))
        )
    }

    private func perform(_ action: Action) {
        guard operation == nil, action == .restore || calibration != nil else { return }
        operation = action
        feedback = nil

        Task {
            defer { operation = nil }
            do {
                switch action {
                case .write:
                    guard let calibration else { return }
                    try await onWrite(calibration)
                    feedback = Feedback(message: "校准曲线已写入。", isError: false)
                case .restore:
                    try await onRestore()
                    feedback = Feedback(message: "已恢复出厂光谱曲线。", isError: false)
                }
                source = nil
                calibration = nil
                inputIssue = nil
            } catch {
                feedback = Feedback(message: error.localizedDescription, isError: true)
            }
        }
    }

    private enum Input { case source, reference }

    private enum Action: String, Identifiable {
        case write, restore
        var id: Self { self }
    }

    private struct Feedback {
        let message: String
        let isError: Bool
    }
}

private struct CalibrationRatioPreview: View {
    let points: [SpectralCalibration.Point]

    var body: some View {
        let values = points.map { Double($0.ratio) }
        let lowest = values.min() ?? 1
        let highest = values.max() ?? 1
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 13) {
                Text("\(points.count) 个波长")
                Text("最小 \(format(lowest))×")
                Text("最大 \(format(highest))×")
            }
            .font(InstrumentFont.style(.caption))

            Canvas { context, size in
                let low = min(1, lowest)
                let high = max(1, highest)
                let padding = high == low ? 0.1 : (high - low) * 0.08
                let range = (low - padding)...(high + padding)
                let plot = CGRect(x: 5, y: 4, width: max(1, size.width - 10), height: max(1, size.height - 8))
                let count = max(1, values.count - 1)
                func y(_ value: Double) -> CGFloat {
                    plot.maxY - CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * plot.height
                }

                var baseline = Path()
                baseline.move(to: CGPoint(x: plot.minX, y: y(1)))
                baseline.addLine(to: CGPoint(x: plot.maxX, y: y(1)))
                context.stroke(baseline, with: .color(.secondary.opacity(0.5)),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                let curve = Path { path in
                    path.addLines(values.enumerated().map { index, value in
                        CGPoint(x: plot.minX + CGFloat(index) / CGFloat(count) * plot.width, y: y(value))
                    })
                }
                context.stroke(curve, with: .color(.accentColor),
                               style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
            }
            .frame(height: 58)
            .background(InstrumentColor.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityLabel("修正系数曲线")

            HStack {
                Text("\(points.first?.wavelength ?? 0) nm")
                Spacer()
                Text("虚线 1×")
                Spacer()
                Text("\(points.last?.wavelength ?? 0) nm")
            }
            .font(InstrumentFont.style(.caption2))
            .foregroundStyle(.secondary)
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.5g", value)
    }
}
