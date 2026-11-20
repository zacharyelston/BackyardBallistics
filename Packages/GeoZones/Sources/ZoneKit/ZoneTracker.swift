import CoreGeo
import Foundation

public enum ZoneRule: String, Codable, CaseIterable, Sendable { case goal, allowedArea }

public struct ZoneDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var shape: ZoneShape
    public var rule: ZoneRule
    public init(id: UUID = UUID(), name: String, shape: ZoneShape, rule: ZoneRule) {
        self.id = id; self.name = name; self.shape = shape; self.rule = rule
    }
}

public struct ZoneFix: Sendable {
    public var at: GeoPoint
    public var accuracy: Double
    public var time: Date
    public init(at: GeoPoint, accuracy: Double, time: Date) { self.at = at; self.accuracy = accuracy; self.time = time }
}

public struct ZoneCrossing: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case arrived, left }
    public var zone: UUID
    public var kind: Kind
    public var time: Date
}

/// Two distinct, fresh reports wholly beyond the accuracy margin confirm a state.
/// Initial positions, reconnects and long gaps establish a baseline without inventing crossings.
public struct ZoneTracker<Subject: Hashable> {
    private struct Key: Hashable { var zone: UUID; var member: Subject }
    private struct State {
        var inside: Bool?
        var candidate: Bool?
        var count = 0
        var lastFix = Date.distantPast
    }
    private var states: [Key: State] = [:]
    private var definitions: [UUID: ZoneDefinition] = [:]
    public init() {}
    public mutating func reset(member: Subject) { states = states.filter { $0.key.member != member } }
    public mutating func retain(zones: Set<UUID>) { states = states.filter { zones.contains($0.key.zone) }; definitions = definitions.filter { zones.contains($0.key) } }
    public mutating func reset(zone: UUID) { states = states.filter { $0.key.zone != zone }; definitions[zone] = nil }

    public mutating func observe(_ position: ZoneFix, subject: Subject, zones: [ZoneDefinition], now: Date) -> [ZoneCrossing] {
        var events: [ZoneCrossing] = []
        for zone in zones {
            if definitions[zone.id] != zone {
                reset(zone: zone.id)
                guard zone.shape.validationError == nil else { continue }
                definitions[zone.id] = zone
            }
            let key = Key(zone: zone.id, member: subject)
            var state = states[key] ?? State()
            guard position.time > state.lastFix else { continue }
            let age = now.timeIntervalSince(position.time)
            guard age >= -30, age <= 120, position.accuracy.isFinite, position.accuracy >= 0,
                  position.at.latitude.isFinite, abs(position.at.latitude) <= 85,
                  position.at.longitude.isFinite, abs(position.at.longitude) <= 180 else {
                states[key] = nil
                continue
            }
            if position.time.timeIntervalSince(state.lastFix) > 120 { state = State() }
            state.lastFix = position.time
            let clearance = zone.shape.clearance(at: position.at)
            let margin = max(3, position.accuracy)
            guard abs(clearance) > margin else {
                state.candidate = nil; state.count = 0; states[key] = state
                continue
            }
            let inside = clearance > 0
            if state.candidate == inside { state.count += 1 } else { state.candidate = inside; state.count = 1 }
            if state.count >= 2 {
                if let before = state.inside, before != inside,
                   (zone.rule == .goal && inside) || (zone.rule == .allowedArea && !inside) {
                    events.append(ZoneCrossing(zone: zone.id, kind: inside ? .arrived : .left, time: position.time))
                }
                state.inside = inside
            }
            states[key] = state
        }
        return events
    }
}
