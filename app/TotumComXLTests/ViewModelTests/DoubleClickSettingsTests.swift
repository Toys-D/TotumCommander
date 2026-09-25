import XCTest

@testable import TotumComXLApp

final class DoubleClickSettingsTests: XCTestCase {
    func test_whenValueWithinRange_shouldKeepSameValue() {
        let raw = 0.42

        let normalized = DoubleClickSettings.normalizedIntervalSeconds(raw)

        XCTAssertEqual(normalized, raw, accuracy: 0.0001)
    }

    func test_whenValueBelowMinimum_shouldClampToMinimum() {
        let normalized = DoubleClickSettings.normalizedIntervalSeconds(0.01)

        XCTAssertEqual(normalized, DoubleClickSettings.minimumIntervalSeconds, accuracy: 0.0001)
    }

    func test_whenValueAboveMaximum_shouldClampToMaximum() {
        let normalized = DoubleClickSettings.normalizedIntervalSeconds(9.0)

        XCTAssertEqual(normalized, DoubleClickSettings.maximumIntervalSeconds, accuracy: 0.0001)
    }

    func test_whenValueIsNotFinite_shouldFallbackToDefault() {
        let normalized = DoubleClickSettings.normalizedIntervalSeconds(.nan)

        XCTAssertEqual(normalized, DoubleClickSettings.defaultIntervalSeconds, accuracy: 0.0001)
    }
}
