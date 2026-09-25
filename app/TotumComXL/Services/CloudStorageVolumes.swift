import Foundation

/// Облачные диски, подключённые их родными программами через File Provider macOS:
/// «Google Drive for desktop», OneDrive, Dropbox. Все они живут в `~/Library/CloudStorage/`,
/// и ходить по ним можно как по обычным папкам — без rclone и без квот Google.
/// iCloud здесь пропускается: у него своя кнопка через «Mobile Documents».
enum CloudStorageVolumes {
    struct Volume: Equatable {
        let label: String
        let path: String
        /// Известное облако, если папка его; незнакомый поставщик — nil.
        var provider: CloudProvider? = nil
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
            return Volume(label: label, path: root + "/" + name, provider: CloudProvider.match(folder: name))
        }
    }

    /// Имя кнопки по имени папки: «GoogleDrive-почта» → «Google Drive», «OneDrive-Personal»
    /// → «OneDrive». Папки iCloud — nil: они не сюда.
    static func label(forFolder name: String) -> String? {
        switch CloudProvider.match(folder: name) {
        case .icloud?: return nil
        case let known?: return known.title
        case nil: return name.split(separator: "-").first.map(String.init) ?? name
        }
    }

    /// Корень облачного диска: выше него лежит служебная папка CloudStorage, куда «..»
    /// вести не должно, как и из корня iCloud Drive.
    static func isRoot(_ path: String, root: String = root) -> Bool {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        let base = URL(fileURLWithPath: root).standardizedFileURL.path
        return (std as NSString).deletingLastPathComponent == base && std != base
    }
}
