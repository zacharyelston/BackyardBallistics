import Foundation

/// What powers a launcher. Only the two kinds in the Launcher standard can conform.
public enum LauncherKind: String, Codable, Sendable, CaseIterable {
    /// Regulated compressed gas, rated parts, three safety layers.
    case pneumaticStandard
    /// Bands or springs; nothing holds pressure.
    case elastic
    /// Combustion, home-built pressure parts, or anything else. Never conforms.
    case other

    public var title: String {
        switch self {
        case .pneumaticStandard: return "Standard pneumatic"
        case .elastic: return "Elastic"
        case .other: return "Other (not supported)"
        }
    }
}

/// The five conformance checks from the Launcher standard, in order.
public enum ConformanceStep: String, Codable, Sendable, CaseIterable {
    case ratingsDocumented
    case reliefTest
    case interlockTest
    case velocityCap
    case preRoundInspection

    public var title: String {
        switch self {
        case .ratingsDocumented: return "Ratings documented"
        case .reliefTest: return "Relief test"
        case .interlockTest: return "Interlock test"
        case .velocityCap: return "Velocity cap"
        case .preRoundInspection: return "Pre-round inspection"
        }
    }

    public var detail: String {
        switch self {
        case .ratingsDocumented:
            return "A photo of every pressure part's rating stamp, all above the relief set point."
        case .reliefTest:
            return "With no projectile, raise the regulator past the relief set point; the relief valve must vent first."
        case .interlockTest:
            return "With no projectile at working pressure, the shot must fail with the key off, over the pressure cutoff, and with the inhibit relay open."
        case .velocityCap:
            return String(format: "Calibration shots at the highest setting must fit at or under %.0f m/s.", SafetyLimits.current.maxMuzzleVelocity)
        case .preRoundInspection:
            return "Before each round, every inspection item must pass."
        }
    }

    /// Steps a launcher of this kind must pass. Elastic launchers hold no pressure.
    public static func required(for kind: LauncherKind) -> [ConformanceStep] {
        switch kind {
        case .pneumaticStandard: return allCases
        case .elastic: return [.velocityCap, .preRoundInspection]
        case .other: return allCases
        }
    }
}

/// One item on the pre-round inspection.
public enum InspectionItem: String, Codable, Sendable, CaseIterable {
    case noDamage
    case fittingsTight
    case tankInTestDate
    case keyAndButtonWork
    case bandsIntact
    case anchorsSecure
    case muzzleDownrange

    public var prompt: String {
        switch self {
        case .noDamage: return "No cracks, dents, corrosion or wear"
        case .fittingsTight: return "All fittings tight, no leaks"
        case .tankInTestDate: return "Tank within its hydro-test date"
        case .keyAndButtonWork: return "Key switch and fire button work"
        case .bandsIntact: return "Bands intact, no nicks or fraying"
        case .anchorsSecure: return "Frame and anchors secure"
        case .muzzleDownrange: return "Pointed downrange, everyone behind the launcher"
        }
    }

    public static func items(for kind: LauncherKind) -> [InspectionItem] {
        switch kind {
        case .pneumaticStandard: return [.noDamage, .fittingsTight, .tankInTestDate, .keyAndButtonWork, .muzzleDownrange]
        case .elastic: return [.noDamage, .bandsIntact, .anchorsSecure, .muzzleDownrange]
        case .other: return []
        }
    }
}

/// The three cases the interlock test must block.
public struct InterlockTest: Codable, Equatable, Sendable {
    public var keyOffBlocked = false
    public var overPressureBlocked = false
    public var inhibitRelayBlocked = false
    public init() {}
    public var passed: Bool { keyOffBlocked && overPressureBlocked && inhibitRelayBlocked }
}

/// A pre-round inspection, valid only for the round it was done for.
public struct Inspection: Codable, Equatable, Sendable {
    public var roundID: String
    public var date: Date
    public var results: [InspectionItem: Bool]

    public init(roundID: String, date: Date = Date(), results: [InspectionItem: Bool]) {
        self.roundID = roundID; self.date = date; self.results = results
    }
}

/// A launcher's conformance record. The app fills it in; SafetyKit decides what it means.
public struct LauncherConformance: Codable, Equatable, Sendable {
    public var launcherID: String
    public var name: String
    public var kind: LauncherKind
    public var ratingsDocumented = false
    public var reliefVented = false
    public var interlock = InterlockTest()
    /// Highest fitted muzzle velocity across all charge settings, m/s.
    public var calibratedMaxVelocity: Double?
    /// Highest regulator setting that passed calibration, psi (pneumatic only).
    public var maxSetpointPSI: Double?
    public var inspection: Inspection?

    public init(launcherID: String, name: String, kind: LauncherKind) {
        self.launcherID = launcherID; self.name = name; self.kind = kind
    }

    /// Any change to a pressure part voids every check; the launcher starts over.
    public mutating func pressurePartsChanged() {
        ratingsDocumented = false
        reliefVented = false
        interlock = InterlockTest()
        calibratedMaxVelocity = nil
        maxSetpointPSI = nil
        inspection = nil
    }
}
