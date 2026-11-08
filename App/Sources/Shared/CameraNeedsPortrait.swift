import SwiftUI
import UIKit

/// The camera screens measure in sensor pixels with the device held upright: the plumb line, the
/// reticle and the crosshair's left/right all assume portrait. On an iPad turned to landscape they
/// would read sideways, so they are covered with a prompt to turn it upright instead of showing a
/// wrong range. The iPhone is locked to portrait and never sees this.
struct CameraNeedsPortrait: ViewModifier {
    func body(content: Content) -> some View {
        // The reader sits in an overlay so it doesn't change the screen's own layout.
        content.overlay {
            GeometryReader { geo in
                    if UIDevice.current.userInterfaceIdiom == .pad && geo.size.width > geo.size.height {
                        ZStack {
                            Color(.systemBackground).ignoresSafeArea()
                            VStack(spacing: 16) {
                                Image(systemName: "ipad.landscape.and.iphone")
                                    .symbolRenderingMode(.hierarchical)
                                    .font(.system(size: 64))
                                    .foregroundStyle(.tint)
                                Text("Turn the iPad upright to use the camera")
                                    .font(.title2.weight(.semibold))
                                Text("Ranging and spotting measure with the camera held in portrait. Everything else works in landscape.")
                                    .font(.body).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center).frame(maxWidth: 460)
                            }
                            .padding()
                        }
                    }
                }
        }
    }
}

extension View {
    /// Covers a camera screen on a landscape iPad with a prompt to turn it upright.
    func cameraNeedsPortrait() -> some View { modifier(CameraNeedsPortrait()) }
}
