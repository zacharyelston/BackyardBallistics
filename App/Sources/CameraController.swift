import AVFoundation
import CoreImage
import SwiftUI
import UIKit
import RangingKit

/// A still frame captured for marking, with the intrinsics of the buffer it came from.
struct FrozenFrame {
    /// Upright (portrait) image for display and marking.
    let image: CGImage
    let intrinsics: Intrinsics
    let lens: String
    let approximateIntrinsics: Bool

    /// Converts a point in the upright image to the camera's native (landscape) buffer pixel.
    /// The buffer is rotated 90° clockwise for display, so x comes from the displayed y.
    func bufferPoint(_ p: CGPoint) -> (x: Double, y: Double) {
        (Double(p.y), Double(intrinsics.height) - 1 - Double(p.x))
    }
}

/// Runs a back-camera session on a chosen physical lens and keeps the latest frame plus
/// its intrinsic matrix, so a tap on a still can be turned into a true viewing angle.
final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Lens: Identifiable, Hashable {
        let id: String
        let name: String
        let device: AVCaptureDevice
    }

    @Published private(set) var lenses: [Lens] = []
    @Published private(set) var selected: Lens?
    @Published private(set) var status = ""
    @Published private(set) var intrinsicsDelivered = false

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.frames")
    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var latestMatrix: simd_float3x3?
    private let ciContext = CIContext()

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else { self.status = "Camera access is off. Turn it on in Settings to run the sighting test."; return }
                self.discover()
            }
        }
    }

    func stop() {
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    private func discover() {
        let types: [AVCaptureDevice.DeviceType] = [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        lenses = found.map { d in
            let name: String
            switch d.deviceType {
            case .builtInUltraWideCamera: name = "0.5×"
            case .builtInTelephotoCamera: name = "Telephoto"
            default: name = "1×"
            }
            return Lens(id: d.uniqueID, name: name, device: d)
        }
        if let wide = lenses.first(where: { $0.name == "1×" }) ?? lenses.first { select(wide) }
        else { status = "No back camera found." }
    }

    func select(_ lens: Lens) {
        selected = lens
        queue.async { [weak self] in self?.configure(lens.device) }
    }

    private func configure(_ device: AVCaptureDevice) {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if session.canSetSessionPreset(.hd4K3840x2160) { session.sessionPreset = .hd4K3840x2160 }
        else { session.sessionPreset = .high }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.status = "Couldn't open that lens." }
            return
        }
        session.addInput(input)
        if session.outputs.isEmpty, session.canAddOutput(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(output)
        }
        var delivered = false
        if let connection = output.connection(with: .video) {
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
            if connection.isCameraIntrinsicMatrixDeliverySupported {
                connection.isCameraIntrinsicMatrixDeliveryEnabled = true
                delivered = true
            }
        }
        try? device.lockForConfiguration()
        device.videoZoomFactor = 1 // intrinsics are only valid unzoomed
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        device.unlockForConfiguration()
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
        DispatchQueue.main.async {
            self.intrinsicsDelivered = delivered
            self.status = delivered ? "" : "This lens doesn't report calibration; ranges use an estimate from its field of view."
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var matrix: simd_float3x3?
        if let data = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                      attachmentModeOut: nil) as? Data {
            matrix = data.withUnsafeBytes { $0.load(as: simd_float3x3.self) }
        }
        lock.lock()
        latestBuffer = buffer
        latestMatrix = matrix
        lock.unlock()
    }

    /// Grabs the most recent frame for marking.
    func freeze() -> FrozenFrame? {
        lock.lock()
        let buffer = latestBuffer
        let matrix = latestMatrix
        lock.unlock()
        guard let buffer, let lens = selected else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let upright = CIImage(cvPixelBuffer: buffer).oriented(.right)
        guard let cg = ciContext.createCGImage(upright, from: upright.extent) else { return nil }
        let intrinsics: Intrinsics
        let approximate: Bool
        if let matrix {
            intrinsics = Intrinsics(matrix: matrix, width: w, height: h)
            approximate = false
        } else {
            intrinsics = Intrinsics(horizontalFOVDegrees: Double(lens.device.activeFormat.videoFieldOfView), width: w, height: h)
            approximate = true
        }
        return FrozenFrame(image: cg, intrinsics: intrinsics, lens: lens.name, approximateIntrinsics: approximate)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
