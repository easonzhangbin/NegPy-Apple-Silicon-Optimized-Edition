import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FilmBaseNegPyVerification: Codable, Sendable {
    struct Frame: Codable, Sendable {
        let channel: RGBLightChannel
        let fileName: String
        let camera: String
        let iso: Double
        let aperture: Double
        let shutterSeconds: Double
        let p999Fraction: Double
        let clippedPixels: Int?
        let p50Fraction: Double?
        let roiClippedPixels: Int?
        let roiSampleCount: Int?
        let roiLinearityFraction: Double?
        let roiPlateauFraction: Double?
        let capturedAt: Date?
    }

    struct SampleRegion: Codable, Equatable, Sendable {
        // Top-left normalized bounds in the unrotated, visible sensor image.
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        fileprivate var isValid: Bool {
            x.isFinite && y.isFinite && width.isFinite && height.isFinite &&
                x >= 0 && y >= 0 && x < 1 && y < 1 && width > 0 && height > 0 &&
                x + width <= 1.000000001 && y + height <= 1.000000001
        }
    }

    let readAt: Date
    let sampleRegion: SampleRegion
    let frames: [Frame]
    let tripletID: String?
    let generatedAt: Date?
    let producerVersion: String?
    let meteringMethod: String?

    var medianPercent: [Double]? {
        let values = frames.compactMap(\.p50Fraction)
        guard values.count == RGBLightChannel.allCases.count else { return nil }
        return values.map { $0 * 100 }
    }

    var medianSpreadEV: Double? { Self.spreadEV(frames.compactMap(\.p50Fraction)) }

    var meteringIssue: String? {
        let roi = sampleRegion
        guard let id = tripletID, !id.isEmpty, let generatedAt,
              generatedAt.timeIntervalSinceReferenceDate.isFinite,
              meteringMethod == "negpy-sensor-linear-half-size-v1",
              roi.x >= 0, roi.y >= 0, roi.width > 0, roi.height > 0,
              roi.x + roi.width <= 1.000000001, roi.y + roi.height <= 1.000000001,
              frames.map(\.channel) == RGBLightChannel.allCases,
              let first = frames.first, !first.camera.isEmpty,
              [first.iso, first.aperture, first.shutterSeconds].allSatisfy({ $0.isFinite && $0 > 0 }),
              frames.allSatisfy({ $0.camera == first.camera && $0.iso == first.iso &&
                  $0.aperture == first.aperture && $0.shutterSeconds == first.shutterSeconds }) else {
            return "请导入 NegPy 新版三色测光报告，核对片基区域和相机设置。"
        }

        // NegPy's 16-bit signal floor and saturation threshold, expressed as fractions.
        let minimumSignal = 10.0 / 65_535
        let saturation = 65_403.0 / 65_535
        for frame in frames {
            let channel = frame.channel.title
            guard let p50 = frame.p50Fraction, (0...1).contains(p50),
                  (p50...1).contains(frame.p999Fraction),
                  let linearity = frame.roiLinearityFraction, (0...1).contains(linearity),
                  let plateau = frame.roiPlateauFraction, (0...1).contains(plateau) else {
                return "\(channel)光缺少有效的片基曝光或裁切数据。"
            }
            guard p50 >= minimumSignal else { return "\(channel)光片基信号太低，请确认取样区域和灯档。" }
            var demosaicedClipping = 0.0
            if let clipped = frame.roiClippedPixels, let count = frame.roiSampleCount, count > 0,
               (0...count).contains(clipped) {
                demosaicedClipping = Double(clipped) / Double(count)
            } else if frame.roiClippedPixels != nil || frame.roiSampleCount != nil {
                return "\(channel)光片基像素计数无效。"
            }
            if frame.p999Fraction >= saturation || plateau > 0.002 || max(linearity, demosaicedClipping) > 0.02 {
                return "\(channel)光片基接近饱和或超出裁切限值，请降低亮度或缩短快门后重拍。"
            }
        }
        return nil
    }

    private static func spreadEV(_ responses: [Double]) -> Double? {
        guard responses.count == RGBLightChannel.allCases.count,
              responses.allSatisfy({ $0.isFinite && $0 > 0 }),
              let low = responses.min(), let high = responses.max() else { return nil }
        return log2(high) - log2(low)
    }

    private struct Report: Decodable {
        let schemaVersion: Int
        let producer: String
        let producerVersion: String
        let generatedAt: Date
        let tripletId: String
        let sampleRegion: SampleRegion
        let meteringMethod: String
        let frames: [Frame]
    }

    static var defaultReportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NegPy-AppleSilicon-067", isDirectory: true)
            .appendingPathComponent("flameeye-trichrome-report.json")
    }

    static func readLatestReport() async throws -> Self {
        let url = defaultReportURL
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw FilmBaseError.message("还没有 NegPy 测光报告。请先在 NegPy 导出报告，或选择已有的 JSON 文件。")
        }
        return try await readReport(url)
    }

    static func readReport(_ url: URL) async throws -> Self {
        try await Task.detached(priority: .userInitiated) {
            guard url.isFileURL, url.pathExtension.lowercased() == "json" else {
                throw FilmBaseError.message("请选择 NegPy 导出的 JSON 测光报告。")
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            let limit = 128 * 1024
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard attributes.isRegularFile == true, let size = attributes.fileSize, size > 0, size <= limit else {
                throw FilmBaseError.message("NegPy 测光报告为空或文件大小无效。")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: limit + 1), !data.isEmpty, data.count <= limit else {
                throw FilmBaseError.message("NegPy 测光报告为空或文件大小无效。")
            }
            return try decodeReport(data)
        }.value
    }

    static func decodeReport(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw FilmBaseError.message("NegPy 测光报告的时间格式无效。")
        }
        let report: Report
        do {
            report = try decoder.decode(Report.self, from: data)
        } catch {
            throw FilmBaseError.message("无法读取 NegPy 测光报告，请在 NegPy 中重新导出。")
        }

        guard report.schemaVersion == 1, report.producer == "NegPy" else {
            throw FilmBaseError.message("此文件不是火眼支持的 NegPy 测光报告。")
        }
        guard report.meteringMethod == "negpy-sensor-linear-half-size-v1" else {
            throw FilmBaseError.message("此报告使用了火眼尚不支持的 NegPy 测光方法。")
        }
        guard validText(report.producerVersion, limit: 128), validText(report.tripletId, limit: 128),
              report.generatedAt.timeIntervalSinceReferenceDate.isFinite, report.sampleRegion.isValid,
              report.frames.map(\.channel) == RGBLightChannel.allCases,
              Set(report.frames.map(\.fileName)).count == RGBLightChannel.allCases.count else {
            throw FilmBaseError.message("NegPy 测光报告的三色组或片基区域无效。")
        }

        let first = report.frames[0]
        for frame in report.frames {
            guard validText(frame.fileName, limit: 255), !frame.fileName.contains("/"),
                  !frame.fileName.contains("\\"), frame.fileName != ".", frame.fileName != "..",
                  validText(frame.camera, limit: 128),
                  [frame.iso, frame.aperture, frame.shutterSeconds].allSatisfy({ $0.isFinite && $0 > 0 }),
                  (0...1).contains(frame.p999Fraction),
                  let median = frame.p50Fraction, (0...frame.p999Fraction).contains(median),
                  let linearity = frame.roiLinearityFraction, (0...1).contains(linearity),
                  let plateau = frame.roiPlateauFraction, (0...1).contains(plateau),
                  frame.clippedPixels.map({ $0 >= 0 }) != false else {
                throw FilmBaseError.message("NegPy 测光报告含无效的曝光或裁切读数。")
            }
            if let count = frame.roiSampleCount, let clipped = frame.roiClippedPixels {
                guard count > 0, (0...count).contains(clipped) else {
                    throw FilmBaseError.message("NegPy 测光报告的片基像素计数无效。")
                }
            } else if frame.roiSampleCount != nil || frame.roiClippedPixels != nil {
                throw FilmBaseError.message("NegPy 测光报告的片基像素计数不完整。")
            }
            guard frame.camera == first.camera, frame.iso == first.iso,
                  frame.aperture == first.aperture, frame.shutterSeconds == first.shutterSeconds else {
                throw FilmBaseError.message("三张 NegPy 实拍须使用同一相机、ISO、光圈和快门。")
            }
        }

        return Self(readAt: Date(), sampleRegion: report.sampleRegion, frames: report.frames,
                    tripletID: report.tripletId, generatedAt: report.generatedAt,
                    producerVersion: report.producerVersion, meteringMethod: report.meteringMethod)
    }

    private static func validText(_ text: String, limit: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= limit &&
            text.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

@MainActor
struct NegPyBalanceAttachmentView: View {
    @Binding var verification: FilmBaseNegPyVerification?
    @Binding var isReading: Bool
    @State private var issue: String?
    @State private var choosingReport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("NegPy 测光报告").font(InstrumentFont.style(.callout))
                Spacer()
                if verification != nil {
                    Button("移除") { verification = nil }
                        .instrumentButton()
                        .disabled(isReading)
                }
                Button {
                    choosingReport = true
                } label: {
                    InstrumentFont.controlText("选择 JSON…")
                }
                    .instrumentButton()
                    .disabled(isReading)
                Button(isReading ? "读取中…" : "读取最新报告") { readReport() }
                    .instrumentButton()
                    .disabled(isReading)
            }
            if let verification {
                if let date = verification.generatedAt {
                    Text("NegPy 导出于 \(date.formatted(date: .abbreviated, time: .standard))")
                        .font(InstrumentFont.style(.caption, light: true))
                        .foregroundStyle(InstrumentColor.secondary)
                }
                if let first = verification.frames.first {
                    let settings = String(format: "ISO %.0f · f/%.2g · %.4g s", first.iso, first.aperture, first.shutterSeconds)
                    Text("\(first.camera) · \(settings)")
                        .font(InstrumentFont.style(.caption, light: true))
                        .foregroundStyle(InstrumentColor.secondary)
                }
                ForEach(verification.frames, id: \.channel) { frame in
                    let high = String(format: "%.2f%%", frame.p999Fraction * 100)
                    let median = frame.p50Fraction.map { String(format: " · P50 %.2f%%", $0 * 100) } ?? ""
                    Text("\(frame.channel.title)  \(frame.fileName)  ·  P99.9 \(high)\(median)")
                        .font(InstrumentFont.style(.caption))
                    if let clipped = frame.roiClippedPixels, let count = frame.roiSampleCount {
                        Text("片基到达上限 \(clipped)/\(count)")
                            .font(InstrumentFont.style(.caption))
                            .foregroundStyle(InstrumentColor.secondary)
                    }
                    if let linearity = frame.roiLinearityFraction, let plateau = frame.roiPlateauFraction {
                        Text(String(format: "片基超线性范围 %.3f%% · 饱和平台 %.3f%%", linearity * 100, plateau * 100))
                            .font(InstrumentFont.style(.caption))
                            .foregroundStyle(plateau > 0 ? InstrumentColor.amber : InstrumentColor.secondary)
                    }
                }
            } else {
                Text("在 NegPy 选中三色合成并框选透明片基，然后导出测光报告。在这里读取报告，核对文件名与测光结果。")
                    .font(InstrumentFont.style(.caption, light: true))
                    .foregroundStyle(InstrumentColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let issue {
                Text(issue).font(InstrumentFont.style(.caption)).foregroundStyle(InstrumentColor.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fileImporter(isPresented: $choosingReport, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url): readReport(url)
            case let .failure(error): issue = error.localizedDescription
            }
        }
    }

    private func readReport(_ url: URL? = nil) {
        isReading = true
        issue = nil
        verification = nil
        Task {
            defer { isReading = false }
            do {
                if let url {
                    verification = try await FilmBaseNegPyVerification.readReport(url)
                } else {
                    verification = try await FilmBaseNegPyVerification.readLatestReport()
                }
            } catch {
                issue = error.localizedDescription
            }
        }
    }
}

extension FilmBaseSavedBalance {
    func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

@MainActor
func exportFilmBaseSavedBalance(_ record: FilmBaseSavedBalance) -> String? {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    let fileName = record.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    panel.nameFieldStringValue = "\(fileName).json"
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    do {
        try record.exportJSON().write(to: url, options: .atomic)
        return nil
    } catch {
        return "导出配平失败。\(error.localizedDescription)"
    }
}
