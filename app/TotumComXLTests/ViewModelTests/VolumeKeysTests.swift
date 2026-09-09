import AppKit
import XCTest
@testable import TotumComXLApp

/// F10–F12 у Mac — «звук выкл / тише / громче». Наш режим F-клавиш переключает всю
/// клавиатуру разом и отнимает их у системы; программе они не нужны, поэтому работу
/// клавиатуры делаем за неё сами — но только когда режим включили мы.
final class VolumeKeysTests: XCTestCase {

    func test_триКлавишиГромкостиУзнаются() {
        XCTAssertEqual(VolumeKeys.action(forKeyCode: 109, flags: []), .mute)
        XCTAssertEqual(VolumeKeys.action(forKeyCode: 103, flags: []), .down)
        XCTAssertEqual(VolumeKeys.action(forKeyCode: 111, flags: []), .up)
    }

    /// Живое нажатие приходит с флагом .function и служебным битом клавиатуры — измерено
    /// на настоящем нажатии; проверка модификаторов не должна об это спотыкаться.
    func test_флагиНастоящегоНажатияНеМешают() {
        let real = NSEvent.ModifierFlags(rawValue: 8_388_864)   // .function + служебный бит
        XCTAssertEqual(VolumeKeys.action(forKeyCode: 111, flags: real), .up)
        XCTAssertEqual(VolumeKeys.action(forKeyCode: 109, flags: real), .mute)
    }

    func test_рабочиеКлавишиПрограммыНеТрогаем() {
        for code: UInt16 in [122, 120, 99, 118, 96, 97, 98, 100, 101] {
            XCTAssertNil(VolumeKeys.action(forKeyCode: code, flags: []),
                         "код \(code) — клавиша программы")
        }
    }

    func test_сМодификаторомЭтоДругоеСочетание() {
        for flags: NSEvent.ModifierFlags in [[.command], [.option], [.shift], [.control]] {
            XCTAssertNil(VolumeKeys.action(forKeyCode: 111, flags: flags))
        }
        XCTAssertEqual(VolumeKeys.action(forKeyCode: 111, flags: [.capsLock]), .up,
                       "Caps Lock не мешает")
    }
}

/// Шаг громкости — как у клавиш Mac: шестнадцатая шкалы, по сетке делений, без выхода за края.
final class SystemVolumeStepTests: XCTestCase {

    func test_шагВверхИВниз() {
        XCTAssertEqual(SystemVolume.stepped(from: 0.5, up: true), 0.5625, accuracy: 0.0001)
        XCTAssertEqual(SystemVolume.stepped(from: 0.5, up: false), 0.4375, accuracy: 0.0001)
    }

    func test_заКраяШкалыНеВыходим() {
        XCTAssertEqual(SystemVolume.stepped(from: 1, up: true), 1, accuracy: 0.0001)
        XCTAssertEqual(SystemVolume.stepped(from: 0, up: false), 0, accuracy: 0.0001)
        XCTAssertEqual(SystemVolume.stepped(from: 2, up: true), 1, accuracy: 0.0001)
        XCTAssertEqual(SystemVolume.stepped(from: -1, up: false), 0, accuracy: 0.0001)
    }

    /// Дробное значение от прошлых нажатий подтягивается к сетке, а не копит хвосты.
    func test_значениеСадитсяНаСеткуДелений() {
        XCTAssertEqual(SystemVolume.stepped(from: 0.49999997, up: true), 0.5625, accuracy: 0.0001)
        XCTAssertEqual(SystemVolume.stepped(from: 0.51, up: false), 0.4375, accuracy: 0.0001)
    }
}
