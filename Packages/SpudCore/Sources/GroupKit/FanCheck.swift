import Foundation
import CoreGeo
import SafetyKit

/// Whether a reported position may be inside a firing point's safety fan (SafetyKit's radius and
/// half-angle), allowing for GPS accuracy. Used only to add a hold; it never clears anything.
public enum FanCheck {
    public static func mayBeInside(_ p: GeoPoint, accuracy: Double, firingPoint: GeoPoint, flag: GeoPoint) -> Bool {
        let en = Geo.eastNorth(of: p, from: firingPoint)
        let r = (en.east * en.east + en.north * en.north).squareRoot()
        // At the line: standing at the firing point is where the squad is meant to be.
        if r <= GroupRules.lineStandoff + accuracy { return false }
        guard r - accuracy <= Safety.limits.fanRange else { return false }
        let centre = Geo.bearing(from: firingPoint, to: flag)
        let toPoint = Geo.degrees(atan2(en.east, en.north))
        var diff = (toPoint - centre).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        let margin = Geo.degrees(atan(accuracy / r))
        return abs(diff) <= Safety.limits.fanHalfAngle + margin
    }
}
