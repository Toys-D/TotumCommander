import XCTest

@testable import TotumComXLApp

/// Отказ во входе на сервер: как он разбирается и что из него следует.
final class RemoteLoginTests: XCTestCase {

    // MARK: - Разбор ответа сервера

    func testRefusalKeepsTheServersOwnWords() {
        guard case .refused(let reply) =
                RemoteLogin.verdict(forServerReply: "530 User cannot log in.") else {
            return XCTFail("отказ должен читаться как отказ")
        }
        XCTAssertEqual(reply, "530 User cannot log in.")
    }

    func testAskedForThePasswordAndWentSilent() {
        XCTAssertEqual(RemoteLogin.verdict(forServerReply: "331 Password required for toys\r\n"),
                       .droppedAfterPassword)
    }

    func testSshRefusalHasNoNumberAndIsStillARefusal() {
        XCTAssertEqual(RemoteLogin.verdict(forServerReply: "SSH authentication failed for toys"),
                       .refused("SSH authentication failed for toys"))
    }

    func testOnlyAThreeDigitStartCountsAsTheServersWords() {
        XCTAssertTrue(RemoteLogin.looksLikeServerReply("530 User cannot log in."))
        XCTAssertFalse(RemoteLogin.looksLikeServerReply("SSH authentication failed"))
        XCTAssertFalse(RemoteLogin.looksLikeServerReply("53 нет"))
    }

    // MARK: - Что читает человек

    func testTheServersAnswerIsShownToTheUser() {
        let text = RemoteLogin.message(for: .refused("530 User cannot log in."))
        XCTAssertTrue(text.contains("530 User cannot log in."), text)
    }

    func testSilenceAfterThePasswordIsExplainedDifferently() {
        let dropped = RemoteLogin.message(for: .droppedAfterPassword)
        let refused = RemoteLogin.message(for: .refused("530 User cannot log in."))
        XCTAssertNotEqual(dropped, refused)
        XCTAssertFalse(dropped.isEmpty)
    }

    func testASilentServerStillGetsASentence() {
        XCTAssertFalse(RemoteLogin.message(for: .refused("")).isEmpty)
    }

    // MARK: - Спрашивать ли пароль заново

    func testLoginRefusalAsksAgain() {
        XCTAssertTrue(RemoteLogin.asksAgain(after: RemoteFileSystemError.loginRefused("нет")))
        XCTAssertTrue(RemoteLogin.asksAgain(after: RemoteFileSystemError.authenticationFailed("нет")))
    }

    func testAnUnreachableServerIsNotAskedForAPassword() {
        XCTAssertFalse(RemoteLogin.asksAgain(after: RemoteFileSystemError.connectionFailed("нет связи")))
        XCTAssertFalse(RemoteLogin.asksAgain(after: RemoteFileSystemError.timeout))
        XCTAssertFalse(RemoteLogin.asksAgain(after: CocoaError(.fileNoSuchFile)))
    }

    func testCloudsAreNotAskedForAPassword() {
        // У Google Drive и прочих облаков пароля нет — доступ выдаёт браузер.
        XCTAssertFalse(RemoteLogin.canAskAgain(.rclone))
        for proto in [RemoteProtocol.ftp, .ftps, .sftp, .webdav, .webdavs, .smb, .s3] {
            XCTAssertTrue(RemoteLogin.canAskAgain(proto), proto.displayName)
        }
    }

    // MARK: - Что делает ответ из окна входа

    /// Одно и то же подключение во всех проверках: вычисляемое свойство выдавало бы каждый
    /// раз новый UUID, и сравнение «то же самое подключение» ничего бы не значило.
    private let sample = RemoteConnection(label: "Сервер", proto: .ftp, host: "ftp.example.com",
                                          username: "toys", initialPath: "/")

    func testANewNameAndPasswordReplaceTheOldOnes() {
        let (updated, password) = RemoteLogin.applying(account: " dimas ", password: "тайна",
                                                       asGuest: false, to: sample)
        XCTAssertEqual(updated.username, "dimas")
        XCTAssertEqual(password, "тайна")
    }

    func testAnEmptyNameLeavesTheOldOne() {
        let (updated, _) = RemoteLogin.applying(account: "   ", password: "тайна",
                                                asGuest: false, to: sample)
        XCTAssertEqual(updated.username, "toys")
    }

    func testGuestOnFtpMeansAnonymous() {
        let (updated, password) = RemoteLogin.applying(account: "неважно", password: "неважно",
                                                       asGuest: true, to: sample)
        XCTAssertEqual(updated.username, "anonymous")
        XCTAssertEqual(password, "anonymous@")
    }

    func testTheRestOfTheConnectionIsUntouched() {
        let (updated, _) = RemoteLogin.applying(account: "dimas", password: "x",
                                                asGuest: false, to: sample)
        XCTAssertEqual(updated.id, sample.id)
        XCTAssertEqual(updated.host, sample.host)
        XCTAssertEqual(updated.proto, sample.proto)
    }

    // MARK: - Окно входа

    @MainActor
    func testTheWindowGrowsForALongExplanation() {
        let plain = NetworkAuthDialog.dialogHeight(rejection: .none, explanation: nil)
        let short = NetworkAuthDialog.dialogHeight(rejection: .credentials, explanation: nil)
        let long = NetworkAuthDialog.dialogHeight(
            rejection: .credentials,
            explanation: RemoteLogin.message(for: .droppedAfterPassword))
        XCTAssertLessThan(plain, short)
        XCTAssertLessThan(short, long)
    }
}
