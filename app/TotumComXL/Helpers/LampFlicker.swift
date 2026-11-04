import AppKit

/// A lamp coming on: a couple of uneven flickers and then steady.
///
/// Written for the quick filter's plate — a control that simply materialises beside the text
/// goes unnoticed, and the flicker is what makes the eye look — and used by everything else
/// that has to announce itself the same way.
enum LampFlicker {

    /// Lamps in one window are never wired to the same switch: each has its own rhythm and
    /// starts a beat after the one above, so they come on as separate lamps rather than as one
    /// block that fades in.
    static let patterns: [(values: [CGFloat], keyTimes: [NSNumber],
                           duration: CFTimeInterval, delay: CFTimeInterval)] = [
        (values: [0.05, 1.0, 0.10, 1.0, 0.45, 1.0],
         keyTimes: [0, 0.10, 0.20, 0.36, 0.52, 1], duration: 0.46, delay: 0),
        (values: [0.05, 0.85, 0.05, 1.0, 0.25, 0.9, 1.0],
         keyTimes: [0, 0.16, 0.26, 0.44, 0.58, 0.74, 1], duration: 0.62, delay: 0.09),
        (values: [0.05, 1.0, 0.30, 0.7, 0.05, 1.0],
         keyTimes: [0, 0.08, 0.30, 0.44, 0.60, 1], duration: 0.54, delay: 0.19),
        (values: [0.05, 0.6, 0.05, 0.9, 0.2, 1.0],
         keyTimes: [0, 0.14, 0.30, 0.50, 0.66, 1], duration: 0.58, delay: 0.28),
    ]

    /// Light `layer` as lamp number `index` — the number only picks the rhythm, so any number
    /// works and neighbours given different ones blink out of step, as real ones do.
    static func light(_ layer: CALayer, pattern index: Int) {
        let p = patterns[abs(index) % patterns.count]
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = p.values
        animation.keyTimes = p.keyTimes
        animation.duration = p.duration
        animation.beginTime = CACurrentMediaTime() + p.delay
        // Held at the first value until its turn comes, or the lamp would sit lit and then
        // start blinking, which reads as a fault rather than as switching on.
        animation.fillMode = .backwards
        animation.isRemovedOnCompletion = true
        layer.add(animation, forKey: "flicker")
    }
}
