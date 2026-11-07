import Foundation

/// One sighting-test photo: where the tip and base were marked, and how the range compared to a tape.
public struct FieldSample: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var lens: String
    public var approximateIntrinsics: Bool
    public var trueDistance: Double?
    public var poleHeight: Double
    public var cameraHeight: Double
    public var tipX: Double
    public var tipY: Double
    public var baseX: Double
    public var baseY: Double
    public var intrinsics: Intrinsics
    public var note: String = ""

    public init(lens: String, approximateIntrinsics: Bool, trueDistance: Double?, poleHeight: Double,
                cameraHeight: Double, tip: (x: Double, y: Double), base: (x: Double, y: Double),
                intrinsics: Intrinsics, note: String = "") {
        self.lens = lens
        self.approximateIntrinsics = approximateIntrinsics
        self.trueDistance = trueDistance
        self.poleHeight = poleHeight
        self.cameraHeight = cameraHeight
        self.tipX = tip.x; self.tipY = tip.y
        self.baseX = base.x; self.baseY = base.y
        self.intrinsics = intrinsics
        self.note = note
    }

    public var subtense: Double {
        RangeMath.subtendedAngle(intrinsics.ray(x: tipX, y: tipY), intrinsics.ray(x: baseX, y: baseY))
    }

    public var polePixels: Double { ((tipX - baseX) * (tipX - baseX) + (tipY - baseY) * (tipY - baseY)).squareRoot() }

    public var estimatedDistance: Double? {
        RangeMath.distance(subtense: subtense, poleHeight: poleHeight, cameraHeight: cameraHeight)
    }

    public var error: Double? {
        guard let t = trueDistance, let e = estimatedDistance else { return nil }
        return e - t
    }

    public var errorPercent: Double? {
        guard let t = trueDistance, t > 0, let e = error else { return nil }
        return e / t * 100
    }
}

public enum FieldCSV {
    public static let header = "date,lens,approx_intrinsics,true_m,est_m,error_m,error_pct,pole_px,subtense_deg,pole_h_m,camera_h_m,tip_x,tip_y,base_x,base_y,fx,fy,cx,cy,buf_w,buf_h,note"

    public static func make(_ samples: [FieldSample]) -> String {
        let iso = ISO8601DateFormatter()
        func n(_ v: Double?, _ digits: Int = 3) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "" }
        let rows = samples.map { s in
            [iso.string(from: s.date), s.lens, s.approximateIntrinsics ? "1" : "0",
             n(s.trueDistance), n(s.estimatedDistance), n(s.error), n(s.errorPercent, 2),
             n(s.polePixels, 1), n(RangeMath.degrees(s.subtense), 5), n(s.poleHeight), n(s.cameraHeight),
             n(s.tipX, 1), n(s.tipY, 1), n(s.baseX, 1), n(s.baseY, 1),
             n(s.intrinsics.fx, 2), n(s.intrinsics.fy, 2), n(s.intrinsics.cx, 2), n(s.intrinsics.cy, 2),
             "\(s.intrinsics.width)", "\(s.intrinsics.height)",
             "\"" + s.note.replacingOccurrences(of: "\"", with: "\"\"") + "\""].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }
}
