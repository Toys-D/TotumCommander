import AppKit
import SwiftUI

/// Что показать в панели обзора сети вместо пустоты.
///
/// Обход занимает несколько секунд, и всё это время панель выглядела так же, как если бы в
/// сети никого не было: пусто и молча. Человек не мог отличить «ищем» от «не нашли».
enum NetworkBrowseStatus: Equatable {
    /// Идём по сети — надо сказать об этом.
    case searching
    /// Обход кончился, никто не отозвался.
    case nobody
    /// Есть кого показать: список сам за себя говорит, полоса не нужна.
    case hosts

    nonisolated static func of(scanning: Bool, hostCount: Int) -> NetworkBrowseStatus {
        if hostCount > 0 { return .hosts }
        return scanning ? .searching : .nobody
    }
}

/// Полоса поверх пустого списка: «ищем» со вращающимся кружком или «никого не нашли»
/// с объяснением, что делать.
struct NetworkBrowseBanner: View {
    let status: NetworkBrowseStatus
    var onOpenSettings: () -> Void = {}

    var body: some View {
        VStack(spacing: 10) {
            switch status {
            case .searching:
                ProgressView()
                    .controlSize(.small)
                Text(L("network.browse.searching"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            case .nobody:
                Image(systemName: "network.slash")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text(L("network.browse.nobody"))
                    .font(.system(size: 13, weight: .medium))
                Text(L("network.browse.nobodyHint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
                Button(L("network.browse.openSettings"), action: onOpenSettings)
                    .buttonStyle(FCXLToolbarButtonStyle())
            case .hosts:
                EmptyView()
            }
        }
        .padding(20)
    }
}
