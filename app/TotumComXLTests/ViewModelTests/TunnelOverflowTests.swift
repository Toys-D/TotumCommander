import XCTest
@testable import TotumComXLApp

/// Сколько кнопок туннеля показать, когда высоты не хватает; остальные — в «Ещё».
final class TunnelOverflowTests: XCTestCase {

    /// Кнопка 30, зазор 10: место — 40 на кнопку; 400 высоты — 10 мест.
    private func plan(_ available: CGFloat, folders: Int, actions: Int) -> TunnelOverflow.Plan {
        TunnelOverflow.plan(available: available, itemHeight: 30, spacing: 10, folders: folders, actions: actions)
    }

    func test_всёВлезает_НичегоНеПрячется() {
        let p = plan(1000, folders: 8, actions: 6)
        XCTAssertEqual(p, .all(folders: 8, actions: 6))
        XCTAssertFalse(p.foldersHidden); XCTAssertFalse(p.actionsHidden)
    }

    func test_неВлезает_МестоДелитсяПополам() {
        // 10 мест на 14 кнопок: по 5 каждой секции, обе прячут хвост в «Ещё».
        let p = plan(400, folders: 8, actions: 6)
        XCTAssertEqual(p.folders, 5); XCTAssertEqual(p.actions, 5)
        XCTAssertTrue(p.foldersHidden); XCTAssertTrue(p.actionsHidden)
    }

    func test_секцииКоторойНужноМеньше_ОтдаётсяСколькоНужно() {
        // Папок 3 — им всё, операциям остальные 7 из 10.
        let p = plan(400, folders: 3, actions: 8)
        XCTAssertEqual(p.folders, 3); XCTAssertFalse(p.foldersHidden)
        XCTAssertEqual(p.actions, 7); XCTAssertTrue(p.actionsHidden)
        // И наоборот.
        let q = plan(400, folders: 9, actions: 2)
        XCTAssertEqual(q.actions, 2); XCTAssertFalse(q.actionsHidden)
        XCTAssertEqual(q.folders, 8); XCTAssertTrue(q.foldersHidden)
    }

    func test_совсемНетМеста_НичегоНеПоказывается() {
        let p = plan(0, folders: 5, actions: 5)
        XCTAssertEqual(p.folders, 0); XCTAssertEqual(p.actions, 0)
        XCTAssertTrue(p.foldersHidden); XCTAssertTrue(p.actionsHidden)
        XCTAssertEqual(plan(-50, folders: 5, actions: 5).folders, 0, "отрицательная высота — как ноль")
    }

    func test_зазорСчитаетсяМеждуКнопками_АНеПослеПоследней() {
        // 3 кнопки по 30 с двумя зазорами по 10 = 110 — влезают ровно в 110.
        XCTAssertEqual(plan(110, folders: 2, actions: 1), .all(folders: 2, actions: 1))
        XCTAssertTrue(plan(109, folders: 2, actions: 1).foldersHidden || plan(109, folders: 2, actions: 1).actionsHidden)
    }
}

/// Пустая часть туннеля и высота кнопки — то, из чего считается число мест.
final class TunnelSpaceTests: XCTestCase {

    /// Высота кнопки берётся у самих кнопок, а не из оценки: оценка «34» прятала в «Ещё»
    /// кнопки, которым хватало места (настоящая высота с подписью — 25).
    func test_высотаКнопки_ИзмереннаяПеревешиваетОценку() {
        XCTAssertEqual(TunnelOverflow.itemHeight(measured: [25, 25, 25], showsLabels: true), 25)
        XCTAssertEqual(TunnelOverflow.itemHeight(measured: [22, 22], showsLabels: false), 22)
        // Самая высокая из кнопок: по ней встают все места.
        XCTAssertEqual(TunnelOverflow.itemHeight(measured: [22, 25, 24], showsLabels: true), 25)
    }

    func test_высотаКнопки_ОценкаТолькоПокаНечегоМерить() {
        XCTAssertEqual(TunnelOverflow.itemHeight(measured: [], showsLabels: true), 25)
        XCTAssertEqual(TunnelOverflow.itemHeight(measured: [], showsLabels: false), 22)
        XCTAssertEqual(TunnelOverflow.itemHeight(measured: [0, 0], showsLabels: true), 25,
                       "нулевые рамки — ещё не измерено")
    }

    /// 400 высоты, шапка 80, разделитель 20, зазор 10: четыре зазора между блоками и
    /// запас у края — под кнопки остаётся 256.
    func test_пустаяЧасть_ЭтоВысотаБезШапкиРазделителяИЗазоров() {
        XCTAssertEqual(TunnelOverflow.available(tunnelHeight: 400, topBlock: 80, midBlock: 20,
                                                hasOffset: false, spacing: 10),
                       260 - TunnelOverflow.edgeMargin)
    }

    /// Сдвинутая стопка добавляет распорку, а с ней ещё один зазор — но сам сдвиг места
    /// у кнопок не отнимает.
    func test_пустаяЧасть_СдвигДобавляетТолькоЗазорРаспорки() {
        XCTAssertEqual(TunnelOverflow.available(tunnelHeight: 400, topBlock: 80, midBlock: 20,
                                                hasOffset: true, spacing: 10),
                       250 - TunnelOverflow.edgeMargin)
    }

    func test_пустаяЧасть_НикогдаНеОтрицательная() {
        XCTAssertEqual(TunnelOverflow.available(tunnelHeight: 40, topBlock: 80, midBlock: 20,
                                                hasOffset: false, spacing: 10), 0)
    }

    /// Остаток — то, что не заняли показанные кнопки.
    func test_остаток_ЭтоПустаяЧастьБезПоказанныхКнопок() {
        // 4 кнопки по 25 с тремя зазорами по 10 = 130; из 200 остаётся 70.
        XCTAssertEqual(TunnelOverflow.leftover(available: 200, shown: 4, itemHeight: 25,
                                               spacing: 10), 70)
        XCTAssertEqual(TunnelOverflow.leftover(available: 200, shown: 0, itemHeight: 25,
                                               spacing: 10), 200)
        XCTAssertEqual(TunnelOverflow.leftover(available: 100, shown: 8, itemHeight: 25,
                                               spacing: 10), 0, "меньше нуля не бывает")
    }

    /// Сдвиг стопки живёт на остатке: сколько осталось — на столько и сдвинулась.
    /// Пока места вдоволь, сдвиг тот, что задал человек.
    func test_сдвигСтопки_НеБольшеОстатка() {
        XCTAssertEqual(TunnelOverflow.usableOffset(100, leftover: 300), 100)
        XCTAssertEqual(TunnelOverflow.usableOffset(100, leftover: 40), 40)
        XCTAssertEqual(TunnelOverflow.usableOffset(100, leftover: 0), 0,
                       "тесно — кнопки важнее сдвига")
        XCTAssertEqual(TunnelOverflow.usableOffset(-100, leftover: 40), -40,
                       "сдвиг вверх укорачивается так же")
        XCTAssertEqual(TunnelOverflow.usableOffset(0, leftover: 300), 0)
    }

    /// Проверка по месту: туннель 700 при шапке 96 и зазоре 10 вмещает 14 кнопок по 25 —
    /// с прежней оценкой 34 их было бы 10, и четыре уходили в «Ещё» при пустом туннеле.
    func test_вместеСПланом_ЧетыреКнопкиБольшеЧемПоПрежнейОценке() {
        let free = TunnelOverflow.available(tunnelHeight: 700, topBlock: 96, midBlock: 20,
                                            hasOffset: false, spacing: 10)
        let honest = TunnelOverflow.plan(available: free, itemHeight: 25, spacing: 10,
                                         folders: 7, actions: 7)
        XCTAssertEqual(honest, .all(folders: 7, actions: 7))
        let guessed = TunnelOverflow.plan(available: free, itemHeight: 34, spacing: 10,
                                          folders: 7, actions: 7)
        XCTAssertTrue(guessed.foldersHidden || guessed.actionsHidden)
    }
}

/// Сдвиг стопки не должен стоить кнопок: это была ровно та жалоба — сдвинутая на сто
/// точек стопка прятала кнопки в «Ещё», а под ними оставалось пустое место.
extension TunnelSpaceTests {

    func test_сдвинутаяСтопкаНеПрячетКнопок_ПокаЕстьМесто() {
        // Шестнадцать кнопок по 25 с пятнадцатью зазорами — 550; плюс шапка, разделитель,
        // зазоры блоков и запас у края: 800 хватает, и ещё остаётся на сдвиг.
        let height: CGFloat = 800, top: CGFloat = 96, mid: CGFloat = 20, gap: CGFloat = 10
        let free = TunnelOverflow.available(tunnelHeight: height, topBlock: top, midBlock: mid,
                                            hasOffset: true, spacing: gap)
        let plan = TunnelOverflow.plan(available: free, itemHeight: 25, spacing: gap,
                                       folders: 8, actions: 8)
        XCTAssertEqual(plan, .all(folders: 8, actions: 8), "шестнадцать кнопок по 25 влезают")
        let left = TunnelOverflow.leftover(available: free, shown: 16, itemHeight: 25, spacing: gap)
        XCTAssertEqual(TunnelOverflow.usableOffset(100, leftover: left), left,
                       "сдвиг берёт остаток, а не место кнопок")
        XCTAssertLessThan(TunnelOverflow.usableOffset(100, leftover: left), 100)
    }

    /// А когда кнопок больше, чем мест, остаток меньше высоты кнопки — пустого места,
    /// в которое влезла бы ещё одна, не остаётся.
    func test_когдаПрячетВЕщё_ПустогоМестаНаКнопкуНеОстаётся() {
        let free = TunnelOverflow.available(tunnelHeight: 480, topBlock: 96, midBlock: 20,
                                            hasOffset: false, spacing: 10)
        let plan = TunnelOverflow.plan(available: free, itemHeight: 25, spacing: 10,
                                       folders: 8, actions: 8)
        XCTAssertTrue(plan.foldersHidden || plan.actionsHidden)
        let left = TunnelOverflow.leftover(available: free, shown: plan.folders + plan.actions,
                                           itemHeight: 25, spacing: 10)
        XCTAssertLessThan(left, 25 + 10, "иначе туда влезла бы ещё кнопка с зазором")
    }

    /// Главное правило, каким бы ни было окно: если что-то ушло в «Ещё», свободного места
    /// на ещё одну кнопку уже нет — и наоборот, показанное никогда не выходит за туннель.
    /// Настройки как у хозяина машины: зазор 10, стопка сдвинута.
    func test_наЛюбойВысоте_ЕслиПрячет_ТоМестаНет() {
        let item: CGFloat = 25, gap: CGFloat = 10
        for height in stride(from: 200.0, through: 1200.0, by: 5.0) {
            let free = TunnelOverflow.available(tunnelHeight: CGFloat(height), topBlock: 96,
                                                midBlock: 20, hasOffset: true, spacing: gap)
            let plan = TunnelOverflow.plan(available: free, itemHeight: item, spacing: gap,
                                           folders: 8, actions: 8)
            let shown = plan.folders + plan.actions
            let left = TunnelOverflow.leftover(available: free, shown: shown,
                                               itemHeight: item, spacing: gap)
            if plan.foldersHidden || plan.actionsHidden {
                // Ещё одна кнопка стоит не только своей высоты, но и зазора перед ней.
                XCTAssertLessThan(left, item + gap, "высота \(height): пустое место на кнопку")
            }
            let used = CGFloat(shown) * item + CGFloat(max(shown - 1, 0)) * gap
            XCTAssertLessThanOrEqual(used, free, "высота \(height): не влезает")
        }
    }
}
