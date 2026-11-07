import SwiftUI

@main
struct SpudGunGolfApp: App {
    @StateObject private var log = FieldLogStore()
    @StateObject private var rangingLog = RangingLogStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(log)
                .environmentObject(rangingLog)
        }
    }
}

enum Settings {
    /// Measured pole height in metres. 8 ft standard until measured.
    static let poleHeightKey = "poleHeightM"
    /// Height of the phone above the ground while sighting, in metres.
    static let cameraHeightKey = "cameraHeightM"
    /// Test flag point until course files exist (milestone 3).
    static let flagLatKey = "flagLat"
    static let flagLonKey = "flagLon"
    static let defaultPoleHeight = 2.438
    static let defaultCameraHeight = 1.5
}

enum Units {
    static func feetInches(_ m: Double) -> String {
        let inches = m / 0.0254
        let ft = Int(inches / 12)
        return String(format: "%d ft %.1f in", ft, inches - Double(ft) * 12)
    }
    static func yards(_ m: Double) -> String { String(format: "%.1f yd", m / 0.9144) }
    static func metres(_ m: Double) -> String { m < 10 ? String(format: "%.2f m", m) : String(format: "%.1f m", m) }
}
