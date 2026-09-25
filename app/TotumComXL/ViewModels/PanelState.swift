import Combine
import Foundation

/// Lightweight ObservableObject that holds UI-only state for SwiftUI components
/// (breadcrumb bar, status bar, volume bar). Properties here change infrequently —
/// only on navigation, mode switches, or errors — so SwiftUI views that observe
/// PanelState won't re-render on every cursor/selection change in PanelViewModel.
@MainActor
final class PanelState: ObservableObject {

    // MARK: - Published Properties

    @Published var currentPath: String = ""
    @Published var viewMode: ViewMode = .detailed
    @Published var insideArchive: Bool = false
    @Published var insideNetworkBrowser: Bool = false
    /// Showing the macOS Trash as a folder.
    @Published var insideTrash: Bool = false
    /// Showing the shelf — files gathered from many folders, listed as one.
    @Published var insideStack: Bool = false
    @Published var archivePath: String? = nil
    @Published var isActivelyRemote: Bool = false
    @Published var remoteSession: RemoteSession? = nil
    @Published var errorMessage: String? = nil
    @Published var launchingFilePath: String? = nil
    @Published var isLoading: Bool = false
    /// True while listing a network computer's shares (smbutil view + possible auth) —
    /// drives the cursor spinner so the user knows the click is working.
    @Published var isListingNetworkShares: Bool = false

    // MARK: - Computed Properties

    /// Whether the panel is currently showing a remote file system.
    var insideRemote: Bool { isActivelyRemote }

    /// Breadcrumb path components for the current path.
    ///
    /// For remote panels the root entry uses the protocol + host as its display name.
    /// For local panels the root entry is named "/".
    /// Matches the algorithm in PanelViewModel.breadcrumbs and
    /// PanelViewModel+Remote.remoteBreadcrumbs.
    var breadcrumbs: [(name: String, path: String)] {
        if insideRemote { return remoteBreadcrumbs }
        if insideNetworkBrowser { return networkBreadcrumbs }
        if insideTrash { return [(name: L("trash.title"), path: TrashService.trashRoot)] }
        if insideStack { return [(name: L("stack.title"), path: DropStackStore.stackRoot)] }

        var components: [(name: String, path: String)] = []
        var path = currentPath as NSString
        while path.length > 1 {
            let name = path.lastPathComponent
            components.append((name: name, path: path as String))
            path = path.deletingLastPathComponent as NSString
        }
        components.append((name: "/", path: "/"))
        let ordered = Array(components.reversed())

        // Mounted SMB share: collapse the "/ ▸ Volumes ▸ <IP>" prefix into one
        // computer-name crumb → "SERVER_SO ▸ Доки", not "Volumes ▸ 192.168… ▸ Доки".
        if let net = NetworkMountInfo.info(forPath: currentPath) {
            let inside = ordered.filter { $0.path == net.mountRoot || $0.path.hasPrefix(net.mountRoot + "/") }
            return [(name: net.computer, path: net.mountRoot)] + Array(inside.dropFirst())
        }
        return ordered
    }

    private var networkBreadcrumbs: [(name: String, path: String)] {
        let root = NetworkBrowserService.networkRoot
        var components: [(name: String, path: String)] = [(name: L("network.browsing"), path: root)]

        if let computer = NetworkBrowserService.computerName(from: currentPath) {
            components.append((name: computer, path: "\(root)/\(computer)"))
        }
        if let info = NetworkBrowserService.shareInfo(from: currentPath) {
            components.append((name: info.share, path: currentPath))
        }
        return components
    }

    // MARK: - Private Helpers

    /// Breadcrumb components for a remote path. Matches
    /// PanelViewModel+Remote.remoteBreadcrumbs exactly.
    private var remoteBreadcrumbs: [(name: String, path: String)] {
        guard let session = remoteSession else { return [] }

        var components: [(name: String, path: String)] = []
        var path = currentPath

        while path != "/" && !path.isEmpty {
            let name = (path as NSString).lastPathComponent
            components.append((name: name, path: path))
            path = session.fileSystem.parentPath(for: path)
        }

        // Root entry with protocol label
        components.append((
            name: session.connection.proto.displayName + "://" + session.connection.host,
            path: "/"
        ))

        return components.reversed()
    }
}
