import Darwin
import Foundation

enum I1MeasurementMode: String, CaseIterable, Identifiable, Sendable {
    case emission
    case ambient

    var id: String { rawValue }

    var label: String {
        switch self {
        case .emission: return "发光测量"
        case .ambient: return "环境光测量"
        }
    }

    var unit: String {
        switch self {
        case .emission: return "cd/m²"
        case .ambient: return "lx"
        }
    }

    var instructions: String {
        switch self {
        case .emission: return "移开环境光扩散罩，将探头朝向要测量的发光表面，保持位置固定。"
        case .ambient: return "将环境光扩散罩盖到探头上，在要测量的位置保持探头和光源不动。"
        }
    }
}

struct I1DisplayReading: Sendable {
    let capturedAt: Date
    let mode: I1MeasurementMode
    let product: String
    let serial: String
    let firmware: String
    let x: Double
    let y: Double
    let z: Double
    let cct: Double?
    let duv: Double?
    let correctionName: String
    let engineVersion: String

    var chromaticityX: Double? { chromaticity(x) }
    var chromaticityY: Double? { chromaticity(y) }

    private func chromaticity(_ value: Double) -> Double? {
        let sum = x + y + z
        guard value.isFinite, sum.isFinite, sum > 0 else { return nil }
        let result = value / sum
        return result.isFinite ? result : nil
    }

    var csv: String {
        let header = "captured_at,mode,product,serial,firmware,X,Y,Z,x,y,Y_unit,CCT_K,Duv,correction,engine_version"
        let fields: [String] = [capturedAt.ISO8601Format(), mode.rawValue, product, serial, firmware,
                                String(x), String(y), String(z), chromaticityX.map { String($0) } ?? "",
                                chromaticityY.map { String($0) } ?? "", mode.unit,
                                cct.map { String($0) } ?? "", duv.map { String($0) } ?? "",
                                correctionName, engineVersion]
        let row = fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        return header + "\r\n" + row + "\r\n"
    }
}

enum I1DisplayBackend {
    static func defaultExecutableURL() -> URL? {
        let manager = FileManager.default
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates += ["spotread", "bin/spotread", "Argyll/bin/spotread", "ArgyllCMS/bin/spotread"]
                .map { resources.appendingPathComponent($0) }
        }
        candidates += ["/opt/homebrew/bin/spotread", "/usr/local/bin/spotread", "/opt/local/bin/spotread",
                       "/Applications/ArgyllCMS/bin/spotread"].map { URL(fileURLWithPath: $0) }
        let home = manager.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent("Applications/ArgyllCMS/bin/spotread"))
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let packages = (try? manager.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])) ?? []
        candidates += packages.filter { $0.lastPathComponent.lowercased().hasPrefix("argyll") }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("bin/spotread") }
        return candidates.first(where: isExecutable)
    }

    static func measure(executableURL: URL, mode: I1MeasurementMode,
                        correctionURL: URL?) async throws -> I1DisplayReading {
        guard isExecutable(executableURL) else {
            throw I1DisplayError.message("所选文件无法执行。请选择 ArgyllCMS 的 spotread。")
        }
        guard mode != .ambient || correctionURL == nil else {
            throw I1DisplayError.message("环境光模式使用仪器扩散罩校正。请清除显示器校正文件。")
        }
        if let correctionURL {
            guard correctionURL.isFileURL,
                  ["ccss", "ccmx"].contains(correctionURL.pathExtension.lowercased()),
                  FileManager.default.isReadableFile(atPath: correctionURL.path),
                  (try? correctionURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw I1DisplayError.message("无法读取校正文件。请选择 CCSS 或 CCMX 文件。")
            }
        }

        let enumeration = try await I1DisplayCommand().run(executableURL: executableURL,
                                                          arguments: ["-?"], timeout: 15)
        try Task.checkCancellation()
        let port = try instrumentPort(in: enumeration.text)
        var arguments = ["-v", "-c", String(port), mode == .emission ? "-e" : "-a", "-x", "-O"]
        if mode == .emission { arguments += ["-yn", "-T"] }
        if let correctionURL { arguments += ["-X", correctionURL.path] }
        let result = try await I1DisplayCommand().run(executableURL: executableURL,
                                                     arguments: arguments, timeout: 45)
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw I1DisplayError.message("ArgyllCMS 测量失败（\(result.status)）。\n\(diagnostic(result.text))")
        }
        let version = matches("(?mi)^Measure spot values, Version\\s+([^\\s\\r\\n]+)", in: enumeration.text).first?[1] ?? ""
        return try parse(result.text, mode: mode,
                         correctionName: mode == .ambient ? "仪器环境光扩散罩校正"
                            : correctionURL?.lastPathComponent ?? "通用（无外部校正）", engineVersion: version)
    }

    private static func isExecutable(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
    }

    private static func instrumentPort(in text: String) throws -> Int {
        let rows = matches("(?m)^\\s*(\\d+)\\s*=\\s*'([^'\\r\\n]+)'", in: text)
        let ports = rows.compactMap { row -> Int? in
            let name = row[2].lowercased()
            guard name.hasPrefix("hid"), isI1DisplayName(name) else {
                return nil
            }
            return Int(row[1])
        }
        guard ports.count == 1, let port = ports.first, port > 0 else {
            if ports.count > 1 {
                throw I1DisplayError.message("发现多台 i1 Display。请只连接要测量的一台，然后重试。")
            }
            throw I1DisplayError.message("ArgyllCMS 未发现 i1 Display USB 设备。请检查连接。\n\(diagnostic(text))")
        }
        return port
    }

    private static func isI1DisplayName(_ name: String) -> Bool {
        let compact = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return compact.contains("i1display") || compact.contains("colormunkidisplay")
    }

    private static func parse(_ text: String, mode: I1MeasurementMode,
                              correctionName: String, engineVersion: String) throws -> I1DisplayReading {
        let number = "([+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?)"
        let xyz = matches("(?mi)^\\s*Result\\s+is\\s+XYZ\\s*:\\s*" + number + "\\s+" + number + "\\s+" + number,
                          in: text).last
        guard let xyz, let x = Double(xyz[1]), let y = Double(xyz[2]), let z = Double(xyz[3]),
              [x, y, z].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw I1DisplayError.message("ArgyllCMS 未返回有效 XYZ。\n\(diagnostic(text))")
        }
        let product = metadata("Product Name", in: text)
        guard isI1DisplayName(product) else {
            throw I1DisplayError.message("ArgyllCMS 返回的仪器不是 i1 Display。请检查 USB 连接后重试。")
        }
        let cctFields = matches("(?mi)(?:^|,)[ \\t]*CCT\\s*=\\s*" + number + "\\s*K(?:[^\\r\\n]*?Duv\\s*=?\\s*" + number + ")?",
                                in: text).last
        let temperature = cctFields.flatMap { Double($0[1]) }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let duv = cctFields.flatMap { $0.count > 2 ? Double($0[2]) : nil }.flatMap { $0.isFinite ? $0 : nil }
        let sum = x + y + z
        return I1DisplayReading(capturedAt: Date(), mode: mode,
                                product: product,
                                serial: metadata("Serial Number", in: text),
                                firmware: metadata("Firmware Version", in: text),
                                x: x, y: y, z: z,
                                cct: sum.isFinite && sum > 0 ? temperature : nil,
                                duv: sum.isFinite && sum > 0 ? duv : nil,
                                correctionName: correctionName, engineVersion: engineVersion)
    }

    private static func metadata(_ key: String, in text: String) -> String {
        matches("(?mi)^\\s*" + NSRegularExpression.escapedPattern(for: key) + "\\s*:\\s*([^\\r\\n]*)", in: text)
            .last?[1].trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
        }
    }

    private static func diagnostic(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(2000))
    }
}

private enum I1DisplayError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(text): return text
        }
    }
}

private struct I1DisplayCommandResult {
    let text: String
    let status: Int32
}

private final class I1DisplayCommand: @unchecked Sendable {
    private enum Interruption { case cancellation, timeout }
    private let lock = NSLock()
    private var process: Process?
    private var interruption: Interruption?

    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) async throws -> I1DisplayCommandResult {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try self.execute(executableURL: executableURL,
                                                                       arguments: arguments, timeout: timeout) })
                }
            }
        } onCancel: {
            self.interrupt(.cancellation)
        }
    }

    private func execute(executableURL: URL, arguments: [String], timeout: TimeInterval) throws -> I1DisplayCommandResult {
        let child = Process()
        let output = Pipe()
        child.executableURL = executableURL
        child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["LC_NUMERIC"] = "C"
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = output

        lock.lock()
        guard interruption == nil else {
            lock.unlock()
            throw CancellationError()
        }
        process = child
        do {
            try child.run()
        } catch {
            process = nil
            lock.unlock()
            throw I1DisplayError.message("无法启动 ArgyllCMS。\(error.localizedDescription)")
        }
        lock.unlock()
        try? output.fileHandleForWriting.close()
        let deadline = DispatchWorkItem { [weak self] in self?.interrupt(.timeout) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        deadline.cancel()
        try? output.fileHandleForReading.close()

        lock.lock()
        process = nil
        let reason = interruption
        lock.unlock()
        switch reason {
        case .cancellation: throw CancellationError()
        case .timeout: throw I1DisplayError.message("ArgyllCMS 测量超时。请检查探头位置和扩散罩后重试。")
        case nil: break
        }
        return I1DisplayCommandResult(text: String(decoding: data, as: UTF8.self), status: child.terminationStatus)
    }

    private func interrupt(_ reason: Interruption) {
        lock.lock()
        if interruption == nil { interruption = reason }
        let child = process
        if let child, child.isRunning { kill(child.processIdentifier, SIGTERM) }
        lock.unlock()
        guard let child else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.process === child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
}
