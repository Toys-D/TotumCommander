import Foundation

/// A named multi-rename preset: everything in the dialog except the file list.
struct RenamePreset: Codable, Equatable {
    var name: String
    var rule: RenameRule
}

/// Persists named multi-rename presets as JSON in UserDefaults. Saving a name that already
/// exists overwrites it (so "save current as <existing>" updates in place).
final class RenamePresetStore {
    static let defaultsKey = "fcxl.multiRename.presets"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func all() -> [RenamePreset] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let list = try? JSONDecoder().decode([RenamePreset].self, from: data) else { return [] }
        return list
    }

    func save(name: String, rule: RenameRule) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = all().filter { $0.name != trimmed }
        list.append(RenamePreset(name: trimmed, rule: rule))
        list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist(list)
    }

    func delete(name: String) {
        persist(all().filter { $0.name != name })
    }

    func rule(named name: String) -> RenameRule? {
        all().first { $0.name == name }?.rule
    }

    private func persist(_ list: [RenamePreset]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
