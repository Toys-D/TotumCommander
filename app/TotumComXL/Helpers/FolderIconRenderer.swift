import AppKit
import SwiftUI

// MARK: - FolderIconStyle enum

enum FolderIconStyle: String, CaseIterable, Identifiable {
    case macos = "macos"
    case catalogV3 = "catalogV3"
    case catalogV4 = "catalogV4"
    case catalogV5 = "catalogV5"
    case catalogV6 = "catalogV6"
    case catalogV7 = "catalogV7"
    case catalogV8 = "catalogV8"
    case catalogV9 = "catalogV9"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macos: return "macOS"
        case .catalogV3: return L("folderIconStyle.catalogV3")
        case .catalogV4: return L("folderIconStyle.catalogV4")
        case .catalogV5: return L("folderIconStyle.catalogV5")
        case .catalogV6: return L("folderIconStyle.catalogV6")
        case .catalogV7: return L("folderIconStyle.catalogV7")
        case .catalogV8: return L("folderIconStyle.catalogV8")
        case .catalogV9: return L("folderIconStyle.catalogV9")
        }
    }

    static let storageKey = "folderIconStyle"
}

// MARK: - FolderIconRenderer (Canvas → NSImage + cache)

enum FolderIconRenderer {
    private static let lock = NSLock()
    private static var cache: [String: NSImage] = [:]

    /// Returns a cached NSImage for the given folder icon style, size, and tint color.
    @MainActor
    static func image(style: FolderIconStyle, size: CGFloat, tintColor: NSColor?) -> NSImage {
        let tintKey = tintColor.map { PanelAppearanceSettings.hexString(from: $0) } ?? "default"
        let key = "\(style.rawValue)_\(Int(size))_\(tintKey)"

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let rendered = renderCanvas(style: style, size: size, tintColor: tintColor)

        lock.lock()
        cache[key] = rendered
        lock.unlock()

        return rendered
    }

    /// Clear cache when settings change.
    static func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: - macOS system folder icon

    private static let systemFolderIcon = NSWorkspace.shared.icon(for: .folder)

    private static func macosImage(size: CGFloat, tintColor: NSColor?) -> NSImage {
        let s = NSSize(width: size, height: size)
        if let tint = tintColor {
            return PanelAppearanceSettings.tintedImage(systemFolderIcon, tintColor: tint, size: s)
        }
        return PanelAppearanceSettings.scaledImage(systemFolderIcon, size: s)
    }

    // MARK: - Canvas rendering

    @MainActor
    private static func renderCanvas(style: FolderIconStyle, size: CGFloat, tintColor: NSColor?) -> NSImage {
        let baseColor: Color
        if let tint = tintColor {
            baseColor = Color(nsColor: tint)
        } else {
            baseColor = Color(red: 0.42, green: 0.73, blue: 0.95)
        }

        let view = FolderCanvasView(style: style, baseColor: baseColor)
            .frame(width: size, height: size)

        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0

        guard let cgImage = renderer.cgImage else {
            return systemFolderIcon
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}

// MARK: - FolderCanvasView (SwiftUI, used for rendering + Settings preview)

struct FolderCanvasView: View {
    let style: FolderIconStyle
    let baseColor: Color

    var body: some View {
        switch style {
        case .macos:
            Image(systemName: "folder.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(baseColor)
        case .catalogV3:
            Canvas { ctx, size in drawCatalogV3(context: &ctx, size: size, base: baseColor) }.clipped()
        case .catalogV4:
            Canvas { ctx, size in drawCatalogV4(context: &ctx, size: size, base: baseColor) }.clipped()
        case .catalogV5:
            Canvas { ctx, size in drawCatalogV5(context: &ctx, size: size, base: baseColor) }.clipped()
        case .catalogV6:
            Canvas { ctx, size in drawCatalogV6(context: &ctx, size: size, base: baseColor) }.clipped()
        case .catalogV7:
            Canvas { ctx, size in drawCatalogV7(context: &ctx, size: size, base: baseColor) }.clipped()
        case .catalogV8:
            Canvas { ctx, size in drawCatalogV8(context: &ctx, size: size, base: baseColor) }.clipped()
        case .catalogV9:
            Canvas { ctx, size in drawCatalogV9(context: &ctx, size: size, base: baseColor) }.clipped()
        }
    }
}

// MARK: - Drawing functions

private func drawCatalogV3(context: inout GraphicsContext, size: CGSize, base: Color) {
    let w = size.width, h = size.height
    let bodyShade = GraphicsContext.Shading.color(base)
    let darkShade = GraphicsContext.Shading.color(Color.black.opacity(0.27))
    let sx: CGFloat = w / 500, sy: CGFloat = h / 407
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }

    var back = Path()
    back.move(to: p(471.35, 70.23))
    back.addLine(to: p(323.25, 70.23))
    back.addCurve(to: p(250, 24), control1: p(270.01, 70.23), control2: p(285.23, 24))
    back.addLine(to: p(28.68, 24))
    back.addCurve(to: p(0, 52.68), control1: p(12.84, 24), control2: p(0, 36.84))
    back.addLine(to: p(0, 134.31))
    back.addLine(to: p(500, 134.31))
    back.addLine(to: p(500, 98.88))
    back.addCurve(to: p(471.35, 70.23), control1: p(500, 83.05), control2: p(487.16, 70.23))
    back.closeSubpath()

    var front = Path()
    front.move(to: p(500, 160.11))
    front.addLine(to: p(500, 384.57))
    front.addCurve(to: p(471.35, 407), control1: p(500, 396.95), control2: p(487.16, 407))
    front.addLine(to: p(28.68, 407))
    front.addCurve(to: p(0, 384.56), control1: p(12.84, 407), control2: p(0, 396.94))
    front.addLine(to: p(0, 160.11))
    front.addLine(to: p(500, 160.11))
    front.closeSubpath()

    context.fill(back, with: bodyShade)
    context.fill(back, with: darkShade)
    context.fill(front, with: bodyShade)
}

private func drawCatalogV4(context: inout GraphicsContext, size: CGSize, base: Color) {
    let w = size.width, h = size.height
    let bodyShade = GraphicsContext.Shading.color(base)
    let darkShade = GraphicsContext.Shading.color(Color.black.opacity(0.24))
    let paperShade = GraphicsContext.Shading.color(Color.white.opacity(0.92))
    let sx: CGFloat = w / 500, sy: CGFloat = h / 407
    let pixel = 1.0 / max(1.0, NSScreen.main?.backingScaleFactor ?? 2.0)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }

    var back = Path()
    back.move(to: p(442.16, 116.31))
    back.addLine(to: p(442.16, 350.32))
    back.addCurve(to: p(416.85, 375.63), control1: p(442.16, 364.29), control2: p(430.82, 375.63))
    back.addLine(to: p(25.84, 375.63))
    back.addCurve(to: p(0.51, 350.32), control1: p(11.85, 375.63), control2: p(0.51, 364.29))
    back.addLine(to: p(0.51, 56.71))
    back.addCurve(to: p(25.84, 31.38), control1: p(0.51, 42.72), control2: p(11.85, 31.38))
    back.addLine(to: p(93.07, 31.38))
    back.addCurve(to: p(130.44, 47.59), control1: p(107.23, 31.38), control2: p(120.76, 37.26))
    back.addLine(to: p(155.93, 74.79))
    back.addCurve(to: p(193.28, 91), control1: p(165.61, 85.12), control2: p(179.13, 91))
    back.addLine(to: p(416.86, 91))
    back.addCurve(to: p(442.16, 116.31), control1: p(430.83, 91), control2: p(442.16, 102.32))
    back.closeSubpath()

    var paper = Path()
    paper.addRoundedRect(
        in: CGRect(x: 36.1 * sx, y: 72.07 * sy, width: 370.46 * sx, height: 262.85 * sy),
        cornerSize: CGSize(width: 34.67 * sx, height: 34.67 * sy), style: .continuous
    )

    var front = Path()
    front.move(to: p(499.25, 139.81))
    front.addLine(to: p(448.66, 349.86))
    front.addCurve(to: p(417.14, 375.63), control1: p(445.24, 364.08), control2: p(431.11, 375.63))
    front.addLine(to: p(26.13, 375.63))
    front.addCurve(to: p(7.01, 349.86), control1: p(12.14, 375.63), control2: p(3.58, 364.08))
    front.addLine(to: p(57.60, 139.81))
    front.addCurve(to: p(89.14, 114.04), control1: p(61.02, 125.59), control2: p(75.15, 114.04))
    front.addLine(to: p(480.16, 114.04))
    front.addCurve(to: p(499.25, 139.81), control1: p(494.13, 114.04), control2: p(502.69, 125.59))
    front.closeSubpath()

    context.fill(back, with: bodyShade)
    context.fill(back, with: darkShade)
    context.fill(paper, with: paperShade)
    context.fill(front, with: bodyShade)
    let edge = Path(CGRect(x: 0, y: h - pixel, width: w, height: pixel))
    context.fill(edge, with: GraphicsContext.Shading.color(Color.black.opacity(0.10)))
}

private func drawCatalogV5(context: inout GraphicsContext, size: CGSize, base: Color) {
    let w = size.width, h = size.height
    let bodyShade = GraphicsContext.Shading.color(base)
    let darkShade = GraphicsContext.Shading.color(Color.black.opacity(0.25))
    let paperShade = GraphicsContext.Shading.color(Color.white.opacity(0.92))
    let sx: CGFloat = w / 500, sy: CGFloat = h / 407
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }

    var back = Path()
    back.move(to: p(500, 134.19))
    back.addLine(to: p(500, 380.38))
    back.addCurve(to: p(471.35, 407), control1: p(500, 395.07), control2: p(487.16, 407))
    back.addLine(to: p(28.68, 407))
    back.addCurve(to: p(0, 380.37), control1: p(12.84, 407), control2: p(0, 395.07))
    back.addLine(to: p(0, 71.49))
    back.addCurve(to: p(28.68, 44.84), control1: p(0, 56.77), control2: p(12.84, 44.84))
    back.addLine(to: p(104.79, 44.84))
    back.addCurve(to: p(147.1, 61.9), control1: p(120.83, 44.84), control2: p(136.14, 51.03))
    back.addLine(to: p(175.96, 90.51))
    back.addCurve(to: p(218.24, 107.56), control1: p(186.91, 101.38), control2: p(202.23, 107.56))
    back.addLine(to: p(471.36, 107.56))
    back.addCurve(to: p(500, 134.19), control1: p(487.17, 107.56), control2: p(500, 119.47))
    back.closeSubpath()

    var paper = Path()
    paper.addRoundedRect(
        in: CGRect(x: 40.3 * sx, y: 78.25 * sy, width: 419.4 * sx, height: 307.88 * sy),
        cornerSize: CGSize(width: 34.67 * sx, height: 34.67 * sy), style: .continuous
    )

    var front = Path()
    front.move(to: p(0, 134.19))
    front.addLine(to: p(0, 380.38))
    front.addCurve(to: p(28.65, 407), control1: p(0, 395.07), control2: p(12.84, 407))
    front.addLine(to: p(471.32, 407))
    front.addCurve(to: p(500, 380.37), control1: p(487.15, 407), control2: p(500, 395.07))
    front.addLine(to: p(500, 71.49))
    front.addCurve(to: p(471.32, 44.84), control1: p(500, 56.78), control2: p(487.16, 44.84))
    front.addLine(to: p(395.21, 44.84))
    front.addCurve(to: p(352.9, 61.9), control1: p(379.17, 44.84), control2: p(363.86, 51.03))
    front.addLine(to: p(324.04, 90.51))
    front.addCurve(to: p(281.76, 107.56), control1: p(313.09, 101.38), control2: p(297.77, 107.56))
    front.addLine(to: p(28.65, 107.56))
    front.addCurve(to: p(0, 134.19), control1: p(12.84, 107.56), control2: p(0, 119.47))
    front.closeSubpath()

    context.fill(back, with: bodyShade)
    context.fill(back, with: darkShade)
    context.fill(paper, with: paperShade)
    context.fill(front, with: bodyShade)
}

private func drawCatalogV6(context: inout GraphicsContext, size: CGSize, base: Color) {
    let w = size.width, h = size.height
    let bodyShade = GraphicsContext.Shading.color(base)
    let darkShade = GraphicsContext.Shading.color(Color.black.opacity(0.22))
    let paperShade = GraphicsContext.Shading.color(Color.white.opacity(0.92))
    let sx: CGFloat = w / 500, sy: CGFloat = h / 407
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }

    var back = Path(); back.move(to: p(259.26, 92.27)); back.addLine(to: p(239.72, 59.34))
    back.addLine(to: p(90.23, 40.11)); back.addLine(to: p(15.45, 353.63))
    back.addLine(to: p(430.43, 407)); back.addLine(to: p(500, 120.12)); back.closeSubpath()

    var shadow2 = Path(); shadow2.move(to: p(138.41, 72.58)); shadow2.addLine(to: p(86.33, 342.59))
    shadow2.addLine(to: p(423.06, 395.03)); shadow2.addLine(to: p(475.15, 125.02)); shadow2.closeSubpath()

    var paper = Path(); paper.move(to: p(430.43, 407)); paper.addLine(to: p(87.98, 348.35))
    paper.addLine(to: p(140.06, 78.34)); paper.addLine(to: p(476.8, 130.78)); paper.closeSubpath()

    var shadow1 = Path(); shadow1.move(to: p(490.63, 158.75)); shadow1.addLine(to: p(445.52, 344.76))
    shadow1.addLine(to: p(430.43, 407)); shadow1.addLine(to: p(475.49, 134.08)); shadow1.closeSubpath()

    var front = Path(); front.move(to: p(414.39, 168.89)); front.addLine(to: p(0, 115.59))
    front.addLine(to: p(15.45, 353.63)); front.addLine(to: p(430.43, 407)); front.closeSubpath()

    context.fill(back, with: bodyShade); context.fill(back, with: darkShade)
    context.fill(shadow2, with: GraphicsContext.Shading.color(Color.black.opacity(0.08)))
    context.fill(paper, with: paperShade)
    context.fill(shadow1, with: GraphicsContext.Shading.color(Color.black.opacity(0.10)))
    context.fill(front, with: bodyShade)
}

private func drawCatalogV7(context: inout GraphicsContext, size: CGSize, base: Color) {
    let w = size.width, h = size.height
    let bodyShade = GraphicsContext.Shading.color(base)
    let darkShade = GraphicsContext.Shading.color(Color.black.opacity(0.22))
    let paperShade = GraphicsContext.Shading.color(Color.white.opacity(0.92))
    let sx: CGFloat = w / 500, sy: CGFloat = h / 407
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }

    var back = Path()
    back.move(to: p(486.17, 65.1)); back.addLine(to: p(155.02, 65.1))
    back.addLine(to: p(134.16, 47.26)); back.addLine(to: p(12.63, 47.26))
    back.addLine(to: p(0, 65.1)); back.addLine(to: p(0, 384.96))
    back.addCurve(to: p(13.83, 396.55), control1: p(0, 391.36), control2: p(6.19, 396.55))
    back.addLine(to: p(486.18, 396.55))
    back.addCurve(to: p(500.01, 384.96), control1: p(493.82, 396.55), control2: p(500.01, 391.36))
    back.addLine(to: p(500.01, 76.68))
    back.addCurve(to: p(486.18, 65.09), control1: p(500.01, 70.28), control2: p(493.82, 65.09))
    back.closeSubpath()

    let paper = Path(CGRect(x: 26.77 * sx, y: 91.99 * sy, width: 446.47 * sx, height: 161.29 * sy))

    var front = Path()
    front.move(to: p(500, 130.37)); front.addLine(to: p(500, 395.79))
    front.addCurve(to: p(486.17, 405.77), control1: p(500, 401.3), control2: p(493.81, 405.77))
    front.addLine(to: p(13.83, 405.77))
    front.addCurve(to: p(0, 395.78), control1: p(6.19, 405.76), control2: p(0, 401.29))
    front.addLine(to: p(0, 138.19)); front.addLine(to: p(137.71, 138.19))
    front.addLine(to: p(156.77, 120.39)); front.addLine(to: p(486.18, 120.39))
    front.addCurve(to: p(500.01, 130.37), control1: p(493.82, 120.39), control2: p(500.01, 124.86))
    front.closeSubpath()

    context.fill(back, with: bodyShade); context.fill(back, with: darkShade)
    context.fill(paper, with: paperShade); context.fill(front, with: bodyShade)
}

private func drawCatalogV8(context: inout GraphicsContext, size: CGSize, base: Color) {
    let w = size.width, h = size.height
    let bodyShade = GraphicsContext.Shading.color(base)
    let darkShade = GraphicsContext.Shading.color(Color.black.opacity(0.22))
    let paperShade = GraphicsContext.Shading.color(Color.white.opacity(0.95))
    let sx: CGFloat = w / 500, sy: CGFloat = h / 407
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }

    var back = Path(); back.move(to: p(25.58, 52.94)); back.addLine(to: p(399.55, 30.85))
    back.addLine(to: p(399.55, 375.14)); back.addLine(to: p(380.19, 373.68))
    back.addLine(to: p(25.58, 352.24)); back.closeSubpath()

    var spine = Path(); spine.move(to: p(460.15, 380.77)); spine.addLine(to: p(395.97, 375.92))
    spine.addLine(to: p(395.97, 30.25)); spine.addLine(to: p(430.22, 28.22))
    spine.addLine(to: p(430.22, 253.1)); spine.addLine(to: p(459.98, 270.1)); spine.closeSubpath()

    var page2 = Path(); page2.move(to: p(399.55, 382.14)); page2.addLine(to: p(25.58, 339.91))
    page2.addLine(to: p(25.58, 66.09)); page2.addLine(to: p(399.55, 22.3)); page2.closeSubpath()

    var page3 = Path(); page3.move(to: p(358.63, 387.69)); page3.addLine(to: p(25.17, 342.77))
    page3.addLine(to: p(25.17, 68.95)); page3.addLine(to: p(358.63, 16.86)); page3.closeSubpath()

    var page4 = Path(); page4.move(to: p(317.01, 393.56)); page4.addLine(to: p(25.58, 339.91))
    page4.addLine(to: p(25.58, 66.09)); page4.addLine(to: p(317.01, 11.33)); page4.closeSubpath()

    var front = Path(); front.move(to: p(273.14, 399.68)); front.addLine(to: p(25.58, 352.24))
    front.addLine(to: p(25.58, 52.94)); front.addLine(to: p(273.14, 5.5)); front.closeSubpath()

    context.fill(back, with: bodyShade); context.fill(spine, with: bodyShade)
    context.fill(spine, with: darkShade); context.fill(page2, with: paperShade)
    context.fill(page3, with: paperShade); context.fill(page4, with: paperShade)
    context.fill(front, with: bodyShade)
}

private func drawCatalogV9(context: inout GraphicsContext, size: CGSize, base: Color) {
    let w = size.width, h = size.height
    let bodyShade = GraphicsContext.Shading.color(base)
    let darkShade = GraphicsContext.Shading.color(Color.black.opacity(0.20))
    let sx: CGFloat = w / 500, sy: CGFloat = h / 407
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }

    var body = Path()
    body.move(to: p(267.83, 85.28)); body.addLine(to: p(216.14, 145.67))
    body.addLine(to: p(11.4, 145.67))
    body.addCurve(to: p(0.01, 157.17), control1: p(4.91, 145.67), control2: p(-0.27, 150.90))
    body.addLine(to: p(0.01, 396.30))
    body.addCurve(to: p(11.39, 406.87), control1: p(0.26, 402.21), control2: p(5.28, 406.87))
    body.addLine(to: p(489.26, 406.87))
    body.addCurve(to: p(500.65, 396.33), control1: p(495.36, 406.87), control2: p(500.37, 402.23))
    body.addLine(to: p(500.65, 92.82))
    body.addCurve(to: p(489.25, 81.28), control1: p(500.93, 86.54), control2: p(495.75, 81.28))
    body.addLine(to: p(276.61, 81.28))
    body.addCurve(to: p(267.83, 85.28), control1: p(273.22, 81.28), control2: p(270.00, 82.74))
    body.closeSubpath()

    var tab = Path()
    tab.move(to: p(222.94, 106.69)); tab.addLine(to: p(165.09, 106.69))
    tab.addLine(to: p(165.09, 61.05))
    tab.addCurve(to: p(160.63, 57.37), control1: p(165.09, 59.02), control2: p(163.09, 57.37))
    tab.addLine(to: p(4.46, 57.37))
    tab.addCurve(to: p(0.0, 61.05), control1: p(2.0, 57.37), control2: p(0.0, 59.02))
    tab.addLine(to: p(0.0, 129.11))
    tab.addCurve(to: p(4.46, 132.79), control1: p(0.0, 131.14), control2: p(2.0, 132.79))
    tab.addLine(to: p(206.21, 132.79)); tab.addLine(to: p(226.38, 112.72))
    tab.addCurve(to: p(222.94, 106.69), control1: p(228.79, 110.32), control2: p(226.72, 106.69))
    tab.closeSubpath()

    context.fill(body, with: bodyShade)
    context.fill(tab, with: bodyShade); context.fill(tab, with: darkShade)
}
