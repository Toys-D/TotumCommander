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
    static let bundle: Bundle = {
        let main = Bundle.main
        let code = Bundle(for: BundleAnchor.self)
        let urls = candidates(mainBundleURL: main.bundleURL, resourceURL: main.resourceURL,
                              codeBundleURL: code.bundleURL)
        if let found = firstBundle(among: urls) { return found }
        // Молчать здесь нельзя: человек увидит ключи вместо слов и пустую справку, а причина
        // не будет написана нигде. В журнале она будет.
        NSLog("FCXL: набор ресурсов не найден — искали в: %@",
              urls.map(\.path).joined(separator: ", "))
        return main
    }()

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
