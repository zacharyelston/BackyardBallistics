import SwiftUI

/// Controls that sit on the camera feed while ranging or spotting, so nothing needs scrolling with
/// the phone held up. The middle of the view stays clear for the crosshair and the pole.

/// A square button for the side columns: an icon over a short caption.
struct HUDButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.title2.weight(.semibold))
                Text(title).font(.caption2.weight(.semibold))
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.75)
            }
            .frame(width: 70, height: 64)
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.ultraThinMaterial))
            }
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }
}

/// A frosted panel for readouts on the feed.
struct HUDPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// A vertical thumbwheel for the range dial. Drag up for farther, down for nearer; the scale is
/// logarithmic (a fixed drag doubles the range), because the plumb line's length goes as 1 / range,
/// so the wheel feels the same at 10 m and at 80 m. The buttons step 0.1 m for the fine match.
struct RangeThumbwheel: View {
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    /// Drag, in points, that doubles the range.
    var doublingPoints: CGFloat = 240

    @State private var dragStart: Double?
    @Environment(\.isEnabled) private var isEnabled

    private var k: CGFloat { doublingPoints / log(2) }

    var body: some View {
        VStack(spacing: 8) {
            step(+0.1, "plus", "Range up 0.1 m")
            wheel.frame(width: 56).frame(maxHeight: 260)
            step(-0.1, "minus", "Range down 0.1 m")
        }
        .opacity(isEnabled ? 1 : 0.4)
        .sensoryFeedback(.selection, trigger: Int(value))
    }

    private func step(_ by: Double, _ icon: String, _ label: String) -> some View {
        Button { set(value + by) } label: {
            Image(systemName: icon).font(.title3.weight(.bold)).foregroundStyle(.white)
                .frame(width: 56, height: 48)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
    }

    private var wheel: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            let lo = max(bounds.lowerBound, value * exp(-Double(mid / k)))
            let hi = min(bounds.upperBound, value * exp(Double(mid / k)))
            var m = floor(lo)
            while m <= ceil(hi) {
                defer { m += 1 }
                guard m >= bounds.lowerBound, m > 0 else { continue }
                // Nearer marks above the middle, farther below: they move with the finger.
                let y = mid + CGFloat(log(m / value)) * k
                guard y > 4, y < size.height - 4 else { continue }
                let major = Int(m) % 10 == 0, mid5 = Int(m) % 5 == 0
                let w: CGFloat = major ? 26 : mid5 ? 18 : 10
                var p = Path()
                p.move(to: CGPoint(x: size.width - 8 - w, y: y))
                p.addLine(to: CGPoint(x: size.width - 8, y: y))
                ctx.stroke(p, with: .color(.white.opacity(major ? 0.95 : 0.6)), lineWidth: major ? 2 : 1)
                if major {
                    ctx.draw(Text("\(Int(m))").font(.caption2.weight(.semibold)).foregroundStyle(.white),
                             at: CGPoint(x: 12, y: y), anchor: .center)
                }
            }
            var cursor = Path()
            cursor.move(to: CGPoint(x: 0, y: mid))
            cursor.addLine(to: CGPoint(x: size.width, y: mid))
            ctx.stroke(cursor, with: .color(.orange), lineWidth: 2)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                let start = dragStart ?? value
                dragStart = start
                set(start * exp(Double(-g.translation.height / k)))
            }
            .onEnded { _ in dragStart = nil })
        .accessibilityElement()
        .accessibilityLabel("Range dial")
        .accessibilityValue(String(format: "%.1f metres", value))
        .accessibilityAdjustableAction { dir in set(value + (dir == .increment ? 1 : -1)) }
    }

    private func set(_ v: Double) {
        value = min(bounds.upperBound, max(bounds.lowerBound, (v * 10).rounded() / 10))
    }
}
