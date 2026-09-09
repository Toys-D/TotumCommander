import Foundation

/// The masks worth keeping — `*.png&!копия*` is not retyped, it is saved once and pressed.
///
/// One list for the whole app, read from the defaults on every use, the same way the favourite
/// folders work and for the same reason: no copy anywhere to go stale.
enum MaskPresets {

    static let key = "fcxl.maskPresets"

    static var masks: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func contains(_ mask: String) -> Bool {
        let trimmed = mask.trimmingCharacters(in: .whitespaces)
        return masks.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Kept in the order they were saved: presets are pressed by remembered position.
    static func add(_ mask: String) {
        let trimmed = mask.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !contains(trimmed) else { return }
        UserDefaults.standard.set(masks + [trimmed], forKey: key)
    }

    static func remove(_ mask: String) {
        let trimmed = mask.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(
            masks.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }, forKey: key)
    }

    /// Saved if it was not, forgotten if it was. Returns whether it is saved NOW.
    @discardableResult
    static func toggle(_ mask: String) -> Bool {
        if contains(mask) { remove(mask); return false }
        add(mask)
        return contains(mask)
    }
}
