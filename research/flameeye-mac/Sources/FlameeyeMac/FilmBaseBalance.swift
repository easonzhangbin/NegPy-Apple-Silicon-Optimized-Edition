import Foundation

enum RGBLightChannel: String, CaseIterable, Codable, Identifiable, Sendable {
    case red, green, blue

    var id: Self { self }

    var index: Int {
        switch self {
        case .red: 0
        case .green: 1
        case .blue: 2
        }
    }

    var title: String {
        switch self {
        case .red: "红"
        case .green: "绿"
        case .blue: "蓝"
        }
    }

    var band: ClosedRange<Int> {
        switch self {
        case .red: 595...720
        case .green: 490...650
        case .blue: 425...540
        }
    }

    var peakBand: ClosedRange<Int> {
        switch self {
        case .red: 595...720
        case .green: 495...594
        case .blue: 405...494
        }
    }
}

struct FilmBaseSpectrum: Sendable {
    let area: Double
    let exposureUS: UInt32
    let deviceID: String

    init(channel: RGBLightChannel, frames: [Measurement], requireNormal: Bool) throws {
        guard let first = frames.first, frames.count >= 5,
              first.device.protocolProfile == .legacyP32,
              (first.device.startNM...first.device.endNM).contains(channel.band.lowerBound),
              (first.device.startNM...first.device.endNM).contains(channel.band.upperBound) else {
            throw FilmBaseError.message("需要至少 5 帧覆盖所选波段的 P32 光谱。")
        }
        let areas = try frames.map { frame in
            guard frame.device == first.device, frame.exposureUS == first.exposureUS else {
                throw FilmBaseError.message("采集期间仪器或曝光发生变化，请重测这一组。")
            }
            switch frame.exposure {
            case .normal: break
            case .underexposed where !requireNormal: break
            default: throw FilmBaseError.message("\(channel.title)光曝光不合适，请重测。")
            }
            let visible = frame.points.filter { (380...780).contains($0.wavelength) }
            guard let peak = visible.max(by: { $0.value < $1.value }), peak.value > 0,
                  channel.peakBand.contains(peak.wavelength) else {
                throw FilmBaseError.message("实测主峰与所选\(channel.title)光不符，或信号太弱。请检查灯档和片基覆盖。")
            }
            let values = visible.filter { channel.band.contains($0.wavelength) }.map(\.value)
            guard values.count == channel.band.count, let low = values.first, let high = values.last else {
                throw FilmBaseError.message("光谱缺少所选波段的采样点。")
            }
            let area = values.reduce(0, +) - (low + high) / 2
            guard area.isFinite, area > 0 else { throw FilmBaseError.message("波段积分无效，请重测。") }
            return area
        }.sorted()
        area = (areas[(areas.count - 1) / 2] + areas[areas.count / 2]) / 2
        exposureUS = first.exposureUS
        deviceID = first.device.id
    }
}

struct FilmBaseLiveReading: Sendable {
    // Nonoverlapping visible bands separated near the valleys in the measured CuteNew spectra.
    static let bands = [625...720, 520...624, 425...519]

    let shares: [Double]
    let total: Double
    let deviceID: String
    let capturedAt: Date
    let exposureUS: UInt32

    init?(measurement: Measurement) {
        guard measurement.device.protocolProfile == .legacyP32,
              case .normal = measurement.exposure,
              measurement.exposureUS > 0 else { return nil }
        var areas: [Double] = []
        for band in Self.bands {
            let points = measurement.points.filter { band.contains($0.wavelength) }
            guard points.count == band.count,
                  points.allSatisfy({ $0.value.isFinite && $0.value >= 0 }) else { return nil }
            areas.append(points.reduce(0) { $0 + $1.value })
        }
        let total = areas.reduce(0, +)
        guard total.isFinite, total > 0 else { return nil }
        self.total = total
        shares = areas.map { $0 / total }
        deviceID = measurement.device.id
        capturedAt = measurement.capturedAt
        exposureUS = measurement.exposureUS
    }

    init?(readings: [FilmBaseLiveReading]) {
        guard let latest = readings.last,
              readings.allSatisfy({ $0.deviceID == latest.deviceID && $0.exposureUS == latest.exposureUS }) else {
            return nil
        }
        let medians = Self.bands.indices.map { index in
            let areas = readings.map { $0.shares[index] * $0.total }.sorted()
            return (areas[(areas.count - 1) / 2] + areas[areas.count / 2]) / 2
        }
        let total = medians.reduce(0, +)
        guard total.isFinite, total > 0 else { return nil }
        self.total = total
        shares = medians.map { $0 / total }
        deviceID = latest.deviceID
        capturedAt = latest.capturedAt
        exposureUS = latest.exposureUS
    }
}

struct FilmBaseLiveReference: Codable, Sendable {
    let shares: [Double]
    let total: Double
    let deviceID: String
    let capturedAt: Date

    init(reading: FilmBaseLiveReading) {
        shares = reading.shares
        total = reading.total
        deviceID = reading.deviceID
        capturedAt = reading.capturedAt
    }
}

struct FilmBaseSavedBalance: Identifiable, Codable, Sendable {
    let id: UUID
    let name: String
    let reference: FilmBaseLiveReference
    let tolerancePercent: Int
    let negPy: FilmBaseNegPyVerification?

    init?(name: String, reference: FilmBaseLiveReference, tolerancePercent: Int,
          negPy: FilmBaseNegPyVerification? = nil) {
        id = UUID()
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reference = reference
        self.tolerancePercent = tolerancePercent
        self.negPy = negPy
        guard isValid else { return nil }
    }

    var isValid: Bool {
        !name.isEmpty && name.count <= 80 &&
            name.rangeOfCharacter(from: .controlCharacters) == nil &&
            !reference.deviceID.isEmpty && reference.capturedAt.timeIntervalSinceReferenceDate.isFinite &&
            reference.shares.count == RGBLightChannel.allCases.count &&
            reference.shares.allSatisfy { $0.isFinite && (0.001...1).contains($0) } &&
            abs(reference.shares.reduce(0, +) - 1) < 0.000001 &&
            reference.total.isFinite && reference.total > 0 &&
            [2, 5, 10].contains(tolerancePercent)
    }
}

struct FilmBaseLightTarget: Codable, Sendable {
    private let baseShares: [Double]
    let deviceID: String
    let capturedAt: Date
    let responsePercent: [Double]

    init?(reading: FilmBaseLiveReading, responsePercent: [Double]) {
        baseShares = reading.shares
        deviceID = reading.deviceID
        capturedAt = reading.capturedAt
        self.responsePercent = responsePercent
        guard shares != nil else { return nil }
    }

    var shares: [Double]? {
        let count = RGBLightChannel.allCases.count
        guard !deviceID.isEmpty, capturedAt.timeIntervalSinceReferenceDate.isFinite,
              baseShares.count == count, responsePercent.count == count,
              baseShares.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1 }),
              abs(baseShares.reduce(0, +) - 1) < 0.000001,
              responsePercent.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 100 }) else { return nil }

        // Inverse response estimates the relative light needed from the recorded baseline.
        let corrected = zip(baseShares, responsePercent).map { $0 / $1 }
        let total = corrected.reduce(0, +)
        guard total.isFinite, total > 0 else { return nil }
        let normalized = corrected.map { $0 / total }
        guard normalized.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1 }) else { return nil }
        return normalized
    }
}

enum FilmBaseError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(text): text
        }
    }
}
