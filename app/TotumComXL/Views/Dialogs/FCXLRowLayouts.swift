import SwiftUI

/// Ряд кнопок одной ширины — по самой широкой: кнопки, стоящие рядом, одного размера, как бы ни
/// разнились подписи («Было», «Сбросить», «Сохранить» под картинкой). Чтобы плашка тянулась на
/// всё место, подпись внутри неё — `.frame(maxWidth: .infinity)`, иначе плашка останется по тексту.
struct FCXLEqualWidthRow: Layout {
    var spacing: CGFloat = 8

    private func cell(_ subviews: Subviews) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).max() ?? 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let cell = cell(subviews)
        let count = CGFloat(subviews.count)
        return CGSize(width: cell.width * count + spacing * max(0, count - 1), height: cell.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cell = cell(subviews)
        var x = bounds.minX
        for subview in subviews {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(cell))
            x += cell.width + spacing
        }
    }
}

/// Полоса инструментов: значки слева, группа кнопок справа (последний вложенный вид — группа,
/// остальные — значки). Всё на своём размере: подпись кнопки не переносится и не режется ни при
/// какой ширине. Тесно — значки сходятся ближе друг к другу (до `minSpacing`); не хватает и так —
/// группа уходит второй строкой под значки, к правому краю.
///
/// Раньше это был HStack с Spacer: в панели шириной ~560 точек (окно 1200) места не хватало, и
/// SwiftUI отдавал недостачу тому, что умеет сжиматься, — «Было» вставало столбиком по букве,
/// «Сбросить» превращалась в «…».
struct FCXLToolbarRow: Layout {
    var spacing: CGFloat = 14
    /// Ближе значки не сходятся: при 4 точках повороты влево и вправо почти касались.
    var minSpacing: CGFloat = 6
    var rowSpacing: CGFloat = 6

    struct Arrangement: Equatable {
        var iconSpacing: CGFloat
        var wraps: Bool
        var size: CGSize
    }

    /// Расстановка для ширины `width` (nil — по себе): зазор между значками и одна строка или две.
    static func arrange(iconWidths: [CGFloat], iconsHeight: CGFloat, trailing: CGSize,
                        width proposed: CGFloat?, spacing: CGFloat, minSpacing: CGFloat,
                        rowSpacing: CGFloat) -> Arrangement {
        let iconsWidth = iconWidths.reduce(0, +)
        let gaps = CGFloat(max(0, iconWidths.count - 1))
        let natural = iconsWidth + spacing * gaps + spacing + trailing.width
        let width = proposed.flatMap { $0.isFinite ? $0 : nil } ?? natural
        let oneRow = max(iconsHeight, trailing.height)
        // Место значкам в одной строке с группой: между значками и группой — обычный зазор.
        let room = width - iconsWidth - trailing.width - spacing
        // Один вид слева (зазоров нет) — тоже проверка места, а не «всегда в строку».
        if room >= minSpacing * gaps {
            let iconSpacing = gaps == 0 ? 0 : min(spacing, room / gaps)
            return Arrangement(iconSpacing: iconSpacing, wraps: false,
                               size: CGSize(width: width, height: oneRow))
        }
        let iconSpacing = gaps == 0 ? 0 : min(spacing, max(minSpacing, (width - iconsWidth) / gaps))
        return Arrangement(iconSpacing: iconSpacing, wraps: true,
                           size: CGSize(width: width, height: iconsHeight + rowSpacing + trailing.height))
    }

    private struct Measured {
        var icons: [CGSize]
        var trailing: CGSize
        var iconsHeight: CGFloat { icons.map(\.height).max() ?? 0 }
    }

    private func measure(_ subviews: Subviews) -> Measured {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return Measured(icons: Array(sizes.dropLast()), trailing: sizes.last ?? .zero)
    }

    private func arrange(_ measured: Measured, width: CGFloat?) -> Arrangement {
        Self.arrange(iconWidths: measured.icons.map(\.width), iconsHeight: measured.iconsHeight,
                     trailing: measured.trailing, width: width, spacing: spacing,
                     minSpacing: minSpacing, rowSpacing: rowSpacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(measure(subviews), width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let trailing = subviews.last else { return }
        let measured = measure(subviews)
        let arrangement = arrange(measured, width: bounds.width)
        let iconsY = arrangement.wraps ? bounds.minY + measured.iconsHeight / 2 : bounds.midY
        var x = bounds.minX
        for (subview, size) in zip(subviews.dropLast(), measured.icons) {
            subview.place(at: CGPoint(x: x, y: iconsY), anchor: .leading, proposal: ProposedViewSize(size))
            x += size.width + arrangement.iconSpacing
        }
        let trailingY = arrangement.wraps ? bounds.maxY - measured.trailing.height / 2 : bounds.midY
        trailing.place(at: CGPoint(x: bounds.maxX, y: trailingY), anchor: .trailing,
                       proposal: ProposedViewSize(measured.trailing))
    }
}
