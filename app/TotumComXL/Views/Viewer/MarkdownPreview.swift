import AppKit
import SwiftUI

/// Markdown in the viewer, laid out by AppKit.
///
/// A SwiftUI `Text` carrying a whole document was the ten-second wait: parsing the markdown
/// takes 20 ms, laying the same 90 000 characters out as one `Text` took seconds (measured:
/// 2 s in a probe, longer in the window), and the page rebuilt itself once it was done.
/// `NSTextView` lays the same text out in 50 ms and only what is on screen.
enum MarkdownStyler {

    /// The parsed markdown as AppKit draws it: the inline intents `AttributedString(markdown:)`
    /// leaves behind — bold, italic, code, strikethrough — become fonts, and links get a colour.
    /// SwiftUI's `Text` did this on its own; `NSTextView` draws only what it is told.
    static func styled(_ source: AttributedString, baseFont: NSFont, ink: NSColor,
                       link: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: NSAttributedString(source))
        result.addAttributes([.font: baseFont, .foregroundColor: ink],
                             range: NSRange(location: 0, length: result.length))
        for run in source.runs {
            let range = NSRange(run.range, in: source)
            if let intent = run.inlinePresentationIntent {
                var font = baseFont
                if intent.contains(.code) {
                    font = .monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
                }
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
                result.addAttribute(.font, value: font, range: range)
                if intent.contains(.strikethrough) {
                    result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            }
            if let url = run.link {
                result.addAttributes([.foregroundColor: link, .link: url,
                                      .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            }
        }
        return result
    }

    /// Parse and style in one go — what the viewer calls off the main thread.
    static func render(_ markdown: String, baseFont: NSFont = .systemFont(ofSize: 13),
                       ink: NSColor = .textColor, link: NSColor = .linkColor) -> NSAttributedString? {
        guard let parsed = try? AttributedString(
            markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return nil }
        return styled(parsed, baseFont: baseFont, ink: ink, link: link)
    }
}

/// The text view the styled markdown lives in: read-only, selectable, wrapping, laid out
/// lazily — the same setup as the plain-text preview.
struct MarkdownPreview: NSViewRepresentable {
    let content: NSAttributedString

    final class Coordinator {
        var shown: NSAttributedString?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.layoutManager?.allowsNonContiguousLayout = true
        show(content, in: textView, context: context)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView,
              context.coordinator.shown !== content else { return }
        show(content, in: textView, context: context)
    }

    private func show(_ text: NSAttributedString, in textView: NSTextView, context: Context) {
        context.coordinator.shown = text
        textView.textStorage?.setAttributedString(text)
        textView.scrollToBeginningOfDocument(nil)
    }
}
