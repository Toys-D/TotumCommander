import AppKit
import QuartzCore
import SwiftUI

/// The mark of a picture made by a neural network: three four-pointed stars with colour flowing
/// through them, twinkling one after another.
///
/// Drawn as layers, not as a symbol: Core Animation keeps a layer's animation running in the
/// window server, so it goes on inside an open menu, whose tracking loop starves everything
/// else on the main thread. The stars are vector paths, sharp at any size the menu settings
/// give the icon.
///
/// With "Reduce motion" on in System Settings the stars stand still — the colour stays.
final class AISparkleView: NSView {

    private let colourLayer = CAGradientLayer()
    private let stars = CALayer()
    private var starLayers: [CAShapeLayer] = []
    private var highlightColor: NSColor?

    /// Cyan, violet, pink, warm orange — in this order, so that every two colours that meet
    /// blend into something clean (orange next to cyan would make mud). Darker in the light
    /// theme, brighter in the dark one, so the stars read on both menu backgrounds.
    private static let palette: [NSColor] = [
        (0x0891B2, 0x22D3EE), (0x7C3AED, 0xA78BFA), (0xDB2777, 0xF472B6), (0xEA580C, 0xFB923C),
    ].map { light, dark in
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }

    /// Where the stars sit in a unit square, and how large: the big one low and left, a small
    /// one up right, a tiny one up left.
    private static let layout: [(x: CGFloat, y: CGFloat, radius: CGFloat)] = [
        (0.42, 0.42, 0.42), (0.80, 0.79, 0.21), (0.17, 0.85, 0.14),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(colourLayer)
        colourLayer.mask = stars
        colourLayer.startPoint = CGPoint(x: 0, y: 0)
        colourLayer.endPoint = CGPoint(x: 1, y: 1)
        for _ in Self.layout {
            let star = CAShapeLayer()
            star.fillColor = NSColor.black.cgColor
            stars.addSublayer(star)
            starLayers.append(star)
        }
        layoutStars()
        applyColours()
        animate()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layoutStars()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColours()
    }

    /// On a highlighted row the colours give way to the row's own text colour — a violet star
    /// on an accent-coloured bar would be lost. The twinkle stays.
    func setHighlightColor(_ color: NSColor?) {
        guard color != highlightColor else { return }
        highlightColor = color
        applyColours()
    }

    private func layoutStars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colourLayer.frame = bounds
        stars.frame = bounds
        let side = min(bounds.width, bounds.height)
        for (star, place) in zip(starLayers, Self.layout) {
            let radius = place.radius * side
            star.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            star.position = CGPoint(x: place.x * side, y: place.y * side)
            star.path = Self.starPath(radius: radius)
        }
        CATransaction.commit()
    }

    /// A four-pointed star whose sides curve in towards the middle — the sparkle shape.
    static func starPath(radius r: CGFloat) -> CGPath {
        let c = CGPoint(x: r, y: r)
        let pinch = r * 0.16
        let path = CGMutablePath()
        path.move(to: CGPoint(x: c.x, y: c.y + r))
        path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + pinch, y: c.y + pinch))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + pinch, y: c.y - pinch))
        path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - pinch, y: c.y - pinch))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - pinch, y: c.y + pinch))
        path.closeSubpath()
        return path
    }

    private var resolvedPalette: [CGColor] {
        var colours: [CGColor] = []
        effectiveAppearance.performAsCurrentDrawingAppearance {
            colours = Self.palette.map { $0.cgColor }
        }
        return colours
    }

    private func applyColours() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colourLayer.removeAnimation(forKey: "flow")
        if let highlightColor {
            var plain = NSColor.white.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance { plain = highlightColor.cgColor }
            colourLayer.colors = [plain, plain]
        } else {
            colourLayer.colors = resolvedPalette
            if !Self.reduceMotion {
                // The gradient turns round its middle: the colours sweep across the stars
                // and come back, never meeting a neighbour they would muddy.
                let turns = stride(from: 0.0, through: 2 * Double.pi, by: Double.pi / 8).map {
                    (CGFloat(cos($0)) * 0.5, CGFloat(sin($0)) * 0.5)
                }
                let start = CAKeyframeAnimation(keyPath: "startPoint")
                start.values = turns.map { CGPoint(x: 0.5 - $0.0, y: 0.5 - $0.1) }
                let end = CAKeyframeAnimation(keyPath: "endPoint")
                end.values = turns.map { CGPoint(x: 0.5 + $0.0, y: 0.5 + $0.1) }
                let flow = CAAnimationGroup()
                flow.animations = [start, end]
                flow.duration = 5.0
                flow.repeatCount = .infinity
                colourLayer.add(flow, forKey: "flow")
            }
        }
        CATransaction.commit()
    }

    /// Each star breathes on its own beat, so they never twinkle together.
    private func animate() {
        guard !Self.reduceMotion else { return }
        let beats: [(duration: Double, low: CGFloat, delay: Double)] = [
            (2.4, 0.84, 0.0), (1.6, 0.45, 0.5), (1.9, 0.35, 1.1),
        ]
        for (star, beat) in zip(starLayers, beats) {
            let twinkle = CAKeyframeAnimation(keyPath: "transform.scale")
            twinkle.values = [1.0, beat.low, 1.0]
            twinkle.keyTimes = [0, 0.5, 1]
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1.0, beat.low < 0.5 ? 0.35 : 0.9, 1.0]
            fade.keyTimes = [0, 0.5, 1]
            let group = CAAnimationGroup()
            group.animations = [twinkle, fade]
            group.duration = beat.duration
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.beginTime = CACurrentMediaTime() + beat.delay
            group.fillMode = .backwards
            star.add(group, forKey: "twinkle")
        }
        // The big star turns a little, back and forth.
        let sway = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        sway.values = [0, 0.14, 0, -0.14, 0]
        sway.duration = 4.8
        sway.repeatCount = .infinity
        sway.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
        starLayers.first?.add(sway, forKey: "sway")
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// The same mark in SwiftUI — for the viewer's header and the panel's own popup menu.
struct AISparkleIcon: NSViewRepresentable {
    /// The row's text colour while it is highlighted; nil for the mark's own colours.
    var highlight: NSColor?

    func makeNSView(context: Context) -> AISparkleView { AISparkleView(frame: .zero) }
    func updateNSView(_ view: AISparkleView, context: Context) { view.setHighlightColor(highlight) }
}
