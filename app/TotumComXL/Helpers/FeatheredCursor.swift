import AppKit
import CoreImage
import QuartzCore

/// Bakes an edge-feathered (Photoshop-style Gaussian "feather") rounded-rect cursor
/// into a bitmap ONCE and caches it. Redrawing/moving the cursor then just blits the
/// cached image — the GPU never re-computes the blur — so it's cheap even while the
/// cursor moves. Re-baked only when the size / colour / blur actually change.
enum FeatheredCursor {
    private static var cache: [String: NSImage] = [:]

    /// Забыть испечённое. Зовётся, когда сменилось хранилище маски: ключ печи включает
    /// номер правки, а у нового хранилища нумерация своя — старая картинка под тем же
    /// номером выдавалась бы за новую.
    static func dropCache() { cache.removeAll() }
    /// Shared GPU context used to render (bake) the blur into a real bitmap once.
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Extra room added on every side of the bar so the soft edges have space to
    /// spread (and spill onto neighbours). Kept in sync between bake and draw.
    static func padding(for blur: CGFloat) -> CGFloat { blur * 2.5 + 4 }

    /// A cached feathered cursor. The returned image is `barSize` grown by
    /// `padding(for: blur)` on each side, with the bar centred and its edges blurred.
    static func image(barSize: NSSize, color: NSColor, blur: CGFloat, corner: CGFloat) -> NSImage {
        let w = max(1, Int(barSize.width.rounded()))
        let h = max(1, Int(barSize.height.rounded()))
        // The hand-drawn mask replaces the SHAPE only; colour and blur remain live on top.
        // Its revision is part of the key, so a fresh drawing invalidates every stale bake.
        let mask = CursorMaskStore.activeMask()
        let maskToken = mask != nil
            ? "m\(CursorMaskStore.revision)p\(CursorMaskStore.previewRevision)" : "m-"
        let outline = PanelAppearanceSettings.isCursorOutlineEnabled
            ? (width: PanelAppearanceSettings.resolvedCursorOutlineWidth,
               colour: PanelAppearanceSettings.resolvedCursorOutlineColor())
            : nil
        let outlineToken = outline.map {
            "o\(Int($0.width * 10))\(PanelAppearanceSettings.hexString(from: $0.colour) ?? "")"
        } ?? "o-"
        let key = "\(w)x\(h)-\(PanelAppearanceSettings.hexString(from: color))-b\(Int(blur.rounded()))-c\(Int(corner.rounded()))-\(maskToken)-\(outlineToken)"
        if let cached = cache[key] { return cached }
        let baked = bake(barSize: NSSize(width: w, height: h), color: color, blur: blur, corner: corner,
                         mask: mask, outline: outline)
        if cache.count > 40 { cache.removeAll() }
        cache[key] = baked
        return baked
    }

    /// Draws the feathered cursor for a cell/row `frame` into the current graphics
    /// context: sizes the bar by the width/height fractions, positions it by the anchor
    /// (0…1, 0.5 = centred) plus the X/Y offset, and blits the cached image so the soft
    /// edges spill onto neighbours. Shared by every view mode (brief, icons/thumbnails,
    /// detailed) so the cursor looks and reacts to the settings identically everywhere.
    static func draw(cellFrame frame: NSRect, color: NSColor, blur: CGFloat, corner: CGFloat,
                     widthFraction: CGFloat, heightFraction: CGFloat,
                     anchorX: CGFloat, anchorY: CGFloat,
                     offsetX: CGFloat, offsetY: CGFloat) {
        guard frame.width > 1, frame.height > 1 else { return }
        let barW = max(6, frame.width * widthFraction)
        let barH = max(6, frame.height * heightFraction)
        let img = image(barSize: NSSize(width: barW, height: barH),
                        color: color, blur: blur, corner: corner)
        let pad = padding(for: blur)
        // Anchor (0…1 in the cell) is the origin of scaling; offset then nudges the bar.
        let barMinX = frame.minX + anchorX * (frame.width - barW) + offsetX
        let barMinY = frame.minY + anchorY * (frame.height - barH) + offsetY
        let drawRect = NSRect(x: barMinX - pad, y: barMinY - pad,
                              width: barW + pad * 2, height: barH + pad * 2)
        // respectFlipped is load-bearing: the table and the collection views are FLIPPED, and
        // the short draw(in:) variant ignores that — it rendered the image upside down. The
        // symmetric bar hid it for ever; the first hand-drawn mask made it visible.
        img.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0,
                 respectFlipped: true, hints: nil)
    }

    private static func bake(barSize: NSSize, color: NSColor, blur: CGFloat, corner cornerRadius: CGFloat,
                             mask: NSImage? = nil,
                             outline: (width: CGFloat, colour: NSColor)? = nil) -> NSImage {
        let pad = padding(for: blur)
        let canvas = NSSize(width: barSize.width + pad * 2, height: barSize.height + pad * 2)
        let barRect = NSRect(x: pad, y: pad, width: barSize.width, height: barSize.height)
        let corner = min(barSize.height / 2, cornerRadius)

        // 1. The crisp shape on a transparent canvas: the hand-drawn mask stretched over the bar
        //    and tinted with the cursor colour — or the classic rounded bar when there is none.
        //    Everything downstream (the Gaussian feather, the cache) is shape-agnostic.
        let sharp = NSImage(size: canvas, flipped: false) { _ in
            if let mask {
                // The corner slider works on the drawing too: the mask is clipped by the same
                // rounded rect the built-in bar uses, so turning the radius up rounds the
                // drawing's corners off instead of doing nothing.
                NSGraphicsContext.current?.saveGraphicsState()
                NSBezierPath(roundedRect: barRect, xRadius: corner, yRadius: corner).addClip()
                mask.draw(in: barRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                color.setFill()
                barRect.fill(using: .sourceIn)   // keep the mask's alpha, take the cursor's colour
                NSGraphicsContext.current?.restoreGraphicsState()
            } else {
                color.setFill()
                NSBezierPath(roundedRect: barRect, xRadius: corner, yRadius: corner).fill()
            }
            return true
        }
        // The rim goes on AFTER the feathering, never into it: blurring an outline turns it into
        // a smudge, and the look being asked for — the mask bubble's — is a soft body inside a
        // sharp edge.
        func stroked(_ image: NSImage) -> NSImage {
            guard let outline else { return image }
            return NSImage(size: canvas, flipped: false) { _ in
                image.draw(in: NSRect(origin: .zero, size: canvas))
                let inset = outline.width / 2
                let path = NSBezierPath(roundedRect: barRect.insetBy(dx: inset, dy: inset),
                                        xRadius: max(0, corner - inset),
                                        yRadius: max(0, corner - inset))
                path.lineWidth = outline.width
                outline.colour.setStroke()
                path.stroke()
                return true
            }
        }

        guard blur > 0.5,
              let cg = sharp.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return stroked(sharp) }
        let ci = CIImage(cgImage: cg)

        // 2. Feather the edges: clamp-to-extent first (avoids Core Image's grey border
        //    artifact), Gaussian-blur, then crop back to the canvas size.
        let blurred = ci.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(blur))
            .cropped(to: ci.extent)

        // 3. Render (BAKE) it to a real bitmap once, so every later draw is just a blit
        //    — the GPU never re-runs the blur.
        guard let baked = ciContext.createCGImage(blurred, from: ci.extent) else { return stroked(sharp) }
        return stroked(NSImage(cgImage: baked, size: canvas))
    }
}

/// "Icon lift" under the cursor: scales a file/folder icon up from its centre when its row
/// is the cursor. Purely a layer transform, so it grows over the neighbours WITHOUT
/// reflowing the layout (the name doesn't shift). Shared by every view mode.
enum CursorIconZoom {
    /// Effective scale factor from the settings (1 = disabled → no growth).
    static var effectiveScale: CGFloat {
        guard UserDefaults.standard.bool(forKey: PanelAppearanceSettings.cursorIconZoomEnabledKey) else { return 1 }
        return PanelAppearanceSettings.resolvedCursorIconZoom
    }

    /// The Dock-style wave: full lift on the cursor row, easing down linearly with distance —
    /// each neighbour sits between normal size and the cursor's, reaching 1 just past the
    /// spread. Spread 0 keeps the classic single-row lift.
    static func scale(atDistance distance: Int) -> CGFloat {
        let zoom = effectiveScale
        guard zoom != 1, distance >= 0 else { return 1 }
        let spread = PanelAppearanceSettings.resolvedCursorIconZoomSpread
        guard distance <= spread else { return 1 }
        let falloff = 1 - CGFloat(distance) / CGFloat(spread + 1)
        return 1 + (zoom - 1) * falloff
    }

    /// Apply `scale` (1 = normal size) to the icon view, growing from its centre.
    static func apply(to imageView: NSImageView?, scale: CGFloat) {
        guard let imageView else { return }
        imageView.wantsLayer = true
        applyNow(imageView, scale)
        // A freshly-created cell may not be laid out yet (bounds == 0), so the centre pivot
        // would be wrong. Re-apply on the next runloop tick once Auto Layout has sized it.
        if imageView.bounds.width < 1 {
            DispatchQueue.main.async { [weak imageView] in applyNow(imageView, scale) }
        }
    }

    private static func applyNow(_ imageView: NSImageView?, _ scale: CGFloat) {
        guard let layer = imageView?.layer else { return }
        let w = layer.bounds.width, h = layer.bounds.height
        guard scale != 1, w > 0, h > 0 else {
            layer.transform = CATransform3DIdentity
            return
        }
        // AppKit backing layers anchor at a corner, so a plain scale grows from the corner.
        // Pivot around the centre explicitly: translate to centre → scale → translate back.
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, w / 2, h / 2, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -w / 2, -h / 2, 0)
        layer.transform = t
    }
}
