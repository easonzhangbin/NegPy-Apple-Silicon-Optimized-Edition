import Darwin
import Foundation

enum DeviceProtocol: Equatable, Sendable {
    case pjg
    case legacyP32

    var measurementCommand: UInt8 {
        switch self {
        case .pjg: return 0x32
        case .legacyP32: return 0x02
        }
    }

    func supports(model: String) -> Bool {
        switch self {
        case .pjg: return ["P42B4W07838CBPD", "P32B4W07834CTPD"].contains(model)
        case .legacyP32: return model == "P32A8R10034NTAD"
        }
    }
}

struct Device: Identifiable, Equatable, Sendable {
    let port: String
    let model: String
    let firmware: String
    let serial: String
    let startNM: Int
    let endNM: Int
    let protocolProfile: DeviceProtocol
    let baud: speed_t

    var id: String { "\(model)-\(serial)" }
    var supportsHardwareCalibration: Bool { protocolProfile == .pjg }
}

enum Exposure: Sendable {
    case normal
    case overexposed
    case underexposed
    case unknown(UInt8)

    init(_ status: UInt8) {
        switch status {
        case 0: self = .normal
        case 1: self = .overexposed
        case 2: self = .underexposed
        default: self = .unknown(status)
        }
    }

    var label: String {
        switch self {
        case .normal: return "曝光正常"
        case .overexposed: return "过曝"
        case .underexposed: return "欠曝"
        case let .unknown(status): return "未知曝光状态（\(status)）"
        }
    }
}

struct SpectrumPoint: Identifiable, Sendable {
    let wavelength: Int
    let value: Double
    var id: Int { wavelength }
}

struct Measurement: Sendable {
    let device: Device
    let capturedAt: Date
    let exposure: Exposure
    let exposureUS: UInt32
    let exposureRevision: UInt64?
    let spectralExponent: Int16
    let points: [SpectrumPoint]
    let metrics: [String: Double]
    let p32Metrics: [String: Float]?

    var csv: String {
        "wavelength_nm,spectral_value\r\n"
            + points.map { "\($0.wavelength),\($0.value)\r\n" }.joined()
    }
}

struct P32StreamCadence {
    private(set) var exposureRevision: UInt64 = 0
    private var latestExposure: (status: UInt8, time: UInt32)?
    private var lastUpdate: (time: DispatchTime, status: UInt8)?

    mutating func shouldPublish(status: UInt8, exposureUS: UInt32, receivedAt: DispatchTime) -> Bool {
        if let latestExposure, latestExposure.status != status || latestExposure.time != exposureUS {
            exposureRevision &+= 1
        }
        latestExposure = (status, exposureUS)

        if let lastUpdate {
            // Refresh the spectrum at up to 8 Hz; show new exposure warnings sooner.
            let interval = DispatchTimeInterval.milliseconds(lastUpdate.status == status ? 125 : 40)
            guard receivedAt >= lastUpdate.time + interval else { return false }
        }
        lastUpdate = (receivedAt, status)
        return true
    }
}

enum Spectrometer {
    private static let queue = DispatchQueue(label: "local.flameeye.serial", qos: .userInitiated)

    static func ports() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return entries.filter { entry in
            let name = entry.lowercased()
            return name.hasPrefix("cu.usbmodem")
                || name.hasPrefix("cu.usbserial")
                || name.hasPrefix("cu.wchusbserial")
        }
        .sorted()
        .map { "/dev/" + $0 }
    }

    static func connect(port: String) async throws -> Device {
        try await perform {
            guard ports().contains(port) else { throw SerialError.portMissing }
            do {
                let serial = try SerialPort(path: port, baud: 115200)
                return try readDevice(on: serial, port: port, profile: .pjg, baud: 115200)
            } catch SerialError.timeout(0x08) {
                let baud: speed_t = 921600
                let serial = try SerialPort(path: port, baud: baud)
                try serial.send(0x04, payload: [], deadline: .now() + .seconds(1))
                Thread.sleep(forTimeInterval: 0.1)
                try serial.discardInput()
                return try readDevice(on: serial, port: port, profile: .legacyP32, baud: baud)
            }
        }
    }

    private static func readDevice(on serial: SerialPort, port: String,
                                   profile: DeviceProtocol, baud: speed_t) throws -> Device {
        // The legacy client queries the range before it reads the model identifier.
        let legacyRange = profile == .legacyP32 ? try serial.request(0x0F) : nil
        let info = try serial.request(0x08, payload: [0x18])
        guard info.count == 24,
              let identifier = String(bytes: info, encoding: .ascii) else {
            throw SerialError.invalidResponse("设备信息")
        }
        let fields = identifier.split(separator: "-").map(String.init)
        guard fields.count == 3 else { throw SerialError.invalidResponse("设备型号") }
        guard profile.supports(model: fields[0]) else { throw SerialError.unsupportedModel(fields[0]) }

        let range = try legacyRange ?? serial.request(0x0F)
        guard range.count == 4 else { throw SerialError.invalidResponse("波长范围") }
        let first = Int(littleEndian16(range, at: 0))
        let last = Int(littleEndian16(range, at: 2))
        guard first > 0, last > first, last - first < 4096 else {
            throw SerialError.invalidResponse("波长范围")
        }

        return Device(port: port, model: fields[0], firmware: fields[1], serial: fields[2],
                      startNM: first, endNM: last, protocolProfile: profile, baud: baud)
    }

    enum CalibrationChange: Sendable {
        case write(SpectralCalibration)
        case restoreFactory

        var title: String {
            switch self {
            case .write: return "写入光谱校准"
            case .restoreFactory: return "恢复出厂光谱曲线"
            }
        }
    }

    static func changeCalibration(_ change: CalibrationChange, device: Device) async throws {
        try await perform {
            guard device.supportsHardwareCalibration else { throw CalibrationError.unsupportedDevice }
            let serial = try SerialPort(path: device.port, baud: device.baud)
            guard try readDevice(on: serial, port: device.port, profile: device.protocolProfile, baud: device.baud) == device else {
                throw CalibrationError.deviceChanged
            }

            let command: UInt8
            switch change {
            case let .write(calibration):
                guard calibration.points.map(\.wavelength) == Array(device.startNM...device.endNM) else {
                    throw CalibrationError.rangeMismatch
                }
                let bytes = calibration.points.flatMap { point in
                    withUnsafeBytes(of: point.ratio.bitPattern.littleEndian) { Array($0) }
                }
                let deadline = DispatchTime.now() + .seconds(6)
                try serial.send(0x23, payload: [0x04], deadline: deadline)
                // The protocol splits the byte stream at 999-byte frames, even inside a Float32.
                let maximumPayload = 999 - 9
                for offset in stride(from: 0, to: bytes.count, by: maximumPayload) {
                    let end = min(offset + maximumPayload, bytes.count)
                    try serial.send(0x23, payload: Array(bytes[offset..<end]), deadline: deadline)
                }
                // Match the official client's pause before asking the firmware to apply the curve.
                Thread.sleep(forTimeInterval: 0.1)
                command = 0x27
            case .restoreFactory:
                command = 0x25
            }

            let response: [UInt8]
            do {
                response = try serial.request(command, deadline: .now() + .seconds(8))
            } catch {
                throw CalibrationError.unconfirmed(change.title)
            }
            switch response {
            case [0x00]: return
            case [0xFF]: throw CalibrationError.rejected(change.title)
            default: throw CalibrationError.unconfirmed(change.title)
            }
        }
    }

    static func measure(device: Device, settleExposure: Bool = false) async throws -> Measurement {
        try await perform {
            let serial = try SerialPort(path: device.port, baud: device.baud)
            let deadline = DispatchTime.now() + .seconds(8)
            func capture() throws -> Measurement {
                let responseCommand: UInt8? = device.protocolProfile == .legacyP32 ? 0x03 : nil
                let payload = try serial.request(device.protocolProfile.measurementCommand,
                                                 responseCommand: responseCommand, deadline: deadline)
                return try decodeMeasurement(payload, device: device)
            }

            var measurement = try capture()
            guard settleExposure else { return measurement }
            switch measurement.exposure {
            case .normal, .unknown: return measurement
            case .underexposed, .overexposed: break
            }

            if device.protocolProfile == .legacyP32 {
                // The legacy firmware adjusts exposure while its stream is active.
                defer { try? serial.send(0x04, payload: [], deadline: .now() + .milliseconds(300)) }
                try serial.send(0x03, payload: [], deadline: deadline)
                do {
                    for _ in 0..<5 {
                        let payload = try serial.readResponse(0x03, deadline: deadline)
                        measurement = try decodeMeasurement(payload, device: device)
                        if case .normal = measurement.exposure { break }
                    }
                } catch SerialError.timeout {
                    return measurement
                }
                return measurement
            }

            // An automatic exposure change applies to subsequent frames.
            do {
                let mode = try serial.request(0x0B, deadline: min(deadline, .now() + .seconds(1)))
                guard mode == [0x01] else { return measurement }
                for _ in 0..<4 {
                    measurement = try capture()
                    if case .normal = measurement.exposure { break }
                }
            } catch SerialError.timeout {
                return measurement
            }
            return measurement
        }
    }

    static func streamP32(device: Device) -> AsyncThrowingStream<Measurement, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            queue.async {
                do {
                    let serial = try SerialPort(path: device.port, baud: device.baud)
                    try serial.send(0x04, payload: [], deadline: .now() + .milliseconds(300))
                    Thread.sleep(forTimeInterval: 0.1)
                    try serial.discardInput()
                    defer { try? serial.send(0x04, payload: [], deadline: .now() + .milliseconds(300)) }
                    try serial.send(0x03, payload: [], deadline: .now() + .seconds(1))

                    var cadence = P32StreamCadence()
                    while true {
                        let payload = try serial.readResponse(0x03, deadline: .now() + .seconds(8))
                        guard payload.count >= 5 else { throw SerialError.invalidResponse("曝光状态") }
                        guard cadence.shouldPublish(status: payload[0], exposureUS: littleEndian32(payload, at: 1),
                                                    receivedAt: .now()) else { continue }
                        let frame = try decodeMeasurement(payload, device: device, exposureRevision: cadence.exposureRevision)
                        if case .terminated = continuation.yield(frame) { break }
                    }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                continuation.finish()
            }
        }
    }

    static func measureFilmBase(device: Device, exposureUS: UInt32?) async throws -> [Measurement] {
        guard device.protocolProfile == .legacyP32 else { throw FilmBaseCaptureError.unsupportedDevice }
        guard exposureUS != 0 else { throw SerialError.invalidResponse("曝光时间") }

        return try await perform {
            let serial = try SerialPort(path: device.port, baud: device.baud)
            try stopFilmBaseStream(on: serial)
            guard try readDevice(on: serial, port: device.port, profile: .legacyP32, baud: device.baud) == device else {
                throw FilmBaseCaptureError.deviceChanged
            }

            guard let exposureUS else { return try captureFilmBase(on: serial, device: device, exposureUS: nil) }
            let originalExposure = try serial.request(0x0D)
            guard originalExposure.count == 4, littleEndian32(originalExposure, at: 0) > 0 else {
                throw SerialError.invalidResponse("原曝光时间")
            }

            let capture = Result {
                try setFilmBaseExposureMode(0x0A, on: serial)
                let payload = withUnsafeBytes(of: exposureUS.littleEndian) { Array($0) }
                try setFilmBaseExposure(payload, on: serial)
                return try captureFilmBase(on: serial, device: device, exposureUS: exposureUS)
            }

            // The legacy protocol has no mode getter. A fixed capture starts from the
            // app's automatic mode. Attempt to restore it even if restoring the time fails.
            let restoreTime = Result { try setFilmBaseExposure(originalExposure, on: serial) }
            do {
                try setFilmBaseExposureMode(0x0B, on: serial)
                try restoreTime.get()
            } catch {
                throw FilmBaseCaptureError.restoreFailed(error.localizedDescription)
            }
            return try capture.get()
        }
    }

    private static func setFilmBaseExposureMode(_ command: UInt8, on serial: SerialPort) throws {
        guard try serial.request(command) == [0x00] else {
            throw SerialError.invalidResponse("曝光模式")
        }
    }

    private static func setFilmBaseExposure(_ payload: [UInt8], on serial: SerialPort) throws {
        try serial.send(0x0C, payload: payload, deadline: .now() + .seconds(1))
        Thread.sleep(forTimeInterval: 0.1)
        guard try serial.request(0x0D) == payload else {
            throw SerialError.invalidResponse("曝光时间")
        }
    }

    private static func stopFilmBaseStream(on serial: SerialPort) throws {
        try serial.send(0x04, payload: [], deadline: .now() + .milliseconds(300))
        Thread.sleep(forTimeInterval: 0.1)
        try serial.discardInput()
    }

    private static func captureFilmBase(on serial: SerialPort, device: Device,
                                        exposureUS: UInt32?) throws -> [Measurement] {
        let result = Result {
            try serial.send(0x03, payload: [], deadline: .now() + .seconds(1))
            let deadline = DispatchTime.now() + .seconds(60)
            var frames: [Measurement] = []
            var selectedExposure = exposureUS
            var warmup = 3

            while DispatchTime.now() < deadline {
                let payload = try serial.readResponse(0x03, deadline: min(deadline, .now() + .seconds(8)))
                let frame = try decodeMeasurement(payload, device: device)
                guard frame.exposureUS > 0, exposureUS == nil || frame.exposureUS == exposureUS else { continue }
                if frame.exposureUS != selectedExposure {
                    selectedExposure = frame.exposureUS
                    frames.removeAll(keepingCapacity: true)
                    warmup = 3
                }

                // The frame can report the new exposure before its spectrum uses it.
                if warmup > 0 {
                    warmup -= 1
                    continue
                }

                switch frame.exposure {
                case .normal: break
                case .underexposed where exposureUS != nil: break
                default:
                    frames.removeAll(keepingCapacity: true)
                    continue
                }
                frames.append(frame)
                if frames.count == 7 { return frames }
            }
            throw FilmBaseCaptureError.insufficientFrames
        }
        try stopFilmBaseStream(on: serial)
        return try result.get()
    }

    private static func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }

    private static let metricNames = [
        "X", "Y", "Z", "x", "y", "u", "v", "u′", "v′", "CCT", "Nit",
        "r_ratio", "g_ratio", "b_ratio", "DUV", "Ra",
        "R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8", "R9", "R10",
        "R11", "R12", "R13", "R14", "R15", "Lp", "HW", "Ld", "purity",
        "SP", "SDCM", "k", "lux", "Ee", "fc", "CQS", "GAI_EES", "GAI_BB_8",
        "GAI_BB_15", "EML", "M_EDI",
    ]

    // The older Windows client mislabels some fields. This order follows the P32 wire frame.
    private static let legacyMetricNames = [
        "X", "Y", "Z", "x", "y", "u", "v", "u′", "v′", "CCT",
        "r_ratio", "g_ratio", "b_ratio", "DUV", "Ra",
        "R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8", "R9", "R10",
        "R11", "R12", "R13", "R14", "Lp", "HW", "Ld", "purity", "SP", "SDCM", "k", "lux",
    ]

    private static func decodeMeasurement(_ payload: [UInt8], device: Device,
                                          exposureRevision: UInt64? = nil) throws -> Measurement {
        let sampleCount = device.endNM - device.startNM + 1
        let names: [String]
        switch device.protocolProfile {
        case .pjg:
            names = metricNames
        case .legacyP32:
            names = legacyMetricNames
        }
        let scaleOffset = 5 + 4 * names.count
        let sampleOffset = scaleOffset + 2
        guard payload.count == sampleOffset + 2 * sampleCount else {
            throw SerialError.invalidResponse("光谱长度")
        }
        let exponent = Int16(bitPattern: littleEndian16(payload, at: scaleOffset))
        let scale = pow(10.0, -Double(exponent))
        guard scale.isFinite, scale > 0, (scale * Double(UInt16.max)).isFinite else {
            throw SerialError.invalidResponse("光谱系数")
        }

        var metrics: [String: Double] = [:]
        var p32Metrics: [String: Float]? = device.protocolProfile == .legacyP32 ? [:] : nil
        for (index, name) in names.enumerated() {
            let raw = Float(bitPattern: littleEndian32(payload, at: 5 + 4 * index))
            p32Metrics?[name] = raw
            if raw.isFinite, device.protocolProfile != .legacyP32 || name != "lux" || raw >= 0 {
                metrics[name] = Double(raw)
            }
        }
        let points = (0..<sampleCount).map { index in
            let raw = littleEndian16(payload, at: sampleOffset + 2 * index)
            return SpectrumPoint(wavelength: device.startNM + index, value: Double(raw) * scale)
        }

        return Measurement(device: device, capturedAt: Date(), exposure: Exposure(payload[0]),
                           exposureUS: littleEndian32(payload, at: 1), exposureRevision: exposureRevision,
                           spectralExponent: exponent,
                           points: points, metrics: metrics, p32Metrics: p32Metrics)
    }

    private static func littleEndian16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func littleEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(littleEndian16(bytes, at: offset)) | (UInt32(littleEndian16(bytes, at: offset + 2)) << 16)
    }
}

enum CalibrationError: LocalizedError {
    case unsupportedDevice
    case deviceChanged
    case rangeMismatch
    case rejected(String)
    case unconfirmed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice: return "此设备不支持通过本应用写入或恢复光谱校准。"
        case .deviceChanged: return "设备连接已变化。请重新连接并核对序列号。"
        case .rangeMismatch: return "CSV 的波长范围与设备不符。"
        case let .rejected(action): return "设备报告\(action)失败。"
        case let .unconfirmed(action):
            return "未收到\(action)的确认，设备状态未知。请重新连接并复测，再决定是否重试。"
        }
    }
}

private enum FilmBaseCaptureError: LocalizedError {
    case unsupportedDevice
    case deviceChanged
    case insufficientFrames
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice: return "片基透过率采集目前仅支持旧款 P32。"
        case .deviceChanged: return "设备连接已变化。请重新连接并核对序列号。"
        case .insufficientFrames: return "未采到七帧符合条件且曝光时间一致的光谱。请检查灯光和探头摆位。"
        case let .restoreFailed(reason): return "未能确认 P32 已恢复原曝光设置。\(reason)"
        }
    }
}

private enum SerialError: LocalizedError {
    case portMissing
    case system(String, Int32)
    case timeout(UInt8)
    case invalidResponse(String)
    case unsupportedModel(String)

    var errorDescription: String? {
        switch self {
        case .portMissing:
            return "找不到所选 USB 串口。请检查连接并刷新串口列表。"
        case let .system(action, code):
            switch code {
            case EBUSY: return "串口正在使用。请关闭其他测量软件后重试。"
            case ENOENT, ENXIO, ENODEV, EIO: return "USB 串口已断开或不可用。请检查连接后重试。"
            default: return "\(action)失败（\(String(cString: strerror(code)))）。"
            }
        case let .timeout(command):
            return "设备响应超时（\(String(format: "0x%02X", Int(command)))）。请确认选择的是火眼设备。"
        case let .invalidResponse(field):
            return "设备返回的\(field)与所用协议不符。"
        case let .unsupportedModel(model):
            return "此版本暂不支持设备 \(model)。"
        }
    }
}

private final class SerialPort {
    private let descriptor: Int32
    private var decoder = ResponseDecoder()

    init(path: String, baud: speed_t) throws {
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SerialError.system("打开串口", errno) }

        do {
            // Darwin's TIOCEXCL is a C macro that Swift cannot import.
            let exclusiveRequest: UInt = 0x2000740D
            guard ioctl(fd, exclusiveRequest) >= 0 else {
                throw SerialError.system("独占串口", errno)
            }
            var settings = termios()
            guard tcgetattr(fd, &settings) == 0 else {
                throw SerialError.system("读取串口设置", errno)
            }
            cfmakeraw(&settings)
            settings.c_cflag &= ~tcflag_t(CSIZE | PARENB | CSTOPB | CRTSCTS | CDTR_IFLOW | CDSR_OFLOW | CCAR_OFLOW)
            settings.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
            settings.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
            guard cfsetspeed(&settings, speed_t(B115200)) == 0,
                  tcsetattr(fd, TCSANOW, &settings) == 0 else {
                throw SerialError.system("配置串口", errno)
            }
            if baud != speed_t(B115200) {
                // Darwin's IOSSIOSPEED takes a pointer to a native speed_t.
                var requestedBaud = baud
                guard ioctl(fd, 0x80085402, &requestedBaud) == 0 else {
                    throw SerialError.system("设置串口波特率", errno)
                }
            }
            if baud == 921600 {
                try CH340Baud.configure921600(port: path)
            }
            guard tcflush(fd, TCIFLUSH) == 0 else {
                throw SerialError.system("清空串口输入", errno)
            }
        } catch {
            close(fd)
            throw error
        }

        descriptor = fd
    }

    deinit { close(descriptor) }

    func discardInput() throws {
        guard tcflush(descriptor, TCIFLUSH) == 0 else {
            throw SerialError.system("清空串口输入", errno)
        }
        decoder = ResponseDecoder()
    }

    func send(_ command: UInt8, payload: [UInt8], deadline: DispatchTime) throws {
        let length = 9 + payload.count
        var packet: [UInt8] = [0xCC, 0x01, UInt8(truncatingIfNeeded: length),
                               UInt8(truncatingIfNeeded: length >> 8), UInt8(length >> 16), command]
        packet.append(contentsOf: payload)
        packet.append(packet.reduce(0, &+))
        packet.append(contentsOf: [0x0D, 0x0A])

        var offset = 0
        try packet.withUnsafeBytes { bytes in
            while offset < bytes.count {
                try wait(for: POLLOUT, until: deadline.uptimeNanoseconds, command: command)
                let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written > 0 { offset += written }
                else if written < 0, errno != EAGAIN, errno != EINTR {
                    throw SerialError.system("发送串口命令", errno)
                }
            }
        }
    }

    func request(_ command: UInt8, payload: [UInt8] = [], responseCommand: UInt8? = nil,
                 deadline: DispatchTime = .now() + .seconds(2)) throws -> [UInt8] {
        decoder = ResponseDecoder()
        try send(command, payload: payload, deadline: deadline)
        return try readResponse(responseCommand ?? command, deadline: deadline)
    }

    func readResponse(_ command: UInt8, deadline: DispatchTime) throws -> [UInt8] {
        if let response = decoder.receive([], command: command) { return response }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try wait(for: POLLIN, until: deadline.uptimeNanoseconds, command: command)
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                if let response = decoder.receive(buffer.prefix(count), command: command) {
                    return response
                }
            } else if count == 0 {
                throw SerialError.system("读取设备响应", ENODEV)
            } else if errno != EAGAIN, errno != EINTR {
                throw SerialError.system("读取设备响应", errno)
            }
        }
    }

    private func wait(for events: Int32, until deadline: UInt64, command: UInt8) throws {
        var event = pollfd(fd: descriptor, events: Int16(events), revents: 0)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw SerialError.timeout(command) }
            let milliseconds = Int32((deadline - now + 999_999) / 1_000_000)
            let ready = poll(&event, 1, milliseconds)
            if ready == 0 { throw SerialError.timeout(command) }
            if ready < 0 {
                if errno == EINTR { continue }
                throw SerialError.system("等待设备响应", errno)
            }
            if (event.revents & event.events) != 0 { return }
            if (event.revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 {
                throw SerialError.system("等待设备响应", ENODEV)
            }
        }
    }
}

private struct ResponseDecoder {
    private var buffer: [UInt8] = []

    mutating func receive(_ chunk: ArraySlice<UInt8>, command: UInt8) -> [UInt8]? {
        buffer.append(contentsOf: chunk)
        var start = 0

        while start + 1 < buffer.count {
            guard buffer[start] == 0xCC, buffer[start + 1] == 0x81 else {
                start += 1
                continue
            }
            guard start + 6 <= buffer.count else { break }
            let length = Int(buffer[start + 2]) | (Int(buffer[start + 3]) << 8) | (Int(buffer[start + 4]) << 16)
            guard (9...16384).contains(length) else {
                start += 1
                continue
            }
            let end = start + length
            guard end <= buffer.count else { break }
            guard buffer[end - 2] == 0x0D, buffer[end - 1] == 0x0A,
                  buffer[start..<(end - 3)].reduce(0, &+) == buffer[end - 3] else {
                start += 1
                continue
            }
            if buffer[start + 5] == command {
                let payload = Array(buffer[(start + 6)..<(end - 3)])
                buffer.removeFirst(end)
                return payload
            }
            start = end
        }

        buffer.removeFirst(start)
        return nil
    }
}
