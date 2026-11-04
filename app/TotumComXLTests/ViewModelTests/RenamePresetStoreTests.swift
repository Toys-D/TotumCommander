import XCTest
@testable import TotumComXLApp

/// Preset persistence, isolated in a throwaway UserDefaults suite (no I/O beyond it).
final class RenamePresetStoreTests: XCTestCase {

    private func freshStore() -> (RenamePresetStore, UserDefaults) {
        let suite = "mrt-presets-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (RenamePresetStore(defaults: defaults), defaults)
    }

    func testSaveAndLoad() {
        let (store, _) = freshStore()
        var rule = RenameRule(); rule.nameMask = "[N]_[C]"; rule.counterDigits = 3
        store.save(name: "Photos", rule: rule)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.rule(named: "Photos")?.nameMask, "[N]_[C]")
        XCTAssertEqual(store.rule(named: "Photos")?.counterDigits, 3)
    }

    func testOverwriteSameName() {
        let (store, _) = freshStore()
        var a = RenameRule(); a.nameMask = "one"
        var b = RenameRule(); b.nameMask = "two"
        store.save(name: "Set", rule: a)
        store.save(name: "Set", rule: b)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.rule(named: "Set")?.nameMask, "two")
    }

    func testDelete() {
        let (store, _) = freshStore()
        store.save(name: "A", rule: RenameRule())
        store.save(name: "B", rule: RenameRule())
        store.delete(name: "A")
        XCTAssertEqual(store.all().map { $0.name }, ["B"])
    }

    func testEmptyNameIgnored() {
        let (store, _) = freshStore()
        store.save(name: "   ", rule: RenameRule())
        XCTAssertTrue(store.all().isEmpty)
    }
}
