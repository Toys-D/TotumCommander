import Foundation

/// Who made the program and where it lives — the one place these facts are written, so the
/// About section, and anything else that names them, cannot drift apart. The GitHub account
/// was renamed once already (toys1981 → Toys-D), and the old name stayed in the About
/// section for a while: it was typed there by hand.
enum AppIdentity {
    /// The person — the GitHub account the program is published from.
    static let developer = "Toys-D"
    /// The company behind the program, as named on GitHub.
    static let company = "Pixmap Labs"

    static let repositorySlug = "Toys-D/TotumCommander"
    static let repositoryURL = URL(string: "https://github.com/\(repositorySlug)")!
    static let releasesURL = repositoryURL.appendingPathComponent("releases")
    static let licenseURL = repositoryURL.appendingPathComponent("blob/TotumCommander/LICENSE")

    static let license = "GNU GPL v3"

    /// Почта автора — и для писем, и для благодарности через PayPal: адрес один, и написан
    /// он здесь один раз, чтобы «О программе», README и руководство не разошлись.
    static let email = "pixmap1981@gmail.com"

    /// Устаревшее имя того же адреса — оставлено, чтобы ссылка на PayPal читалась по смыслу.
    static var supportEmail: String { email }

    /// Письмо автору. Тема подставляется сразу: письмо о программе не потеряется среди прочей
    /// почты, а человеку не надо придумывать, с чего начать.
    static var contactURL: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [URLQueryItem(name: "subject", value: "Totum Commander")]
        return components.url ?? URL(string: "mailto:\(email)")!
    }

    // MARK: - Заголовок главного окна

    /// Версия из бандла — та, что видят люди («1.0»).
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// Копия «как у нового пользователя» (launch.sh --fresh): свой идентификатор с хвостом .fresh.
    static func isFreshCopy(bundleIdentifier: String?) -> Bool {
        bundleIdentifier?.hasSuffix(".fresh") == true
    }

    /// Номер сборки — внутренняя бухгалтерия автора: по нему сверяются отчёты о правках.
    /// Людям — версия: ни в релизе, ни в копии для нового пользователя «Build 2243» не место.
    static func showsBuildInTitle(debugBuild: Bool, freshCopy: Bool) -> Bool {
        debugBuild && !freshCopy
    }

    static var showsBuildInTitle: Bool {
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        return showsBuildInTitle(debugBuild: debugBuild,
                                 freshCopy: isFreshCopy(bundleIdentifier: Bundle.main.bundleIdentifier))
    }

    static func windowTitle(product: String, version: String, build: Int, showsBuild: Bool) -> String {
        showsBuild ? "\(product) — Build \(build)" : "\(product) \(version)"
    }
    static let supportURL = URL(string: "https://www.paypal.com/cgi-bin/webscr?cmd=_xclick"
        + "&business=pixmap1981%40gmail.com&item_name=Totum+Commander&currency_code=USD")!
}
