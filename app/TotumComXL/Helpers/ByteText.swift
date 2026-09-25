import Foundation

/// Размер по-человечески — в одном месте на всю программу.
///
/// `ByteCountFormatter` пишет ноль словами: «Zero KB». В русском окне это выглядит
/// опиской, и человек её видел — в полосе загрузки из облака стояло «Обработано: Zero KB
/// из 3,7 MB». В панели это когда-то обошли отдельной строкой, а в остальных двадцати
/// восьми местах — нет. Теперь обход один и общий.
enum ByteText {

    /// Обычный размер файла: килобайты по тысяче, как их считает Finder.
    static func file(_ bytes: Int64) -> String { text(bytes, style: .file) }

    /// Размер в памяти: килобайты по 1024.
    static func memory(_ bytes: Int64) -> String { text(bytes, style: .memory) }

    private static func text(_ bytes: Int64, style: ByteCountFormatter.CountStyle) -> String {
        guard bytes > 0 else { return L("size.zero") }
        let formatter = ByteCountFormatter()
        formatter.countStyle = style
        // На всякий случай и здесь: словесных «Zero»/«Пусто» в цифрах быть не должно.
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}
