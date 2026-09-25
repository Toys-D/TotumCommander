import NetFS
import XCTest

@testable import TotumComXLApp

/// Signing in to a server through our own window instead of the system one.
///
/// macOS put up its own authentication sheet whenever NetFS was handed no credentials. That sheet
/// belongs to another process and cannot be restyled, so the only way to stop seeing it is to
/// never need it: suppress it, ask here, and pass the answer straight to the mount.
@MainActor
final class NetworkAuthTests: XCTestCase {

    private let server = "totum-test-server.invalid"
    private let scheme = "smb"

    override func tearDown() async throws {
        NetworkCredentialStore.remove(server: server, scheme: scheme, account: nil)
        try await super.tearDown()
    }

    // MARK: - Which failures deserve a login dialog

    /// Only "the server wants a different login" — putting a password dialog up because a server
    /// is switched off would be worse than the system sheet we replaced.
    func testOnlyAuthFailuresRaiseTheDialog() {
        for status in [Int32(EACCES), Int32(EPERM), Int32(EAUTH),
                       ENETFSPWDNEEDSCHANGE, ENETFSACCOUNTRESTRICTED, ENETFSNOAUTHMECHSUPP] {
            XCTAssertTrue(NetworkBrowserService.isAuthFailure(status), "status \(status)")
        }
    }

    func testAMissingOrUnreachableServerDoesNotAskForAPassword() {
        for status in [Int32(ENOENT), Int32(ETIMEDOUT), Int32(EHOSTDOWN),
                       Int32(ENETUNREACH), Int32(ECANCELED), Int32(ECONNREFUSED)] {
            XCTAssertFalse(NetworkBrowserService.isAuthFailure(status), "status \(status)")
        }
    }

    func testSuccessIsNotAFailure() {
        XCTAssertFalse(NetworkBrowserService.isAuthFailure(0))
    }

    // MARK: - The Keychain drawer

    /// Stored the way Finder stores them, so a share saved there logs in here without asking.
    func testTheProtocolIsTheOneFinderUses() {
        XCTAssertEqual(NetworkCredentialStore.protocolAttribute(for: "smb"), kSecAttrProtocolSMB)
        XCTAssertEqual(NetworkCredentialStore.protocolAttribute(for: "SMB"), kSecAttrProtocolSMB)
        XCTAssertEqual(NetworkCredentialStore.protocolAttribute(for: "afp"), kSecAttrProtocolAFP)
        XCTAssertNil(NetworkCredentialStore.protocolAttribute(for: "nfs"),
                     "no keychain protocol for it — stored without one rather than under a wrong one")
    }

    func testAStoredLoginComesBack() throws {
        try XCTSkipUnless(
            NetworkCredentialStore.save(server: server, scheme: scheme,
                                        account: "дима", password: "п-а-р-о-л-ь"),
            "the keychain refused to store — likely no keychain in this environment")

        let found = NetworkCredentialStore.lookup(server: server, scheme: scheme)
        XCTAssertEqual(found?.account, "дима")
        XCTAssertEqual(found?.password, "п-а-р-о-л-ь")
    }

    /// A changed password must replace the old one, not sit beside it — two entries for one
    /// account is how a stale password goes on being tried forever.
    func testSavingAgainReplacesRatherThanDuplicates() throws {
        try XCTSkipUnless(
            NetworkCredentialStore.save(server: server, scheme: scheme,
                                        account: "дима", password: "старый"),
            "no keychain here")
        NetworkCredentialStore.save(server: server, scheme: scheme,
                                    account: "дима", password: "новый")

        XCTAssertEqual(NetworkCredentialStore.lookup(server: server, scheme: scheme)?.password,
                       "новый")
    }

    func testForgettingALoginRemovesIt() throws {
        try XCTSkipUnless(
            NetworkCredentialStore.save(server: server, scheme: scheme,
                                        account: "дима", password: "пароль"),
            "no keychain here")

        NetworkCredentialStore.remove(server: server, scheme: scheme, account: "дима")

        XCTAssertNil(NetworkCredentialStore.lookup(server: server, scheme: scheme))
    }

    func testAnUnknownServerHasNothingStored() {
        XCTAssertNil(NetworkCredentialStore.lookup(server: "nobody.invalid", scheme: scheme))
    }

    /// Empty fields are not a login. Storing one would make the next connection fail silently
    /// instead of asking.
    func testEmptyCredentialsAreNotStored() {
        XCTAssertFalse(NetworkCredentialStore.save(server: server, scheme: scheme,
                                                   account: "дима", password: ""))
        XCTAssertFalse(NetworkCredentialStore.save(server: server, scheme: scheme,
                                                   account: "", password: "пароль"))
        XCTAssertNil(NetworkCredentialStore.lookup(server: server, scheme: scheme))
    }

    /// The name offered when nothing is saved — the same one Finder starts with.
    func testTheSuggestedNameIsTheLocalUser() {
        XCTAssertEqual(NetworkAuthDialog.defaultAccount, NSUserName())
        XCTAssertFalse(NetworkAuthDialog.defaultAccount.isEmpty)
    }

    // MARK: - The strings the dialog shows

    func testEveryLabelIsTranslated() {
        for key in ["network.auth.title", "network.auth.subtitle", "network.auth.subtitleShare",
                    "network.auth.connectAs", "network.auth.guest", "network.auth.registered",
                    "network.auth.name", "network.auth.password", "network.auth.remember",
                    "network.auth.rejected"] {
            XCTAssertNotEqual(L(key), key, "\(key) would appear on screen as its own key")
        }
    }

    /// Гостю, которого не пустили, говорят это прямо — не «попробуйте ещё раз».
    func test_отказГостюНазванСвоимиСловами() {
        XCTAssertNil(NetworkAuthDialog.bannerKey(for: .none))
        XCTAssertEqual(NetworkAuthDialog.bannerKey(for: .credentials), "network.auth.rejected")
        XCTAssertEqual(NetworkAuthDialog.bannerKey(for: .guest), "network.auth.guestRefused")
        XCTAssertNotEqual(L("network.auth.guestRefused"), "network.auth.guestRefused")
    }
}
