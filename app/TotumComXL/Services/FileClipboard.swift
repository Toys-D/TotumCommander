import AppKit

/// Tracks what is on the clipboard and whether it was CUT (move on paste) or copied.
///
/// Two kinds of source:
///
/// - LOCAL files go on `NSPasteboard.general` as real file URLs, so Cmd+V works in Finder
///   too. macOS has no system-level "cut" for files, so the move intent is kept here, tied to
///   the pasteboard's `changeCount`: the moment anything else is copied (by this app or any
///   other), the count moves on and the mark is silently void. A stale mark can never turn an
///   unrelated paste into a move. Consequence: cut→paste moves only INSIDE this app; pasting
///   into Finder copies, because there is no way to tell Finder to remove the source.
///
/// - REMOTE files (FTP/SFTP/WebDAV) can't be file URLs — the path lives on a server, and a
///   `file://` URL of it would point at an unrelated LOCAL file of the same name. So a remote
///   copy stores the real payload here (which server, which items, where they came from) and
///   writes only a PRIVATE pasteboard type plus a readable, non-file description string. Paste
///   feeds the payload into the same transfer queue F5/F6 uses. SMB is NOT remote here: macOS
///   mounts it, so its paths are ordinary local paths handled by the local branch above.
///
/// Every writer clears the whole clipboard state and records the pasteboard's `changeCount`,
/// so the remote payload is only honoured while it is still the current clipboard contents —
/// copy a remote file, copy something else in Finder, come back, Cmd+V, and the stale remote
/// payload is correctly ignored.
@MainActor
enum FileClipboard {

    // MARK: - Remote payload

    struct RemotePayload {
        let connectionID: UUID
        let label: String
        /// The items as listed on the server (paths are server paths, not local).
        let items: [FileItem]
        /// The remote directory they were copied from.
        let sourceDir: String
        let isCut: Bool
        /// Pasteboard changeCount at write time — the payload is void once this no longer matches.
        let changeCount: Int
    }

    private static var remoteStore: RemotePayload?
    private static let remoteType = NSPasteboard.PasteboardType("com.fcxl.remoteClipboard")

    // MARK: - Local state

    private static var cutChangeCount: Int?
    private static var cutPaths: Set<String> = []

    // MARK: - Local writers (unchanged behaviour: real file URLs, Finder interop)

    /// Put local files on the pasteboard as a plain copy.
    static func copy(_ paths: [String]) {
        writeLocalToPasteboard(paths)
        cutChangeCount = nil
        cutPaths = []
        remoteStore = nil
        notifyChanged()
    }

    /// Put local files on the pasteboard marked to be MOVED when pasted.
    static func cut(_ paths: [String]) {
        writeLocalToPasteboard(paths)
        cutChangeCount = NSPasteboard.general.changeCount
        cutPaths = Set(paths)
        remoteStore = nil
        notifyChanged()
    }

    // MARK: - Remote writers

    static func copyRemote(items: [FileItem], connectionID: UUID, label: String, sourceDir: String) {
        writeRemoteMarker(items: items, label: label, sourceDir: sourceDir)
        storeRemote(items: items, connectionID: connectionID, label: label,
                    sourceDir: sourceDir, isCut: false)
    }

    static func cutRemote(items: [FileItem], connectionID: UUID, label: String, sourceDir: String) {
        writeRemoteMarker(items: items, label: label, sourceDir: sourceDir)
        storeRemote(items: items, connectionID: connectionID, label: label,
                    sourceDir: sourceDir, isCut: true)
    }

    private static func storeRemote(items: [FileItem], connectionID: UUID, label: String,
                                    sourceDir: String, isCut: Bool) {
        // Local marks are cleared: the remote payload IS the clipboard now.
        cutChangeCount = nil
        cutPaths = []
        remoteStore = RemotePayload(
            connectionID: connectionID, label: label, items: items, sourceDir: sourceDir,
            isCut: isCut, changeCount: NSPasteboard.general.changeCount)
        notifyChanged()
    }

    // MARK: - Readers

    /// The remote payload IF it is still the current clipboard contents (nil otherwise).
    static var remotePayload: RemotePayload? {
        guard let p = remoteStore, p.changeCount == NSPasteboard.general.changeCount else { return nil }
        return p
    }

    /// True when the pasteboard's current contents are the LOCAL files we marked as cut.
    static var isCutPending: Bool {
        cutChangeCount != nil && cutChangeCount == NSPasteboard.general.changeCount
    }

    /// Paths currently marked as cut (local only). Empty as soon as the pasteboard moves on.
    static var pendingCutPaths: Set<String> {
        isCutPending ? cutPaths : []
    }

    /// True when this exact local file is waiting to be moved, so the list can dim it.
    static func isCut(_ path: String) -> Bool {
        isCutPending && cutPaths.contains(path)
    }

    /// Posted whenever the clipboard state appears or clears, so open panels can repaint.
    static let didChangeNotification = Notification.Name("fcxl.fileClipboardDidChange")

    // MARK: - Invalidation

    /// Drop the mark when a cut LOCAL file is acted on some other way — renamed, deleted, moved
    /// by F6 or drag. The remembered path no longer holds that file, so a pending paste would
    /// aim at something that isn't there.
    static func invalidate(paths: [String]) {
        guard isCutPending, paths.contains(where: { cutPaths.contains($0) }) else { return }
        clearCutMark()
    }

    /// Clear every kind of pending state — after a move completes, at app close, on Esc.
    static func clearCutMark() {
        cutChangeCount = nil
        cutPaths = []
        remoteStore = nil
        notifyChanged()
    }

    // MARK: - Pasteboard writing

    private static func notifyChanged() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private static func writeLocalToPasteboard(_ paths: [String]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
    }

    /// Writes ONLY a private marker type plus a readable, non-file string — never a file URL.
    /// The private type is enough for us; the string lets Cmd+V into a text field show
    /// something sensible ("label:/path") instead of nothing, without ever looking like a
    /// local file to Finder or to our own local paste path.
    private static func writeRemoteMarker(items: [FileItem], label: String, sourceDir: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let pbItem = NSPasteboardItem()
        pbItem.setString("\(label):\(sourceDir)", forType: remoteType)
        let readable = items.map { "\(label):\($0.path)" }.joined(separator: "\n")
        pbItem.setString(readable, forType: .string)
        pb.writeObjects([pbItem])
    }
}
