import XCTest
@testable import TotumComXLApp

/// Правила моста к rclone, которые можно проверить без него самого: как путь программы
/// превращается в путь хранилища, как читается строка выдачи и как чужая жалоба становится
/// внятным отказом.
final class RcloneRulesTests: XCTestCase {

    // MARK: - Пути

    func test_путьТеряетСлэшиПоКраям() {
        XCTAssertEqual(RcloneRemoteFileSystem.remotePath("/папка/файл.txt"), "папка/файл.txt")
        XCTAssertEqual(RcloneRemoteFileSystem.remotePath("/"), "")
        XCTAssertEqual(RcloneRemoteFileSystem.remotePath("/папка/"), "папка")
        XCTAssertEqual(RcloneRemoteFileSystem.remotePath(""), "")
    }

    func test_путьРазбираетсяНаПапкуИИмя() {
        let deep = RcloneRemoteFileSystem.split("/папка/вложенная/файл.txt")
        XCTAssertEqual(deep.directory, "папка/вложенная")
        XCTAssertEqual(deep.name, "файл.txt")

        let shallow = RcloneRemoteFileSystem.split("/файл.txt")
        XCTAssertEqual(shallow.directory, "", "в корне папки нет")
        XCTAssertEqual(shallow.name, "файл.txt")
    }

    // MARK: - Строка выдачи

    func test_строкаВыдачиЧитаетсяЦеликом() {
        let row: [String: Any] = [
            "Name": "отчёт.pdf", "Path": "папка/отчёт.pdf",
            "Size": 1234, "IsDir": false,
            "ModTime": "2026-08-28T10:20:30.000000000Z"
        ]
        let item = RcloneRemoteFileSystem.item(from: row, in: "/папка/")
        XCTAssertEqual(item?.name, "отчёт.pdf")
        XCTAssertEqual(item?.size, 1234)
        XCTAssertEqual(item?.fileExtension, "pdf")
        XCTAssertEqual(item?.isDirectory, false)
        // Путь собран от запрошенной папки, а не взят из Path: иначе вышло бы удвоение.
        XCTAssertEqual(item?.path, "/папка/отчёт.pdf")
    }

    /// У папки rclone отдаёт размер −1. Отрицательный размер в панели выглядел бы дико,
    /// а точка в имени папки не делает её расширением.
    func test_папкаБезРазмераИБезРасширения() {
        let row: [String: Any] = [
            "Name": "архив.старое", "Size": -1, "IsDir": true,
            "ModTime": "2026-08-28T10:20:30Z"
        ]
        let item = RcloneRemoteFileSystem.item(from: row, in: "/")
        XCTAssertEqual(item?.isDirectory, true)
        XCTAssertEqual(item?.size, 0)
        XCTAssertEqual(item?.fileExtension, "")
    }

    func test_безымяннаяСтрокаПропускается() {
        XCTAssertNil(RcloneRemoteFileSystem.item(from: ["IsDir": false], in: "/"))
        XCTAssertNil(RcloneRemoteFileSystem.item(from: ["Name": ""], in: "/"))
    }

    func test_времяЧитаетсяИСДолямиСекундыИБезНих() {
        XCTAssertNotNil(RcloneRemoteFileSystem.date(from: "2026-08-28T10:20:30.123456789Z"))
        XCTAssertNotNil(RcloneRemoteFileSystem.date(from: "2026-08-28T10:20:30Z"))
        XCTAssertNotNil(RcloneRemoteFileSystem.date(from: "2026-08-28T10:20:30+03:00"))
        XCTAssertNil(RcloneRemoteFileSystem.date(from: "вчера"))
    }

    // MARK: - Чужие жалобы

    func test_жалобаНаОтсутствиеХранилищаНазываетГдеИскать() {
        let error = RcloneDaemon.error(
            from: ["error": "didn't find section in config file (мойдиск)"],
            path: "operations/fsinfo")
        guard case .connectionFailed(let text) = error else {
            return XCTFail("это отказ подключения, а не \(error)")
        }
        XCTAssertTrue(text.contains("rclone config"))
    }

    func test_жалобыРазложеныПоСвоимПолкам() {
        if case .pathNotFound = RcloneDaemon.error(from: ["error": "directory not found"],
                                                   path: "operations/list") {} else {
            XCTFail("«папки нет» — это отсутствующий путь")
        }
        if case .permissionDenied = RcloneDaemon.error(from: ["error": "permission denied"],
                                                       path: "operations/list") {} else {
            XCTFail("«доступ запрещён» — это запрет доступа")
        }
        if case .authenticationFailed = RcloneDaemon.error(
            from: ["error": "couldn't fetch token: unauthorized"], path: "x") {} else {
            XCTFail("протухший пропуск — это отказ в опознании")
        }
    }

    /// Незнакомая жалоба обязана дойти до человека целиком: «что-то пошло не так» не
    /// поможет никому, а текст rclone обычно называет причину прямо.
    func test_незнакомаяЖалобаДоходитЦеликом() {
        let strange = "quota exceeded for this drive"
        let error = RcloneDaemon.error(from: ["error": strange], path: "operations/copyfile")
        guard case .operationFailed(let text) = error else {
            return XCTFail("незнакомое — это просто сбой операции, а не \(error)")
        }
        XCTAssertEqual(text, strange)
    }

    // MARK: - Порт

    func test_свободныйПортНаходитсяИНеПовторяется() throws {
        let first = try RcloneDaemon.freePort()
        let second = try RcloneDaemon.freePort()
        XCTAssertGreaterThan(first, 1024, "не из числа занятых системой")
        XCTAssertGreaterThan(second, 1024)
    }

    func test_парольНаЗапускКаждыйРазДругой() {
        let one = RcloneDaemon.freshPassword()
        let two = RcloneDaemon.freshPassword()
        XCTAssertNotEqual(one, two)
        XCTAssertGreaterThanOrEqual(one.count, 24, "угадывать нечего")
    }

    // MARK: - Заведение облака

    /// Пропуск rclone печатает между двумя метками. Взять его надо целиком: это JSON,
    /// и половина от него бесполезна.
    func test_пропускВыковыриваетсяИзВывода() {
        let output = """
        2026/08/28 22:00:00 NOTICE: Waiting for code...
        Got code
        Paste the following into your remote machine --->
        {"access_token":"ЯЩЕРИЦА","token_type":"Bearer","expiry":"2030-01-01T00:00:00Z"}
        <---End paste
        """
        XCTAssertEqual(RcloneCloudSetup.token(in: output),
                       "{\"access_token\":\"ЯЩЕРИЦА\",\"token_type\":\"Bearer\",\"expiry\":\"2030-01-01T00:00:00Z\"}")
    }

    func test_безПропускаНичегоНеПридумывается() {
        XCTAssertNil(RcloneCloudSetup.token(in: "Waiting for code...\nошибка входа"))
        XCTAssertNil(RcloneCloudSetup.token(in: ""))
        // Метки есть, а между ними пусто — это не пропуск.
        XCTAssertNil(RcloneCloudSetup.token(in: "x --->\n\n<---End paste"))
    }

    func test_ссылкаНаРазрешениеНаходится() {
        let line = "2026/08/28 22:00:00 NOTICE: Please go to the following link: "
            + "http://127.0.0.1:53682/auth?state=abc"
        XCTAssertEqual(RcloneCloudSetup.link(in: line)?.absoluteString,
                       "http://127.0.0.1:53682/auth?state=abc")
        XCTAssertNil(RcloneCloudSetup.link(in: "NOTICE: Waiting for code..."))

        // Первой строкой rclone пишет про адрес возврата — и в ней тоже есть 127.0.0.1.
        // Принять её за ссылку значит увести человека в браузер по обрывку фразы.
        XCTAssertNil(RcloneCloudSetup.link(
            in: "NOTICE: Make sure your Redirect URL is set to "
                + "\"http://127.0.0.1:53682/\" in your custom config."))
    }

    /// Ответы на вопросы rclone при заведении хранилища. Самый важный — про обновление
    /// пропуска: ответишь «как по умолчанию» (да) — и rclone пойдёт за НОВЫМ пропуском,
    /// то есть откроет браузер второй раз и повиснет, ожидая того, что уже получено.
    func test_наВопросПроОбновлениеПропускаОтвечаемНет() {
        XCTAssertEqual(RcloneCloudSetup.answer(to: "config_refresh_token", default: "true"),
                       "false")
    }

    func test_остальныеОтветыНеПортятНастройку() {
        // Да, общим ключом rclone.
        XCTAssertEqual(RcloneCloudSetup.answer(to: "config_shared_client_id", default: "false"),
                       "true")
        // Свой ключ не выдумываем: пустое поле означает «общий».
        XCTAssertEqual(RcloneCloudSetup.answer(to: "client_id", default: ""), "")
        XCTAssertEqual(RcloneCloudSetup.answer(to: "client_secret", default: ""), "")
        XCTAssertEqual(RcloneCloudSetup.answer(to: "config_change_team_drive", default: "false"),
                       "false")
        // Незнакомый вопрос — как предлагает сам rclone.
        XCTAssertEqual(RcloneCloudSetup.answer(to: "нечто_новое", default: "по умолчанию"),
                       "по умолчанию")
    }

    /// Два Google Drive у одного человека — обычное дело: свой и рабочий. Второй не
    /// должен затирать первый.
    func test_имяДляВторогоТакогоЖеОблакаСвободное() {
        XCTAssertEqual(RcloneCloudSetup.freeName(basedOn: "Google Drive", among: []),
                       "Google Drive")
        XCTAssertEqual(RcloneCloudSetup.freeName(basedOn: "Google Drive",
                                                 among: ["Google Drive"]),
                       "Google Drive 2")
        XCTAssertEqual(RcloneCloudSetup.freeName(basedOn: "Google Drive",
                                                 among: ["Google Drive", "Google Drive 2"]),
                       "Google Drive 3")
    }

    /// У Google по умолчанию дают права только на файлы, созданные самой программой.
    /// Панели этого мало: она обязана показывать то, что там уже лежит.
    func test_уGoogleПросимДоступКоВсемуДиску() {
        let drive = RcloneCloudService.popular.first { $0.type == "drive" }
        XCTAssertEqual(drive?.extras["scope"], "drive")
    }

    // MARK: - Выбор диска OneDrive

    /// За одной учётной записью Microsoft бывает несколько «дисков», и первый в списке —
    /// не обязательно живой. Настоящий случай: первым шёл мёртвый остаток SharePoint,
    /// его корень отвечал «ObjectHandle is Invalid» — и подключение падало, хотя браузер
    /// честно сказал «Success».
    func test_изДисковБерётсяЛичный() {
        let диски: [[String: Any]] = [
            ["Value": "b!мёртвый", "Help": "SharePoint (documentLibrary)"],
            ["Value": "живой123", "Help": "OneDrive (personal)"]
        ]
        XCTAssertEqual(RcloneCloudSetup.pickDrive(from: диски, rejecting: []), "живой123",
                       "личный диск важнее первого места в списке")
    }

    func test_вычеркнутыйДискНеПредлагается() {
        let диски: [[String: Any]] = [
            ["Value": "первый", "Help": "OneDrive (personal)"],
            ["Value": "второй", "Help": "OneDrive (business)"]
        ]
        XCTAssertEqual(RcloneCloudSetup.pickDrive(from: диски, rejecting: ["первый"]),
                       "второй", "не открывшийся личный уступает живому деловому")
        XCTAssertNil(RcloneCloudSetup.pickDrive(from: диски,
                                                rejecting: ["первый", "второй"]),
                     "когда вычеркнуты все — предлагать нечего")
    }

    /// Жалоба rclone называет диск, чей корень не открылся, — его и вычёркиваем.
    func test_номерМёртвогоДискаЧитаетсяИзЖалобы() {
        let жалоба = "Ошибка операции: Failed to query root for drive "
            + "\"b!TyPSJlPxvEWgamRsAqKCRIfc\": HTTP error 400 (400 Bad Request)"
        XCTAssertEqual(RcloneCloudSetup.failedDrive(in: жалоба),
                       "b!TyPSJlPxvEWgamRsAqKCRIfc")
        XCTAssertNil(RcloneCloudSetup.failedDrive(in: "couldn't fetch token"),
                     "чужая жалоба диска не называет")
    }

    // MARK: - Ввоз в документы Google

    func test_жалобаНаДокументGoogleУзнаётся() {
        XCTAssertTrue(RcloneRemoteFileSystem.needsGoogleImport(
            .operationFailed("can't update google document type without --drive-import-formats")))
        XCTAssertFalse(RcloneRemoteFileSystem.needsGoogleImport(
            .operationFailed("quota exceeded")))
    }

    /// Ключ ввоза — одним расширением: запятая в строке подключения rclone разделяет
    /// ключи, и список расширений сломал бы её разбор.
    func test_имяХранилищаСКлючомВвоза() {
        XCTAssertEqual(RcloneRemoteFileSystem.importFs(remote: "Google Drive",
                                                       fileExtension: "DOCX"),
                       "Google Drive,import_formats=docx:")
    }
}
