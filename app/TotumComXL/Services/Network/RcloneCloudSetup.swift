import AppKit
import Foundation
import SwiftUI

/// Одна служба хранения — так, как её знает человек, и так, как её зовёт rclone.
struct RcloneCloudService: Identifiable, Hashable {
    /// Имя бэкенда у rclone: «drive», «dropbox», «onedrive»…
    let type: String
    /// Как это называется у людей.
    let title: String
    /// Запасной системный значок — на случай, если логотип не нашёлся в ресурсах.
    let icon: String
    /// Логотип службы. Человек узнаёт её в лицо: слово «rclone» и системное облачко
    /// говорят ему одинаково мало.
    let logo: String
    /// Цвет службы — тот, по которому её узнают с одного взгляда.
    let tint: String
    /// Дополнительные ключи в настройку хранилища — то, без чего оно работает не так.
    var extras: [String: String] = [:]

    var color: Color { PanelAppearanceSettings.swiftUIColor(from: tint, fallback: .secondary) }

    /// Картинка логотипа, если она на месте. Нет — плитка обойдётся системным значком:
    /// подключение к облаку не должно ломаться из-за пропавшей картинки.
    var logoImage: NSImage? { CloudLogos.image(named: logo) }
    var id: String { type }

    /// Те, за которыми приходят чаще всего. Все они пускают через браузер: человек
    /// нажимает «Разрешить», и больше от него ничего не нужно.
    ///
    /// Список нарочно короткий. rclone умеет семь десятков хранилищ, но у большинства
    /// вход не через браузер, а логином, паролем или ключом — им нужны свои поля, и
    /// сваливать всё в одно окно значит сделать его непонятным. Остальные заводятся
    /// в самом rclone и появляются здесь сами.
    static let popular: [RcloneCloudService] = [
        // Полный доступ к диску, иначе видны только файлы, созданные самой программой.
        RcloneCloudService(type: "drive", title: "Google Drive", icon: "triangle.fill",
                           logo: "cloud-drive", tint: "#1A73E8", extras: ["scope": "drive"]),
        RcloneCloudService(type: "dropbox", title: "Dropbox", icon: "diamond.fill",
                           logo: "cloud-dropbox", tint: "#0061FF"),
        RcloneCloudService(type: "onedrive", title: "OneDrive", icon: "cloud.fill",
                           logo: "cloud-onedrive", tint: "#0078D4"),
        RcloneCloudService(type: "yandex", title: "Яндекс.Диск",
                           icon: "externaldrive.fill.badge.wifi",
                           logo: "cloud-yandex", tint: "#FC3F1D"),
        RcloneCloudService(type: "box", title: "Box", icon: "shippingbox.fill",
                           logo: "cloud-box", tint: "#0061D5"),
        RcloneCloudService(type: "pcloud", title: "pCloud", icon: "cloud.circle.fill",
                           logo: "cloud-pcloud", tint: "#00A3E0")
    ]
}

/// Логотипы служб из ресурсов. Читаются один раз: окно подключения открывают не раз в
/// жизни, а перечитывать шесть картинок с диска каждый показ незачем.
enum CloudLogos {
    private static var loaded: [String: NSImage] = [:]
    private static let lock = NSLock()

    static func image(named name: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let ready = loaded[name] { return ready }
        guard let url = AppResources.bundle.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        loaded[name] = image
        return image
    }
}

/// Заведение облака без Терминала: человек выбирает службу, разрешает доступ в браузере —
/// и хранилище появляется в списке.
///
/// Внутри это две части. Сначала `rclone authorize` поднимает у себя страничку, уводит
/// человека к службе и получает от неё пропуск. Потом пропуск отдаётся служебному серверу
/// rclone, и тот записывает хранилище в свою настройку.
///
/// Вторая часть — не один вызов, а разговор: rclone задаёт вопросы («ключ общий или свой?»,
/// «пропуск обновить?») и ждёт ответов. Проверено на живом rclone: без ответов он молча
/// висит, а без пометки «не спрашивать вслух» — висит навсегда, потому что спрашивает
/// в никуда.
enum RcloneCloudSetup {

    // MARK: - Разговор с rclone при записи хранилища

    /// Ответы на вопросы, которые rclone задаёт при заведении хранилища.
    ///
    /// Отвечать «как по умолчанию» на всё нельзя: на «пропуск обновить?» по умолчанию «да»,
    /// и rclone полез бы за новым пропуском вместо того, который мы только что получили, —
    /// то есть открыл бы браузер второй раз и завис в ожидании.
    static func answer(to question: String, default fallback: String) -> String {
        switch question {
        // Да, общим ключом rclone. Свой ключ — отдельное поле в окне, и если он задан,
        // то приезжает параметром и этот вопрос не задаётся.
        case "config_shared_client_id": return "true"
        case "client_id", "client_secret": return ""
        // Пропуск у нас уже есть — обновлять нечего.
        case "config_refresh_token": return "false"
        // Общий диск организации — не наше дело: нужен корневой.
        case "config_change_team_drive": return "false"
        default: return fallback
        }
    }

    /// Записать хранилище в настройку rclone.
    static func createRemote(named name: String, service: RcloneCloudService,
                             token: String, clientID: String = "", clientSecret: String = "",
                             daemon: RcloneDaemon = .shared) async throws {
        var parameters: [String: String] = service.extras
        parameters["token"] = token
        if !clientID.isEmpty { parameters["client_id"] = clientID }
        if !clientSecret.isEmpty { parameters["client_secret"] = clientSecret }

        let place = try await daemon.acquire()
        defer { Task { await daemon.release(place.ticket) } }

        // Диски учётной записи, чей корень не открылся. У OneDrive за одной учётной
        // записью бывает несколько «дисков», и первый в списке — не обязательно живой:
        // у человека им оказался мёртвый остаток SharePoint, корень которого отвечал
        // «ObjectHandle is Invalid». Такой вычёркиваем и пробуем следующий.
        var deadDrives: Set<String> = []

        // Внешний круг — по дискам, внутренний — по вопросам одного захода.
        attempts: for _ in 0..<6 {
            var options: [String: Any] = ["nonInteractive": true]
            for _ in 0..<12 {
                let answer: [String: Any]
                do {
                    answer = try await daemon.call("config/create", [
                        "name": name, "type": service.type,
                        "parameters": parameters, "opt": options
                    ])
                } catch let error as RemoteFileSystemError {
                    if let dead = Self.failedDrive(in: error.errorDescription ?? ""),
                       !deadDrives.contains(dead) {
                        deadDrives.insert(dead)
                        continue attempts
                    }
                    // Хранилище уже записано в настройку — config/create пишет его до
                    // вопросов. Не убрать его значит копить огрызки: у человека после
                    // трёх неудачных попыток лежали «OneDrive», «OneDrive 2», «OneDrive 3».
                    try? await daemon.call("config/delete", ["name": name])
                    throw error
                }
                if let complaint = answer["Error"] as? String, !complaint.isEmpty {
                    if let dead = Self.failedDrive(in: complaint), !deadDrives.contains(dead) {
                        deadDrives.insert(dead)
                        continue attempts
                    }
                    try? await daemon.call("config/delete", ["name": name])
                    throw RemoteFileSystemError.operationFailed(complaint)
                }
                guard let state = answer["State"] as? String, !state.isEmpty else { return }

                let question = answer["Option"] as? [String: Any] ?? [:]
                let questionName = question["Name"] as? String ?? ""
                let fallback = question["ValueStr"] as? String ?? ""
                let result: String
                if questionName == "config_driveid_fixed" || questionName == "config_driveid" {
                    let examples = question["Examples"] as? [[String: Any]] ?? []
                    result = Self.pickDrive(from: examples, rejecting: deadDrives) ?? fallback
                } else {
                    result = Self.answer(to: questionName, default: fallback)
                }
                options = ["nonInteractive": true, "continue": true, "state": state,
                           "result": result]
            }
            break
        }
        try? await daemon.call("config/delete", ["name": name])
        throw RemoteFileSystemError.operationFailed(L("rclone.error.tooManyQuestions"))
    }

    /// Какой из дисков учётной записи брать.
    ///
    /// Вычеркнутые не предлагаем; из остальных первым — личный: за ним люди и приходят,
    /// а деловые и библиотечные пусть выбирает тот, кто заведёт хранилище в самом rclone.
    static func pickDrive(from examples: [[String: Any]], rejecting dead: Set<String>)
    -> String? {
        let alive = examples.compactMap { row -> (id: String, help: String)? in
            guard let id = row["Value"] as? String, !dead.contains(id) else { return nil }
            return (id, (row["Help"] as? String ?? "").lowercased())
        }
        return (alive.first { $0.help.contains("personal") } ?? alive.first)?.id
    }

    /// Номер диска из жалобы «Failed to query root for drive "…"».
    static func failedDrive(in text: String) -> String? {
        guard let marker = text.range(of: "Failed to query root for drive \"") else { return nil }
        let tail = text[marker.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        let id = String(tail[..<end])
        return id.isEmpty ? nil : id
    }

    /// Убрать хранилище из настройки rclone.
    static func deleteRemote(named name: String, daemon: RcloneDaemon = .shared) async throws {
        let place = try await daemon.acquire()
        defer { Task { await daemon.release(place.ticket) } }
        try await daemon.call("config/delete", ["name": name])
    }

    /// Свободное имя: к занятому приписывается число. Два Google Drive у одного человека —
    /// обычное дело (свой и рабочий), и второй не должен затирать первый.
    static func freeName(basedOn wanted: String, among taken: [String]) -> String {
        guard taken.contains(wanted) else { return wanted }
        for number in 2...99 where !taken.contains("\(wanted) \(number)") {
            return "\(wanted) \(number)"
        }
        return wanted + " " + UUID().uuidString.prefix(4)
    }

    // MARK: - Пропуск от службы

    /// Строки, которыми rclone обрамляет выданный пропуск.
    static let tokenOpening = "--->"
    static let tokenClosing = "<---"

    /// Выковырять пропуск из того, что напечатал rclone.
    static func token(in output: String) -> String? {
        let lines = output.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.hasSuffix(tokenOpening) }) else { return nil }
        var collected: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix(tokenClosing) { break }
            collected.append(line)
        }
        let token = collected.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Ссылка, которую rclone просит открыть.
    ///
    /// Искать в строке просто «http://127.0.0.1:» нельзя: первой же строкой rclone пишет
    /// «Make sure your Redirect URL is set to "http://127.0.0.1:53682/" in your custom
    /// config», и в браузер уехал бы обрывок этой фразы вместо ссылки. Проверено на живом
    /// rclone. Поэтому берём только ту строку, которая ссылку и предлагает.
    static func link(in line: String) -> URL? {
        guard let marker = line.range(of: "following link:") else { return nil }
        let tail = line[marker.upperBound...]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard let url = URL(string: tail), url.scheme?.hasPrefix("http") == true else {
            return nil
        }
        return url
    }

    /// Сходить к службе за пропуском.
    ///
    /// Браузер открываем сами, а не оставляем это rclone: так человек видит, что произошло
    /// по нажатию его кнопки, а если браузер не открылся — ссылку можно показать в окне
    /// и дать скопировать.
    static func authorize(service: RcloneCloudService,
                          clientID: String = "", clientSecret: String = "",
                          onLink: @escaping (URL) -> Void) async throws -> String {
        guard let binary = RcloneDaemon.binaryPath() else {
            throw RemoteFileSystemError.connectionFailed(
                L("rclone.error.notInstalled", RcloneDaemon.installHint))
        }

        let run = AuthorizeRun(binary: binary, service: service,
                               clientID: clientID, clientSecret: clientSecret)
        return try await withTaskCancellationHandler {
            try await run.start(onLink: onLink)
        } onCancel: {
            run.stop()
        }
    }

    /// Один поход за пропуском. Отдельным предметом — чтобы отмену было кому исполнить:
    /// человек закрыл окно, а чужой процесс так и сидел бы, слушая свой порт.
    private final class AuthorizeRun: @unchecked Sendable {
        private let task = Process()
        private let pipe = Pipe()
        private let lock = NSLock()
        private var collected = ""
        private var linkSeen = false
        private var finished = false
        /// Отмену могли попросить раньше, чем процесс успел родиться. Просто спросить
        /// «он ещё бежит?» и уйти нельзя: через миг он побежит — и останется висеть на
        /// своём порту навсегда, а следующий заход упрётся в занятый порт.
        private var stopWanted = false

        init(binary: String, service: RcloneCloudService, clientID: String, clientSecret: String) {
            task.executableURL = URL(fileURLWithPath: binary)
            var arguments = ["authorize", service.type, "--auth-no-open-browser"]
            // Свой ключ службы, если человек его завёл: rclone принимает его парой
            // следом за именем хранилища.
            if !clientID.isEmpty, !clientSecret.isEmpty {
                arguments.insert(contentsOf: [clientID, clientSecret], at: 2)
            }
            // Область доступа задаётся так же, как в самой настройке: без неё Google даёт
            // права только на файлы, созданные самой программой, — для панели это пусто.
            for (key, value) in service.extras {
                arguments.append("--\(service.type)-\(key.replacingOccurrences(of: "_", with: "-"))=\(value)")
            }
            task.arguments = arguments
            task.standardOutput = pipe
            task.standardError = pipe
        }

        func stop() {
            lock.lock()
            stopWanted = true
            let alive = task.isRunning
            lock.unlock()
            if alive { task.terminate() }
        }

        func start(onLink: @escaping (URL) -> Void) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                let handle = pipe.fileHandleForReading
                handle.readabilityHandler = { [weak self] handle in
                    guard let self else { return }
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    let text = String(data: chunk, encoding: .utf8) ?? ""

                    self.lock.lock()
                    self.collected += text
                    let showLink = !self.linkSeen
                    let everything = self.collected
                    self.lock.unlock()

                    guard showLink else { return }
                    for line in text.components(separatedBy: .newlines) {
                        if let url = RcloneCloudSetup.link(in: line) {
                            self.lock.lock(); self.linkSeen = true; self.lock.unlock()
                            DispatchQueue.main.async { onLink(url) }
                            break
                        }
                    }
                    _ = everything
                }

                task.terminationHandler = { [weak self] process in
                    guard let self else { return }
                    handle.readabilityHandler = nil
                    // Хвост, дописанный между последним чтением и завершением: пропуск
                    // печатается последним, и потерять именно его было бы обидно.
                    let tail = (try? handle.readToEnd()).flatMap { String(data: $0, encoding: .utf8) }

                    self.lock.lock()
                    if let tail { self.collected += tail }
                    let output = self.collected
                    let already = self.finished
                    self.finished = true
                    self.lock.unlock()
                    guard !already else { return }

                    if let token = RcloneCloudSetup.token(in: output) {
                        continuation.resume(returning: token)
                    } else if process.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: RemoteFileSystemError.transferCancelled)
                    } else {
                        continuation.resume(throwing: RemoteFileSystemError.authenticationFailed(
                            Self.complaint(in: output)))
                    }
                }

                do {
                    try task.run()
                    // Отмену могли попросить, пока процесс поднимался.
                    lock.lock(); let wanted = stopWanted; lock.unlock()
                    if wanted { task.terminate() }
                } catch {
                    lock.lock(); let already = finished; finished = true; lock.unlock()
                    if !already {
                        continuation.resume(throwing: RemoteFileSystemError.connectionFailed(
                            L("rclone.error.cannotStart", error.localizedDescription)))
                    }
                }
            }
        }

        /// Последняя внятная строка того, что напечатал rclone: она обычно и называет причину.
        static func complaint(in output: String) -> String {
            let meaningful = output.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasSuffix("Waiting for code...") }
            guard let last = meaningful.last else { return L("rclone.error.noToken") }
            // Метка времени и уровень в начале строки человеку ничего не говорят.
            if let range = last.range(of: "NOTICE: ") ?? last.range(of: "ERROR : ") {
                return String(last[range.upperBound...])
            }
            return last
        }
    }
}
