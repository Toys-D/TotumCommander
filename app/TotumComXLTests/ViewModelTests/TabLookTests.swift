import XCTest
@testable import TotumComXLApp

/// Активная вкладка выше остальных (TabLook).
final class TabLookTests: XCTestCase {

    func test_активнаяВкладкаВышеНаПодъём_остальныеКакЗаданы() {
        XCTAssertEqual(TabLook.chipHeight(chip: 32, lift: 4, isActive: true), 36)
        XCTAssertEqual(TabLook.chipHeight(chip: 32, lift: 4, isActive: false), 32)
        XCTAssertEqual(TabLook.chipHeight(chip: 32, lift: 0, isActive: true), 32, "0 — все вровень")
    }

    func test_подъёмВПределахПолзунка() {
        XCTAssertEqual(TabLook.chipHeight(chip: 28, lift: -5, isActive: true), 28)
        XCTAssertEqual(TabLook.chipHeight(chip: 28, lift: 50, isActive: true), 28 + 10)
    }

    func test_полосаРастётТолькоКогдаПоднятаяВкладкаНеВходит() {
        XCTAssertEqual(TabLook.barHeight(bar: 36, chip: 32, lift: 4), 36, "входит — полоса как задана")
        XCTAssertEqual(TabLook.barHeight(bar: 32, chip: 30, lift: 4), 34, "не входит — ровно по вкладке")
        XCTAssertEqual(TabLook.barHeight(bar: 40, chip: 28, lift: 0), 40)
    }
}
