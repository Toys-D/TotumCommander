import AppKit
import Foundation

/// Облака, которые умеет показывать полоса томов: iCloud Drive (системный) и облака,
/// подключаемые их родными программами через File Provider (Google Drive for desktop,
/// OneDrive, Dropbox). Подключённое стоит в полосе, остальное — в меню сети, откуда его
/// можно подключить или вернуть после извлечения.
enum CloudProvider: String, CaseIterable, Identifiable {
    case icloud, googleDrive, oneDrive, dropbox, box, pCloud, yandexDisk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icloud:      return "iCloud Drive"
        case .googleDrive: return "Google Drive"
        case .oneDrive:    return "OneDrive"
        case .dropbox:     return "Dropbox"
        case .box:         return "Box"
        case .pCloud:      return "pCloud"
        case .yandexDisk:  return "Яндекс Диск"
        }
    }

    var icon: String { self == .icloud ? "icloud" : "cloud" }

    /// Фирменный логотип из ресурсов (те же, что у плиток менеджера подключений); у iCloud
    /// системный значок.
    var logo: NSImage? {
        let name: String
        switch self {
        case .icloud:      return nil
        case .googleDrive: name = "cloud-drive"
        case .oneDrive:    name = "cloud-onedrive"
        case .dropbox:     name = "cloud-dropbox"
        case .box:         name = "cloud-box"
        case .pCloud:      name = "cloud-pcloud"
        case .yandexDisk:  name = "cloud-yandex"
        }
        return CloudLogos.image(named: name)
    }

    /// Начала имён папки в ~/Library/CloudStorage: «GoogleDrive-почта», «OneDrive-Personal»,
    /// «Box-Box». У pCloud и Яндекса имена точно не известны — перечислены вероятные.
    var folderPrefixes: [String] {
        switch self {
        case .icloud:      return []
        case .googleDrive: return ["GoogleDrive"]
        case .oneDrive:    return ["OneDrive"]
        case .dropbox:     return ["Dropbox"]
        case .box:         return ["Box"]
        case .pCloud:      return ["pCloud"]
        case .yandexDisk:  return ["Yandex", "YandexDisk", "Яндекс"]
        }
    }

    /// Где ещё может лежать диск поставщика, если он подключает его не через CloudStorage.
    /// pCloud Drive монтирует свой том (pCloudFS) в /Volumes — такой том полоса показывает
    /// как обычный диск, а здесь он нужен, чтобы pCloud считался подключённым и не звал
    /// «войти» из меню. Яндекс Диск кладёт папку в домашнюю («~» — домашняя папка).
    var extraPaths: [String] {
        switch self {
        case .pCloud:     return ["/Volumes/pCloud Drive", "~/pCloud Drive", "~/pCloudDrive"]
        case .yandexDisk: return ["~/Yandex.Disk.localized", "~/Yandex.Disk", "~/Яндекс.Диск"]
        default:          return []
        }
    }

    /// Возможные имена программы поставщика в /Applications.
    var appNames: [String] {
        switch self {
        case .icloud:      return []
        case .googleDrive: return ["Google Drive"]
        case .oneDrive:    return ["OneDrive"]
        case .dropbox:     return ["Dropbox"]
        case .box:         return ["Box"]
        case .pCloud:      return ["pCloud Drive"]
        case .yandexDisk:  return ["Yandex Disk", "Яндекс Диск", "Yandex.Disk"]
        }
    }

    /// Прямой адрес установщика у поставщика (проверены 2026-09-25), если он есть.
    var installerURL: URL? {
        switch self {
        case .googleDrive: return URL(string: "https://dl.google.com/drive-file-stream/GoogleDrive.dmg")
        case .oneDrive:    return URL(string: "https://go.microsoft.com/fwlink/?linkid=823060")
        case .dropbox:     return URL(string: "https://www.dropbox.com/download?full=1&plat=mac")
        case .box:         return URL(string: "https://e3.boxcdn.net/desktop/releases/mac/BoxDrive.pkg")
        default:           return nil
        }
    }

    /// Как назвать скачанный установщик в «Загрузках».
    var installerFileName: String {
        switch self {
        case .googleDrive: return "GoogleDrive.dmg"
        case .oneDrive:    return "OneDrive.pkg"
        case .dropbox:     return "DropboxInstaller.dmg"
        case .box:         return "BoxDrive.pkg"
        default:           return "\(title).dmg"
        }
    }

    /// Чьё имя должно стоять в подписи разработчика на установщике.
    var signer: String {
        switch self {
        case .icloud:      return "Apple"
        case .googleDrive: return "Google"
        case .oneDrive:    return "Microsoft"
        case .dropbox:     return "Dropbox"
        case .box:         return "Box"
        case .pCloud:      return "pCloud"
        case .yandexDisk:  return "Yandex"
        }
    }

    /// Страница загрузки — когда прямого адреса нет.
    var downloadPage: URL? {
        switch self {
        case .icloud:      return nil
        case .googleDrive: return URL(string: "https://www.google.com/drive/download/")
        case .oneDrive:    return URL(string: "https://www.microsoft.com/microsoft-365/onedrive/download")
        case .dropbox:     return URL(string: "https://www.dropbox.com/install")
        case .box:         return URL(string: "https://www.box.com/resources/downloads")
        case .pCloud:      return URL(string: "https://www.pcloud.com/how-to-install-pcloud-drive-mac-os.html?download=mac")
        case .yandexDisk:  return URL(string: "https://360.yandex.com/disk/download/")
        }
    }

    /// Какому облаку принадлежит папка из CloudStorage. У Apple в имени неразрывный пробел
    /// («iCloud\u{00A0}Drive-…»), потому iCloud узнаётся по началу без учёта регистра.
    static func match(folder name: String) -> CloudProvider? {
        if name.lowercased().hasPrefix("icloud") { return .icloud }
        return allCases.first { p in
            p.folderPrefixes.contains { name == $0 || name.hasPrefix($0 + "-") || name.hasPrefix($0 + " ") }
        }
    }

    var isInstalled: Bool {
        if appNames.isEmpty { return true }
        return appNames.contains { FileManager.default.fileExists(atPath: "/Applications/\($0).app") }
    }

    /// Где диск поставщика сейчас: папка в CloudStorage или один из запасных путей.
    func connectedPath(cloudStorage: [CloudStorageVolumes.Volume],
                       home: String = NSHomeDirectory(),
                       exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        if let folder = cloudStorage.first(where: { $0.provider == self }) { return folder.path }
        return extraPaths.map { $0.replacingOccurrences(of: "~", with: home) }.first(where: exists)
    }
}

/// Где облаку место: в полосе или в меню сети, и почему.
enum CloudPlacement: Equatable {
    /// В полосе, открывается по этому пути.
    case bar(path: String)
    /// В меню: подключено, но убрано человеком; вернётся по щелчку.
    case menuHidden(path: String)
    /// В меню: программа стоит, но входа нет — по щелчку запускается программа.
    case menuSignIn
    /// В меню: программы нет — по щелчку предлагается её взять.
    case menuInstall
    /// В меню: iCloud Drive выключен — по щелчку открываются Системные настройки.
    case menuSystemSettings

    var isInBar: Bool { if case .bar = self { return true } else { return false } }
}

enum CloudPlaces {
    static let hiddenKey = "fcxl.clouds.hidden"

    static var hidden: Set<CloudProvider> {
        get {
            Set((UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
                .compactMap(CloudProvider.init(rawValue:)))
        }
        set { UserDefaults.standard.set(newValue.map(\.rawValue).sorted(), forKey: hiddenKey) }
    }

    static func hide(_ provider: CloudProvider) { hidden.insert(provider) }
    static func show(_ provider: CloudProvider) { hidden.remove(provider) }

    /// Чистое решение: куда класть облако при таких обстоятельствах.
    static func placement(of provider: CloudProvider, connectedAt path: String?,
                          installed: Bool, hidden: Bool) -> CloudPlacement {
        if let path {
            return hidden ? .menuHidden(path: path) : .bar(path: path)
        }
        if provider == .icloud { return .menuSystemSettings }
        return installed ? .menuSignIn : .menuInstall
    }

    /// Куда класть каждое облако сейчас: iCloud — по его доступности, остальные — по папкам
    /// в CloudStorage и по наличию программы.
    static func placements(icloudAvailable: Bool,
                           cloudStorage: [CloudStorageVolumes.Volume] = CloudStorageVolumes.volumes(),
                           hidden: Set<CloudProvider> = hidden,
                           installed: (CloudProvider) -> Bool = { $0.isInstalled }
    ) -> [(provider: CloudProvider, placement: CloudPlacement)] {
        CloudProvider.allCases.map { provider in
            let path: String?
            if provider == .icloud {
                path = icloudAvailable ? CloudStatusService.cloudDriveRoot : nil
            } else {
                path = provider.connectedPath(cloudStorage: cloudStorage)
            }
            return (provider, placement(of: provider, connectedAt: path,
                                        installed: installed(provider), hidden: hidden.contains(provider)))
        }
    }

    /// Щелчок по облаку в меню: вернуть в полосу, запустить программу для входа, предложить
    /// взять программу или открыть Системные настройки для iCloud.
    @MainActor
    static func activate(_ provider: CloudProvider, placement: CloudPlacement) {
        show(provider)
        switch placement {
        case .bar, .menuHidden:
            break
        case .menuSignIn:
            if let appName = provider.appNames.first(where: {
                FileManager.default.fileExists(atPath: "/Applications/\($0).app") }) {
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: "/Applications/\(appName).app"),
                    configuration: NSWorkspace.OpenConfiguration())
            }
        case .menuInstall:
            if provider.installerURL != nil {
                Task { await CloudInstallerDownload.fetch(provider) }
            } else if let page = provider.downloadPage {
                NSWorkspace.shared.open(page)
            }
        case .menuSystemSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?iCloud") {
                NSWorkspace.shared.open(url)
            }
        }
        NotificationCenter.default.post(name: .volumeBarNeedsRefresh, object: nil)
    }
}

/// Следит за ~/Library/CloudStorage: папка поставщика появляется после входа в его программу
/// и исчезает после выхода — полоса должна узнать об этом сама, без перезапуска.
final class CloudStorageWatcher {
    static let shared = CloudStorageWatcher()
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1

    func start(path: String = CloudStorageVolumes.root) {
        guard source == nil else { return }
        descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                            eventMask: [.write, .rename, .delete],
                                                            queue: .main)
        src.setEventHandler {
            NotificationCenter.default.post(name: .volumeBarNeedsRefresh, object: nil)
        }
        src.setCancelHandler { [descriptor] in close(descriptor) }
        src.resume()
        source = src
    }
}
