import Foundation

struct SpectrumTransition {
    private var origin: [Double] = []
    private var target: [Double] = []
    private var startedAt: TimeInterval = 0
    private var duration: TimeInterval = 0
    private var receivedAt: TimeInterval?
    private(set) var ticks: [Date] = [Date()]
    private(set) var generation: UInt64 = 0

    static func normalized(_ values: [Double], peak: Double) -> [Double] {
        guard peak.isFinite, peak > 0 else { return values.map { _ in 0 } }
        return values.map { $0.isFinite ? min(1, max(0, $0 / peak)) : 0 }
    }

    func values(at time: TimeInterval) -> [Double] {
        guard duration > 0, time.isFinite else { return target }
        let progress = min(1, max(0, (time - startedAt) / duration))
        if progress == 0 { return origin }
        if progress == 1 { return target }
        return zip(origin, target).map { $0 + ($1 - $0) * progress }
    }

    mutating func update(
        to values: [Double], at time: TimeInterval, date: Date, animated: Bool
    ) {
        let current = self.values(at: time)
        let interval = receivedAt.map { time - $0 } ?? 0
        let canAnimate = animated && !current.isEmpty && current.count == values.count
            && interval > 0 && current != values
        origin = canAnimate ? current : values
        target = values
        startedAt = time
        duration = canAnimate ? min(0.18, max(1.0 / 30, interval * 0.85)) : 0
        receivedAt = time
        generation &+= 1
        let count = Int(ceil(duration * 60))
        ticks = (0...count).map { date.addingTimeInterval(min(duration, Double($0) / 60)) }
        if duration > 0 {
            // Allow a display interval after the endpoint for the final draw.
            ticks.append(date.addingTimeInterval(duration + 1.0 / 30))
        }
    }
}
