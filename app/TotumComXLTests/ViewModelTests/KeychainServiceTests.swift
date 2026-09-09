import XCTest

@testable import TotumComXLApp

final class KeychainServiceTests: XCTestCase {

    private let testService = "com.fcxl.test.keychain"
    private let testAccount = "test-account-\(UUID().uuidString)"

    override func tearDown() {
        super.tearDown()
        KeychainService.delete(account: testAccount, service: testService)
    }

    func test_saveAndLoad_roundTrip() {
        let password = "correct horse battery staple"

        let saved = KeychainService.save(password: password, account: testAccount, service: testService)
        let loaded = KeychainService.load(account: testAccount, service: testService)

        XCTAssertTrue(saved)
        XCTAssertEqual(loaded, password)
    }

    func test_saveTwice_replacesTheOldPassword() {
        XCTAssertEqual(KeychainService.saveStatus(password: "первый", account: testAccount,
                                                  service: testService), errSecSuccess)
        XCTAssertEqual(KeychainService.saveStatus(password: "второй", account: testAccount,
                                                  service: testService), errSecSuccess)
        XCTAssertEqual(KeychainService.load(account: testAccount, service: testService), "второй")
    }

    func test_saveStatus_tellsSuccessForBothTheFirstAndTheSecondWrite() {
        // Первая запись идёт через SecItemAdd, вторая — через SecItemUpdate; раньше о разнице
        // между «не записалось» и «записалось» знал только `Bool`, и причина терялась.
        let first = KeychainService.saveStatus(password: "пароль", account: testAccount,
                                               service: testService)
        KeychainService.delete(account: testAccount, service: testService)
        let afterDelete = KeychainService.saveStatus(password: "пароль", account: testAccount,
                                                     service: testService)
        XCTAssertEqual(first, errSecSuccess)
        XCTAssertEqual(afterDelete, errSecSuccess)
    }

    func test_load_returnNilForMissingAccount() {
        let loaded = KeychainService.load(account: "nonexistent-account-xyz", service: testService)

        XCTAssertNil(loaded)
    }

    func test_delete_removesEntry() {
        KeychainService.save(password: "to-be-deleted", account: testAccount, service: testService)

        let deleted = KeychainService.delete(account: testAccount, service: testService)
        let loaded = KeychainService.load(account: testAccount, service: testService)

        XCTAssertTrue(deleted)
        XCTAssertNil(loaded)
    }

    func test_delete_returnsTrueForMissingEntry() {
        let result = KeychainService.delete(account: "never-saved-account-xyz", service: testService)

        XCTAssertTrue(result)
    }

    func test_save_updatesExistingEntry() {
        KeychainService.save(password: "first-password", account: testAccount, service: testService)

        let updated = KeychainService.save(password: "second-password", account: testAccount, service: testService)
        let loaded = KeychainService.load(account: testAccount, service: testService)

        XCTAssertTrue(updated)
        XCTAssertEqual(loaded, "second-password")
    }

    func test_save_unicodePasswordRoundTrip() {
        let unicode = "пароль🔑日本語한국어"

        KeychainService.save(password: unicode, account: testAccount, service: testService)
        let loaded = KeychainService.load(account: testAccount, service: testService)

        XCTAssertEqual(loaded, unicode)
    }
}
