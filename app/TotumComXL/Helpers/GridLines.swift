import AppKit

/// Линии сетки списка: где их класть — чистая геометрия, отдельно от рисования.
///
/// Чередование красит строки, линии их разграничивают, и одно другому не мешает: выключил
/// чередование — включил линии, и строки по-прежнему видны. Вертикальные идут по кромкам
/// столбцов, горизонтальные — под каждой строкой, только там, где строки есть.
enum GridLines {

    struct Style: Equatable {
        var vertical = false
        var horizontal = false
        var isOn: Bool { vertical || horizontal }
    }

    /// Толщина линии; линия стоит верхом на кромке, по полпункта в каждую сторону.
    static let thickness: CGFloat = 1

    /// Подробный режим. Вертикальные — по правой кромке каждого столбца, кроме последнего
    /// (за ним ничего нет) и кроме значка: значок и имя читаются одним столбцом, у них и
    /// заголовок один. Во всю высоту `bounds`. Горизонтальные — под каждой строкой во всю
    /// ширину.
    static func table(columns: [(id: String, rect: NSRect)], rows: [NSRect], bounds: NSRect,
                      style: Style) -> [NSRect] {
        var lines: [NSRect] = []
        if style.vertical {
            for column in columns.dropLast() where column.id != "icon" {
                lines.append(NSRect(x: column.rect.maxX - thickness / 2, y: bounds.minY,
                                    width: thickness, height: bounds.height))
            }
        }
        if style.horizontal {
            for row in rows {
                lines.append(NSRect(x: bounds.minX, y: row.maxY - thickness / 2,
                                    width: bounds.width, height: thickness))
            }
        }
        return lines
    }

    /// Краткий режим: элементы идут колонками сверху вниз, по `rowsPerColumn` в колонке,
    /// элемент `i` стоит в колонке `i / rowsPerColumn` и строке `i % rowsPerColumn`.
    /// Горизонтальные — под каждым элементом в ширину его колонки; вертикальные — между
    /// колонками, на высоту полной колонки (левая у любой границы всегда полная).
    static func brief(itemCount: Int, rowsPerColumn: Int, itemWidth: CGFloat, itemHeight: CGFloat,
                      style: Style) -> [NSRect] {
        guard itemCount > 0, rowsPerColumn > 0, itemWidth > 0, itemHeight > 0 else { return [] }
        let columns = (itemCount + rowsPerColumn - 1) / rowsPerColumn
        var lines: [NSRect] = []
        if style.horizontal {
            for item in 0..<itemCount {
                let column = item / rowsPerColumn, row = item % rowsPerColumn
                lines.append(NSRect(x: CGFloat(column) * itemWidth,
                                    y: CGFloat(row + 1) * itemHeight - thickness / 2,
                                    width: itemWidth, height: thickness))
            }
        }
        if style.vertical, columns > 1 {
            for column in 1..<columns {
                lines.append(NSRect(x: CGFloat(column) * itemWidth - thickness / 2, y: 0,
                                    width: thickness, height: CGFloat(rowsPerColumn) * itemHeight))
            }
        }
        return lines
    }
}
