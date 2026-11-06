import Foundation

struct WavelengthCorrection: Sendable {
    let startNM: Int
    let endNM: Int
    private let slope: Double
    private let intercept: Double

    static func forDevice(_ device: Device) -> Self? {
        local?.correction(for: device)
    }

    func wavelength(for rawNM: Int) -> Double {
        slope * Double(rawNM) + intercept
    }

    private struct Anchor: Decodable, Sendable {
        let rawNM: Double
        let referenceNM: Double
    }

    private struct Configuration: Decodable, Sendable {
        let model: String
        let serial: String
        let firmware: String
        let anchors: [Anchor]
    }

    private struct LocalProfile: Sendable {
        let configuration: Configuration
        let fit: WavelengthCorrection

        func correction(for device: Device) -> WavelengthCorrection? {
            guard device.model == configuration.model, device.serial == configuration.serial,
                  device.firmware == configuration.firmware,
                  device.startNM <= fit.startNM, device.endNM >= fit.endNM else { return nil }
            return fit
        }
    }

    // The spectrum can refresh several times a second. Read the optional profile once per launch.
    private static let local: LocalProfile? = {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let file = support.appendingPathComponent("Flameeye", isDirectory: true)
            .appendingPathComponent("WavelengthCorrection.json")
        return loadProfile(at: file)
    }()

    private static func loadProfile(at file: URL) -> LocalProfile? {
        guard let data = try? Data(contentsOf: file),
              let config = try? JSONDecoder().decode(Configuration.self, from: data),
              !config.model.isEmpty, !config.serial.isEmpty, !config.firmware.isEmpty,
              let fit = WavelengthCorrection(anchors: config.anchors) else { return nil }
        return LocalProfile(configuration: config, fit: fit)
    }

    private init?(anchors: [Anchor]) {
        guard anchors.count >= 2,
              anchors.allSatisfy({ $0.rawNM.isFinite && $0.rawNM > 0 && $0.referenceNM.isFinite && $0.referenceNM > 0 }),
              zip(anchors, anchors.dropFirst()).allSatisfy({ pair in
                  pair.0.rawNM < pair.1.rawNM && pair.0.referenceNM < pair.1.referenceNM
              }),
              let first = anchors.first, let last = anchors.last,
              let start = Int(exactly: first.rawNM.rounded(.down)),
              let end = Int(exactly: last.rawNM.rounded(.up)) else { return nil }

        let count = Double(anchors.count)
        let meanRaw = anchors.reduce(0.0) { $0 + $1.rawNM } / count
        let meanReference = anchors.reduce(0.0) { $0 + $1.referenceNM } / count
        let covariance = anchors.reduce(0.0) { $0 + ($1.rawNM - meanRaw) * ($1.referenceNM - meanReference) }
        let variance = anchors.reduce(0.0) { $0 + ($1.rawNM - meanRaw) * ($1.rawNM - meanRaw) }
        let slope = covariance / variance
        let intercept = meanReference - slope * meanRaw
        let correctedStart = slope * Double(start) + intercept
        let correctedEnd = slope * Double(end) + intercept
        guard slope.isFinite, slope > 0, intercept.isFinite,
              correctedStart.isFinite, correctedStart > 0,
              correctedEnd.isFinite, correctedEnd > correctedStart else { return nil }

        startNM = start
        endNM = end
        self.slope = slope
        self.intercept = intercept
    }
}
