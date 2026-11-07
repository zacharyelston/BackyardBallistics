import Foundation
import CoreGeo

/// Why something was blocked, in words a player can read.
public enum SafetyReason: Equatable, Sendable, CustomStringConvertible {
    case muzzleVelocityOverCap(measured: Double, cap: Double)
    case beyondSolutionRange(distance: Double, limit: Double)
    case noFlag
    case flagTooFar(miss: Double, tolerance: Double)
    case noBoundary
    case fanLeavesBoundary(pointsOutside: Int)
    case downrangeNotConfirmed
    case unsupportedLauncher
    case launcherNotConforming(missing: [ConformanceStep])
    case inspectionNeeded
    case inspectionFailed(items: [InspectionItem])
    case pressureOverSetpoint(reading: Double, cap: Double)

    public var description: String {
        switch self {
        case let .muzzleVelocityOverCap(v, cap):
            return String(format: "This charge setting measured %.1f m/s, over the %.0f m/s limit. Solutions for it are blocked.", v, cap)
        case let .beyondSolutionRange(d, limit):
            return String(format: "The hole is %.0f m away, past the %.0f m (100 yd) limit. Lay up closer first.", d, limit)
        case .noFlag:
            return "No published flag here. Ranging only works on a loaded course's flags."
        case let .flagTooFar(miss, tol):
            return String(format: "The range lands %.0f m from the published flag, more than %.0f m. Re-mark the photos or re-range.", miss, tol)
        case .noBoundary:
            return "The course has no boundary, so its safety fans can't be checked."
        case let .fanLeavesBoundary(n):
            return "The safety fan from this start spot leaves the course boundary (\(n) check points outside). Move the start spot or the flag."
        case .downrangeNotConfirmed:
            return "Confirm the fan is clear of people and animals before the first shot on this hole."
        case .unsupportedLauncher:
            return "This launcher isn't a standard pneumatic or elastic launcher, so the app won't solve for it."
        case let .launcherNotConforming(missing):
            return "This launcher hasn't passed: " + missing.map(\.title).joined(separator: ", ") + "."
        case .inspectionNeeded:
            return "Do the pre-round inspection for this round before the first shot."
        case let .inspectionFailed(items):
            return "The pre-round inspection failed on: " + items.map(\.prompt).joined(separator: "; ") + ". Fix it before firing."
        case let .pressureOverSetpoint(reading, cap):
            return String(format: "Pressure reads %.0f psi, over this launcher's %.0f psi calibrated limit. The shot is held.", reading, cap)
        }
    }
}

public enum Verdict: Equatable, Sendable {
    case allowed
    case blocked([SafetyReason])

    public var isAllowed: Bool { if case .allowed = self { return true } else { return false } }
    public var reasons: [SafetyReason] { if case let .blocked(r) = self { return r } else { return [] } }

    init(_ reasons: [SafetyReason]) { self = reasons.isEmpty ? .allowed : .blocked(reasons) }
}

public struct SafetyBlock: Error, Equatable, Sendable {
    public let reasons: [SafetyReason]
}

/// A value that has passed the safety checks. Only SafetyKit can create one, so any API that
/// demands a `Cleared` value cannot be reached without going through these checks.
public struct Cleared<Value> {
    public let value: Value
    public let limitsVersion: Int
    fileprivate init(_ value: Value) {
        self.value = value
        self.limitsVersion = SafetyLimits.current.version
    }
}

extension Cleared: Sendable where Value: Sendable {}

/// Which players have confirmed the downrange fan is clear, per hole.
public struct DownrangeLog: Codable, Equatable, Sendable {
    public static let prompt = "Is the whole fan downrange clear of people and animals?"
    private var confirmed: Set<String> = []

    public init() {}

    private static func key(_ player: String, _ hole: Int) -> String { "\(hole)|\(player)" }
    public mutating func confirm(player: String, hole: Int) { confirmed.insert(Self.key(player, hole)) }
    public func isConfirmed(player: String, hole: Int) -> Bool { confirmed.contains(Self.key(player, hole)) }
}

public enum Safety {
    public static var limits: SafetyLimits { .current }

    // MARK: Launcher calibration

    /// A calibrated charge setting is usable only at or under the velocity cap.
    public static func checkCalibration(muzzleVelocity v: Double) -> Verdict {
        Verdict(v > limits.maxMuzzleVelocity ? [.muzzleVelocityOverCap(measured: v, cap: limits.maxMuzzleVelocity)] : [])
    }

    // MARK: Firing solutions

    /// The only way to turn a firing solution into something the app may show.
    public static func clearSolution<S>(_ solution: S, distance: Double, muzzleVelocity: Double,
                                        launcher: LauncherConformance, roundID: String,
                                        downrange: DownrangeLog, player: String, hole: Int) -> Result<Cleared<S>, SafetyBlock> {
        var reasons = checkLauncher(launcher, roundID: roundID).reasons
        if distance > limits.maxSolutionRange {
            reasons.append(.beyondSolutionRange(distance: distance, limit: limits.maxSolutionRange))
        }
        let velocity = checkCalibration(muzzleVelocity: muzzleVelocity).reasons
        reasons += velocity.filter { !reasons.contains($0) }
        if !downrange.isConfirmed(player: player, hole: hole) { reasons.append(.downrangeNotConfirmed) }
        return reasons.isEmpty ? .success(Cleared(solution)) : .failure(SafetyBlock(reasons: reasons))
    }

    // MARK: Launcher standard

    /// Whether a launcher conforms to the Launcher standard for this round.
    public static func checkLauncher(_ c: LauncherConformance, roundID: String) -> Verdict {
        guard c.kind != .other else { return .blocked([.unsupportedLauncher]) }
        var missing: [ConformanceStep] = []
        var reasons: [SafetyReason] = []
        for step in ConformanceStep.required(for: c.kind) {
            switch step {
            case .ratingsDocumented:
                if !c.ratingsDocumented { missing.append(step) }
            case .reliefTest:
                if !c.reliefVented { missing.append(step) }
            case .interlockTest:
                if !c.interlock.passed { missing.append(step) }
            case .velocityCap:
                if let v = c.calibratedMaxVelocity {
                    reasons += checkCalibration(muzzleVelocity: v).reasons
                } else {
                    missing.append(step)
                }
                if c.kind == .pneumaticStandard, c.maxSetpointPSI == nil, !missing.contains(step) { missing.append(step) }
            case .preRoundInspection:
                break // reported separately below, after the one-time checks
            }
        }
        if !missing.isEmpty { reasons.insert(.launcherNotConforming(missing: missing), at: 0) }
        if let inspection = c.inspection, inspection.roundID == roundID {
            let failed = InspectionItem.items(for: c.kind).filter { inspection.results[$0] != true }
            if !failed.isEmpty { reasons.append(.inspectionFailed(items: failed)) }
        } else {
            reasons.append(.inspectionNeeded)
        }
        return Verdict(reasons)
    }

    /// The pressure interlock rule for the inhibit relay: hold the shot if pressure is over the
    /// calibrated setpoint or the launcher has none. Inhibit only; this never starts a shot.
    public static func pressureInhibit(readingPSI: Double, launcher: LauncherConformance) -> Verdict {
        guard launcher.kind == .pneumaticStandard else { return .blocked([.unsupportedLauncher]) }
        guard let cap = launcher.maxSetpointPSI else { return .blocked([.launcherNotConforming(missing: [.velocityCap])]) }
        return Verdict(readingPSI > cap ? [.pressureOverSetpoint(reading: readingPSI, cap: cap)] : [])
    }

    // MARK: Ranging (course flags only)

    public struct FlagCheck: Equatable, Sendable {
        public var rangedHole: GeoPoint
        /// Distance from the ranged hole to the published flag, or nil without a flag.
        public var miss: Double?
        public var verdict: Verdict
    }

    /// - Parameters:
    ///   - lie: GPS position of the player when ranging.
    ///   - east, north: ranged offset from the lie to the hole (the pole's base), metres.
    ///   - flag: the published flag point from the loaded course.
    public static func checkFlag(lie: GeoPoint, east: Double, north: Double, flag: GeoPoint?) -> FlagCheck {
        let hole = Geo.offset(lie, east: east, north: north)
        guard let flag else { return FlagCheck(rangedHole: hole, miss: nil, verdict: .blocked([.noFlag])) }
        let miss = Geo.distance(hole, flag)
        let verdict = Verdict(miss > limits.flagGateTolerance ? [.flagTooFar(miss: miss, tolerance: limits.flagGateTolerance)] : [])
        return FlagCheck(rangedHole: hole, miss: miss, verdict: verdict)
    }

    /// The only way to turn a range into something the firing computer may use.
    public static func clearRange<R>(_ range: R, lie: GeoPoint, east: Double, north: Double,
                                     flag: GeoPoint?) -> Result<Cleared<R>, SafetyBlock> {
        let check = checkFlag(lie: lie, east: east, north: north, flag: flag)
        return check.verdict.isAllowed ? .success(Cleared(range)) : .failure(SafetyBlock(reasons: check.verdict.reasons))
    }

    // MARK: Course publishing

    /// Every point of the fan from `start` toward `hole` (radius `fanRange`, ± `fanHalfAngle`)
    /// must lie inside the course boundary.
    public static func checkFan(start: GeoPoint, hole: GeoPoint, boundary: GeoPolygon?) -> Verdict {
        guard let boundary, boundary.vertices.count >= 3 else { return .blocked([.noBoundary]) }
        let centre = Geo.bearing(from: start, to: hole)
        let radii = Array(stride(from: 5.0, to: limits.fanRange, by: 5)) + [limits.fanRange]
        let angles = Array(stride(from: -limits.fanHalfAngle, through: limits.fanHalfAngle, by: 1))
        var outside = 0
        for a in angles {
            for r in radii where !boundary.contains(Geo.destination(start, bearing: centre + a, distance: r)) {
                outside += 1
            }
        }
        return Verdict(outside > 0 ? [.fanLeavesBoundary(pointsOutside: outside)] : [])
    }
}
