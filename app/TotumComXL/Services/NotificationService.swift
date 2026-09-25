import AppKit
import Foundation
import UserNotifications

/// Sends macOS notifications for completed operations when the app is not in the foreground.
final class NotificationService: @unchecked Sendable {
    static let shared = NotificationService()

    private var authorized = false

    private init() {
        requestAuthorization()
    }

    /// UNUserNotificationCenter belongs to APP BUNDLES: touched from a bare executable it does
    /// not fail, it raises NSInternalInconsistencyException and takes the process down — which
    /// is how the undo tests met it, driving a real move through the service. The xctest runner
    /// even carries a bundle identifier, so the only honest question is whether the process
    /// lives inside a .app.
    private static var processHasBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private func requestAuthorization() {
        guard Self.processHasBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }

    /// Send a notification about operation completion.
    /// Only sends if the app is NOT the active application.
    func notifyOperationCompleted(title: String, message: String) {
        guard authorized else { return }

        // Only notify when app is not active (user is in another app)
        DispatchQueue.main.async {
            guard !NSApp.isActive else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    /// Notify about a copy/move operation completion.
    func notifyCopyMoveCompleted(operationName: String, itemCount: Int, destination: String) {
        let destName = URL(fileURLWithPath: destination).lastPathComponent
        let title = L("notification.operation.completed")
        let message: String
        if itemCount == 1 {
            message = String(format: L("notification.operation.singleItem"), operationName, destName)
        } else {
            message = String(format: L("notification.operation.multipleItems"), operationName, itemCount, destName)
        }
        notifyOperationCompleted(title: title, message: message)
    }

    /// Notify about a pack/unpack operation completion.
    func notifyArchiveCompleted(operationName: String, archiveName: String) {
        let title = L("notification.operation.completed")
        let message = String(format: L("notification.archive.completed"), operationName, archiveName)
        notifyOperationCompleted(title: title, message: message)
    }
}
