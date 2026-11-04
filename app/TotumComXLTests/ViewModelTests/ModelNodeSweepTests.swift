import SceneKit
import SwiftUI
import AppKit
import XCTest
@testable import TotumComXLApp

/// Глазки узлов сбоку от 3D-модели: щелчок переключает один, нажал и провёл — переключаются
/// все пройденные, так же, как первый.
///
/// Сначала — правило само по себе, потом — мышью по настоящей панели (MouseLikeAPerson):
/// нажатие на глазок, путь с зажатой кнопкой, отпускание.
@MainActor
final class ModelNodeSweepTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MouseLikeAPerson.setAccessibility(true)
    }

    override func tearDown() {
        MouseLikeAPerson.setAccessibility(false)
        super.tearDown()
    }

    // MARK: - Правило

    func test_первыйГлазокРешаетСкрытьИлиПоказать() {
        XCTAssertTrue(ModelVisibilitySweep(from: 2, wasHidden: false).hide)
        XCTAssertFalse(ModelVisibilitySweep(from: 2, wasHidden: true).hide)
    }

    func test_пройденноеКопитсяВОбеСтороны() {
        var sweep = ModelVisibilitySweep(from: 3, wasHidden: false)
        sweep.reach(5)
        XCTAssertEqual(sweep.rows, 3...5)
        sweep.reach(4)
        XCTAssertEqual(sweep.rows, 3...5, "вернулся назад — пройденное остаётся")
        sweep.reach(1)
        XCTAssertEqual(sweep.rows, 1...5)
    }

    func test_строкаПодМышьюНеВыходитЗаСписок() {
        XCTAssertEqual(ModelVisibilitySweep.row(at: 0, rowHeight: 20, count: 5), 0)
        XCTAssertEqual(ModelVisibilitySweep.row(at: 19.9, rowHeight: 20, count: 5), 0)
        XCTAssertEqual(ModelVisibilitySweep.row(at: 20, rowHeight: 20, count: 5), 1)
        XCTAssertEqual(ModelVisibilitySweep.row(at: -30, rowHeight: 20, count: 5), 0)
        XCTAssertEqual(ModelVisibilitySweep.row(at: 500, rowHeight: 20, count: 5), 4)
    }

    // MARK: - Мышью по панели

    func test_провёлПоГлазкамВниз_всеПройденныеСкрыты() throws {
        let (window, nodes) = try panel()
        defer { window.orderOut(nil) }
        let eyes = try eyesOf(window, count: nodes.count)
        MouseLikeAPerson.drag(from: center(eyes[0]), to: center(eyes[3]), in: window)
        settle()
        XCTAssertEqual(nodes.map(\.isHidden), [true, true, true, true, false])
    }

    func test_провёлВверхОтСкрытого_пройденныеПоказаны() throws {
        let (window, nodes) = try panel()
        defer { window.orderOut(nil) }
        let eyes = try eyesOf(window, count: nodes.count)
        MouseLikeAPerson.drag(from: center(eyes[0]), to: center(eyes[4]), in: window)
        settle()
        XCTAssertEqual(nodes.map(\.isHidden), [true, true, true, true, true])
        MouseLikeAPerson.drag(from: center(eyes[3]), to: center(eyes[1]), in: window)
        settle()
        XCTAssertEqual(nodes.map(\.isHidden), [true, false, false, false, true])
    }

    func test_щелчокПоГлазкуПереключаетОдинУзел() throws {
        let (window, nodes) = try panel()
        defer { window.orderOut(nil) }
        let eyes = try eyesOf(window, count: nodes.count)
        MouseLikeAPerson.click(eyes[1], in: window)
        settle()
        XCTAssertEqual(nodes.map(\.isHidden), [false, true, false, false, false])
        MouseLikeAPerson.click(eyes[1], in: window)
        settle()
        XCTAssertEqual(nodes.map(\.isHidden), [false, false, false, false, false])
    }

    func test_провёлПоИменам_ничегоНеСкрыто() throws {
        let (window, nodes) = try panel()
        defer { window.orderOut(nil) }
        let eyes = try eyesOf(window, count: nodes.count)
        let aside = NSPoint(x: 80, y: 0)
        MouseLikeAPerson.drag(from: center(eyes[0]) + aside, to: center(eyes[3]) + aside, in: window)
        settle()
        XCTAssertEqual(nodes.map(\.isHidden), [false, false, false, false, false])
    }

    // MARK: - Панель

    /// Боковая панель с пятью узлами-коробками — в окне на экране, как в просмотрщике.
    private func panel() throws -> (NSWindow, [SCNNode]) {
        let scene = SCNScene()
        let nodes = (1...5).map { index -> SCNNode in
            let node = SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0))
            node.name = "Деталь \(index)"
            scene.rootNode.addChildNode(node)
            return node
        }
        let model = Model3DScene(scene: scene, meshCount: nodes.count, vertexCount: 0, faceCount: 0,
                                 reader: .apple, radius: 1, center: SCNVector3(0, 0, 0))
        // Панель, а не простое окно: она становится главной, не выводя вперёд всю программу.
        // Нажатие в не главном окне AppKit тратит на то, чтобы сделать его главным, и до
        // жеста внутри прокрутки оно не доходит — а в просмотрщике окно и так главное.
        let window = NSPanel(contentRect: NSRect(x: 300, y: 300, width: 240, height: 420),
                             styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(model: model))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        settle()
        return (window, nodes)
    }

    /// Панель держит скрытое в привязке — снаружи её держит просмотрщик, здесь — эта обёртка.
    private struct Host: View {
        let model: Model3DScene
        @State private var hidden: Set<ObjectIdentifier> = []
        var body: some View {
            ModelSidePanel(model: model, measurements: nil, hidden: $hidden)
        }
    }

    /// Глазки сверху вниз (у экрана ось y смотрит вверх).
    private func eyesOf(_ window: NSWindow, count: Int) throws -> [NSRect] {
        let eyes = MouseLikeAPerson.elements(withHelp: L("viewer.model.toggleNode"), in: window)
            .sorted { $0.midY > $1.midY }
        return try XCTUnwrap(eyes.count == count ? eyes : nil, "нашлось глазков: \(eyes.count) из \(count)")
    }

    private func center(_ frame: NSRect) -> NSPoint { NSPoint(x: frame.midX, y: frame.midY) }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
}

private func + (lhs: NSPoint, rhs: NSPoint) -> NSPoint {
    NSPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}
