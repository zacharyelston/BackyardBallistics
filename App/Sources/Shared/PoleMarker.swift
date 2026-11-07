import SwiftUI
import RangingKit

/// A frozen photo with a tip/base marker and a magnifying loupe for pixel-level nudging.
struct PoleMarker: View {
    enum Target: String, CaseIterable { case tip = "Tip", base = "Base" }

    let frame: FrozenFrame
    @Binding var tip: CGPoint?
    @Binding var base: CGPoint?
    var photoHeight: CGFloat = 360

    @State private var target: Target = .tip
    @State private var dragStart: CGPoint?

    private let loupeSource: CGFloat = 64   // image pixels shown in the loupe
    private let loupeSize: CGFloat = 220    // points on screen

    private var imageSize: CGSize { CGSize(width: frame.image.width, height: frame.image.height) }
    private var current: CGPoint? { target == .tip ? tip : base }

    var body: some View {
        VStack(spacing: 12) {
            photo
            Picker("Marking", selection: $target) {
                ForEach(Target.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            loupe
        }
    }

    // Tap anywhere on the photo to drop the active marker.
    private var photo: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / imageSize.width, geo.size.height / imageSize.height)
            let shown = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let origin = CGPoint(x: (geo.size.width - shown.width) / 2, y: (geo.size.height - shown.height) / 2)
            ZStack(alignment: .topLeading) {
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    .frame(width: shown.width, height: shown.height)
                    .offset(x: origin.x, y: origin.y)
                if let p = tip { marker(p, .orange, origin, scale) }
                if let p = base { marker(p, .cyan, origin, scale) }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { loc in
                let p = CGPoint(x: (loc.x - origin.x) / scale, y: (loc.y - origin.y) / scale)
                guard p.x >= 0, p.y >= 0, p.x < imageSize.width, p.y < imageSize.height else { return }
                set(p)
                if target == .tip && base == nil { target = .base }
            }
        }
        .frame(height: photoHeight)
    }

    private func marker(_ p: CGPoint, _ color: Color, _ origin: CGPoint, _ scale: CGFloat) -> some View {
        Circle().stroke(color, lineWidth: 2).frame(width: 14, height: 14)
            .position(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
    }

    // Magnified view of the active marker; drag to nudge it a pixel at a time.
    @ViewBuilder private var loupe: some View {
        if let p = current, let crop = crop(around: p) {
            ZStack {
                Image(decorative: crop.image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: loupeSize, height: loupeSize)
                Path { path in
                    let c = CGPoint(x: (p.x - crop.origin.x) / loupeSource * loupeSize,
                                    y: (p.y - crop.origin.y) / loupeSource * loupeSize)
                    path.move(to: CGPoint(x: c.x - 14, y: c.y)); path.addLine(to: CGPoint(x: c.x + 14, y: c.y))
                    path.move(to: CGPoint(x: c.x, y: c.y - 14)); path.addLine(to: CGPoint(x: c.x, y: c.y + 14))
                }
                .stroke(target == .tip ? Color.orange : Color.cyan, lineWidth: 1.5)
            }
            .frame(width: loupeSize, height: loupeSize)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStart == nil { dragStart = p }
                    let k = loupeSource / loupeSize / 2 // half speed for fine control
                    if let s = dragStart {
                        set(CGPoint(x: (s.x + g.translation.width * k).rounded(), y: (s.y + g.translation.height * k).rounded()))
                    }
                }
                .onEnded { _ in dragStart = nil })
            Text(String(format: "%@ at (%.0f, %.0f). Drag in the loupe to nudge.", target.rawValue, p.x, p.y))
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            Text("Tap the \(target.rawValue.lowercased()) of the pole in the photo.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func set(_ p: CGPoint) {
        let clamped = CGPoint(x: min(max(p.x, 0), imageSize.width - 1), y: min(max(p.y, 0), imageSize.height - 1))
        if target == .tip { tip = clamped } else { base = clamped }
    }

    private func crop(around p: CGPoint) -> (image: CGImage, origin: CGPoint)? {
        let half = loupeSource / 2
        let x = min(max(p.x - half, 0), imageSize.width - loupeSource)
        let y = min(max(p.y - half, 0), imageSize.height - loupeSource)
        let rect = CGRect(x: x.rounded(.down), y: y.rounded(.down), width: loupeSource, height: loupeSource)
        guard let img = frame.image.cropping(to: rect) else { return nil }
        return (img, rect.origin)
    }
}
