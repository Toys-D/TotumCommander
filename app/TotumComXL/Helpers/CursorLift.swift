import AppKit
import QuartzCore

/// Плавный рост под курсором: значок и шрифт не прыгают в новый размер, а дорастают до него.
///
/// Пункт «Плавная анимация» в режиме красоты. Значок растёт преобразованием слоя — оно
/// анимируется прямо. Шрифт подменяется кеглем, и его слою на время перехода даётся тот же
/// масштаб от прежнего кегля к новому, а в конце остаётся настоящий шрифт — текст чёткий.
///
/// Анимируется только смена размера у ТОГО ЖЕ элемента: курсор ушёл или пришёл. Ячейка,
/// переиспользованная под другой файл при прокрутке, встаёт в свой размер сразу — иначе на
/// каждом новом ряду что-то бы съёживалось.
enum CursorLift {
    static let enabledKey = "beautySmoothAnimation"
    /// Быстро, но заметно; к концу замедляется.
    static let duration: TimeInterval = 0.15

    /// Действует только вместе с режимом красоты, как и остальные его пункты; сам по себе
    /// включён, пока не выключили.
    static func isEnabled(_ defaults: UserDefaults = .standard, supportsBeauty: Bool) -> Bool {
        guard supportsBeauty, defaults.bool(forKey: PanelAppearanceSettings.beautyModeEnabledKey) else {
            return false
        }
        return defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    @MainActor
    static var isEnabled: Bool {
        isEnabled(.standard, supportsBeauty: MacCapabilities.supportsBeautyMode)
    }

    /// Когда анимировать: включено, элемент тот же и он уже разложен на экране.
    static func shouldAnimate(sameItem: Bool, laidOut: Bool, enabled: Bool) -> Bool {
        enabled && sameItem && laidOut
    }

    /// Во сколько раз текст был крупнее (или мельче) до перехода — с него и начинается рост.
    /// Единица — переход не нужен.
    static func fontRatio(previousScale: CGFloat, newScale: CGFloat) -> CGFloat {
        guard previousScale > 0, newScale > 0 else { return 1 }
        return previousScale / newScale
    }

    private static var timing: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }

    /// Довести слой до `transform` плавно, с того, что на экране сейчас — а не с модели:
    /// стрелка, зажатая в прокрутке, обрывает предыдущий рост и начинает новый с полпути.
    static func animateTransform(of layer: CALayer, to transform: CATransform3D) {
        let from = layer.presentation()?.transform ?? layer.transform
        layer.removeAnimation(forKey: "fcxl.lift")
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = from
        animation.toValue = transform
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: "fcxl.lift")
        layer.transform = transform
    }

    /// Текст уже в новом шрифте; показать, как он к нему дорастает: слой стартует с масштаба
    /// `ratio` (прежний размер) и приходит к единице. Опора — левая середина у строк списка,
    /// центр у подписи миниатюры.
    static func animateTextGrowth(of label: NSView, ratio: CGFloat, centred: Bool) {
        guard ratio > 0, abs(ratio - 1) > 0.001 else { return }
        label.wantsLayer = true
        guard let layer = label.layer, layer.bounds.width > 0, layer.bounds.height > 0 else { return }
        let w = layer.bounds.width, h = layer.bounds.height
        let px = centred ? w / 2 : 0, py = h / 2
        var start = CATransform3DIdentity
        start = CATransform3DTranslate(start, px, py, 0)
        start = CATransform3DScale(start, ratio, ratio, 1)
        start = CATransform3DTranslate(start, -px, -py, 0)
        layer.removeAnimation(forKey: "fcxl.lift")
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = start
        animation.toValue = CATransform3DIdentity
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: "fcxl.lift")
        layer.transform = CATransform3DIdentity
    }
}
