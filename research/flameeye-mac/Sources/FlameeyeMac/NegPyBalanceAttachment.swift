import AppKit
import SQLite3
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
        let clippedPixels: Int
    }

    struct SampleRegion: Codable, Sendable {
        // Normalized bounds in the unrotated sensor image.
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    let readAt: Date
    let sampleRegion: SampleRegion
    let frames: [Frame]

    static func readCurrentTriplet() async throws -> Self {
        try await Task.detached(priority: .userInitiated) {
            let paths = try currentTripletPaths()
            guard let executable = Bundle.main.url(forAuxiliaryExecutable: "MeasureNegPyExposure") else {
                throw FilmBaseError.message("找不到 NegPy 曝光读取组件。请打开完整的火眼 Mac 应用。")
            }
            let frames = try zip(RGBLightChannel.allCases, paths).map { color, path in
                try readFrame(path, color: color, executable: executable)
            }
            return Self(readAt: Date(), sampleRegion: SampleRegion(x: 0.445, y: 0.007, width: 0.115, height: 0.018),
                        frames: frames)
        }.value
    }

    private static func currentTripletPaths() throws -> [String] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let options = ["NegPy-AppleSilicon-067", "NegPy"].map {
            support.appendingPathComponent($0, isDirectory: true).appendingPathComponent("settings.db")
        }
        guard let settings = options.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) else {
            throw FilmBaseError.message("找不到 NegPy 的会话记录。请先在 NegPy 中打开一组三色合成。")
        }

        var db: OpaquePointer?
        let status = sqlite3_open_v2(settings.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard status == SQLITE_OK, let db else {
            throw FilmBaseError.message("无法打开 NegPy 会话记录。")
        }
        sqlite3_busy_timeout(db, 600)
        var statement: OpaquePointer?
        let query = """
            SELECT key, value_json FROM global_settings
            WHERE key IN ('session_active_path', 'session_triplets')
            """
        let prepared = sqlite3_prepare_v2(db, query, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK, let statement else {
            throw FilmBaseError.message("当前 NegPy 版本的会话格式无法读取。")
        }
        var entries = [String: Data]()
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let key = sqlite3_column_text(statement, 0), let value = sqlite3_column_text(statement, 1) {
                entries[String(cString: key)] = Data(String(cString: value).utf8)
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else {
            throw FilmBaseError.message("NegPy 会话记录暂时无法读取，请稍后重试。")
        }
        guard let activeData = entries["session_active_path"], let groupsData = entries["session_triplets"],
              let red = try? JSONDecoder().decode(String.self, from: activeData),
              let groups = try? JSONSerialization.jsonObject(with: groupsData) as? [String: [Any]],
              let members = groups[red], members.count >= 2,
              let green = members[0] as? String, let blue = members[1] as? String else {
            throw FilmBaseError.message("请在 NegPy 中选中要附上的三色合成，再点读取。")
        }

        let paths = [red, green, blue]
        guard Set(paths).count == RGBLightChannel.allCases.count,
              paths.allSatisfy({ $0.hasPrefix("/") }) else {
            throw FilmBaseError.message("NegPy 会话中的三色原片路径无效。")
        }
        if let missing = paths.first(where: { !FileManager.default.isReadableFile(atPath: $0) }) {
            throw FilmBaseError.message("找不到原片 \(URL(fileURLWithPath: missing).lastPathComponent)。请确认相机或存储卡已连接。")
        }
        return paths
    }

    private struct ExposureResult: Decodable {
        let p999: Double
        let clippedPixels: Int
        let camera: String
        let iso: Double
        let aperture: Double
        let shutter: Double
        let dominant: String
    }

    private static func readFrame(_ path: String, color: RGBLightChannel, executable: URL) throws -> Frame {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let process = Process()
        process.executableURL = executable
        process.arguments = [path, color.rawValue.prefix(1).uppercased()]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw FilmBaseError.message("无法读取 \(name) · \(detail)")
        }
        guard let result = try? JSONDecoder().decode(ExposureResult.self, from: data),
              !result.camera.isEmpty, result.iso > 0, result.aperture > 0, result.shutter > 0,
              result.p999.isFinite, result.p999 >= 0, result.clippedPixels >= 0 else {
            throw FilmBaseError.message("\(name) 的曝光读数不完整。")
        }
        guard result.dominant == color.rawValue.prefix(1).uppercased() else {
            throw FilmBaseError.message("\(name) 的主通道与 NegPy 分配的\(color.title)光不符。请核对三色组。")
        }
        return Frame(channel: color, fileName: name, camera: result.camera, iso: result.iso,
                     aperture: result.aperture, shutterSeconds: result.shutter, p999Fraction: result.p999,
                     clippedPixels: result.clippedPixels)
    }
}

@MainActor
struct NegPyBalanceAttachmentView: View {
    @Binding var verification: FilmBaseNegPyVerification?
    @Binding var isReading: Bool
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("NegPy 实拍").font(.callout.weight(.medium))
                Spacer()
                if verification != nil {
                    Button("移除") { verification = nil }
                        .disabled(isReading)
                }
                Button(isReading ? "读取中…" : "读取 NegPy 当前三色组") { readTriplet() }
                    .disabled(isReading)
            }
            if let verification {
                ForEach(verification.frames, id: \.channel) { frame in
                    let percent = String(format: "%.1f%%", frame.p999Fraction * 100)
                    Text("\(frame.channel.title)  \(frame.fileName)  ·  \(percent)  ·  削顶 \(frame.clippedPixels) 像素")
                        .font(.system(.caption, design: .monospaced))
                }
            } else {
                Text("在 NegPy 选中要保存的三色合成，再读取并核对文件名。曝光沿用 S1H 原片的固定片边取样位置。")
                    .font(.caption)
                    .foregroundStyle(InstrumentColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let issue {
                Text(issue).font(.caption).foregroundStyle(InstrumentColor.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func readTriplet() {
        isReading = true
        issue = nil
        verification = nil
        Task {
            defer { isReading = false }
            do { verification = try await FilmBaseNegPyVerification.readCurrentTriplet() }
            catch { issue = error.localizedDescription }
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
