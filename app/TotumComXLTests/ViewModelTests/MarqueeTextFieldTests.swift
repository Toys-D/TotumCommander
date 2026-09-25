import XCTest
import AppKit
@testable import TotumComXLApp

/// The name cell hands this field an ATTRIBUTED string whenever the name carries decoration — a
/// symlink's italic + 🔗 marker, or the Finder tag dots. Every one of those is a per-run attribute,
/// so the single thing worth pinning down is that assigning the attributed value actually keeps it.
@MainActor
final class MarqueeTextFieldTests: XCTestCase {

    private func decorated(_ name: String) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: name,
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemYellow])
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { _ in
            NSColor.systemPurple.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 8, height: 8)).fill()
            return true
        }
        text.append(NSAttributedString(attachment: attachment))
        return text
    }

    /// A fresh cell starts empty, so the very first name it is given is a string CHANGE. That is the
    /// case the panel hits on every directory load.
    func test_keepsAttributedValueOnAFreshField() {
        let field = MarqueeTextField(labelWithString: "")
        let name = decorated("Documents")
        field.attributedStringValue = name
        XCTAssertEqual(field.attributedStringValue, name,
                       "the decoration was dropped the moment it was assigned")
    }

    /// Table cells are recycled: the field already holds some other file's name when it is handed
    /// this one. Assigning a DIFFERENT string used to clear the attributes that came with it.
    func test_keepsAttributedValueWhenTheStringChanges() {
        let field = MarqueeTextField(labelWithString: "")
        field.attributedStringValue = decorated("Documents")
        let next = decorated("Downloads")
        field.attributedStringValue = next
        XCTAssertEqual(field.attributedStringValue, next,
                       "recycling the cell onto another name dropped that name's decoration")
    }

    /// Re-assigning the same text with different attributes is what a cursor move does: same name,
    /// new colour. The new attributes must win.
    func test_keepsAttributedValueWhenOnlyTheAttributesChange() {
        let field = MarqueeTextField(labelWithString: "")
        field.attributedStringValue = decorated("Documents")
        let recoloured = NSAttributedString(
            string: "Documents",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemRed])
        field.attributedStringValue = recoloured
        XCTAssertEqual(field.attributedStringValue, recoloured)
    }

    /// The plain path must still clear a stale decoration, or a previous row's tag dots would
    /// linger on a file that has none.
    func test_plainStringAssignmentClearsStaleDecoration() {
        let field = MarqueeTextField(labelWithString: "")
        field.attributedStringValue = decorated("Documents")
        field.stringValue = "plain.txt"
        XCTAssertEqual(field.attributedStringValue.string, "plain.txt")
        XCTAssertNil(field.attributedStringValue.attribute(.attachment, at: 0, effectiveRange: nil),
                     "the previous name's dot survived onto an untagged file")
    }

    /// `stringValue` must report the text, not the text plus whatever the getter reconstructed.
    func test_stringValueTracksTheAttributedText() {
        let field = MarqueeTextField(labelWithString: "")
        let name = decorated("Documents")
        field.attributedStringValue = name
        XCTAssertEqual(field.stringValue, name.string)
    }
}
