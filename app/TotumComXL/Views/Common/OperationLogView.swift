import SwiftUI

struct OperationLogView: View {
    @ObservedObject var logService: OperationLogService

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("operationLog.title"))
                    .font(.headline)
                Spacer()
                if !logService.entries.isEmpty {
                    Button(L("operationLog.clear")) {
                        logService.clear()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if logService.entries.isEmpty {
                VStack {
                    Spacer()
                    Text(L("operationLog.empty"))
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Spacer()
                }
            } else {
                List(logService.entries) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(entry.success ? .green : .red)
                            .font(.caption)

                        Text(entry.formattedTimestamp)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)

                        Text(entry.summary)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let duration = entry.duration {
                            Spacer()
                            Text(Self.formatDuration(duration))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 300, minHeight: 100)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return String(format: "%.0fms", seconds * 1000)
        } else if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            let m = Int(seconds) / 60
            let s = Int(seconds) % 60
            return "\(m)m \(s)s"
        }
    }
}
