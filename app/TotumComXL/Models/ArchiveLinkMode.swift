import FCXLBridgeObjC
import Foundation

/// Что класть в новый архив на месте символической ссылки — выбор окна упаковки.
///
/// По умолчанию ссылка ложится ссылкой, как в tar и в «Сжать» Finder: папка сборки с фреймворками
/// упаковывается как есть. Но ссылка наружу — по полному пути или выше упакованного — после
/// распаковки на другом Mac ведёт в никуда, и для неё есть выбор положить то, на что она ведёт
/// (rsync --copy-unsafe-links), или так поступить со всеми ссылками (zip без -y, tar -h).
enum ArchiveLinkMode: String, CaseIterable {
    case keep
    case followOutside
    case followAll

    /// Выбор запоминается: окно упаковки, «Архивировать на месте» и очередь берут один и тот же.
    static let defaultsKey = "archive.linkMode"

    static var stored: ArchiveLinkMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .keep
    }

    var title: String {
        switch self {
        case .keep: return L("pack.links.keep")
        case .followOutside: return L("pack.links.followOutside")
        case .followAll: return L("pack.links.followAll")
        }
    }

    /// Под выбором в окне — что именно ляжет в архив.
    var note: String {
        switch self {
        case .keep: return L("pack.links.keep.note")
        case .followOutside: return L("pack.links.followOutside.note")
        case .followAll: return L("pack.links.followAll.note")
        }
    }

    /// Отправляемое должно дойти целым: у получателя ссылка наружу ведёт в никуда, так что
    /// наружные ссылки при отправке — всегда тем, на что ведут.
    var forSending: ArchiveLinkMode { self == .keep ? .followOutside : self }

    var bridgeValue: FCXLArchiveLinks {
        switch self {
        case .keep: return .keep
        case .followOutside: return .followOutside
        case .followAll: return .followAll
        }
    }
}
