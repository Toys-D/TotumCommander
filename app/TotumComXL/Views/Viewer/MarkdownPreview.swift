import AppKit
import SwiftUI

/// Markdown в просмотрщике, разложенный средствами AppKit.
///
/// Раньше здесь разбиралась только строчная разметка: жирное, курсив, `код`, ссылки. Всё
/// остальное человек видел ровно так, как оно записано в файле, — решётки вместо заголовков,
/// чёрточки вместо списков и вертикальные палки вместо таблицы. Теперь разбирается весь
/// документ: заголовки, списки, цитаты, блоки кода, разделители и таблицы.
///
/// Не SwiftUI `Text`: документ целиком в одном `Text` раскладывался секундами (измерено:
/// 90 000 знаков — две секунды в пробе и дольше в окне). `NSTextView` раскладывает то же за
/// 50 мс и только то, что на экране.
enum MarkdownStyler {

    /// Чем рисуется разметка. Цвета системные: они сами меняются вместе с темой.
    struct Look {
        var base: NSFont = .systemFont(ofSize: 13)
        var ink: NSColor = .textColor
        var faint: NSColor = .secondaryLabelColor
        var link: NSColor = .linkColor
        var rule: NSColor = .separatorColor
        var codeBackground: NSColor = NSColor.textColor.withAlphaComponent(0.06)
        var headerFill: NSColor = NSColor.textColor.withAlphaComponent(0.08)

        /// Во сколько раз заголовок крупнее обычного текста. Шестой — уже мельче основного:
        /// так он и задуман, это подпись, а не заголовок.
        func headerScale(_ level: Int) -> CGFloat {
            switch level {
            case 1: return 1.7
            case 2: return 1.45
            case 3: return 1.25
            case 4: return 1.1
            case 5: return 1.0
            default: return 0.92
            }
        }
    }

    /// Отступ одного уровня списка или цитаты.
    private static let step: CGFloat = 20

    // MARK: - Разбор и раскладка

    /// Разобрать и оформить за один проход — то, что просмотрщик зовёт вне главного потока.
    static func render(_ markdown: String, baseFont: NSFont = .systemFont(ofSize: 13),
                       ink: NSColor = .textColor, link: NSColor = .linkColor) -> NSAttributedString? {
        var look = Look()
        look.base = baseFont
        look.ink = ink
        look.link = link
        return render(markdown, look: look)
    }

    static func render(_ markdown: String, look: Look) -> NSAttributedString? {
        guard let parsed = try? AttributedString(markdown: markdown, options: .init(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible))
        else { return nil }

        let out = NSMutableAttributedString()
        // Таблицы и блоки кода живут дольше одного куска текста: у таблицы это все её ячейки,
        // у блока кода — все его строки. Оба узнаются по своему номеру.
        var tables: [Int: NSTextTable] = [:]
        var codeBlocks: [Int: NSTextBlock] = [:]
        var lastBlockID: Int?
        var lastItemID: Int?

        for run in parsed.runs {
            var text = String(parsed[run.range].characters)
            let inline = run.inlinePresentationIntent ?? []
            // Одиночный перенос строки Markdown считает пробелом. В просмотрщике файла
            // человек ждёт увидеть свой файл, а не его пересказ, — перенос остаётся переносом.
            if inline.contains(.softBreak) { text = "\n" }
            guard !text.isEmpty else { continue }

            let block = Block(components: run.presentationIntent?.components ?? [])

            if let id = block.innerIdentity, id != lastBlockID {
                if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
                lastBlockID = id
            }

            let style = paragraphStyle(for: block, look: look, tables: &tables,
                                       codeBlocks: &codeBlocks)
            var font = font(for: block, inline: inline, look: look)
            let colour = block.inQuote ? look.faint : look.ink

            // Маркер списка — один раз на пункт, а не на каждый его абзац.
            if let itemID = block.listItemIdentity, itemID != lastItemID,
               let marker = block.listMarker {
                out.append(NSAttributedString(string: marker, attributes: [
                    .font: NSFontManager.shared.convert(look.base, toHaveTrait: .boldFontMask),
                    .foregroundColor: look.faint,
                    .paragraphStyle: style
                ]))
            }
            lastItemID = block.listItemIdentity

            if block.isHeaderRow {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: colour, .paragraphStyle: style
            ]
            if inline.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let url = run.link {
                attributes[.foregroundColor] = look.link
                attributes[.link] = url
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: text, attributes: attributes))
        }
        return out
    }

    // MARK: - Что это за кусок документа

    /// Разбор цепочки блоков, в которых лежит кусок текста: от внутреннего к внешнему.
    struct Block {
        var headerLevel: Int?
        var listDepth = 0
        var quoteDepth = 0
        var isCode = false
        var codeIdentity: Int?
        var isThematicBreak = false
        var listItemIdentity: Int?
        var listOrdinal: Int?
        var listIsOrdered = false
        var innerIdentity: Int?
        // Таблица
        var tableIdentity: Int?
        var tableColumns: [PresentationIntent.TableColumn] = []
        var row: Int?
        var column: Int?
        var isHeaderRow = false

        var inQuote: Bool { quoteDepth > 0 }
        var inTable: Bool { tableIdentity != nil }

        /// Чем помечен пункт списка: точкой или его номером.
        var listMarker: String? {
            guard listItemIdentity != nil else { return nil }
            if listIsOrdered, let ordinal = listOrdinal { return "\(ordinal). " }
            return "•  "
        }

        init(components: [PresentationIntent.IntentType]) {
            innerIdentity = components.first?.identity
            for component in components {
                switch component.kind {
                case .header(let level):
                    headerLevel = level
                case .unorderedList:
                    listDepth += 1
                case .orderedList:
                    listDepth += 1
                    listIsOrdered = true
                case .listItem(let ordinal):
                    if listItemIdentity == nil {
                        listItemIdentity = component.identity
                        listOrdinal = ordinal
                    }
                case .blockQuote:
                    quoteDepth += 1
                case .codeBlock:
                    isCode = true
                    codeIdentity = component.identity
                case .thematicBreak:
                    isThematicBreak = true
                case .table(let columns):
                    tableIdentity = component.identity
                    tableColumns = columns
                case .tableHeaderRow:
                    isHeaderRow = true
                    row = 0
                case .tableRow(let index):
                    row = index
                case .tableCell(let index):
                    column = index
                default:
                    break
                }
            }
        }
    }

    // MARK: - Шрифт и абзац

    private static func font(for block: Block, inline: InlinePresentationIntent,
                             look: Look) -> NSFont {
        var font = look.base
        if let level = block.headerLevel {
            font = .systemFont(ofSize: look.base.pointSize * look.headerScale(level), weight: .bold)
        } else if block.isCode || inline.contains(.code) {
            font = .monospacedSystemFont(ofSize: look.base.pointSize * 0.95, weight: .regular)
        }
        var traits: NSFontTraitMask = []
        if inline.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
        if inline.contains(.emphasized) { traits.insert(.italicFontMask) }
        if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
        return font
    }

    private static func paragraphStyle(for block: Block, look: Look,
                                       tables: inout [Int: NSTextTable],
                                       codeBlocks: inout [Int: NSTextBlock]) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.paragraphSpacing = 8

        if let level = block.headerLevel {
            style.paragraphSpacingBefore = level <= 2 ? 16 : 10
            style.paragraphSpacing = 6
        }

        let indent = CGFloat(block.listDepth + block.quoteDepth) * step
        if indent > 0 {
            style.firstLineHeadIndent = indent
            style.headIndent = indent + (block.listItemIdentity != nil ? 16 : 0)
        }

        if block.inQuote {
            // Полоска слева — та самая, что рисуют у цитаты.
            let bar = NSTextBlock()
            bar.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            bar.setBorderColor(look.rule)
            bar.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
            style.textBlocks = [bar]
        }

        if block.isCode, let id = block.codeIdentity {
            // Один блок на весь кусок кода: иначе каждая строка обзаведётся своей рамкой.
            let fill = codeBlocks[id] ?? {
                let made = NSTextBlock()
                made.backgroundColor = look.codeBackground
                made.setWidth(10, type: .absoluteValueType, for: .padding)
                codeBlocks[id] = made
                return made
            }()
            style.textBlocks = [fill]
            style.paragraphSpacing = 0
        }

        if let tableID = block.tableIdentity, let row = block.row, let column = block.column {
            let table = tables[tableID] ?? {
                let made = NSTextTable()
                made.numberOfColumns = max(block.tableColumns.count, column + 1)
                made.layoutAlgorithm = .automaticLayoutAlgorithm
                made.collapsesBorders = true
                made.hidesEmptyCells = false
                tables[tableID] = made
                return made
            }()
            let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                                        startingColumn: column, columnSpan: 1)
            cell.setBorderColor(look.rule)
            cell.setWidth(1, type: .absoluteValueType, for: .border)
            cell.setWidth(6, type: .absoluteValueType, for: .padding)
            if block.isHeaderRow { cell.backgroundColor = look.headerFill }
            style.textBlocks = [cell]
            style.paragraphSpacing = 0
            style.firstLineHeadIndent = 0
            style.headIndent = 0
            if block.tableColumns.indices.contains(column) {
                switch block.tableColumns[column].alignment {
                case .left: style.alignment = .left
                case .center: style.alignment = .center
                case .right: style.alignment = .right
                @unknown default: style.alignment = .natural
                }
            }
        }

        if block.isThematicBreak {
            let rule = NSTextBlock()
            rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
            rule.setBorderColor(look.rule)
            style.textBlocks = [rule]
            style.paragraphSpacingBefore = 10
        }

        return style
    }
}

/// Вид, в котором живёт разложенная разметка: только для чтения, с выделением, с переносом
/// строк и ленивой раскладкой — тот же порядок, что и у обычного текстового просмотра.
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
