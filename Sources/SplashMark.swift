// Ported from incoai/splash app/Sources/Splash/Mark.swift (Apache-2.0) so the
// menu bar icon matches the Splash app's own.

import AppKit
import SwiftUI

/// Splash's mark, as the app icon draws it (app/AppIcon.icon/Assets/mark.svg): three arcs of water
/// springing from one point of a rippled surface, two thrown to the right and one to the left, each
/// throwing a drop. `spread` is how far the splash has risen, from 0, the surface alone, to 1, the
/// icon's pose; the mark keeps its place and size at every spread.
struct SplashMark: Shape {
    var spread = 1.0

    var animatableData: Double {
        get { spread }
        set { spread = newValue }
    }

    // On the icon's 1024-point canvas, drawn in strokes 76 points wide with round ends.
    private static let surface = Path { path in
        path.move(to: CGPoint(x: 200, y: 717.2))
        path.addCurve(to: CGPoint(x: 398, y: 717.2), control1: CGPoint(x: 270, y: 699.2), control2: CGPoint(x: 340, y: 699.2))
        path.addCurve(to: CGPoint(x: 606, y: 717.2), control1: CGPoint(x: 444, y: 733.2), control2: CGPoint(x: 560, y: 733.2))
        path.addCurve(to: CGPoint(x: 824, y: 717.2), control1: CGPoint(x: 670, y: 699.2), control2: CGPoint(x: 744, y: 699.2))
    }

    /// Each arc, from its root in the surface, and the drop it throws.
    private static let arcs: [(arc: Path, drop: CGPoint, radius: CGFloat)] = [
        (arc(CGPoint(x: 502, y: 711.2), CGPoint(x: 500, y: 593.2), CGPoint(x: 534, y: 471.2), CGPoint(x: 604, y: 399.2)),
         CGPoint(x: 684.3, y: 312.8), 36),
        (arc(CGPoint(x: 516, y: 711.2), CGPoint(x: 544, y: 633.2), CGPoint(x: 606, y: 567.2), CGPoint(x: 700, y: 547.2)),
         CGPoint(x: 805.2, y: 522.6), 30),
        (arc(CGPoint(x: 490, y: 711.2), CGPoint(x: 466, y: 653.2), CGPoint(x: 424, y: 621.2), CGPoint(x: 364, y: 609.2)),
         CGPoint(x: 267.2, y: 588.4), 25),
    ]

    /// The icon's pose, by which the mark is placed.
    private static let bounds = CGRect(x: 162, y: 276.8, width: 700, height: 490.4)

    private static func arc(_ root: CGPoint, _ control1: CGPoint, _ control2: CGPoint, _ end: CGPoint) -> Path {
        Path { path in
            path.move(to: root)
            path.addCurve(to: end, control1: control1, control2: control2)
        }
    }

    func path(in rect: CGRect) -> Path {
        let stroke = StrokeStyle(lineWidth: 76, lineCap: .round)
        var mark = Self.surface.strokedPath(stroke)
        // The drops come as the arcs reach their full height.
        let drop = min(max((spread - 0.75) / 0.25, 0), 1)
        for (arc, center, radius) in Self.arcs {
            mark = mark.union(arc.trimmedPath(from: 0, to: spread).strokedPath(stroke))
            if drop > 0 {
                let r = radius * drop
                mark = mark.union(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)))
            }
        }
        // Placed as the icon's pose fits rect, centred.
        let bounds = Self.bounds
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        return mark.applying(CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
    }

    /// The mark as the menu bar shows the app: in the menu bar's own color, faint until a model
    /// serves.
    static func menuBarImage(serving: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: true) { rect in
            NSColor.black.withAlphaComponent(serving ? 1 : 0.45).setFill()
            NSBezierPath(cgPath: SplashMark().path(in: rect.insetBy(dx: 1, dy: 1)).cgPath).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
