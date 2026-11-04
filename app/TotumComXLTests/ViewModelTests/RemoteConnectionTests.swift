import XCTest

@testable import TotumComXLApp

/// Tests for `RemoteConnection` / `RemoteProtocol` — the saved-bookmark model behind the FTP/SFTP/
/// SMB/WebDAV connection window: default ports, the address/title strings shown in the UI, and the
/// Codable persistence that stores bookmarks (passwords live separately in the Keychain). All pure.
final class RemoteConnectionTests: XCTestCase {

    // MARK: - RemoteProtocol

    func test_defaultPorts_perProtocol() {
        XCTAssertEqual(RemoteProtocol.ftp.defaultPort, 21)
        XCTAssertEqual(RemoteProtocol.ftps.defaultPort, 990)
        XCTAssertEqual(RemoteProtocol.sftp.defaultPort, 22)
        XCTAssertEqual(RemoteProtocol.webdav.defaultPort, 80)
        XCTAssertEqual(RemoteProtocol.webdavs.defaultPort, 443)
        XCTAssertEqual(RemoteProtocol.smb.defaultPort, 445)
    }

    func test_displayName_perProtocol() {
        XCTAssertEqual(RemoteProtocol.ftp.displayName, "FTP")
        XCTAssertEqual(RemoteProtocol.sftp.displayName, "SFTP")
        XCTAssertEqual(RemoteProtocol.webdavs.displayName, "WebDAV (HTTPS)")
        XCTAssertEqual(RemoteProtocol.smb.displayName, "SMB")
    }

    func test_allCases_coversEveryProtocol() {
        XCTAssertEqual(RemoteProtocol.allCases.count, 8)
        // rawValue is the Identifiable id — must stay unique for the picker.
        XCTAssertEqual(Set(RemoteProtocol.allCases.map(\.id)).count, 8)
        XCTAssertTrue(RemoteProtocol.allCases.contains(.s3), "S3 попадает в список сам")
        XCTAssertEqual(RemoteProtocol.s3.defaultPort, 443)
        XCTAssertEqual(RemoteProtocol.s3.displayName, "S3")
        XCTAssertTrue(RemoteProtocol.allCases.contains(.rclone), "и мост к rclone тоже")
        // Порта у него нет: куда идти, знает сам rclone по имени хранилища.
        XCTAssertEqual(RemoteProtocol.rclone.defaultPort, 0)
    }

    /// У подключения через rclone нет ни адреса, ни имени входа — в общем списке его
    /// узнают по имени хранилища. Пустая строка там означала бы подключение без примет.
    func test_rcloneShowsItsRemoteNameInsteadOfAnAddress() {
        let connection = RemoteConnection(label: "Диск", proto: .rclone,
                                          rcloneRemote: "мойдиск")
        XCTAssertEqual(connection.displayAddress, "мойдиск:")
        XCTAssertTrue(connection.displayTitle.contains("мойдиск:"))
        XCTAssertEqual(RemoteConnection(proto: .rclone).displayAddress, "—")
    }

    /// Закладка, записанная до появления моста, читается как была.
    func test_bookmarksWrittenBeforeRcloneStillDecode() throws {
        let json = """
        {"id":"\(UUID().uuidString)","label":"S3","proto":"s3","host":"s3.example.com",
         "port":443,"username":"AKIA","initialPath":"/","useKeyAuth":false,"keyPath":"",
         "passiveMode":true,"s3Bucket":"ведро","s3Region":"us-east-1",
         "s3UsePathStyle":false,"s3UsesTLS":true}
        """
        let connection = try JSONDecoder().decode(RemoteConnection.self,
                                                  from: Data(json.utf8))
        XCTAssertEqual(connection.s3Bucket, "ведро")
        XCTAssertEqual(connection.rcloneRemote, "", "нового поля в старой закладке нет")
    }

    /// Закладки, записанные до появления S3, читаются как были — иначе человек теряет
    /// все свои подключения после обновления.
    func test_bookmarksWrittenBeforeS3StillDecode() throws {
        let json = """
        {"id":"\(UUID().uuidString)","label":"Старый сервер","proto":"sftp",
         "host":"example.com","port":22,"username":"dimas","initialPath":"/home/dimas",
         "useKeyAuth":false,"keyPath":"","passiveMode":true}
        """
        let connection = try JSONDecoder().decode(RemoteConnection.self,
                                                  from: Data(json.utf8))
        XCTAssertEqual(connection.host, "example.com")
        XCTAssertEqual(connection.proto, .sftp)
        XCTAssertEqual(connection.s3Bucket, "", "поля S3 получают разумные значения")
        XCTAssertEqual(connection.s3Region, "us-east-1")
        XCTAssertTrue(connection.s3UsesTLS)
    }

    // MARK: - Host

    /// Хост с пробелом или кириллицей не собирается в адрес — раньше это роняло программу
    /// при первом обращении к WebDAV. Теперь такой хост не даёт сохранить подключение.
    func test_хостГодитсяТолькоЕслиСобираетсяВАдрес() {
        XCTAssertTrue(RemoteConnection.isUsableHost("example.com"))
        XCTAssertTrue(RemoteConnection.isUsableHost("192.168.1.10"))
        XCTAssertTrue(RemoteConnection.isUsableHost("  nas.local  "), "края обрезаются")
        XCTAssertFalse(RemoteConnection.isUsableHost(""))
        XCTAssertFalse(RemoteConnection.isUsableHost("my server"), "пробел внутри")
        // Кириллицу Foundation кодирует сама — такой хост собирается, и запрещать его незачем.
        XCTAssertTrue(RemoteConnection.isUsableHost("сервер.рф"))
        XCTAssertFalse(RemoteConnection.isUsableHost("host/path"), "путь — не хост")
    }

    /// Даже сохранённое раньше подключение с негодным хостом не роняет программу:
    /// подключение отказывает с понятной ошибкой, а не падает на развёртке.
    func test_webdavСНегоднымХостомОтказываетАНеПадает() async {
        var connection = RemoteConnection()
        connection.proto = .webdav
        connection.host = "my server"
        let fs = WebDAVRemoteFileSystem(connection: connection, password: "")
        do {
            try await fs.connect()
            XCTFail("подключение к «my server» не должно было удаться")
        } catch {
            XCTAssertTrue("\(error)".contains("my server") || error.localizedDescription.contains("my server"),
                          "в ошибке назван сам адрес: \(error)")
        }
    }

    // MARK: - effectivePort

    func test_effectivePort_fallsBackToProtocolDefault() {
        let c = RemoteConnection(proto: .sftp, host: "h", port: 0)
        XCTAssertEqual(c.effectivePort, 22)
    }

    func test_effectivePort_usesExplicitPort() {
        let c = RemoteConnection(proto: .sftp, host: "h", port: 2222)
        XCTAssertEqual(c.effectivePort, 2222)
    }

    // MARK: - displayAddress

    func test_displayAddress_hostOnlyWhenNoUserAndDefaultPort() {
        let c = RemoteConnection(proto: .ftp, host: "example.com", port: 0, username: "")
        XCTAssertEqual(c.displayAddress, "example.com")
    }

    func test_displayAddress_includesUser() {
        let c = RemoteConnection(proto: .ftp, host: "example.com", port: 0, username: "dima")
        XCTAssertEqual(c.displayAddress, "dima@example.com")
    }

    func test_displayAddress_showsNonDefaultPort() {
        let c = RemoteConnection(proto: .ftp, host: "example.com", port: 2121, username: "dima")
        XCTAssertEqual(c.displayAddress, "dima@example.com:2121")
    }

    func test_displayAddress_hidesDefaultPortEvenWhenExplicit() {
        // Port equal to the protocol default is not worth showing.
        let c = RemoteConnection(proto: .ftp, host: "example.com", port: 21, username: "dima")
        XCTAssertEqual(c.displayAddress, "dima@example.com")
    }

    // MARK: - displayTitle

    func test_displayTitle_withoutLabel() {
        let c = RemoteConnection(proto: .ftp, host: "h", username: "u")
        XCTAssertEqual(c.displayTitle, "FTP: u@h")
    }

    func test_displayTitle_withLabel() {
        let c = RemoteConnection(label: "Работа", proto: .sftp, host: "h", username: "u")
        XCTAssertEqual(c.displayTitle, "Работа (SFTP: u@h)")
    }

    // MARK: - Codable persistence + equality

    func test_codableRoundTrip_preservesAllFields() throws {
        let original = RemoteConnection(
            label: "Мой сервер", proto: .sftp, host: "10.0.0.5", port: 2200,
            username: "dima", initialPath: "/home/dima",
            useKeyAuth: true, keyPath: "/keys/id_ed25519", passiveMode: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RemoteConnection.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_equatable_differsById() {
        let a = RemoteConnection(label: "x", proto: .ftp, host: "h")
        let b = RemoteConnection(label: "x", proto: .ftp, host: "h")
        XCTAssertNotEqual(a, b, "distinct ids must make bookmarks distinct")
        XCTAssertEqual(a, a)
    }
}
