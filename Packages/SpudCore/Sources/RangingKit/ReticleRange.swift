import Foundation
import CoreGeo

/// Stadia ranging with a plumb reticle: the crosshair sits on the pole's base, a line rises from it,
/// and the range dial is turned until the line's top meets the pole's top. No tapping.
///
/// With the camera level, a pole of height `H` at range `d` is `f·H/d` sensor pixels tall, so
/// `d = f·H/h`. A phone held on the base looks down a little, which makes the pole look slightly
/// taller close in (about 1.4% at 10 m from eye height, nothing that matters past 30 m). When the
/// angle below level is known, this type corrects for it exactly; at zero it is the plain formula.
///
/// Everything here is in sensor pixels of the camera's native buffer, never screen points, so
/// pinch zoom and the screen size never change the maths.
public struct ReticleRange: Codable, Equatable, Sendable {
    /// Focal length in sensor pixels (`fy` of the native buffer; `fx` on square-pixel sensors).
    public var focalPixels: Double
    /// Known pole height, metres (8, 10 or 12 ft).
    public var poleHeight: Double
    /// Angle of the crosshair's line of sight below level, degrees. Zero for the plain formula.
    public var angleBelowLevel: Double

    public init(focalPixels: Double, poleHeight: Double, angleBelowLevel: Double = 0) {
        self.focalPixels = focalPixels
        self.poleHeight = poleHeight
        self.angleBelowLevel = angleBelowLevel
    }

    private var tilt: Double { Geo.radians(angleBelowLevel) }

    /// Length of the plumb line, in sensor pixels from the crosshair, that matches a pole at `range` metres.
    public func linePixels(range d: Double) -> Double {
        guard d > 0 else { return .infinity }
        // The tip is (H/d − tanθ) above level; the line runs from the base ray (the optical axis) to it.
        let tipAboveAxis = tilt + atan(poleHeight / d - tan(tilt))
        return focalPixels * tan(tipAboveAxis)
    }

    /// Range in metres for a plumb line `linePixels` long; nil if the line is too short to mean anything.
    public func range(linePixels h: Double) -> Double? {
        guard h > 0, focalPixels > 0, poleHeight > 0 else { return nil }
        let alpha = atan(h / focalPixels)
        let denom = tan(tilt) + tan(alpha - tilt)
        guard denom > 0 else { return nil }
        return poleHeight / denom
    }

    /// One-sigma range error from ±1 px (or `pixelError`) on each end of the line, combined in quadrature.
    ///
    /// `σ_d = √2·σ_px·d/h = √2·σ_px·d²/(f·H)`: it grows with the square of the range.
    public func sigma(range d: Double, pixelError: Double = 1) -> Double {
        let h = focalPixels * poleHeight / d
        return 2.0.squareRoot() * pixelError * d / h
    }

    /// Height of the pole's base relative to the ground under the shooter, metres (+ uphill).
    ///
    /// The camera is `cameraHeight` above its own ground and sees the base `angleBelowLevel` down,
    /// so the base sits `d·tanθ` below the camera.
    public static func heightDifference(range d: Double, cameraHeight: Double, angleBelowLevel: Double) -> Double {
        cameraHeight - d * tan(Geo.radians(angleBelowLevel))
    }
}

/// Everything recorded when the player presses Lock.
public struct ReticleLock: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var reticle: ReticleRange
    /// The range the dial was locked at, metres.
    public var range: Double
    /// Compass bearing of the crosshair, degrees clockwise from true north.
    public var bearing: Double
    /// Phone height above its own ground while ranging, metres.
    public var cameraHeight: Double
    /// GPS position of the player (the lie) at the lock.
    public var location: GeoPoint
    /// GPS horizontal accuracy, metres.
    public var horizontalAccuracy: Double?

    public init(reticle: ReticleRange, range: Double, bearing: Double, cameraHeight: Double,
                location: GeoPoint, horizontalAccuracy: Double?) {
        self.reticle = reticle
        self.range = range
        self.bearing = bearing
        self.cameraHeight = cameraHeight
        self.location = location
        self.horizontalAccuracy = horizontalAccuracy
    }

    public var angleBelowLevel: Double { reticle.angleBelowLevel }
    /// Plumb-line length at the lock, sensor pixels.
    public var linePixels: Double { reticle.linePixels(range: range) }
    /// One-sigma range error from ±1 px at the base and the top.
    public var sigma: Double { reticle.sigma(range: range) }
    public var heightDifference: Double {
        ReticleRange.heightDifference(range: range, cameraHeight: cameraHeight, angleBelowLevel: angleBelowLevel)
    }
    /// Where the pole (the hole) is: GPS position plus bearing and distance.
    public var polePosition: GeoPoint { Geo.destination(location, bearing: bearing, distance: range) }
    /// Ranged offset from the lie to the pole, metres east and north, for the safety flag check.
    public var eastNorth: (east: Double, north: Double) {
        (range * sin(Geo.radians(bearing)), range * cos(Geo.radians(bearing)))
    }
}
