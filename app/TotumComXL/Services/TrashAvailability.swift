import Foundation

/// Есть ли у тома корзина.
///
/// У сетевой папки (SMB, AFP, NFS) её нет. На «в корзину» система там показывает собственное
/// окно — «объект будет удалён немедленно» — уже после вопроса программы: два вопроса подряд,
/// причём первый обещал корзину, а второй чужого вида. Программа узнаёт об этом заранее и
/// спрашивает один раз, честно: удаление насовсем.
enum TrashAvailability {

    /// Решение по двум признакам. Без корзины — только сетевой том, у которого система
    /// корзину не находит. Местный диск всегда идёт прежней дорогой: ошибиться здесь значило
    /// бы стереть то, что можно было вернуть.
    static func isWithoutTrash(isLocal: Bool?, trashLookupFails: Bool) -> Bool {
        isLocal == false && trashLookupFails
    }

    static func isWithoutTrash(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let isLocal = (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal
        guard isLocal == false else { return false }
        let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                  appropriateFor: url, create: false)
        return isWithoutTrash(isLocal: isLocal, trashLookupFails: trash == nil)
    }

    /// Разделить на то, что уйдёт в корзину, и то, что корзины не имеет. Том спрашивается раз
    /// на папку: файлы одной папки лежат на одном томе.
    static func split(_ items: [FileItem],
                      withoutTrash: (String) -> Bool = TrashAvailability.isWithoutTrash(path:))
        -> (toTrash: [FileItem], toErase: [FileItem]) {
        var answers: [String: Bool] = [:]
        var toTrash: [FileItem] = [], toErase: [FileItem] = []
        for item in items {
            let folder = (item.path as NSString).deletingLastPathComponent
            let none: Bool
            if let known = answers[folder] {
                none = known
            } else {
                none = withoutTrash(item.path)
                answers[folder] = none
            }
            if none { toErase.append(item) } else { toTrash.append(item) }
        }
        return (toTrash, toErase)
    }
}
