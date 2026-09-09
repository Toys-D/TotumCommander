import Foundation

/// A single logged file operation.
struct OperationLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let operationType: String
    let itemCount: Int
    let sourcePath: String
    let destinationPath: String?
    let success: Bool
    let errorMessage: String?
    let duration: TimeInterval?

    var formattedTimestamp: String {
        Self.dateFormatter.string(from: timestamp)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var summary: String {
        let srcName = URL(fileURLWithPath: sourcePath).lastPathComponent
        if let dest = destinationPath {
            let destName = URL(fileURLWithPath: dest).lastPathComponent
            if itemCount > 1 {
                return "\(operationType): \(itemCount) items -> \(destName)"
            }
            return "\(operationType): \(srcName) -> \(destName)"
        }
        if itemCount > 1 {
            return "\(operationType): \(itemCount) items"
        }
        return "\(operationType): \(srcName)"
    }
}

/// Tracks all file operations in-memory for the current session.
@MainActor
final class OperationLogService: ObservableObject {
    static let shared = OperationLogService()

    @Published private(set) var entries: [OperationLogEntry] = []

    private static let maxEntries = 500

    private init() {}

    func log(
        operationType: String,
        itemCount: Int = 1,
        sourcePath: String,
        destinationPath: String? = nil,
        success: Bool = true,
        errorMessage: String? = nil,
        duration: TimeInterval? = nil
    ) {
        let entry = OperationLogEntry(
            timestamp: Date(),
            operationType: operationType,
            itemCount: itemCount,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            success: success,
            errorMessage: errorMessage,
            duration: duration
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
