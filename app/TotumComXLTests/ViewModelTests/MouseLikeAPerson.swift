import AppKit
import XCTest

/// Мышь в проверках — как у человека: кнопка ищется по надписи в дереве доступности окна,
/// нажатия идут в окно настоящими событиями. Так проверяется то, что человек видит и жмёт,
/// а не то, что функция вызвана.
///
/// Без читалки экрана SwiftUI не строит дерево доступности — проверка включает его
/// (`setAccessibility(true)` в `setUp`, `false` в `tearDown`).
@MainActor
enum MouseLikeAPerson {

    /// То, что включает читалка экрана: с ним SwiftUI отдаёт свои кнопки в дерево доступности.
    static func setAccessibility(_ on: Bool) {
        _ = NSApplication.shared            // в проверках `NSApp` сам не появляется
        NSApplication.shared.accessibilitySetValue(
            on, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }

    /// Щелчок мышью по середине кнопки с такой надписью. `false` — такой кнопки нет.
    @discardableResult
    static func press(_ label: String, in window: NSWindow, prefix: Bool = false) -> Bool {
        guard let frame = element(label, in: window, prefix: prefix) else { return false }
        click(frame, in: window)
        return true
    }

    /// Нажать и отпустить левую кнопку мыши посреди рамки (в координатах экрана).
    static func click(_ frame: NSRect, in window: NSWindow) {
        let point = NSPoint(x: frame.midX, y: frame.midY)
        send(.leftMouseDown, at: point, in: window)
        send(.leftMouseUp, at: point, in: window)
    }

    /// Нажать в одной точке, провести с зажатой кнопкой до другой и отпустить (координаты
    /// экрана). Путь — мелкими шагами и с паузами, как идёт настоящая мышь: жест SwiftUI
    /// разбирает движение между кругами обработки, и путь, выданный разом, он не видит.
    static func drag(from start: NSPoint, to end: NSPoint, in window: NSWindow, steps: Int = 12) {
        send(.leftMouseDown, at: start, in: window)
        pause()
        for step in 1...steps {
            let share = CGFloat(step) / CGFloat(steps)
            send(.leftMouseDragged, at: NSPoint(x: start.x + (end.x - start.x) * share,
                                                y: start.y + (end.y - start.y) * share), in: window)
            pause()
        }
        send(.leftMouseUp, at: end, in: window)
        pause()
    }

    private static func pause() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    private static func send(_ type: NSEvent.EventType, at screenPoint: NSPoint, in window: NSWindow) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: window.convertPoint(fromScreen: screenPoint), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1) else { return }
        window.sendEvent(event)
    }

    /// Рамка (в координатах экрана) элемента с такой надписью.
    static func element(_ label: String, in window: NSWindow, prefix: Bool = false) -> NSRect? {
        frames(in: window) { node in
            [node.accessibilityLabel?() ?? nil, node.accessibilityTitle?() ?? nil].contains { text in
                guard let text, !text.isEmpty else { return false }
                return prefix ? text.hasPrefix(label) : text == label
            }
        }.first
    }

    /// Рамки элементов с такой подсказкой — так находятся кнопки без надписи (значки).
    static func elements(withHelp help: String, in window: NSWindow) -> [NSRect] {
        frames(in: window) { ($0.accessibilityHelp?() ?? nil) == help }
    }

    /// Рамки всех элементов окна, что подходят под `test`, — по дереву доступности. Узлы
    /// SwiftUI к протоколу доступности не приводятся, поэтому спрашиваются напрямую.
    static func frames(in window: NSWindow, where test: (AnyObject) -> Bool) -> [NSRect] {
        var found: [NSRect] = []
        func walk(_ node: AnyObject, depth: Int) {
            guard depth < 40 else { return }
            if test(node), let frame = node.accessibilityFrame?() { found.append(frame) }
            for child in (node.accessibilityChildren?() ?? nil) ?? [] {
                walk(child as AnyObject, depth: depth + 1)
            }
        }
        if let root = window.contentView { walk(root, depth: 0) }
        return found
    }
}
