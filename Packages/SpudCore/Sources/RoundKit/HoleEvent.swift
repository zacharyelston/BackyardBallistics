import Foundation
import CoreGeo
import RangingKit

/// One step of a hole, as `HolePlay` records it. A hole is a pure function of its events, so a
/// host can amend a spot by editing the event and replaying.
public enum HoleEvent: Codable, Equatable, Sendable {
    case begin(lockedRange: Double, bearing: Double, heightDifference: Double, from: GeoPoint?)
    case spot(Spot)
    case lost
    case ceaseFire(closest: Double?)
    case resume
    case advance(lockedRange: Double, bearing: Double, heightDifference: Double, from: GeoPoint?)
    case finish
}

public extension HolePlay {
    /// Applies one event, with the same rules (and errors) as the matching method.
    mutating func apply(_ event: HoleEvent) throws {
        switch event {
        case let .begin(r, b, h, from): try begin(lockedRange: r, bearing: b, heightDifference: h, from: from)
        case let .spot(s): try record(s)
        case .lost: try recordLost()
        case let .ceaseFire(c): try ceaseFire(closest: c)
        case .resume: try resume()
        case let .advance(r, b, h, from): try advance(lockedRange: r, bearing: b, heightDifference: h, from: from)
        case .finish: try finish()
        }
    }

    /// Rebuilds a hole from its events.
    init(holeNumber: Int, par: Int, inRadius: Double, downrangePlay: Bool, replaying events: [HoleEvent]) throws {
        self.init(holeNumber: holeNumber, par: par, inRadius: inRadius, downrangePlay: downrangePlay)
        for e in events { try apply(e) }
    }

    /// A fresh hole with the same rules, replaying `events`.
    func replayed(_ events: [HoleEvent]) throws -> HolePlay {
        try HolePlay(holeNumber: holeNumber, par: par, inRadius: inRadius, downrangePlay: downrangePlay, replaying: events)
    }
}
