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
        // 2. Рядом с .app и рядом с исполняемым файлом отладочной сборки — сюда смотрит
        //    сгенерированный SwiftPM поиск, и здесь набор лежит при запуске из-под сборки.
        list.append(mainBundleURL.appendingPathComponent(leaf))
        // 3. Рядом с набором, в котором лежит наш код: так набор находится в тестах.
        if let codeBundleURL {
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

    /// Первый существующий набор из перечисленных.
    nonisolated static func firstBundle(among urls: [URL]) -> Bundle? {
        for url in urls {
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
        return firstBundle(among: urls) ?? main
    }()

    /// Нашёлся ли настоящий набор ресурсов, а не запасной `.app`.
    static var found: Bool { bundle.bundleURL.lastPathComponent == bundleName + ".bundle" }

    /// Проверка для сборочного скрипта: видит ли собранная программа свои ресурсы ВНУТРИ себя.
    ///
    /// Зовётся с ключом `--fcxl-resource-check` и печатает, что нашла. Раньше это узнавалось
    /// только на чужом Mac и узнавалось падением; теперь узнаёт скрипт выкладки, до DMG.
    static func selfCheck() -> Bool {
        let names = ["ru.lproj/Localizable.strings", "en.lproj/Localizable.strings",
                     "DefaultStyle.plist", "help.ru.md"]
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
