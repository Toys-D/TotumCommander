import CoreGraphics
import Foundation

/// Как делится часть: рядом (граница вертикальная) или друг под другом.
enum TerminalSplitAxis: Equatable {
    case sideBySide
    case stacked
}

/// Куда перейти от части: ⌘⌥ со стрелкой.
enum TerminalDirection {
    case left, right, up, down
}

/// Полоска между двумя соседними частями: какое разделение (путь от корня по номерам детей),
/// между какими детьми (`index` и `index + 1`) и где она лежит.
struct TerminalDivider: Equatable {
    let path: [Int]
    let index: Int
    let axis: TerminalSplitAxis
    let rect: CGRect
}

struct TerminalLayoutGeometry {
    var panes: [UUID: CGRect] = [:]
    var dividers: [TerminalDivider] = []
}

/// Раскладка вкладки терминала: часть или разделение частей с долями.
///
/// Чистое значение: деление, закрытие, геометрия и переходы считаются здесь, без окон и
/// процессов, — вид только раскладывает готовые прямоугольники. Координаты — y вниз: первая
/// часть разделения «друг под другом» верхняя.
indirect enum TerminalLayout: Equatable {
    case pane(UUID)
    case split(TerminalSplitAxis, [TerminalLayout], [CGFloat])

    /// Части слева направо и сверху вниз — в порядке дерева.
    var panes: [UUID] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, let children, _): return children.flatMap(\.panes)
        }
    }

    func contains(_ id: UUID) -> Bool { panes.contains(id) }

    // MARK: - Деление и закрытие

    /// Разделить часть `target`, поставив `newPane` после неё.
    ///
    /// Родитель той же оси получает нового соседа, и тот делит долю разделённой части пополам —
    /// три части рядом, а не две в двух. Иначе часть становится разделением из двух половин.
    func splitting(_ target: UUID, axis: TerminalSplitAxis, newPane: UUID) -> TerminalLayout {
        switch self {
        case .pane(let id):
            guard id == target else { return self }
            return .split(axis, [.pane(id), .pane(newPane)], [0.5, 0.5])
        case .split(let ownAxis, let children, let fractions):
            guard contains(target) else { return self }
            if ownAxis == axis, let i = children.firstIndex(of: .pane(target)) {
                var kids = children, shares = fractions
                let half = shares[i] / 2
                shares[i] = half
                kids.insert(.pane(newPane), at: i + 1)
                shares.insert(half, at: i + 1)
                return .split(ownAxis, kids, shares)
            }
            return .split(ownAxis, children.map { $0.splitting(target, axis: axis, newPane: newPane) },
                          fractions)
        }
    }

    /// Убрать часть. Её доля уходит соседу (предыдущему, у первой — следующему); разделение из
    /// одного ребёнка схлопывается, вложенное разделение той же оси вливается в родителя.
    /// Последняя часть — `nil`.
    func removing(_ target: UUID) -> TerminalLayout? {
        switch self {
        case .pane(let id):
            return id == target ? nil : self
        case .split(let axis, let children, let fractions):
            guard contains(target) else { return self }
            var kids = children, shares = fractions
            if let i = kids.firstIndex(of: .pane(target)) {
                let freed = shares[i]
                kids.remove(at: i)
                shares.remove(at: i)
                guard !kids.isEmpty else { return nil }
                shares[i > 0 ? i - 1 : 0] += freed
            } else if let i = kids.firstIndex(where: { $0.contains(target) }) {
                if let rest = kids[i].removing(target) {
                    kids[i] = rest
                } else {
                    kids.remove(at: i)
                    let freed = shares.remove(at: i)
                    guard !kids.isEmpty else { return nil }
                    shares[i > 0 ? i - 1 : 0] += freed
                }
            }
            return TerminalLayout.split(axis, kids, shares).normalized()
        }
    }

    /// Один ребёнок — он сам; дети той же оси — вливаются в родителя со своими долями.
    private func normalized() -> TerminalLayout {
        guard case .split(let axis, let children, let fractions) = self else { return self }
        if children.count == 1 { return children[0] }
        var kids: [TerminalLayout] = [], shares: [CGFloat] = []
        for (child, share) in zip(children, fractions) {
            if case .split(let childAxis, let grandchildren, let childShares) = child, childAxis == axis {
                kids.append(contentsOf: grandchildren)
                shares.append(contentsOf: childShares.map { $0 * share })
            } else {
                kids.append(child)
                shares.append(share)
            }
        }
        return .split(axis, kids, shares)
    }

    // MARK: - Геометрия

    /// Прямоугольники частей и полосок-разделителей толщиной `divider` в `rect`.
    func frames(in rect: CGRect, divider: CGFloat) -> TerminalLayoutGeometry {
        var geometry = TerminalLayoutGeometry()
        collect(into: &geometry, rect: rect, divider: divider, path: [])
        return geometry
    }

    private func collect(into geometry: inout TerminalLayoutGeometry, rect: CGRect,
                         divider: CGFloat, path: [Int]) {
        switch self {
        case .pane(let id):
            geometry.panes[id] = rect
        case .split(let axis, let children, let fractions):
            let rects = Self.childRects(axis: axis, fractions: fractions, in: rect, divider: divider)
            for (i, child) in children.enumerated() {
                child.collect(into: &geometry, rect: rects[i], divider: divider, path: path + [i])
                guard i < children.count - 1 else { continue }
                let bar = axis == .sideBySide
                    ? CGRect(x: rects[i].maxX, y: rect.minY, width: divider, height: rect.height)
                    : CGRect(x: rect.minX, y: rects[i].maxY, width: rect.width, height: divider)
                geometry.dividers.append(TerminalDivider(path: path, index: i, axis: axis, rect: bar))
            }
        }
    }

    /// Доли — в целые точки; последний ребёнок забирает остаток, чтобы не было щели у края.
    private static func childRects(axis: TerminalSplitAxis, fractions: [CGFloat],
                                   in rect: CGRect, divider: CGFloat) -> [CGRect] {
        let total = axis == .sideBySide ? rect.width : rect.height
        let available = max(0, total - divider * CGFloat(fractions.count - 1))
        var rects: [CGRect] = []
        var offset: CGFloat = 0
        for (i, share) in fractions.enumerated() {
            let length = i == fractions.count - 1
                ? max(0, available - (offset - divider * CGFloat(i)))
                : (available * share).rounded(.down)
            rects.append(axis == .sideBySide
                         ? CGRect(x: rect.minX + offset, y: rect.minY, width: length, height: rect.height)
                         : CGRect(x: rect.minX, y: rect.minY + offset, width: rect.width, height: length))
            offset += length + divider
        }
        return rects
    }

    /// Прямоугольник узла по пути от корня.
    private func rect(at path: [Int], in rect: CGRect, divider: CGFloat) -> CGRect? {
        guard let first = path.first else { return rect }
        guard case .split(let axis, let children, let fractions) = self,
              children.indices.contains(first) else { return nil }
        let rects = Self.childRects(axis: axis, fractions: fractions, in: rect, divider: divider)
        return children[first].rect(at: Array(path.dropFirst()), in: rects[first], divider: divider)
    }

    /// Разделитель между детьми `index` и `index + 1` разделения по пути `path` перетащили
    /// так, что его передний край стоит на `position`. Меняются доли только этих двух детей,
    /// и ни один не становится меньше `minimum` точек.
    func movingDivider(at path: [Int], index: Int, to position: CGFloat, in rect: CGRect,
                       divider: CGFloat, minimum: CGFloat) -> TerminalLayout {
        guard let nodeRect = self.rect(at: path, in: rect, divider: divider) else { return self }
        return replacingNode(at: path) { node in
            guard case .split(let axis, let children, var fractions) = node,
                  fractions.indices.contains(index + 1) else { return node }
            let rects = Self.childRects(axis: axis, fractions: fractions, in: nodeRect, divider: divider)
            let start = axis == .sideBySide ? rects[index].minX : rects[index].minY
            let pair = axis == .sideBySide
                ? rects[index].width + rects[index + 1].width
                : rects[index].height + rects[index + 1].height
            guard pair > 0 else { return node }
            let low = min(minimum, pair / 2)
            let first = min(max(position - start, low), pair - low)
            let shares = fractions[index] + fractions[index + 1]
            fractions[index] = shares * first / pair
            fractions[index + 1] = shares - fractions[index]
            return .split(axis, children, fractions)
        }
    }

    private func replacingNode(at path: [Int], with change: (TerminalLayout) -> TerminalLayout) -> TerminalLayout {
        guard let first = path.first else { return change(self) }
        guard case .split(let axis, var children, let fractions) = self,
              children.indices.contains(first) else { return self }
        children[first] = children[first].replacingNode(at: Array(path.dropFirst()), with: change)
        return .split(axis, children, fractions)
    }

    // MARK: - Переходы

    /// Ближайшая часть в направлении `direction`: она должна лежать за краем этой и перекрывать
    /// её поперёк. Из равных по расстоянию — верхняя (для «влево/вправо») или левая.
    static func neighbour(of id: UUID, direction: TerminalDirection, frames: [UUID: CGRect]) -> UUID? {
        guard let from = frames[id] else { return nil }
        var best: (id: UUID, distance: CGFloat, across: CGFloat)?
        for (other, rect) in frames where other != id {
            let distance: CGFloat, overlap: CGFloat, across: CGFloat
            switch direction {
            case .right:
                distance = rect.minX - from.maxX
                overlap = min(rect.maxY, from.maxY) - max(rect.minY, from.minY)
                across = rect.minY
            case .left:
                distance = from.minX - rect.maxX
                overlap = min(rect.maxY, from.maxY) - max(rect.minY, from.minY)
                across = rect.minY
            case .down:
                distance = rect.minY - from.maxY
                overlap = min(rect.maxX, from.maxX) - max(rect.minX, from.minX)
                across = rect.minX
            case .up:
                distance = from.minY - rect.maxY
                overlap = min(rect.maxX, from.maxX) - max(rect.minX, from.minX)
                across = rect.minX
            }
            guard distance >= 0, overlap > 0 else { continue }
            if let current = best,
               distance > current.distance || (distance == current.distance && across >= current.across) {
                continue
            }
            best = (other, distance, across)
        }
        return best?.id
    }
}
