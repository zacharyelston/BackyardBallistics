import Foundation
import CoreGeo

/// The long/short call on a round, made by eye from the firing point.
///
/// Long/short is called rather than measured: from eye height the ground near the pole is seen at
/// about 1°, so a measured long/short miss would swing by metres with every bump in the ground.
public enum RangeCall: String, Codable, Sendable, CaseIterable {
    case short
    case over
    case rangeCorrect

    public var label: String {
        switch self {
        case .short: return "Short"
        case .over: return "Over"
        case .rangeCorrect: return "Range correct"
        }
    }
}

/// One spotted round: a called long/short and a measured left/right miss.
public struct Spot: Codable, Equatable, Sendable {
    public var call: RangeCall
    /// Measured miss across the line from the pole, metres (+ right of the pole, − left).
    public var lateral: Double

    public init(call: RangeCall, lateral: Double) {
        self.call = call
        self.lateral = lateral
    }

    /// Left/right from the crosshair: the angle from the pole to the round (degrees, + right) times the range.
    public init(call: RangeCall, crosshairAngleDegrees: Double, range: Double) {
        self.init(call: call, lateral: Spotting.lateralMiss(crosshairAngleDegrees: crosshairAngleDegrees, range: range))
    }
}

public enum Spotting {
    /// Metres across the line for a crosshair angle (degrees, + right) at `range` metres.
    public static func lateralMiss(crosshairAngleDegrees a: Double, range d: Double) -> Double {
        d * tan(Geo.radians(a))
    }
}

/// Fire control's adjustment from the firing point, relative to the locked range and the line to the pole.
///
/// - Long/short brackets: the first step is `max(2 m, 6% of range)`. A range-correct call or a change
///   of call means the pole is bracketed; from then on each short or over call halves the step
///   (never below 0.5 m) before applying it. Range correct leaves the range alone.
/// - Left/right corrects by the mean measured miss of every round so far, so scatter averages out
///   and a steady drift (wind, a bent sight) is taken out.
public struct FireControl: Codable, Equatable, Sendable {
    public static let minimumStep = 0.5

    public static func initialStep(range d: Double) -> Double { max(2, 0.06 * d) }

    /// The locked range along the line to the pole, metres.
    public let lockedRange: Double
    /// Add (+) or drop (−) from the locked range, metres.
    public private(set) var rangeAdjustment: Double = 0
    /// Aim right (+) or left (−) of the line, metres at the pole.
    public private(set) var lateralCorrection: Double = 0
    /// Current bracketing step, metres.
    public private(set) var step: Double
    public private(set) var bracketed = false
    public private(set) var lastCall: RangeCall?
    public private(set) var rounds = 0
    /// Sum of each round's miss as it would have been with no lateral correction.
    private var rawLateralSum = 0.0

    public init(lockedRange: Double) {
        self.lockedRange = lockedRange
        self.step = Self.initialStep(range: lockedRange)
    }

    /// Range fire control aims at now.
    public var aimRange: Double { lockedRange + rangeAdjustment }

    /// The change from the previous aim: add/drop metres along the line, right/left metres across it.
    public struct Correction: Equatable, Sendable {
        public var addDrop: Double
        public var rightLeft: Double
    }

    /// Records a spotted round and returns the correction for the next one.
    @discardableResult
    public mutating func record(_ spot: Spot) -> Correction {
        let before = (rangeAdjustment, lateralCorrection)

        // The round was fired with the current lateral correction applied, so its uncorrected miss is
        // the spotted miss minus that correction. Aim off by the mean uncorrected miss.
        rawLateralSum += spot.lateral - lateralCorrection
        rounds += 1
        lateralCorrection = -rawLateralSum / Double(rounds)

        if spot.call == .rangeCorrect || (lastCall != nil && lastCall != spot.call) { bracketed = true }
        if spot.call != .rangeCorrect {
            if bracketed { step = max(Self.minimumStep, step / 2) }
            rangeAdjustment += spot.call == .short ? step : -step
        }
        lastCall = spot.call

        return Correction(addDrop: rangeAdjustment - before.0, rightLeft: lateralCorrection - before.1)
    }
}
