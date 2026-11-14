import Foundation

/// Shake to ask: deciding, from accelerometer readings, that the phone was shaken.
///
/// The rule: the total acceleration (gravity included, in g) rises above 2.3 g twice within
/// 600 ms. A single bump, such as putting the phone down hard or a step while walking, crosses
/// once; a deliberate shake crosses again on the way back. A peak counts once, on the way up,
/// however many readings it lasts. After a shake nothing counts for 1.5 s, so one long shake asks
/// once, not three times. Pure, so the tests can feed it readings; the same rule as shake.ts in
/// the earlier iPhone app.
public struct ShakeOptions: Equatable, Sendable {
    /// Total acceleration, in g, a peak must exceed.
    public var thresholdG: Double
    /// Two peaks closer together than this are a shake.
    public var windowMs: Double
    /// Quiet period after a shake.
    public var cooldownMs: Double

    public init(thresholdG: Double = 2.3, windowMs: Double = 600, cooldownMs: Double = 1500) {
        self.thresholdG = thresholdG; self.windowMs = windowMs; self.cooldownMs = cooldownMs
    }

    public static let defaults = ShakeOptions()
}

public struct ShakeDetector: Sendable {
    public let options: ShakeOptions
    private var above = false
    private var lastPeakAt: Double?
    private var quietUntil = -Double.infinity

    public init(options: ShakeOptions = .defaults) { self.options = options }

    public static func magnitude(_ x: Double, _ y: Double, _ z: Double) -> Double {
        (x * x + y * y + z * z).squareRoot()
    }

    /// One reading in g with its time in ms. True when this reading completes a shake.
    public mutating func push(x: Double, y: Double, z: Double, timeMs: Double) -> Bool {
        guard x.isFinite, y.isFinite, z.isFinite, timeMs.isFinite else { return false }
        let isAbove = ShakeDetector.magnitude(x, y, z) > options.thresholdG
        let rising = isAbove && !above
        above = isAbove
        guard rising else { return false }
        guard timeMs >= quietUntil else { return false }
        if let last = lastPeakAt, timeMs - last <= options.windowMs {
            lastPeakAt = nil
            quietUntil = timeMs + options.cooldownMs
            return true
        }
        lastPeakAt = timeMs
        return false
    }

    public mutating func reset() {
        above = false
        lastPeakAt = nil
        quietUntil = -Double.infinity
    }
}
