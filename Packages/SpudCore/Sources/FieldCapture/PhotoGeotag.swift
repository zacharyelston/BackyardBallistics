import Foundation
import ImageIO
import CoreGeo

// FieldCapture: the parts of `spud-mesh` (docs/MESHING.md) that don't need RealityKit, so they
// can be tested anywhere: each photo's EXIF GPS, pairing reconstructed cameras with it, and the
// fit that pins the reconstruction to the course's ENU frame.
//
// The field model is a picture, never an input to firing: nothing here feeds SafetyKit.

/// Where a photo says it was taken, from its EXIF GPS block.
public struct PhotoGeotag: Equatable, Sendable {
    public var url: URL
    public var point: GeoPoint
    /// Metres above sea level, if the photo has it.
    public var altitude: Double?
    /// The phone's horizontal position error, metres (EXIF `GPSHPositioningError`), if present.
    public var horizontalAccuracy: Double?

    public init(url: URL, point: GeoPoint, altitude: Double? = nil, horizontalAccuracy: Double? = nil) {
        self.url = url
        self.point = point
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
    }

    /// Reads an image file's GPS; nil if the file isn't an image or has no usable position.
    public static func read(_ url: URL) -> PhotoGeotag? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] else { return nil }
        return parse(gps: gps, url: url)
    }

    /// Turns an ImageIO GPS dictionary into a geotag. Latitude and longitude are unsigned in EXIF,
    /// with N/S and E/W refs; an altitude ref of 1 means below sea level.
    public static func parse(gps: [String: Any], url: URL) -> PhotoGeotag? {
        func number(_ key: CFString) -> Double? {
            switch gps[key as String] {
            case let d as Double: return d
            case let n as NSNumber: return n.doubleValue
            case let s as String: return Double(s)
            default: return nil
            }
        }
        func ref(_ key: CFString) -> String? { (gps[key as String] as? String)?.uppercased() }

        guard var lat = number(kCGImagePropertyGPSLatitude),
              var lon = number(kCGImagePropertyGPSLongitude) else { return nil }
        if ref(kCGImagePropertyGPSLatitudeRef) == "S" { lat = -abs(lat) }
        if ref(kCGImagePropertyGPSLongitudeRef) == "W" { lon = -abs(lon) }
        guard (-90...90).contains(lat), (-180...180).contains(lon), !(lat == 0 && lon == 0) else { return nil }

        var altitude = number(kCGImagePropertyGPSAltitude)
        if let a = altitude {
            let below = number(kCGImagePropertyGPSAltitudeRef) == 1
            altitude = below ? -abs(a) : a
        }
        var accuracy = number(kCGImagePropertyGPSHPositioningError)
        if let a = accuracy, !(a > 0 && a.isFinite) { accuracy = nil }
        return PhotoGeotag(url: url, point: GeoPoint(latitude: lat, longitude: lon),
                           altitude: altitude, horizontalAccuracy: accuracy)
    }
}

/// The photos in a folder, in name order.
public enum PhotoFolder {
    /// Extensions Object Capture reads.
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "dng"]

    public static func imageURLs(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Every photo's geotag, and the photos that had none.
    public static func geotags(in folder: URL) throws -> (tagged: [PhotoGeotag], untagged: [URL]) {
        var tagged: [PhotoGeotag] = [], untagged: [URL] = []
        for url in try imageURLs(in: folder) {
            if let tag = PhotoGeotag.read(url) { tagged.append(tag) } else { untagged.append(url) }
        }
        return (tagged, untagged)
    }
}
