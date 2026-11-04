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

    /// Папки поставщиков, как они лежат на диске. Полоса зовёт это при каждой перерисовке,
    /// и не раз (по кнопке на диск), потому ответ помнится секунду — измерено в пробе
    /// стеков: чтение каталога шло из отрисовки.
    private static var memo: (root: String, at: Date, volumes: [Volume])?
    private static let memoLock = NSLock()

    static func volumes(in root: String = root, now: Date = Date()) -> [Volume] {
        memoLock.lock()
        if let memo, memo.root == root, now.timeIntervalSince(memo.at) < 1 {
            memoLock.unlock()
            return memo.volumes
        }
        memoLock.unlock()
        let scanned = scan(root)
        memoLock.lock(); memo = (root, now, scanned); memoLock.unlock()
        return scanned
    }

    private static func scan(_ root: String) -> [Volume] {
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
