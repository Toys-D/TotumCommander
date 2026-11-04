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

    // MARK: - Рост

    /// Промежуточный кегль: все шрифты, разрядка и вложение (🔗 ссылки) крупнее в `scale` раз;
    /// хранимая строка не тронута.
    func test_масштабированиеТрогаетВсеШрифтыИВложения() throws {
        let text = NSMutableAttributedString(attributedString: decorated("Documents"))
        text.addAttribute(.kern, value: NSNumber(value: 1.0), range: NSRange(location: 0, length: 3))
        let big = MarqueeTextField.scaled(text, by: 1.5)
        let font = try XCTUnwrap(big.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 18, accuracy: 0.001)
        let kern = try XCTUnwrap(big.attribute(.kern, at: 0, effectiveRange: nil) as? NSNumber)
        XCTAssertEqual(kern.doubleValue, 1.5, accuracy: 0.001)
        let attachment = try XCTUnwrap(
            big.attribute(.attachment, at: big.length - 1, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertEqual(attachment.bounds.width, 0, "у вложения без bounds они и остаются нулевыми")
        let original = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(original.pointSize, 12, "исходная строка не изменилась")
        XCTAssertTrue(MarqueeTextField.scaled(text, by: 1) === text, "единица — та же строка")
    }

    /// Обрезка по ширине работает и для промежуточного кегля: результат помещается в колонку,
    /// а многоточие — тем же шрифтом, что и имя.
    func test_обрезкаВПромежуточномКеглеПомещаетсяВКолонку() throws {
        let name = NSAttributedString(
            string: "очень длинное имя файла, которое точно не помещается в колонку",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemRed])
        let width: CGFloat = 120
        for scale: CGFloat in [1, 1.3, 0.8] {
            let cut = MarqueeTextField.truncatedToFit(MarqueeTextField.scaled(name, by: scale), width: width)
            XCTAssertLessThanOrEqual(cut.size().width, width, "масштаб \(scale) вылез за колонку")
            XCTAssertTrue(cut.string.hasSuffix("…"))
            let nameFont = try XCTUnwrap(cut.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            let dotsFont = try XCTUnwrap(cut.attribute(.font, at: cut.length - 1, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(dotsFont.pointSize, nameFont.pointSize, accuracy: 0.001, "масштаб \(scale)")
            let dotsColor = cut.attribute(.foregroundColor, at: cut.length - 1, effectiveRange: nil) as? NSColor
            XCTAssertEqual(dotsColor, .systemRed, "многоточие цветом имени")
        }
        let short = NSAttributedString(string: "a.txt", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        XCTAssertEqual(MarqueeTextField.truncatedToFit(short, width: width), short, "помещается — как есть")
    }

    /// Рост идёт от прежнего масштаба и заканчивается настоящим кеглем; новый текст обрывает его.
    func test_ростЗаканчиваетсяНастоящимКеглем() {
        let field = MarqueeTextField(labelWithString: "имя")
        field.frame = NSRect(x: 0, y: 0, width: 100, height: 20)
        field.animateGrowth(fromRatio: 1.3, duration: 0.05)
        XCTAssertEqual(field.currentGrowthScale, 1.3, accuracy: 0.05)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        XCTAssertEqual(field.currentGrowthScale, 1, accuracy: 0.001, "после перехода — настоящий шрифт")

        field.animateGrowth(fromRatio: 1.3, duration: 1)
        field.stringValue = "другое имя"
        XCTAssertEqual(field.currentGrowthScale, 1, accuracy: 0.001, "новый текст встаёт в размер сразу")
        field.animateGrowth(fromRatio: 1, duration: 1)
        XCTAssertEqual(field.currentGrowthScale, 1, accuracy: 0.001, "единица — перехода нет")
    }

    /// `stringValue` must report the text, not the text plus whatever the getter reconstructed.
    func test_stringValueTracksTheAttributedText() {
        let field = MarqueeTextField(labelWithString: "")
        let name = decorated("Documents")
        field.attributedStringValue = name
        XCTAssertEqual(field.stringValue, name.string)
    }
}
