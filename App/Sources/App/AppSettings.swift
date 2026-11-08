import Foundation

enum Settings {
    /// Measured pole height in metres. 8 ft standard until measured.
    static let poleHeightKey = "poleHeightM"
    /// Height of the phone above the ground while sighting, in metres.
    static let cameraHeightKey = "cameraHeightM"
    /// Test flag point until course files exist (milestone 3).
    static let flagLatKey = "flagLat"
    static let flagLonKey = "flagLon"
    /// Use the simulated camera for ranging (always on in the Simulator).
    static let simulatedCaptureKey = "simulatedCapture"
    /// Name on the scorecard and in the downrange confirmations.
    static let playerNameKey = "playerName"
    static let defaultPlayerName = "Player 1"
    static let defaultPoleHeight = 2.438
    static let defaultCameraHeight = 1.5
}

enum Units {
    static func feetInches(_ m: Double) -> String {
        // Round to the tenth of an inch first, so 2.4384 m reads "8 ft 0.0 in", not "7 ft 12.0 in".
        let tenths = Int((m / 0.0254 * 10).rounded())
        return String(format: "%d ft %.1f in", tenths / 120, Double(tenths % 120) / 10)
    }
    static func yards(_ m: Double) -> String { String(format: "%.1f yd", m / 0.9144) }
    static func metres(_ m: Double) -> String { m < 10 ? String(format: "%.2f m", m) : String(format: "%.1f m", m) }
}
