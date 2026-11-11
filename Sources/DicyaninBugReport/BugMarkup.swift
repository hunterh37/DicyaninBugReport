import SwiftUI
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// One freehand stroke. Points are normalized to the image (0...1) so the markup
/// scales with the preview and flattens at full pixel resolution.
struct MarkupStroke: Identifiable, Equatable {
    let id = UUID()
    var points: [CGPoint]
    var color: Color
}

enum MarkupPalette {
    static let colors: [Color] = [
        Color(red: 1.0, green: 0.19, blue: 0.19),
        Color(red: 1.0, green: 0.80, blue: 0.0),
        Color(red: 0.20, green: 0.84, blue: 0.29),
        Color(red: 0.04, green: 0.52, blue: 1.0),
        .white,
        .black,
    ]
    /// Default stroke width in screen points.
    static let width: CGFloat = 10
}

/// Midpoint-smoothed path through the points. Single taps draw a dot.
func markupPath(_ pts: [CGPoint], in size: CGSize) -> Path {
    var p = Path()
    guard let first = pts.first else { return p }
    func s(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x * size.width, y: q.y * size.height) }
    let a = s(first)
    p.move(to: a)
    if pts.count == 1 { p.addLine(to: CGPoint(x: a.x + 0.01, y: a.y)); return p }
    if pts.count == 2 { p.addLine(to: s(pts[1])); return p }
    for i in 1..<(pts.count - 1) {
        let c = s(pts[i]), n = s(pts[i + 1])
        p.addQuadCurve(to: CGPoint(x: (c.x + n.x) / 2, y: (c.y + n.y) / 2), control: c)
    }
    p.addLine(to: s(pts[pts.count - 1]))
    return p
}

struct MarkupLayer: View {
    var strokes: [MarkupStroke]
    var live: MarkupStroke?
    /// Stroke width as a fraction of image width.
    var widthFraction: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let style = StrokeStyle(lineWidth: widthFraction * size.width, lineCap: .round, lineJoin: .round)
            for s in strokes + (live.map { [$0] } ?? []) {
                ctx.stroke(markupPath(s.points, in: size), with: .color(s.color), style: style)
            }
        }
        .allowsHitTesting(false)
    }
}

enum BugMarkup {
    static func pixelSize(_ data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    @MainActor static var displayScale: CGFloat {
        #if canImport(UIKit)
        return UITraitCollection.current.displayScale
        #else
        return 2
        #endif
    }

    @MainActor static func widthFraction(pixelWidth: CGFloat) -> CGFloat {
        MarkupPalette.width * displayScale / max(pixelWidth, 1)
    }

    /// Flattens the strokes onto the screenshot at full pixel size.
    @MainActor static func flatten(_ data: Data, strokes: [MarkupStroke]) -> Data? {
        guard !strokes.isEmpty, let size = pixelSize(data), let base = image(data) else { return nil }
        let frac = widthFraction(pixelWidth: size.width)
        let content = ZStack {
            base.resizable().frame(width: size.width, height: size.height)
            MarkupLayer(strokes: strokes, live: nil, widthFraction: frac)
        }
        .frame(width: size.width, height: size.height)
        let r = ImageRenderer(content: content)
        r.scale = 1
        guard let cg = r.cgImage else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

/// Screenshot with direct freehand markup, color row and undo.
struct MarkupEditor: View {
    var png: Data
    @Binding var strokes: [MarkupStroke]
    @State private var live: MarkupStroke?
    @State private var color = MarkupPalette.colors[0]
    @State private var drawing = false

    var body: some View {
        let px = BugMarkup.pixelSize(png) ?? CGSize(width: 9, height: 16)
        let frac = BugMarkup.widthFraction(pixelWidth: px.width)
        VStack(spacing: 12) {
            if let img = image(png) {
                img.resizable().scaledToFit()
                    .overlay {
                        GeometryReader { geo in
                            MarkupLayer(strokes: strokes, live: live, widthFraction: frac)
                                .contentShape(Rectangle())
                                .gesture(draw(in: geo.size))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            toolbar
        }
        .interactiveDismissDisabled(drawing)
    }

    private func draw(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                let p = CGPoint(x: min(max(v.location.x / max(size.width, 1), 0), 1),
                                y: min(max(v.location.y / max(size.height, 1), 0), 1))
                if live == nil {
                    drawing = true
                    live = MarkupStroke(points: [p], color: color)
                    tick(.soft)
                } else if let last = live?.points.last, hypot((p.x - last.x) * size.width, (p.y - last.y) * size.height) >= 1.5 {
                    live?.points.append(p)
                }
            }
            .onEnded { _ in
                if let s = live { withAnimation(nil) { strokes.append(s) } }
                live = nil
                drawing = false
            }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            ForEach(Array(MarkupPalette.colors.enumerated()), id: \.offset) { _, c in
                let on = c == color
                Circle().fill(c)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(.white.opacity(c == .black ? 0.35 : 0.15), lineWidth: 1))
                    .padding(3)
                    .overlay(Circle().stroke(.white, lineWidth: 2).opacity(on ? 1 : 0))
                    .scaleEffect(on ? 1.12 : 1)
                    .animation(.spring(response: 0.28, dampingFraction: 0.65), value: on)
                    .onTapGesture { color = c; tick(.selection) }
                    .accessibilityLabel("Pen color")
                    .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
            Button {
                guard !strokes.isEmpty else { return }
                _ = withAnimation(.snappy(duration: 0.18)) { strokes.removeLast() }
                tick(.soft)
            } label: {
                Image(systemName: "arrow.uturn.backward").font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .disabled(strokes.isEmpty)
            .opacity(strokes.isEmpty ? 0.3 : 1)
            .accessibilityLabel("Undo")
        }
        .padding(.horizontal, 4)
    }

    private enum Tick { case soft, selection }
    private func tick(_ t: Tick) {
        #if canImport(UIKit) && !os(visionOS)
        switch t {
        case .soft: UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        }
        #endif
    }
}
