import AppKit
import UniformTypeIdentifiers

// Keep prior report fields when re-encoding saved references.
struct FilmBaseLegacyNegPyReport: Codable, Sendable {
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

    struct SampleRegion: Codable, Sendable {
        // Top-left normalized bounds in the unrotated, visible sensor image.
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    let readAt: Date
    let sampleRegion: SampleRegion
    let frames: [Frame]
    let tripletID: String?
    let generatedAt: Date?
    let producerVersion: String?
    let meteringMethod: String?
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
