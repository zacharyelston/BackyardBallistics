import Foundation
import CoreGeo

/// Requests to and answers from the USGS elevation services (public domain, US coverage only):
/// the 3DEP ImageServer's `getSamples` for many points at once, and the Elevation Point Query
/// Service (EPQS) for one point at a time. Only the request building and parsing live here, so they
/// can be tested; the Theater app does the networking.
public enum USGSElevation {
    /// The credit to show wherever these heights are drawn.
    public static let source = "USGS 3DEP"

    public static let samplesURL = URL(string: "https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer/getSamples")!
    public static let pointQueryURL = URL(string: "https://epqs.nationalmap.gov/v1/json")!

    /// Points per `getSamples` request: the service is happy with a few hundred.
    public static let batchSize = 400

    /// The form-encoded POST body for `getSamples`: a WGS84 multipoint, bilinear, first value only.
    public static func samplesBody(_ points: [GeoPoint]) -> Data {
        let coords = points.map { String(format: "[%.8f,%.8f]", $0.longitude, $0.latitude) }.joined(separator: ",")
        let geometry = "{\"points\":[\(coords)],\"spatialReference\":{\"wkid\":4326}}"
        let fields: [(String, String)] = [
            ("geometry", geometry),
            ("geometryType", "esriGeometryMultipoint"),
            ("returnFirstValueOnly", "true"),
            ("interpolation", "RSP_BilinearInterpolation"),
            ("f", "json"),
        ]
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&")
        return Data(body.utf8)
    }

    public enum ParseError: Error, Equatable {
        case notJSON
        case serviceError(String)
    }

    /// Heights in metres for `count` requested points, in request order. The service leaves out
    /// points it has no data for (and may say "NoData"); those come back NaN.
    public static func parseSamples(_ data: Data, count: Int) throws -> [Double] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notJSON }
        if let err = obj["error"] as? [String: Any] {
            throw ParseError.serviceError((err["message"] as? String) ?? "error")
        }
        guard let samples = obj["samples"] as? [[String: Any]] else { throw ParseError.notJSON }
        var out = Array(repeating: Double.nan, count: count)
        for s in samples {
            guard let id = (s["locationId"] as? NSNumber)?.intValue, id >= 0, id < count else { continue }
            out[id] = heightValue(s["value"])
        }
        return out
    }

    /// The EPQS URL for one point, in metres.
    public static func pointQuery(_ p: GeoPoint) -> URL {
        var c = URLComponents(url: pointQueryURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "x", value: String(format: "%.8f", p.longitude)),
            URLQueryItem(name: "y", value: String(format: "%.8f", p.latitude)),
            URLQueryItem(name: "units", value: "Meters"),
            URLQueryItem(name: "wkid", value: "4326"),
            URLQueryItem(name: "includeDate", value: "false"),
        ]
        return c.url!
    }

    /// One EPQS answer's height; NaN when it has none (outside coverage it answers -1000000, or not JSON).
    public static func parsePointQuery(_ data: Data) -> Double {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .nan }
        return heightValue(obj["value"])
    }

    /// A height from a JSON value (number or numeric string); NaN for "NoData" and the sentinels
    /// the services use for no data.
    static func heightValue(_ v: Any?) -> Double {
        let d: Double?
        if let n = v as? NSNumber { d = n.doubleValue } else if let s = v as? String { d = Double(s) } else { d = nil }
        guard let h = d, h.isFinite, h > -10_000, h < 10_000 else { return .nan }
        return h
    }
}
