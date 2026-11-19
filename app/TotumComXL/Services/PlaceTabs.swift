import Foundation

/// Подключаемое место — то, что появляется рядом со своим диском: его монтируют, в него
/// входят по сети, оно приходит из облака. У каждого вида своя строка в настройках вкладок.
///
/// Системный диск и домашняя папка сюда не входят: их не подключают, они есть всегда.
/// Серверы (FTP, SFTP, облака через подключения) тоже: их сеанс живёт в своей вкладке.
enum MountedPlace: String, CaseIterable {
    /// Общая папка другого компьютера (SMB и прочие сетевые тома).
    case networkShare
    /// Обзор сети: список компьютеров и их общих папок.
    case networkBrowser
    /// Внешний диск: флешка, карта памяти, диск по USB или Thunderbolt.
    case externalDisk
    /// Смонтированный образ диска и зашифрованное хранилище.
    case diskImage
    /// Облако, подключённое своей программой: iCloud Drive, Google Drive, OneDrive…
    case cloud

    var defaultsKey: String { "fcxl.placeTab." + rawValue }

    /// Как было до появления настройки: сетевая папка — в своей вкладке, остальное — на месте.
    var fallback: PlaceTabMode { self == .networkShare ? .newTab : .currentTab }
}

/// Где показать подключаемое место.
enum PlaceTabMode: String, CaseIterable {
    /// В своей вкладке, одной на место: папка, из которой пришли, остаётся на своей.
    case newTab
    /// Во вкладке, где стоит человек, — как переход в любую другую папку.
    case currentTab

    var titleKey: String { "settings.placeTab.mode." + rawValue }
}

enum PlaceTabs {
    /// «Из закреплённой вкладки — всегда в своей». Закреплённая место показать может, но своей
    /// папки не забывает: уйдёшь с неё и вернёшься — она снова на своей папке, а диск придётся
    /// открывать заново.
    static let fromPinnedKey = "fcxl.placeTab.fromPinnedNew"

    /// Само решение — без обращения к настройкам, для проверок.
    nonisolated static func mode(for place: MountedPlace, savedRawValue: String?) -> PlaceTabMode {
        savedRawValue.flatMap(PlaceTabMode.init(rawValue:)) ?? place.fallback
    }

    static func mode(for place: MountedPlace, defaults: UserDefaults = .standard) -> PlaceTabMode {
        mode(for: place, savedRawValue: defaults.string(forKey: place.defaultsKey))
    }

    nonisolated static func opensNewTab(mode: PlaceTabMode, tabPinned: Bool, fromPinnedNew: Bool) -> Bool {
        mode == .newTab || (tabPinned && fromPinnedNew)
    }

    /// Заводить ли месту свою вкладку, когда его открывают из этой.
    static func opensNewTab(_ place: MountedPlace, from tab: PanelTab,
                            defaults: UserDefaults = .standard) -> Bool {
        opensNewTab(mode: mode(for: place, defaults: defaults), tabPinned: tab.pinned,
                    fromPinnedNew: defaults.bool(forKey: fromPinnedKey))
    }

    /// Диск на полосе томов бывает и смонтированным образом — у образов своя строка настроек.
    nonisolated static func refined(_ place: MountedPlace,
                                    busType: VolumeInterfaceInfo.BusType) -> MountedPlace {
        place == .externalDisk && busType == .diskImage ? .diskImage : place
    }
}
