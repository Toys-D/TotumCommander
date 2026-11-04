import AppKit
import XCTest
@testable import TotumComXLApp

/// Пипетка: держат до ответа, а лупу службы, пережившую ответ (ошибка macOS 27), убирают —
/// закрывают службу. Настоящая пипетка в проверках не открывается — она закрыла бы экран, — и
/// настоящая служба не закрывается: вместо них подмены.
@MainActor
final class ScreenColorPickTests: XCTestCase {

    private final class FakeSampler: ScreenColorSampler {
        var handler: (@Sendable (NSColor?) -> Void)?
        func show(selectionHandler: @escaping @Sendable (NSColor?) -> Void) { handler = selectionHandler }
    }

    private var terminated: [pid_t] = []

    override func setUp() {
        super.setUp()
        terminated = []
        ScreenColorPick.lingeringSampler = { nil }
        ScreenColorPick.terminate = { [weak self] in self?.terminated.append($0) }
        ScreenColorPick.lingerCheckDelay = 0.01
    }

    override func tearDown() {
        ScreenColorPick.makeSampler = { NSColorSampler() }
        ScreenColorPick.lingeringSampler = { ScreenColorPick.findLingeringSampler() }
        ScreenColorPick.terminate = { _ = kill($0, SIGKILL) }
        ScreenColorPick.lingerCheckDelay = 1
        super.tearDown()
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    func test_пипеткаЖивёт_покаНеОтветит_иОтпускаетсяПосле() {
        weak var shown: FakeSampler?
        ScreenColorPick.makeSampler = { let fake = FakeSampler(); shown = fake; return fake }
        var picked: NSColor?
        autoreleasepool {
            ScreenColorPick.start { picked = $0 }
        }
        settle()
        XCTAssertNotNil(shown, "пипетка на экране — её держат")

        shown?.handler?(.systemRed)
        settle()
        XCTAssertEqual(picked, .systemRed)
        XCTAssertNil(ScreenColorPick.active, "ответила — отпущена")
    }

    /// Пипетка, что так и не ответила, не запирает кнопку: новая её сменяет и отвечает сама.
    func test_новаяПипеткаСменяетПрежнюю() {
        var fakes: [FakeSampler] = []
        ScreenColorPick.makeSampler = { let fake = FakeSampler(); fakes.append(fake); return fake }
        var answers: [NSColor?] = []
        ScreenColorPick.start { answers.append($0) }
        ScreenColorPick.start { answers.append($0) }
        XCTAssertTrue(ScreenColorPick.active === fakes[1])

        fakes[0].handler?(nil)          // прежняя отозвалась поздно — новую не отпускает
        settle()
        XCTAssertTrue(ScreenColorPick.active === fakes[1])
        fakes[1].handler?(.systemBlue)
        settle()
        XCTAssertNil(ScreenColorPick.active)
        XCTAssertEqual(answers.count, 2)
    }

    // MARK: - Лупа, пережившая ответ

    func test_лупаОсталасьПослеОтвета_службуЗакрывают() {
        var fakes: [FakeSampler] = []
        ScreenColorPick.makeSampler = { let fake = FakeSampler(); fakes.append(fake); return fake }
        ScreenColorPick.lingeringSampler = { 4242 }
        ScreenColorPick.start { _ in }
        fakes[0].handler?(.systemRed)
        settle()
        XCTAssertEqual(terminated, [4242])
    }

    func test_лупаУшла_службуНеТрогают() {
        var fakes: [FakeSampler] = []
        ScreenColorPick.makeSampler = { let fake = FakeSampler(); fakes.append(fake); return fake }
        ScreenColorPick.start { _ in }
        fakes[0].handler?(.systemRed)
        settle()
        XCTAssertEqual(terminated, [])
    }

    /// Человек сразу открыл пипетку снова: на экране её законная лупа — службу не закрывать.
    func test_открылиНовуюПипетку_еёЛупуНеТрогают() {
        var fakes: [FakeSampler] = []
        ScreenColorPick.makeSampler = { let fake = FakeSampler(); fakes.append(fake); return fake }
        ScreenColorPick.lingeringSampler = { 4242 }
        ScreenColorPick.lingerCheckDelay = 0.2
        ScreenColorPick.start { _ in }
        fakes[0].handler?(.systemRed)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        ScreenColorPick.start { _ in }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(terminated, [])
    }
}
