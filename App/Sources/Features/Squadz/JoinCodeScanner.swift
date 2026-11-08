import SwiftUI
import VisionKit
import GroupLink

/// Reads the join code from the QR code on the commander's iPad, with VisionKit's live scanner.
/// The QR's payload is the code itself; anything that doesn't look like a code is ignored.
struct JoinCodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    /// Live scanning needs a recent iPhone (A12 or later) and camera access.
    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    /// The code in a QR payload, if it holds one: six characters from the join-code alphabet.
    static func code(in payload: String) -> String? {
        let c = JoinCode.normalized(payload)
        let allowed = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        return c.count == 6 && c.allSatisfy(allowed.contains) ? c : nil
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case let .barcode(b) = item, let payload = b.payloadStringValue, let code = JoinCodeScanner.code(in: payload) {
                    done = true
                    scanner.stopScanning()
                    onCode(code)
                    return
                }
            }
        }
    }
}

/// The scanner, full screen, with a way out.
struct JoinCodeScanSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            JoinCodeScanner { code in
                onCode(code)
                dismiss()
            }
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                Text("Point the camera at the QR code on the commander's iPad.")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 32)
            }
            .navigationTitle("Scan the join code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
