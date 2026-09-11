import Darwin
import Foundation

/// Ресурсы программы: строки перевода, руководство, оформление по умолчанию, картинки.
///
/// Почему свой поиск вместо `Bundle.module`. SwiftPM сам пишет `Bundle.module` — и пишет его
/// ровно из двух путей: набор рядом с `.app` и набор по АБСОЛЮТНОМУ пути сборочной папки той
/// машины, где собирали. Ни там, ни там его в собранной программе нет: правильное место
/// ресурсов в программе для macOS — `Contents/Resources`, туда их и кладут наши скрипты. На
/// машине автора спасала сборочная папка — она никуда не девалась. А на чужом Mac не нашлось
/// ни того, ни другого, и `Bundle.module` вызвал `fatalError` в первой же строке запуска:
/// программа не открывала даже окна.
///
/// Здесь порядок поиска полный, а на самый крайний случай — сам `.app`: без строк перевода
/// человек увидит ключи вместо слов, но программа запустится и будет работать. Ресурс,
/// которого нет, — это неудобство; падение до первого окна — это «программа не работает».
enum AppResources {

    /// Имя, которое SwiftPM даёт набору ресурсов этой цели.
    static let bundleName = "TotumComXL_TotumComXLApp"

    /// Где искать набор, по порядку. Вынесено отдельной чистой функцией, чтобы порядок
    /// проверялся тестом, а не сборкой всего `.app`.
    ///
    /// - Parameters:
    ///   - mainBundleURL: `Bundle.main.bundleURL` — сам `.app` или папка исполняемого файла.
    ///   - resourceURL: `Bundle.main.resourceURL` — `Contents/Resources` у собранной программы.
    ///   - codeBundleURL: адрес набора, в котором лежит наш код: у тестов это тестовый набор,
    ///     рядом с которым SwiftPM кладёт и набор ресурсов.
    nonisolated static func candidates(mainBundleURL: URL, resourceURL: URL?,
                                       codeBundleURL: URL? = nil) -> [URL] {
        let leaf = bundleName + ".bundle"
        var list: [URL] = []
        // 1. Contents/Resources — место ресурсов в собранной программе.
        if let resourceURL { list.append(resourceURL.appendingPathComponent(leaf)) }
        // 2. В корне самого .app (а у отладочной сборки — рядом с исполняемым файлом):
        //    именно сюда смотрит сгенерированный SwiftPM поиск.
        list.append(mainBundleURL.appendingPathComponent(leaf))
        // 3. Рядом с набором, в котором лежит наш код: так набор находится в тестах и при
        //    запуске из-под сборки. Только когда программа запущена НЕ из `.app`: у
        //    собранной программы это папка, В КОТОРОЙ она лежит, — Загрузки например, — и
        //    случайный чужой набор рядом не должен подменять наш собственный.
        if let codeBundleURL, mainBundleURL.pathExtension != "app" {
            list.append(codeBundleURL.deletingLastPathComponent().appendingPathComponent(leaf))
            list.append(codeBundleURL.appendingPathComponent(leaf))
        }
        // 4. Внутри .app рядом с исполняемым файлом — на случай самосборной раскладки.
        list.append(mainBundleURL.appendingPathComponent("Contents/MacOS/" + leaf))
        // Один и тот же путь мог попасть в список дважды — например, когда код лежит в самой
        // программе. Проверять его дважды незачем.
        var seen = Set<String>()
        return list.filter { seen.insert($0.path).inserted }
    }

    /// Приметы настоящего набора: по ним видно, что это наши ресурсы, а не пустая папка с
    /// подходящим именем. `Bundle(url:)` соглашается на любую существующую папку, а поиск на
    /// ней останавливается — и программа осталась бы с ключами вместо слов, не сказав ни слова.
    static let markers = ["ru.lproj", "DefaultStyle.plist"]

    /// Есть ли в этой папке хоть одна примета нашего набора.
    nonisolated static func looksLikeOurBundle(_ url: URL,
                                               exists: (String) -> Bool = {
                                                   FileManager.default.fileExists(atPath: $0)
                                               }) -> Bool {
        markers.contains { exists(url.appendingPathComponent($0).path) }
    }

    /// Первый ПРИГОДНЫЙ набор из перечисленных: существующий и с ресурсами внутри.
    nonisolated static func firstBundle(among urls: [URL]) -> Bundle? {
        for url in urls where looksLikeOurBundle(url) {
            if let found = Bundle(url: url) { return found }
        }
        return nil
    }

    /// Набор ресурсов. Никогда не роняет программу: если набора нет, это сам `.app`.
    /// Найденный набор. Держится между обращениями, но перед выдачей проверяется: на месте
    /// ли он ещё.
    ///
    /// Зачем проверка. Программу можно сдвинуть, пока она работает, — перетащить из Загрузок
    /// в Программы или переименовать папку, в которой она лежит; файловым менеджером это
    /// делается на раз, им можно переместить и его самого. Запомненный путь после этого
    /// указывает в пустоту, и всё, что читается с диска потом — справка, части редактора,
    /// маски курсора, значки облаков, — не находится до перезапуска. Проверка «папка ещё
    /// там?» стоит микросекунды, а обращения к своим файлам редки: открыли справку, открыли
    /// редактор. Пропала — ищем себя заново, уже по новому месту.
    private static var resolved: Bundle?
    private static let lock = NSLock()

    static var bundle: Bundle {
        lock.lock()
        defer { lock.unlock() }
        if let resolved, looksLikeOurBundle(resolved.bundleURL) { return resolved }
        let found = locate()
        resolved = found
        return found
    }

    /// Где программа лежит ПРЯМО СЕЙЧАС — по слову ядра, а не по памяти.
    ///
    /// Измерено: после переноса работающей программы `Bundle.main.bundleURL` продолжает
    /// отдавать прежний путь (он взят при запуске и больше не меняется), а ядро отдаёт
    /// новый. Поэтому «найти себя заново» без этого вопроса не работает.
    nonisolated static func liveExecutablePath() -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Что из пути исполняемого файла считать корнем программы и что — её папкой.
    ///
    /// У собранной программы это `…/Totum Commander.app/Contents/MacOS/исполняемый`, и корень
    /// — три уровня вверх. У отладочного запуска корня `.app` нет вовсе, и остаётся папка,
    /// в которой лежит исполняемый файл.
    nonisolated static func liveRoots(executablePath: String) -> (app: URL?, directory: URL) {
        let executable = URL(fileURLWithPath: executablePath)
        let directory = executable.deletingLastPathComponent()
        let candidate = directory.deletingLastPathComponent().deletingLastPathComponent()
        return (candidate.pathExtension == "app" ? candidate : nil, directory)
    }

    /// Поиск набора с нуля.
    private static func locate() -> Bundle {
        let main = Bundle.main
        let code = Bundle(for: BundleAnchor.self)
        var urls: [URL] = []
        // Сначала то, где программа лежит сейчас: после переноса только этот путь и верен.
        if let live = liveExecutablePath() {
            let roots = liveRoots(executablePath: live)
            let leaf = bundleName + ".bundle"
            if let app = roots.app {
                urls.append(app.appendingPathComponent("Contents/Resources/" + leaf))
                urls.append(app.appendingPathComponent(leaf))
            }
            urls.append(roots.directory.appendingPathComponent(leaf))
        }
        urls += candidates(mainBundleURL: main.bundleURL, resourceURL: main.resourceURL,
                           codeBundleURL: code.bundleURL)
        if let found = firstBundle(among: urls) { return found }
        // Молчать здесь нельзя: человек увидит ключи вместо слов и пустую справку, а причина
        // не будет написана нигде. В журнале она будет.
        NSLog("FCXL: набор ресурсов не найден — искали в: %@",
              urls.map(\.path).joined(separator: ", "))
        return main
    }

    /// Нашёлся ли настоящий набор ресурсов, а не запасной `.app`.
    static var found: Bool { bundle.bundleURL.lastPathComponent == bundleName + ".bundle" }

    /// Проверка для сборочного скрипта: видит ли собранная программа свои ресурсы ВНУТРИ себя.
    ///
    /// Зовётся с ключом `--fcxl-resource-check` и печатает, что нашла. Раньше это узнавалось
    /// только на чужом Mac и узнавалось падением; теперь узнаёт скрипт выкладки, до DMG.
    static func selfCheck() -> Bool {
        // Не четыре файла, а по одному от каждой части, которая без своего ресурса
        // молча перестаёт работать: слова, оформление, справка, редактор, курсор, облака.
        let names = ["ru.lproj/Localizable.strings", "en.lproj/Localizable.strings",
                     "DefaultStyle.plist", "help.ru.md", "help.en.md",
                     "monaco-editor.html", "monaco/loader.min.js",
                     "DefaultCursorMask.png", "cloud-box.png"]
        print("набор ресурсов: \(bundle.bundleURL.path)")
        guard found else {
            print("НЕ НАЙДЕН: ресурсов нет ни в Contents/Resources, ни рядом с программой")
            return false
        }
        var ok = true
        for name in names {
            let url = bundle.bundleURL.appendingPathComponent(name)
            let exists = FileManager.default.fileExists(atPath: url.path)
            print("  \(exists ? "есть" : "НЕТ ") \(name)")
            if !exists { ok = false }
        }
        return ok
    }

    /// Пустой класс, по которому находится набор с нашим кодом.
    private final class BundleAnchor {}
}
