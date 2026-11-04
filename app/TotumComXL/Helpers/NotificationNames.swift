import Foundation

extension Notification.Name {
    static let fcxlOperationCompleted = Notification.Name("fcxlOperationCompleted")
    static let fcxlRequestEditorClose = Notification.Name("fcxlRequestEditorClose")
    /// Вид панели инструментов сменился — окна пересобирают её.
    static let fcxlToolbarLookChanged = Notification.Name("fcxlToolbarLookChanged")
}
