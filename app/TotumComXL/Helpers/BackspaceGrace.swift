import Foundation

/// Пауза после того, как Backspace стёр маску быстрого поиска.
///
/// Последний Backspace стирает маску и закрывает поиск, а следующий — или автоповтор той же
/// зажатой клавиши — уже попадает в панель, где Backspace удаляет файл или уходит на папку
/// вверх. Человек стирал слово, а не просил удалить. Поэтому после закрытия маски Backspace
/// полсекунды не действует, а зажатая клавиша — пока её не отпустят.
struct BackspaceGrace {
    static let duration: TimeInterval = 0.5

    private var closedAt: Date?

    /// Маска закрылась по Backspace.
    mutating func filterClosed(at now: Date = Date()) {
        closedAt = now
    }

    /// Пропустить ли это нажатие Backspace в панели. `true` — проглотить без действия.
    /// Первое нажатие после паузы возвращает обычное поведение, и его автоповторы тоже
    /// работают: зажатый Backspace по-прежнему поднимает на несколько папок.
    mutating func swallows(isRepeat: Bool, now: Date = Date()) -> Bool {
        guard let closedAt else { return false }
        if isRepeat || now.timeIntervalSince(closedAt) < Self.duration { return true }
        self.closedAt = nil
        return false
    }
}
