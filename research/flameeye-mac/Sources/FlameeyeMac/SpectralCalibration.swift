import Foundation

struct SpectralCalibration: Sendable {
    struct Point: Sendable {
        let wavelength: Int
        let ratio: Float
    }

    let points: [Point]

    init(source: URL, reference: URL, startNM: Int, endNM: Int) throws {
        guard startNM > 0, endNM >= startNM else {
            throw ImportError("设备的波长范围无效。")
        }

        let sourceValues = try Self.read(source, startNM: startNM, endNM: endNM)
        let referenceValues = try Self.read(reference, startNM: startNM, endNM: endNM)
        points = try sourceValues.enumerated().map { index, sourceValue in
            let wavelength = startNM + index
            let referenceValue = referenceValues[index]
            // The official client scales the device's efficiency curve by source / reference.
            let ratio = Float(sourceValue / referenceValue)
            guard ratio.isFinite, ratio > 0 else {
                throw ImportError("\(wavelength) nm 的修正系数超出了设备可接受的正数范围。")
            }
            return Point(wavelength: wavelength, ratio: ratio)
        }
    }

    private static func read(_ url: URL, startNM: Int, endNM: Int) throws -> [Double] {
        let name = url.lastPathComponent
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ImportError("无法读取「\(name)」，请确认文件存在且采用 UTF-8 编码。")
        }

        let csv = contents.hasPrefix("\u{FEFF}") ? contents.dropFirst() : contents[...]
        let lines = csv.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let count = endNM - startNM + 1
        var values: [Double] = []
        var firstRow = true

        for (lineIndex, line) in lines.enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let location = "「\(name)」第 \(lineIndex + 1) 行"
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(fieldValue)
            guard fields.count == 2 else {
                throw ImportError("\(location)应包含以逗号分隔的波长和光谱值两列。")
            }

            let isHeader = firstRow && isSpectrumHeader(fields)
            firstRow = false
            if isHeader { continue }

            guard values.count < count else {
                throw ImportError("\(location)超出设备的波长范围 \(startNM)–\(endNM) nm。")
            }
            let expectedWavelength = startNM + values.count
            guard Double(fields[0]) == Double(expectedWavelength) else {
                throw ImportError("\(location)的波长应为 \(expectedWavelength) nm。请按 1 nm 间隔依次排列。")
            }
            guard let value = Double(fields[1]), value.isFinite, value > 0 else {
                throw ImportError("\(location)（\(expectedWavelength) nm）的光谱值必须是有限正数。")
            }
            values.append(value)
        }

        guard values.count == count else {
            throw ImportError("「\(name)」包含 \(values.count) 个光谱点。设备范围 \(startNM)–\(endNM) nm 需要 \(count) 个点。")
        }
        return values
    }

    private static func fieldValue(_ field: Substring) -> String {
        let value = field.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        return value.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
    }

    private static func isSpectrumHeader(_ fields: [String]) -> Bool {
        ["wavelength_nm", "wavelength", "波长(nm)", "波长"].contains(fields[0].lowercased())
            && ["spectral_value", "spectral value", "intensity", "value", "光谱值"].contains(fields[1].lowercased())
    }

    private struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }

        init(_ message: String) { self.message = message }
    }
}
