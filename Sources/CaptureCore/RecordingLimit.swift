import Foundation

/// Uses elapsed monotonic time so changing the wall clock cannot postpone a stop.
public struct RecordingLimit: Sendable {
    public static let defaultSeconds = 120 * 60
    public static let maximumSeconds = 12 * 60 * 60
    public private(set) var durationSeconds: Int
    private var announced: Set<Int> = []

    public enum Event: Equatable, Sendable {
        case warning(minutes: Int)
        case stop
    }

    public init(seconds: Int = Self.defaultSeconds) {
        durationSeconds = min(Self.maximumSeconds, max(60, seconds))
    }

    public mutating func extend(by seconds: Int = 15 * 60) {
        durationSeconds += min(Self.maximumSeconds - durationSeconds, max(0, seconds))
        announced.removeAll()
    }

    public func remaining(elapsedSeconds: Double) -> Int {
        max(0, Int(ceil(Double(durationSeconds) - max(0, elapsedSeconds))))
    }

    public mutating func poll(elapsedSeconds: Double) -> Event? {
        let remaining = remaining(elapsedSeconds: elapsedSeconds)
        if remaining == 0 { return .stop }
        // If a suspended app resumes late, announce the most urgent warning only.
        for minutes in [1, 5] where durationSeconds > minutes * 60 {
            if remaining <= minutes * 60, !announced.contains(minutes) {
                announced.formUnion([minutes, 5])
                return .warning(minutes: minutes)
            }
        }
        return nil
    }
}

public struct AudioSignalLevel: Equatable, Sendable {
    public let rms: Double
    public let peak: Double
    public init(rms: Double, peak: Double) {
        self.rms = rms.isFinite ? max(0, min(1, rms)) : 0
        self.peak = peak.isFinite ? max(0, min(1, peak)) : 0
    }
    public var decibels: Double { max(-60, 20 * log10(max(rms, 0.000_001))) }
    public var meterValue: Double { (decibels + 60) / 60 }
    public var hasSound: Bool { decibels > -50 }
    public var isClipping: Bool { peak >= 0.995 }
}
