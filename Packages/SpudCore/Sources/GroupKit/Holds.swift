import Foundation
import SafetyKit

/// A reason the group holds firing data. Holds are turn and field rules layered on top of SafetyKit:
/// they can only add to a block, never remove one.
public enum Hold: Codable, Hashable, Sendable, CustomStringConvertible {
    /// Another squad's turn, or no turn granted yet.
    case notYourTurn
    /// A squad has ceased fire and is walking out to verify.
    case walkingOut(SquadID)
    /// Someone called check fire.
    case checkFire(by: DeviceID)
    /// A member is inside the active firing point's fan.
    case memberInFan(MemberID)
    /// A member's position is unknown or stale, so the fan can't be called clear.
    case memberPositionUnknown(MemberID)
    /// The commander hasn't heard from the match host within the lease.
    case matchHostLost

    public var description: String {
        switch self {
        case .notYourTurn: return "Not your squad's turn."
        case .walkingOut: return "A squad is downrange verifying."
        case .checkFire: return "Check fire."
        case .memberInFan: return "Someone is inside the fan."
        case .memberPositionUnknown: return "A member's position is unknown; account for them before firing."
        case .matchHostLost: return "Lost the match host. Firing is held until it's back."
        }
    }
}

/// What a commander's iPad may show for a solution.
public enum Gated<S> {
    /// SafetyKit cleared it and the group has no holds.
    case show(Cleared<S>)
    /// Blocked: SafetyKit's reasons, the group's holds, or both.
    case held(safety: [SafetyReason], group: [Hold])

    public var isShown: Bool { if case .show = self { return true } else { return false } }
}

/// Combines SafetyKit's verdict with the group's holds. It can only take away: `.show` needs a
/// `Cleared` value, which only SafetyKit can make, and any hold turns it into `.held`.
public enum GroupGate {
    public static func gate<S>(_ safety: Result<Cleared<S>, SafetyBlock>, holds: [Hold]) -> Gated<S> {
        switch safety {
        case let .success(cleared) where holds.isEmpty: return .show(cleared)
        case .success: return .held(safety: [], group: holds)
        case let .failure(block): return .held(safety: block.reasons, group: holds)
        }
    }
}
