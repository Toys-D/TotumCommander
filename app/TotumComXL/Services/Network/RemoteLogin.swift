import Foundation

/// Вход на сервер: что он ответил, как это сказать человеку и что спросить заново.
///
/// Раньше отказ во входе доезжал до окна ошибки словами libcurl — «Login denied», — и на этом
/// всё кончалось: панель оставалась пустой, а спросить пароль заново было негде. Здесь ответ
/// сервера разбирается на смысл, а `MainWindowController` по нему решает, открыть ли окно входа
/// и повторить ли попытку.
enum RemoteLogin {

    /// Чем кончилась попытка войти.
    enum Verdict: Equatable {
        /// Сервер отказал и сказал, почему («530 User cannot log in.»). Строка может быть и
        /// пустой: не всякий сервер объясняется.
        case refused(String)
        /// Сервер попросил пароль — и закрыл связь, не ответив на него.
        case droppedAfterPassword
    }

    /// Разбор последнего ответа сервера. Первые три цифры — это код FTP: 331 означает, что до
    /// пароля дошло, а раз ответа на него не было, связь оборвалась именно на нём.
    nonisolated static func verdict(forServerReply reply: String) -> Verdict {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("331") { return .droppedAfterPassword }
        return .refused(trimmed)
    }

    /// Начинается ли строка с трёхзначного кода ответа — тогда это дословные слова сервера,
    /// и их стоит подписать как ответ сервера, а не выдавать за нашу мысль.
    nonisolated static func looksLikeServerReply(_ text: String) -> Bool {
        let digits = text.prefix(3)
        return digits.count == 3 && digits.allSatisfy(\.isNumber)
    }

    /// Что человек прочтёт в окне ошибки.
    nonisolated static func message(for verdict: Verdict) -> String {
        switch verdict {
        case .droppedAfterPassword:
            return L("network.login.dropped")
        case .refused(let reply) where reply.isEmpty:
            return L("network.login.refused")
        case .refused(let reply) where looksLikeServerReply(reply):
            return L("network.login.refusedWithReply", reply)
        case .refused(let reply):
            return L("network.login.refusedWithReason", reply)
        }
    }

    /// Ошибка входа отличается от «сервер недоступен»: на первую надо спросить пароль заново,
    /// на вторую спрашивать нечего. Ядро отвечает на отказ во входе кодом `permissionDenied` —
    /// и FTP (530 и подобные), и SFTP (ключ или пароль не подошли).
    nonisolated static func error(from error: Error) -> RemoteFileSystemError {
        let detail = error.localizedDescription
        guard CoreErrorCode.of(error) == .permissionDenied else {
            return .connectionFailed(detail)
        }
        return .loginRefused(message(for: verdict(forServerReply: detail)))
    }

    /// Стоит ли открыть окно входа и попробовать ещё раз.
    nonisolated static func asksAgain(after error: Error) -> Bool {
        guard let remote = error as? RemoteFileSystemError else { return false }
        switch remote {
        case .loginRefused, .authenticationFailed: return true
        default: return false
        }
    }

    /// У каких подключений вообще есть имя и пароль, которые можно переспросить. У облаков
    /// их нет: доступ туда выдаёт браузер, ключи лежат у rclone, и окно с полем «пароль»
    /// человека только запутало бы.
    nonisolated static func canAskAgain(_ proto: RemoteProtocol) -> Bool { proto != .rclone }

    /// Что ответ из окна входа меняет в подключении.
    ///
    /// «Как гость» на FTP — это анонимный вход, каким его знают все серверы: имя `anonymous`
    /// и почтовый адрес вместо пароля. Пустое имя ничего не меняет: человек оставил прежнее.
    nonisolated static func applying(account: String, password: String, asGuest: Bool,
                                     to connection: RemoteConnection) -> (RemoteConnection, String) {
        var updated = connection
        if asGuest {
            updated.username = "anonymous"
            return (updated, "anonymous@")
        }
        let name = account.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { updated.username = name }
        return (updated, password)
    }
}
