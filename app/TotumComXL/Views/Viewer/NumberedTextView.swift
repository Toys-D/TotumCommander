import AppKit
import SwiftUI

/// Текст файла с номерами строк — для просмотрщика. Движок тот же, что у TextEdit:
/// раскладку и прокрутку ведёт AppKit, и текст идёт за пальцами без рывков. Раньше каждая
/// строка была отдельным текстом SwiftUI в ленивом списке: список досчитывал строки на ходу,
/// на длинных проседал и отставал от трекпада.
///
/// Номера рисует сам вид, в левом поле, у первой экранной строки каждой строки файла:
/// длинная строка, перенесённая на несколько экранных, получает один номер. Вид прежний —
/// шрифты, отступы и зазор между строками те же, что были у списка.
final class NumberedTextView: NSTextView {

    // Поле слева: отступ, колонка номеров (номера прижаты к её правому краю), зазор до текста.
    static let leftPadding: CGFloat = 10
    static let numberColumn: CGFloat = 56
    static let gap: CGFloat = 10
    static let rightPadding: CGFloat = 10
    static var textLeft: CGFloat { leftPadding + numberColumn + gap }

    static let textFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let numberFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    /// Между строками файла 4 pt — как было между строками списка; внутри переноса зазора нет.
    static let lineGap: CGFloat = 4

    /// Начала строк файла, смещения в UTF-16 — номер находится по ним двоичным поиском.
    private(set) var lineStarts: [Int] = [0]
    /// Что показано — чтобы не перекладывать тот же текст при каждом обновлении SwiftUI.
    private(set) var shownText = ""

    /// Прокрутка с этим видом внутри. Раскладка TextKit 1 без сплошной вёрстки: считается
    /// только то, что видно, — как в просмотрщике больших файлов.
    static func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let size = scroll.contentSize
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: textWidth(forViewWidth: size.width),
                                                     height: CGFloat.greatestFiniteMagnitude))
        // Ширину текста ведёт сам вид (setFrameSize): слева от текста — поле номеров.
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        // Вид ровно в размер содержимого прокрутки: дальше ширина меняется у обоих на одну
        // и ту же величину, и текст не вылезает за правый край.
        let view = NumberedTextView(frame: NSRect(origin: .zero, size: size), textContainer: container)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = false
        view.usesFontPanel = false
        view.drawsBackground = false
        scroll.documentView = view
        return scroll
    }

    static func textWidth(forViewWidth width: CGFloat) -> CGFloat {
        max(width - textLeft - rightPadding, 1)
    }

    func show(_ text: String) {
        shownText = text
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = Self.lineGap
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: Self.textFont,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: style,
        ]))
        lineStarts = Self.lineStarts(of: textStorage?.string ?? text)
        setSelectedRange(NSRange(location: 0, length: 0))
        scroll(.zero)
        needsDisplay = true
    }

    override var textContainerOrigin: NSPoint {
        NSPoint(x: Self.textLeft, y: textContainerInset.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let width = Self.textWidth(forViewWidth: newSize.width)
        if let container = textContainer, container.size.width != width {
            container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // NSTextView оставляет после себя обрезку по полю текста — номера слева от него
        // она бы срезала целиком. Поэтому текст рисуется в своём, сохранённом состоянии.
        NSGraphicsContext.saveGraphicsState()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.numberFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let right = Self.leftPadding + Self.numberColumn
        for label in numberLabels(in: dirtyRect) {
            let number = NSAttributedString(string: String(label.number), attributes: attributes)
            let width = number.size().width
            number.draw(at: NSPoint(x: right - width, y: label.baseline - Self.numberFont.ascender))
        }
    }

    /// Номера, видимые в прямоугольнике: номер строки файла и линия шрифта её первой экранной
    /// строки, в координатах вида. Строка, чья первая экранная строка выше прямоугольника,
    /// номера здесь не получает — он нарисован там, наверху.
    func numberLabels(in rect: NSRect) -> [(number: Int, baseline: CGFloat)] {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage
        else { return [] }
        let origin = textContainerOrigin
        let length = storage.length
        let area = NSRect(x: 0, y: rect.minY - origin.y, width: container.size.width, height: rect.height)
        let glyphs = layout.glyphRange(forBoundingRect: area, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var index = Self.lineIndex(at: chars.location, in: lineStarts)
        if lineStarts[index] < chars.location { index += 1 }
        var labels: [(number: Int, baseline: CGFloat)] = []
        while index < lineStarts.count {
            let start = lineStarts[index]
            let baseline: CGFloat
            if start >= length {
                // Пустая строка после последнего перевода строки — у раскладки она «лишняя».
                let extra = layout.extraLineFragmentRect
                guard extra.height > 0 else { break }
                baseline = extra.minY + layout.defaultBaselineOffset(for: Self.textFont)
            } else {
                if start > NSMaxRange(chars) { break }
                let glyph = layout.glyphIndexForCharacter(at: start)
                let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                baseline = fragment.minY + layout.location(forGlyphAt: glyph).y
            }
            let y = baseline + origin.y
            if y - Self.numberFont.ascender > rect.maxY { break }
            labels.append((index + 1, y))
            index += 1
        }
        return labels
    }

    /// Где начинается каждая строка файла. Концы строк — как у раскладки текста: \n, \r\n,
    /// одиночный \r. Перевод строки в самом конце даёт пустую последнюю строку — в файле
    /// она есть, и номер у неё есть.
    static func lineStarts(of text: String) -> [Int] {
        let string = text as NSString
        let length = string.length
        var starts = [0]
        var index = 0
        var end = 0
        var contentsEnd = 0
        while index < length {
            string.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd,
                                     for: NSRange(location: index, length: 0))
            guard end > index else { break }
            index = end
            if index < length || end > contentsEnd { starts.append(index) }
        }
        return starts
    }

    /// Номер (с нуля) строки, в которой лежит смещение: последнее начало, не правее него.
    static func lineIndex(at location: Int, in starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// Текст файла в просмотрщике — NumberedTextView внутри SwiftUI.
struct NumberedTextPreview: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NumberedTextView.makeScrollView()
        (scroll.documentView as? NumberedTextView)?.show(text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NumberedTextView, view.shownText != text else { return }
        view.show(text)
    }
}
