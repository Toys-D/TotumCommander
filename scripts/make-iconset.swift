import AppKit
import WebKit

/// Renders SVGs into every PNG a macOS .icns needs, with transparency intact.
///
///     swift scripts/make-iconset.swift full.svg out/AppIcon.iconset [small.svg]
///
/// Rendered through WebKit, and neither of the obvious shortcuts works:
///
/// `qlmanage` composites its thumbnails onto WHITE, so an icon with a transparent background came
/// out sitting in a white square.
///
/// `NSImage`'s own SVG support draws the file but ignores `display: none` in a `<style>` block —
/// which is exactly how Illustrator hides its guide layers. The guides, the crop rectangle and a
/// second copy of the wordmark all came back visible.
///
/// WebKit applies the stylesheet the way a browser does, and its snapshots keep the alpha channel,
/// so what lands on disk is what the artwork actually says.
///
/// Every size is drawn from the vector rather than downscaled from one big bitmap, so the 16pt icon
/// is as sharp as the artwork allows instead of a blurred shrink of the 1024 one.
///
/// The optional `small.svg` is used for the 16pt and 32pt icons. A wordmark that reads fine in the
/// Dock turns into two grey smudges in a Finder list, so those sizes get artwork of their own.

// MARK: - What has to be produced

/// One file in the iconset. Name and pixel count are tracked TOGETHER on purpose: several
/// different names share a pixel count (32px is both `icon_32x32` and `icon_16x16@2x`), and keying
/// the work by size alone silently wrote one of each pair twice and never wrote the other.
struct Target {
    let name: String
    let pixels: Int
    /// 16pt and 32pt read at a glance; anything with small print in it is illegible there.
    let wantsSmallArtwork: Bool
}

let targets: [Target] = [16, 32, 128, 256, 512].flatMap { points -> [Target] in
    let small = points <= 32
    return [
        Target(name: "icon_\(points)x\(points).png", pixels: points, wantsSmallArtwork: small),
        Target(name: "icon_\(points)x\(points)@2x.png", pixels: points * 2, wantsSmallArtwork: small)
    ]
}

// MARK: - Arguments

let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 4 else {
    FileHandle.standardError.write(Data(
        "usage: make-iconset.swift <full.svg> <output.iconset> [small.svg]\n".utf8))
    exit(2)
}

let fullSVG = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let smallSVG = arguments.count == 4 ? URL(fileURLWithPath: arguments[3]) : nil

for url in [fullSVG, smallSVG].compactMap({ $0 }) where !FileManager.default.fileExists(atPath: url.path) {
    FileHandle.standardError.write(Data("cannot read \(url.path)\n".utf8))
    exit(1)
}
do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("cannot create \(output.path): \(error)\n".utf8))
    exit(1)
}

// MARK: - Rendering

final class Renderer: NSObject, WKNavigationDelegate {

    private let webView: WKWebView
    private let svg: URL
    private let destination: URL
    private var pending: [Target]
    private var failure: String?

    init(svg: URL, destination: URL, targets: [Target]) {
        self.svg = svg
        self.destination = destination
        // Largest first: the view is created at the biggest size and only ever shrinks, so the
        // page never has to re-layout upward mid-run.
        self.pending = targets.sorted { $0.pixels > $1.pixels }

        let side = CGFloat(pending.first?.pixels ?? 1024)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: side, height: side),
                            configuration: WKWebViewConfiguration())
        super.init()
        // Both are needed: the modern property, and the old private flag some versions still
        // consult. Without them the snapshot comes back on opaque white.
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .clear }
        webView.navigationDelegate = self
    }

    func run() -> String? {
        guard !pending.isEmpty else { return nil }
        // The SVG markup is INLINED rather than referenced: WKWebView restricts file access from a
        // loadHTMLString page, so an <img src="…"> pointing at the neighbouring file may simply
        // never load. Inline markup needs no file access at all.
        guard var markup = try? String(contentsOf: svg, encoding: .utf8) else {
            return "cannot read \(svg.path)"
        }
        // The XML declaration is only legal at the very start of a document.
        if markup.hasPrefix("<?xml"), let end = markup.range(of: "?>") {
            markup = String(markup[end.upperBound...])
        }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;padding:0;background:transparent;width:100%;height:100%;overflow:hidden}
        svg{display:block;width:100%;height:100%}
        </style></head><body>\(markup)</body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)

        let deadline = Date().addingTimeInterval(60)
        while failure == nil, !pending.isEmpty, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if failure == nil, !pending.isEmpty { return "timed out waiting for WebKit" }
        return failure
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // One layout pass after load, then start snapshotting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.next() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failure = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        failure = error.localizedDescription
    }

    private func next() {
        guard let target = pending.first else { return }
        webView.frame = NSRect(x: 0, y: 0, width: CGFloat(target.pixels), height: CGFloat(target.pixels))
        webView.layoutSubtreeIfNeeded()

        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        // 1 point per pixel: the frame is already in final pixels, so no extra scaling.
        configuration.snapshotWidth = NSNumber(value: target.pixels)

        // A beat for the resize to take effect before the snapshot is taken.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    self.failure = error.localizedDescription
                    return
                }
                guard let image, let png = Self.png(from: image, side: target.pixels) else {
                    self.failure = "snapshot for \(target.name) produced nothing"
                    return
                }
                do {
                    try png.write(to: self.destination.appendingPathComponent(target.name))
                } catch {
                    self.failure = "\(error)"
                    return
                }
                self.pending.removeFirst()
                if !self.pending.isEmpty { self.next() }
            }
        }
    }

    private static func png(from image: NSImage, side: Int) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = NSSize(width: side, height: side)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // The bitmap comes back zeroed, which IS transparent — nothing is filled in behind the art.
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: .zero, operation: .sourceOver, fraction: 1.0)

        return bitmap.representation(using: .png, properties: [:])
    }
}

// MARK: - Run

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// Without a separate small artwork every size comes from the one file, which is the old behaviour.
let smallTargets = smallSVG == nil ? [] : targets.filter { $0.wantsSmallArtwork }
let fullTargets = targets.filter { target in !smallTargets.contains { $0.name == target.name } }

for (svg, group) in [(fullSVG, fullTargets), (smallSVG ?? fullSVG, smallTargets)] where !group.isEmpty {
    if let problem = Renderer(svg: svg, destination: output, targets: group).run() {
        FileHandle.standardError.write(Data("render failed for \(svg.lastPathComponent): \(problem)\n".utf8))
        exit(1)
    }
}

// Every expected file must exist: a missing size is not an error macOS reports — it silently
// scales a neighbour, and the icon just looks soft with nothing to say why.
var missing: [String] = []
for target in targets where !FileManager.default.fileExists(
    atPath: output.appendingPathComponent(target.name).path) {
    missing.append(target.name)
}
guard missing.isEmpty else {
    FileHandle.standardError.write(Data("missing: \(missing.joined(separator: ", "))\n".utf8))
    exit(1)
}

print("rendered \(targets.count) images into \(output.path)"
      + (smallSVG == nil ? "" : " (\(smallTargets.count) from \(smallSVG!.lastPathComponent))"))
