import AppKit

/// Shift + a two-finger swipe on the trackpad: fingers to the LEFT go up a folder, fingers to
/// the RIGHT go back in — forward in the history, or into the folder under the cursor, which
/// right after going up is the one just left.
///
/// Shift on purpose: a bare two-finger swipe is horizontal scrolling in the detailed list and
/// "swipe between pages" for the system, and neither should start moving between folders.
/// The gesture is read from the scroll events the trackpad sends with phases: summed from
/// `began` to `ended`, judged once at the end, and momentum after it is ignored.
struct SwipeNavigator {
    enum Direction: Equatable { case up, into }

    /// How far the fingers must travel, in points, before it counts as a swipe.
    static let threshold: CGFloat = 40

    private var active = false
    private var sumX: CGFloat = 0
    private var sumY: CGFloat = 0

    /// The fingers' own motion along X (positive — to the right), whatever the scrolling
    /// direction setting. With "natural" scrolling the deltas already follow the fingers;
    /// without it they follow the old wheel and are turned around here.
    static func fingerMotion(deltaX: CGFloat, invertedFromDevice: Bool) -> CGFloat {
        invertedFromDevice ? deltaX : -deltaX
    }

    /// Feed one scroll event. Answers a direction at the END of a gesture that travelled far
    /// enough and mostly sideways; nil otherwise.
    mutating func feed(phase: NSEvent.Phase, fingerX: CGFloat, fingerY: CGFloat) -> Direction? {
        switch phase {
        case .began:
            active = true
            sumX = fingerX
            sumY = fingerY
            return nil
        case .changed:
            guard active else { return nil }
            sumX += fingerX
            sumY += fingerY
            return nil
        case .ended:
            guard active else { return nil }
            active = false
            defer { sumX = 0; sumY = 0 }
            guard abs(sumX) >= Self.threshold, abs(sumX) > abs(sumY) else { return nil }
            return sumX < 0 ? .up : .into
        case .cancelled:
            active = false
            sumX = 0
            sumY = 0
            return nil
        default:
            return nil
        }
    }

    var isActive: Bool { active }
}
