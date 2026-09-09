import AppKit
import FCXLBridgeObjC

// Shared DjVu page renderer — used BOTH by the commander's built-in F3 viewer and by the
// standalone reader in Contents/Library. It lives in its own module precisely so the two
// cannot drift: the first version of this existed twice, and optimising one copy left the
// other stuttering.

// MARK: - Scrolling page view

/// Draws a scanned book as a vertical strip of pages.
///
/// Decoding a DjVu page costs hundreds of milliseconds, so nothing is decoded on the main
/// thread: `draw` only paints what is already cached and asks for the rest in the
/// background, repainting that page when it arrives. Everything else here exists to keep
/// scrolling cheap — a book runs to hundreds of pages, so per-frame work must not be
/// proportional to the page count, and the cache must not grow to the whole book.
public final class DjVuPagesView: NSView {
    private let reader: FCXLDjVuReader
    private var pageSizes: [CGSize] = []
    private var pageOffsets: [CGFloat] = []      // y of each page, ascending
    private var cache: [Int: NSImage] = [:]
    private var pending: Set<Int> = []
    private var maxPageWidth: CGFloat = 1        // computed once, not per draw
    private var scale: CGFloat = 1               // current fit-to-width scale
    private var lastFitWidth: CGFloat = 0
    private let gap: CGFloat = 12

    /// Pages kept around the viewport. A Retina page is several MB; the whole book would be
    /// gigabytes, and the resulting memory pressure is itself a source of stutter.
    private let cacheLimit = 8

    /// ddjvu decoding is not re-entrant — one serial queue keeps every render off the main
    /// thread AND serialises access to the reader.
    private let renderQueue = DispatchQueue(label: "com.fcxl.djvu.render", qos: .userInitiated)

    public override var isFlipped: Bool { true }

    /// Width available for a page. Read from the clip view on demand — reading it once at
    /// init returned 0 (the scroll view had no frame yet), which made the scale fall back
    /// to 1:1 and pushed the full-resolution page off the left edge.
    private var availableWidth: CGFloat {
        let w = enclosingScrollView?.contentSize.width ?? bounds.width
        return w > 1 ? w : 800
    }

    public init(reader: FCXLDjVuReader) {
        self.reader = reader
        super.init(frame: .zero)
        for i in 0..<reader.pageCount {
            pageSizes.append(reader.pageSize(at: i))
        }
        maxPageWidth = max(pageSizes.map(\.width).max() ?? 1, 1)
        relayout()
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    private func relayout() {
        let newScale = availableWidth / maxPageWidth
        var y: CGFloat = gap
        pageOffsets.removeAll(keepingCapacity: true)
        for size in pageSizes {
            pageOffsets.append(y)
            y += size.height * newScale + gap
        }
        if newScale != scale {
            scale = newScale
            cache.removeAll()          // every cached bitmap is the wrong size now
            pending.removeAll()
        }
        setFrameSize(NSSize(width: availableWidth, height: max(y, 1)))
        needsDisplay = true
    }

    /// The scroll view lays out after init, and again on every window resize; re-fit then.
    public override func layout() {
        super.layout()
        if lastFitWidth != availableWidth {
            lastFitWidth = availableWidth
            relayout()
        }
    }

    /// Which page is being looked at — the topmost one crossing the middle of the window.
    /// Needed by anything outside that has to say "page 42 of 282": a bookmark, the header.
    public var currentPageIndex: Int {
        guard !pageOffsets.isEmpty else { return 0 }
        let viewport = enclosingScrollView?.contentView.bounds ?? bounds
        let top = viewport.origin.y
        let bottom = top + viewport.height

        // The page you are actually LOOKING at is the one filling most of the window — not
        // the one whose top happens to have crossed the middle. Judging by the middle made
        // the counter jump a page early: the next page's edge creeps past the centre line
        // while nine tenths of what you see is still the previous one.
        var bestIndex = 0
        var bestVisible: CGFloat = -1
        for index in pageOffsets.indices {
            let pageTop = pageOffsets[index]
            let pageBottom = pageTop + pageSizes[index].height * scale
            if pageTop > bottom { break }              // ниже окна — и все следующие тоже
            let visible = min(pageBottom, bottom) - max(pageTop, top)
            if visible > bestVisible {
                bestVisible = visible
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// Jump to a page — how a bookmark takes you back.
    public func scrollToPage(_ index: Int) {
        guard pageOffsets.indices.contains(index) else { return }
        let point = NSPoint(x: 0, y: max(0, pageOffsets[index] - gap))
        enclosingScrollView?.contentView.scroll(to: point)
        enclosingScrollView?.reflectScrolledClipView(enclosingScrollView!.contentView)
    }

    private func rect(for index: Int) -> NSRect {
        let size = pageSizes[index]
        let w = size.width * scale
        return NSRect(x: (bounds.width - w) / 2, y: pageOffsets[index],
                      width: w, height: size.height * scale)
    }

    /// First..last page intersecting `rect`, found by binary search instead of walking the
    /// whole book on every frame.
    private func visibleRange(in rect: NSRect) -> ClosedRange<Int> {
        guard !pageOffsets.isEmpty else { return 0...0 }
        var lo = 0, hi = pageOffsets.count - 1
        while lo < hi {                                   // last page starting at/above minY
            let mid = (lo + hi + 1) / 2
            if pageOffsets[mid] <= rect.minY { lo = mid } else { hi = mid - 1 }
        }
        var last = lo
        while last + 1 < pageOffsets.count, pageOffsets[last + 1] < rect.maxY { last += 1 }
        return lo...last
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        let range = visibleRange(in: dirtyRect)
        for index in range {
            let frame = rect(for: index)
            guard frame.intersects(dirtyRect) else { continue }

            if let image = cache[index] {
                image.draw(in: frame)
            } else {
                // Placeholder now, real page when the background decode lands — scrolling
                // must never wait for a decode.
                NSColor.white.setFill()
                frame.fill()
                requestRender(index)
            }
            NSColor.separatorColor.setStroke()
            NSBezierPath(rect: frame).stroke()
        }
        trimCache(keeping: range)
    }

    private func requestRender(_ index: Int) {
        guard !pending.contains(index), cache[index] == nil else { return }
        pending.insert(index)
        let backing = window?.backingScaleFactor ?? 2
        let renderScale = scale * backing            // sharp on Retina
        let reader = self.reader
        renderQueue.async { [weak self] in
            let image = Self.render(reader: reader, index: index, scale: renderScale)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(index)
                // Window resized mid-decode — this bitmap is already the wrong size.
                guard renderScale == self.scale * (self.window?.backingScaleFactor ?? 2)
                else { return }
                guard let image else { return }
                self.cache[index] = image
                self.setNeedsDisplay(self.rect(for: index))
            }
        }
    }

    /// Drop pages far from the viewport, keeping a couple on each side for smooth scrolling.
    private func trimCache(keeping range: ClosedRange<Int>) {
        guard cache.count > cacheLimit else { return }
        let keep = (range.lowerBound - 2)...(range.upperBound + 2)
        for key in cache.keys where !keep.contains(key) {
            cache.removeValue(forKey: key)
        }
    }

    /// Bridge output → NSImage. The bridge hands back RGBA with alpha last, matching the
    /// CGImage layout below.
    public static func render(reader: FCXLDjVuReader, index: Int, scale: CGFloat) -> NSImage? {
        guard let result = reader.renderPage(at: index, scale: scale),
              let data = result["data"] as? Data,
              let w = result["width"] as? Int,
              let h = result["height"] as? Int,
              let stride = result["stride"] as? Int,
              let provider = CGDataProvider(data: data as CFData),
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = CGImage(
                width: w, height: h,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: stride, space: cs,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(w) / scale,
                                                      height: CGFloat(h) / scale))
    }
}

