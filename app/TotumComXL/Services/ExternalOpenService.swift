import AppKit
import OSLog

/// The single place where we hand a file — or an `.app` bundle — to another
/// application. Every launch site funnels through here so the cooperative
/// activation handshake macOS 14+ requires is never forgotten again.
///
/// Why the handshake exists: `activates` on `NSWorkspace.OpenConfiguration`
/// already defaults to true, so *asking* for the foreground was never the
/// problem. But AppKit's `-activate` documentation states that the launched
/// app's own `activate()` is not honoured unless the app that is currently
/// active — us, since the user just double-clicked in our panel — yields
/// first. On a cold launch LaunchServices spawns the process frontmost and
/// papers over the omission. When the target is ALREADY RUNNING it only
/// receives an open-document event: it orders the new window front inside its
/// own layer and stays behind us, and the desync survives until the window
/// server rebuilds the Space. That is the "switch desktops and the viewer pops
/// forward" bug.
@MainActor
enum ExternalOpenService {
    /// The activation handshake keeps failing in ways reasoning has not caught — twice now the
    /// theory was wrong. So the handshake KEEPS A DIARY: every step logs, and the diary is read
    /// back with `log show` after the failing gesture instead of guessing again.
    private static let diary = Logger(subsystem: "com.fcxl.filecommander", category: "open")

    /// Open `url` with the user's default handler for that file type.
    static func open(_ url: URL, completion: ((Error?) -> Void)? = nil) {
        yieldActivation(toApplicationAt: NSWorkspace.shared.urlForApplication(toOpen: url))
        NSWorkspace.shared.open(url, configuration: openConfiguration()) { app, error in
            finish(app: app, error: error, completion: completion)
        }
    }

    /// Open `urls` with one specific application.
    static func open(_ urls: [URL],
                     withApplicationAt appURL: URL,
                     completion: ((Error?) -> Void)? = nil) {
        yieldActivation(toApplicationAt: appURL)
        NSWorkspace.shared.open(urls,
                                withApplicationAt: appURL,
                                configuration: openConfiguration()) { app, error in
            finish(app: app, error: error, completion: completion)
        }
    }

    /// Launch an `.app` bundle on its own (Finder-style double-click).
    static func openApplication(at appURL: URL, completion: ((Error?) -> Void)? = nil) {
        yieldActivation(toApplicationAt: appURL)
        NSWorkspace.shared.openApplication(at: appURL,
                                           configuration: openConfiguration()) { app, error in
            finish(app: app, error: error, completion: completion)
        }
    }

    // MARK: - Handshake

    private static func openConfiguration() -> NSWorkspace.OpenConfiguration {
        let config = NSWorkspace.OpenConfiguration()
        // Redundant against the SDK default, spelled out so nobody re-opens
        // the question of whether we asked for the foreground. We did.
        config.activates = true
        return config
    }

    /// Half one: announce that we're giving up front status to the app we are
    /// about to launch. The bundle-identifier form is the required one — the
    /// target usually isn't running yet, so no `NSRunningApplication` exists.
    /// If the handler can't be resolved we skip the yield and lean on half two.
    private static func yieldActivation(toApplicationAt appURL: URL?) {
        guard let appURL, let bundleID = Bundle(url: appURL)?.bundleIdentifier else {
            diary.info("yield-1: пропущен — обработчик не разрешился")
            return
        }
        diary.info("yield-1: уступаю \(bundleID, privacy: .public), мы активны: \(NSApp.isActive)")
        NSApplication.shared.yieldActivation(toApplicationWithBundleIdentifier: bundleID)
    }

    /// Half two: activate the instance we just launched. This is what fixes the
    /// already-running case, where nobody else brings the window forward.
    /// `nonisolated` because NSWorkspace calls its completion handler off the
    /// main thread — the hop back happens inside.
    private nonisolated static func finish(app: NSRunningApplication?,
                                           error: Error?,
                                           completion: ((Error?) -> Void)?) {
        Task { @MainActor in
            if error == nil, let app {
                diary.info("finish: цель \(app.bundleIdentifier ?? "?", privacy: .public) активна=\(app.isActive) мы активны=\(NSApp.isActive)")
                // Yield HERE as well, to the exact instance we now hold. Half one yields by
                // bundle identifier resolved BEFORE the launch — and when that resolution
                // fails (seen with files on a freshly mounted vault volume), the yield is
                // skipped, macOS 14 refuses the other app's activation, and its window stays
                // behind ours. This yield needs no resolving: the running app is in hand.
                NSApplication.shared.yieldActivation(to: app)
                diary.info("finish: yield-2 сделан")
                // DO NOT guard this with `!app.isActive`. In the warm case the
                // target is ALREADY active by now (config.activates saw to that),
                // so such a guard skips the call entirely — and with it
                // .activateAllWindows, which is the part that actually raises the
                // new document window. That produced exactly the reported bug:
                // the viewer owned the menu bar while its window stayed behind us.
                // Measured: 5/5 warm opens correct with the call unconditional.
                let took = app.activate(from: .current, options: [.activateAllWindows])
                diary.info("finish: activate вернул \(took)")
                // Who actually ended up in front — the one fact every theory so far got wrong.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let front = NSWorkspace.shared.frontmostApplication
                    diary.info("итог через 0.6с: впереди \(front?.bundleIdentifier ?? "?", privacy: .public), цель активна=\(app.isActive), мы активны=\(NSApp.isActive)")
                }
            }
            completion?(error)
        }
    }
}
