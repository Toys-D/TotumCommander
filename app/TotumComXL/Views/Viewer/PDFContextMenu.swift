import AppKit
import PDFKit

/// The PDF page's context menu in the app's own words and look.
///
/// PDFKit's menu is a system one: it came up in English on a Russian Mac (the bundle declared
/// no localizations — mended in launch.sh too) and looked like nothing else in the program.
/// This one is built the way every other context menu here is, from styled items.
final class FCXLPDFView: PDFView {

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu(at: convert(event.locationInWindow, from: nil))
    }

    /// The menu for the view's current state — a function of its own so a test can read it.
    func contextMenu(at point: NSPoint) -> NSMenu {
        let menu = NSMenu()
        // Enabled states are set by hand below; letting AppKit validate would re-enable them.
        menu.autoenablesItems = false

        if let text = currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            menu.addStyledItem(title: String(format: L("viewer.pdf.menu.lookUp"), Self.excerpt(of: text)),
                               symbolName: "character.book.closed", id: "pdf.lookUp") { [weak self] in
                self?.showDefinition(for: NSAttributedString(string: text), at: point)
            }
            menu.addStyledItem(title: L("viewer.pdf.menu.searchWeb"), symbolName: "magnifyingglass",
                               id: "pdf.searchWeb") { Self.searchWeb(for: text) }
            menu.addItem(.separator())
            menu.addStyledItem(title: L("viewer.pdf.menu.copy"), symbolName: "doc.on.doc",
                               id: "pdf.copy") { [weak self] in self?.copy(nil) }
            menu.addItem(.separator())
        }

        addItem(to: menu, L("viewer.pdf.menu.autoResize"), "arrow.up.left.and.arrow.down.right",
                id: "pdf.autoResize", checked: autoScales) { [weak self] in self?.autoScales.toggle() }
        addItem(to: menu, L("viewer.pdf.menu.zoomIn"), "plus.magnifyingglass",
                id: "pdf.zoomIn", enabled: canZoomIn) { [weak self] in self?.zoomIn(nil) }
        addItem(to: menu, L("viewer.pdf.menu.zoomOut"), "minus.magnifyingglass",
                id: "pdf.zoomOut", enabled: canZoomOut) { [weak self] in self?.zoomOut(nil) }
        addItem(to: menu, L("viewer.pdf.menu.actualSize"), "1.magnifyingglass",
                id: "pdf.actualSize") { [weak self] in
            self?.autoScales = false
            self?.scaleFactor = 1
        }
        menu.addItem(.separator())

        let layouts: [(PDFDisplayMode, String, String)] = [
            (.singlePage, "single", "doc"),
            (.singlePageContinuous, "singleContinuous", "doc.text"),
            (.twoUp, "twoUp", "book"),
            (.twoUpContinuous, "twoUpContinuous", "book.pages"),
        ]
        for (mode, key, symbol) in layouts {
            addItem(to: menu, L("viewer.pdf.menu.\(key)"), symbol, id: "pdf.\(key)",
                    checked: displayMode == mode) { [weak self] in self?.displayMode = mode }
        }
        menu.addItem(.separator())

        addItem(to: menu, L("viewer.pdf.menu.nextPage"), "arrow.down", id: "pdf.nextPage",
                enabled: canGoToNextPage) { [weak self] in self?.goToNextPage(nil) }
        addItem(to: menu, L("viewer.pdf.menu.previousPage"), "arrow.up", id: "pdf.previousPage",
                enabled: canGoToPreviousPage) { [weak self] in self?.goToPreviousPage(nil) }

        menu.applyAccentStyle()
        return menu
    }

    private func addItem(to menu: NSMenu, _ title: String, _ symbol: String, id: String,
                         checked: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        menu.addStyledItem(title: title, symbolName: symbol, id: id, action: action)
        menu.items.last?.state = checked ? .on : .off
        menu.items.last?.isEnabled = enabled
    }

    /// The selection as the menu names it: its beginning, on one line, with an ellipsis once
    /// it runs past what a menu row can carry.
    static func excerpt(of text: String, limit: Int = 32) -> String {
        let oneLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The selection in the default browser's search — the one thing the system menu did that
    /// a reader of a Russian book actually used, kept.
    static func searchWeb(for text: String) {
        guard let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=" + query) else { return }
        NSWorkspace.shared.open(url)
    }
}
