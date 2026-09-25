import Combine
import CoreGraphics
import Foundation

/// Перетаскивание кнопки внутри своей части туннеля: папки среди папок, операции среди
/// операций. Здесь только счёт — где призрак и к какому месту он ближе; вид рисует.
///
/// Места — это рамки кнопок в момент захвата, снимком. Во время перестановки настоящие
/// кнопки едут с анимацией, а места стоят: иначе призрак прыгал бы вслед за ними и
/// перестановка дёргалась бы туда-сюда на границе.
struct TunnelReorder: Equatable {

    enum Section { case folders, actions }

    let section: Section
    /// Путь папки или ключ операции — то, чем кнопка известна хранилищу.
    let id: String
    /// Рамки кнопок части в порядке списка, в координатах туннеля (ось вниз).
    let slots: [CGRect]
    /// На сколько ниже центра кнопки её взяли: призрак висит там, где взяли, а не
    /// подпрыгивает к центру в первое же мгновение.
    let grab: CGFloat
    /// Центр призрака по вертикали, в координатах туннеля.
    private(set) var ghostCenter: CGFloat

    /// nil — рамок ещё нет (кнопка не успела отчитаться) или кнопка не из этого списка.
    init?(section: Section, id: String, ids: [String], frames: [String: CGRect],
          mouseY: CGFloat) {
        let slots = ids.compactMap { frames[$0] }
        guard slots.count == ids.count, !slots.isEmpty,
              let index = ids.firstIndex(of: id) else { return nil }
        self.section = section
        self.id = id
        self.slots = slots
        grab = mouseY - slots[index].midY
        ghostCenter = slots[index].midY
    }

    /// Мышь сдвинулась. Призрак не улетает из своей части: выше первого и ниже последнего
    /// места ему делать нечего — папка среди операций не бывает.
    mutating func follow(mouseY: CGFloat) {
        let free = mouseY - grab
        ghostCenter = min(max(free, slots[0].midY), slots[slots.count - 1].midY)
    }

    /// Место, к которому призрак сейчас ближе всего, — туда и встанет кнопка.
    var targetIndex: Int {
        slots.indices.min {
            abs(slots[$0].midY - ghostCenter) < abs(slots[$1].midY - ghostCenter)
        } ?? 0
    }

    var slotHeight: CGFloat { slots[0].height }
}

/// Папка, брошенная в туннель извне, встаёт туда, где её отпустили, а не в конец.
enum TunnelDrop {

    /// Номер места по точке броска (ось вниз): перед первой кнопкой, чья середина ниже
    /// точки. Ниже всех — в конец.
    static func insertionIndex(y: CGFloat, slots: [CGRect]) -> Int {
        slots.firstIndex { $0.midY >= y } ?? slots.count
    }

    /// Где рисовать черту вставки: в зазоре над кнопкой с этим номером, под последней —
    /// если в конец. Без кнопок черты нет.
    static func lineY(index: Int, slots: [CGRect], gap: CGFloat) -> CGFloat? {
        guard !slots.isEmpty else { return nil }
        if index < slots.count { return slots[index].minY - gap / 2 }
        return slots[slots.count - 1].maxY + gap / 2
    }
}

/// Живое состояние броска папки в туннель — мост между AppKit, который принимает
/// перетаскивание, и SwiftUI, который рисует черту.
@MainActor
final class TunnelDropState: ObservableObject {

    static let shared = TunnelDropState()

    /// Рамки кнопок папок в координатах туннеля, сверху вниз. Пишет вид, читают приём
    /// броска и правая кнопка — чтобы знать, чьё меню показывать.
    var folderSlots: [CGRect] = []
    /// Рамки кнопок операций — в порядке списка операций.
    var actionSlots: [CGRect] = []
    /// Зазор между кнопками — чтобы черта легла ровно посередине.
    var gap: CGFloat = 2
    /// Куда встанет папка, пока её несут над туннелем; nil — над туннелем никого нет.
    @Published var insertionIndex: Int?
}

/// Сколько кнопок папок и операций показывать, когда туннелю не хватает высоты.
///
/// Остальные уходят в кнопку «Ещё» с выпадающим списком — она сама занимает одно
/// место, поэтому секция, которой не хватило, показывает на одну кнопку меньше, чем ей
/// отведено. Место делится пополам; секции, которой нужно меньше половины, отдаётся
/// столько, сколько нужно, а остаток — другой.
enum TunnelOverflow {

    struct Plan: Equatable {
        /// Сколько мест отведено секции папок (включая «Сеть» и, если надо, «Ещё»).
        let folders: Int
        /// Сколько мест отведено секции операций (включая «Ещё», если надо).
        let actions: Int
        let foldersHidden: Bool
        let actionsHidden: Bool

        static func all(folders: Int, actions: Int) -> Plan {
            Plan(folders: folders, actions: actions, foldersHidden: false, actionsHidden: false)
        }
    }

    /// Пустая часть туннеля — высота под обе секции кнопок: вся высота туннеля минус то,
    /// что занято всегда, — шапка, разделитель между папками и операциями и зазоры между
    /// блоками. Остаток годен под N кнопок и N−1 зазор между ними, как того и ждёт
    /// plan(available:…).
    ///
    /// Зазоров между блоками ровно четыре: шапка — пустое место — папки — разделитель —
    /// операции; при сдвинутой стопке добавляется пятый, у распорки сдвига.
    ///
    /// Сам сдвиг стопки здесь НЕ вычитается: он занимает только то, что осталось после
    /// кнопок (см. usableOffset). Иначе сдвиг на сто точек прятал в «Ещё» три кнопки, а
    /// под ними оставалось пустое место — ровно то, что было видно на экране.
    static func available(tunnelHeight: CGFloat, topBlock: CGFloat, midBlock: CGFloat,
                          hasOffset: Bool, spacing: CGFloat) -> CGFloat {
        let gap = max(spacing, 0)
        let blockGaps = gap * (hasOffset ? 5 : 4)
        return max(0, tunnelHeight - topBlock - midBlock - blockGaps - edgeMargin)
    }

    /// Что осталось от пустой части после показанных кнопок.
    static func leftover(available: CGFloat, shown: Int, itemHeight: CGFloat,
                         spacing: CGFloat) -> CGFloat {
        guard shown > 0 else { return max(available, 0) }
        let used = CGFloat(shown) * max(itemHeight, 0)
            + CGFloat(shown - 1) * max(spacing, 0)
        return max(0, available - used)
    }

    /// Сдвиг стопки, который туннель может себе позволить: не больше остатка. Когда места
    /// вдоволь — сдвиг тот, что задал человек; когда его нет — стопка уступает место
    /// кнопкам, а не наоборот.
    static func usableOffset(_ offsetY: CGFloat, leftover: CGFloat) -> CGFloat {
        let room = max(leftover, 0)
        return offsetY < 0 ? -min(-offsetY, room) : min(offsetY, room)
    }

    /// Запас у нижнего края: последняя кнопка не должна упираться в рамку туннеля, и
    /// округления не должны её срезать — туннель обрезает всё, что вышло за края.
    static let edgeMargin: CGFloat = 4

    /// Высота одной кнопки. Берётся ИЗМЕРЕННАЯ у самих кнопок: прежняя оценка «34 точки с
    /// подписью» была на треть больше настоящих двадцати пяти, и туннель убирал в «Ещё»
    /// три-четыре кнопки, которым места хватало. Оценка нужна только на первом проходе,
    /// пока ни одна кнопка о себе ещё не отчиталась.
    static func itemHeight(measured: [CGFloat], showsLabels: Bool) -> CGFloat {
        let real = measured.filter { $0 > 1 }.max()
        return max(real ?? (showsLabels ? 25 : 22), 1)
    }

    /// - available: высота под обе секции вместе, уже без шапки, разделителя и отступов.
    /// - itemHeight, spacing: высота кнопки и зазор между кнопками.
    /// - folders, actions: сколько кнопок нужно каждой секции.
    static func plan(available: CGFloat, itemHeight: CGFloat, spacing: CGFloat,
                     folders: Int, actions: Int) -> Plan {
        let step = max(itemHeight, 1) + max(spacing, 0)
        let slots = max(0, Int(floor((max(available, 0) + max(spacing, 0)) / step)))
        if folders + actions <= slots { return .all(folders: folders, actions: actions) }
        let half = slots / 2
        let actionsAllotted = min(actions, max(half, slots - folders))
        let foldersAllotted = min(folders, slots - actionsAllotted)
        return Plan(folders: foldersAllotted, actions: actionsAllotted,
                    foldersHidden: foldersAllotted < folders,
                    actionsHidden: actionsAllotted < actions)
    }
}
