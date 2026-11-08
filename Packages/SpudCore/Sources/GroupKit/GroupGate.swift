import Foundation
import SafetyKit

/// What the commander's iPad may show for a firing solution.
public enum FiringDisplay<Value> {
    case show(Cleared<Value>)
    /// SafetyKit's reasons and the group's holds; either list can be empty, never both.
    case blocked(safety: [SafetyReason], holds: [Hold])

    public var isShown: Bool { if case .show = self { return true } else { return false } }
    public var holds: [Hold] { if case let .blocked(_, h) = self { return h } else { return [] } }
    public var safetyReasons: [SafetyReason] { if case let .blocked(s, _) = self { return s } else { return [] } }
}

/// Combines SafetyKit's verdict with the group's holds. Holds only add: GroupGate can turn a
/// cleared solution into a blocked one, never the reverse. It can't create a `Cleared` value
/// (only SafetyKit can), so the only way to `.show` is to pass SafetyKit's own through.
public enum GroupGate {
    public static func display<Value>(_ verdict: Result<Cleared<Value>, SafetyBlock>, holds: Set<Hold>) -> FiringDisplay<Value> {
        let h = holds.sorted { $0.description < $1.description }
        switch verdict {
        case let .success(cleared):
            return h.isEmpty ? .show(cleared) : .blocked(safety: [], holds: h)
        case let .failure(block):
            return .blocked(safety: block.reasons, holds: h)
        }
    }
}
