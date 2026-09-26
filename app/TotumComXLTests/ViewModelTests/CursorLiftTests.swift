import AppKit
import XCTest
@testable import TotumComXLApp

/// Плавный рост под курсором: когда анимировать, с чего начинать и что слой действительно
/// получает анимацию нужной длины.
@MainActor
final class CursorLiftTests: XCTestCase {

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "fcxl.lift.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: - Правило

    /// Только вместе с красотой; сама по себе включена, пока не выключили.
    func test_действуетТолькоСКрасотой() {
        XCTAssertFalse(CursorLift.isEnabled(defaults, supportsBeauty: true), "красота выключена")
        defaults.set(true, forKey: PanelAppearanceSettings.beautyModeEnabledKey)
        XCTAssertTrue(CursorLift.isEnabled(defaults, supportsBeauty: true), "по умолчанию включена")
        XCTAssertFalse(CursorLift.isEnabled(defaults, supportsBeauty: false), "Mac без красоты — нет")
        defaults.set(false, forKey: CursorLift.enabledKey)
        XCTAssertFalse(CursorLift.isEnabled(defaults, supportsBeauty: true), "выключили сами")
    }

    /// Тот же файл и уже на экране — плавно; ячейка под другой файл — сразу.
    func test_анимируетсяТолькоТотЖеЭлемент() {
        XCTAssertTrue(CursorLift.shouldAnimate(sameItem: true, laidOut: true, enabled: true))
        XCTAssertFalse(CursorLift.shouldAnimate(sameItem: false, laidOut: true, enabled: true),
                       "переиспользованная ячейка встаёт в размер сразу")
        XCTAssertFalse(CursorLift.shouldAnimate(sameItem: true, laidOut: false, enabled: true),
                       "ещё не разложена — не с чего расти")
        XCTAssertFalse(CursorLift.shouldAnimate(sameItem: true, laidOut: true, enabled: false))
    }

    /// Текст был крупнее в 1.3 раза — рост начинается с 1.3 и приходит к единице.
    func test_отношениеКеглей() {
        XCTAssertEqual(CursorLift.fontRatio(previousScale: 1.3, newScale: 1), 1.3, accuracy: 0.001)
        XCTAssertEqual(CursorLift.fontRatio(previousScale: 1, newScale: 1.3), 1 / 1.3, accuracy: 0.001)
        XCTAssertEqual(CursorLift.fontRatio(previousScale: 0, newScale: 1.3), 1, "мусор — без перехода")
    }

    // MARK: - Слой

    private func laidOutView() -> NSView {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let view = NSImageView(frame: NSRect(x: 10, y: 10, width: 32, height: 32))
        view.wantsLayer = true
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        withExtendedLifetime(window) {}
        return view
    }

    /// Слой получает анимацию длиной в переход и в конце стоит в новом масштабе.
    func test_значокДорастаетПлавно() throws {
        let view = laidOutView()
        let layer = try XCTUnwrap(view.layer)
        let target = CursorIconZoom.transform(for: 1.3, in: layer)
        CursorLift.animateTransform(of: layer, to: target)
        let animation = try XCTUnwrap(layer.animation(forKey: "fcxl.lift") as? CABasicAnimation)
        XCTAssertEqual(animation.duration, CursorLift.duration, accuracy: 0.001)
        XCTAssertTrue(CATransform3DEqualToTransform(layer.transform, target), "модель — уже в конце пути")

        // Тот же путь через CursorIconZoom: без анимации — сразу и без следа.
        CursorIconZoom.apply(to: view as? NSImageView, scale: 1, animated: false)
        XCTAssertNil(layer.animation(forKey: "fcxl.lift"))
        XCTAssertTrue(CATransform3DIsIdentity(layer.transform))
        CursorIconZoom.apply(to: view as? NSImageView, scale: 1.3, animated: true)
        XCTAssertNotNil(layer.animation(forKey: "fcxl.lift"), "с анимацией — след есть")
    }

    /// Текст стартует с прежнего масштаба и приходит к настоящему шрифту (единице).
    func test_текстДорастаетКНастоящемуШрифту() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let label = NSTextField(labelWithString: "имя")
        label.frame = NSRect(x: 0, y: 0, width: 100, height: 20)
        window.contentView?.addSubview(label)
        CursorLift.animateTextGrowth(of: label, ratio: 1.3, centred: false)
        let layer = try XCTUnwrap(label.layer)
        let animation = try XCTUnwrap(layer.animation(forKey: "fcxl.lift") as? CABasicAnimation)
        XCTAssertEqual(animation.duration, CursorLift.duration, accuracy: 0.001)
        XCTAssertTrue(CATransform3DIsIdentity(layer.transform), "в конце — настоящий шрифт без масштаба")
        let start = try XCTUnwrap(animation.fromValue as? CATransform3D)
        XCTAssertEqual(start.m11, 1.3, accuracy: 0.001, "стартует с прежнего размера")

        CursorLift.animateTextGrowth(of: label, ratio: 1, centred: false)
        withExtendedLifetime(window) {}
    }

    /// Поле имени растёт отрисовкой, а не масштабом слоя: обрезанное «имя…» в масштабе слоя
    /// вылезало за колонку в соседний столбец и уже оттуда сжималось на место.
    func test_полеИмениРастётОтрисовкойАНеСлоем() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let field = MarqueeTextField(labelWithString: "очень длинное имя файла, которое не помещается")
        field.frame = NSRect(x: 0, y: 0, width: 100, height: 20)
        window.contentView?.addSubview(field)
        CursorLift.animateTextGrowth(of: field, ratio: 1.3, centred: false)
        XCTAssertNil(field.layer?.animation(forKey: "fcxl.lift"), "слой не масштабируется")
        XCTAssertEqual(field.currentGrowthScale, 1.3, accuracy: 0.05, "первый кадр — прежний размер")
        withExtendedLifetime(window) {}
    }

    // MARK: - Ход роста

    /// Начинается с прежнего масштаба, приходит к единице, к концу замедляется.
    func test_ходРостаОтПрежнегоКЕдинице() {
        let growth = TextGrowth(startRatio: 1.3, duration: 0.15)
        XCTAssertEqual(growth.scale(at: 0), 1.3, accuracy: 0.001)
        XCTAssertEqual(growth.scale(at: 0.15), 1, accuracy: 0.001)
        XCTAssertEqual(growth.scale(at: 1), 1, accuracy: 0.001, "после конца — единица")
        let early = 1.3 - growth.scale(at: 0.05)
        let late = growth.scale(at: 0.1) - growth.scale(at: 0.15)
        XCTAssertGreaterThan(early, abs(late), "первая треть проходит больший путь, чем последняя")
        XCTAssertFalse(growth.isFinished(at: 0.1))
        XCTAssertTrue(growth.isFinished(at: 0.15))
        // Уменьшение (курсор пришёл): с 0.8 к единице, монотонно.
        let shrink = TextGrowth(startRatio: 0.8, duration: 0.15)
        XCTAssertLessThan(shrink.scale(at: 0.03), shrink.scale(at: 0.06))
        XCTAssertEqual(TextGrowth(startRatio: 1.3, duration: 0).scale(at: 0), 1, "без длительности — сразу")
    }
}
