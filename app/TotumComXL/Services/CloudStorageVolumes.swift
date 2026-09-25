import Foundation

/// Облачные диски, подключённые их родными программами через File Provider macOS:
/// «Google Drive for desktop», OneDrive, Dropbox. Все они живут в `~/Library/CloudStorage/`,
/// и ходить по ним можно как по обычным папкам — без rclone и без квот Google.
/// iCloud здесь пропускается: у него своя кнопка через «Mobile Documents».
enum CloudStorageVolumes {
    struct Volume: Equatable {
        let label: String
        let path: String
    }

    static let root = NSHomeDirectory() + "/Library/CloudStorage"

    /// Папки поставщиков, как они лежат на диске. Читается при каждой отрисовке полосы:
    /// один список каталога, дёшево.
    static func volumes(in root: String = root) -> [Volume] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        return names.sorted().compactMap { name in
            var isDir: ObjCBool = false
            guard !name.hasPrefix("."), fm.fileExists(atPath: root + "/" + name, isDirectory: &isDir),
                  isDir.boolValue, let label = label(forFolder: name) else { return nil }
            return Volume(label: label, path: root + "/" + name)
        }
    }

    /// Имя кнопки по имени папки: «GoogleDrive-почта» → «Google Drive», «OneDrive-Personal»
    /// → «OneDrive». Папки iCloud — nil: они не сюда.
    static func label(forFolder name: String) -> String? {
        // У Apple в имени папки неразрывный пробел («iCloud\u{00A0}Drive-…»), потому не по
        // строке «iCloud Drive», а по началу без учёта регистра и пробелов.
        if name.lowercased().hasPrefix("icloud") { return nil }
        let known: [(prefix: String, label: String)] = [
            ("GoogleDrive", "Google Drive"), ("OneDrive", "OneDrive"),
            ("Dropbox", "Dropbox"), ("Box", "Box"), ("pCloud", "pCloud"),
        ]
        for entry in known where name == entry.prefix || name.hasPrefix(entry.prefix + "-") {
            return entry.label
        }
        return name.split(separator: "-").first.map(String.init) ?? name
    }

    /// Корень облачного диска: выше него лежит служебная папка CloudStorage, куда «..»
    /// вести не должно, как и из корня iCloud Drive.
    static func isRoot(_ path: String, root: String = root) -> Bool {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        let base = URL(fileURLWithPath: root).standardizedFileURL.path
        return (std as NSString).deletingLastPathComponent == base && std != base
    }
}
