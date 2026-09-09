import Combine
import Foundation

@MainActor
final class OperationQueueViewModel: ObservableObject {
    @Published private(set) var operations: [QueuedOperation] = []
    @Published var isPanelVisible = false

    private let queueService: OperationQueueService
    private var cancellable: AnyCancellable?

    init(queueService: OperationQueueService) {
        self.queueService = queueService
        cancellable = queueService.$operations
            .receive(on: RunLoop.main)
            .assign(to: \.operations, on: self)
    }

    var activeCount: Int {
        operations.filter(\.isActive).count
    }

    var hasActiveOperations: Bool {
        operations.contains(where: \.isActive)
    }

    /// True while something is actually transferring (as opposed to queued or paused).
    /// Read live from the service; the view re-renders whenever `operations` changes.
    var isProcessing: Bool { queueService.isProcessing }

    var overallProgress: Double {
        let active = operations.filter { $0.status == .running || $0.status == .paused }
        guard !active.isEmpty else { return 0 }
        let total = active.reduce(0.0) { $0 + $1.progress }
        return total / Double(active.count)
    }

    func pause(_ id: UUID) {
        queueService.pause(id)
    }

    func resume(_ id: UUID) {
        queueService.resume(id)
    }

    func cancel(_ id: UUID) {
        queueService.cancel(id)
    }

    func clearCompleted() {
        queueService.removeCompleted()
    }

    func removeOperation(_ id: UUID) {
        queueService.removeOperation(id)
    }

    /// Pick a broken transfer up from where it stopped — the `.part` twin holds what already
    /// arrived, so nothing that was paid for over the wire is paid for twice.
    func continueTransfer(_ id: UUID) {
        queueService.continueTransfer(id)
    }

    func showPanel() {
        isPanelVisible = true
    }

    func hidePanel() {
        isPanelVisible = false
    }
}
