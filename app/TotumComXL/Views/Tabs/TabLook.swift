import CoreGraphics

/// Активная вкладка стоит выше остальных: какая открыта, видно сразу, даже когда вкладки одного
/// цвета. Полоса выравнивает вкладки по низу, поэтому лишняя высота активной уходит вверх.
enum TabLook {
    /// На сколько пунктов активная вкладка выше остальных. 0 — все вровень.
    static let activeLiftKey = "tabActiveLift"
    static let defaultActiveLift: Double = 4
    static let activeLiftRange: ClosedRange<Double> = 0...10

    /// Подъём в пределах ползунка: значение, правленное руками, не уводит вкладку за полосу.
    static func clampedLift(_ raw: Double) -> CGFloat {
        CGFloat(min(max(raw, activeLiftRange.lowerBound), activeLiftRange.upperBound))
    }

    /// Высота вкладки: у активной — плюс подъём.
    static func chipHeight(chip: Double, lift: Double, isActive: Bool) -> CGFloat {
        CGFloat(chip) + (isActive ? clampedLift(lift) : 0)
    }

    /// Высота полосы вкладок: заданная настройкой, а если поднятая вкладка в неё не входит —
    /// столько, сколько ей нужно. Иначе верх активной вкладки срезался бы.
    static func barHeight(bar: Double, chip: Double, lift: Double) -> CGFloat {
        max(CGFloat(bar), chipHeight(chip: chip, lift: lift, isActive: true))
    }
}
