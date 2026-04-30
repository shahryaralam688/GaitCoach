import SwiftUI

/// Fits planar meter coordinates into view rect; draws polyline (screen Y flipped).
struct PlanarTraceMiniMap: View {
    let points: [PlanarTrackPoint]

    private let insetPad: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard points.count >= 2 else { return }

                let xs = points.map(\.xM)
                let ys = points.map(\.yM)
                guard let minX = xs.min(), let maxX = xs.max(),
                      let minY = ys.min(), let maxY = ys.max() else { return }

                let spanX = max(maxX - minX, 0.35)
                let spanY = max(maxY - minY, 0.35)
                let span = max(spanX, spanY)

                let w = size.width - insetPad * 2
                let h = size.height - insetPad * 2
                guard w > 4, h > 4 else { return }

                func toScreen(_ p: PlanarTrackPoint) -> CGPoint {
                    let nx = (p.xM - minX) / span
                    let ny = (p.yM - minY) / span
                    let sx = insetPad + CGFloat(nx) * w
                    let sy = insetPad + CGFloat(1 - ny) * h
                    return CGPoint(x: sx, y: sy)
                }

                var path = Path()
                path.move(to: toScreen(points[0]))
                for i in 1..<points.count {
                    path.addLine(to: toScreen(points[i]))
                }

                ctx.stroke(path, with: .color(Color(red: 39/255, green: 77/255, blue: 67/255)), lineWidth: 2.5)

                let head = toScreen(points[points.count - 1])
                ctx.fill(
                    Path(ellipseIn: CGRect(x: head.x - 4, y: head.y - 4, width: 8, height: 8)),
                    with: .color(.orange)
                )
            }
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(height: 168)
        .accessibilityLabel("Planar trace map")
    }
}
