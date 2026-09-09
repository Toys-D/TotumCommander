import AppKit
import UniformTypeIdentifiers

/// Which application macOS opens a KIND of file with — the binding Finder changes from its
/// "Change All…" button.
///
/// This is deliberately a system setting, not one of ours: the point of remembering "open .psd
/// in Affinity" is that it holds everywhere — in Finder, in the Dock, in another file manager —
/// and a preference kept privately by this program would be a different, quieter promise.
enum DefaultApplication {

    /// The type a file belongs to, taken from its extension.
    ///
    /// The extension rather than the file's own metadata on purpose: the binding being set is
    /// for every file of this kind, and that is exactly what the extension names. A file with
    /// no extension has no kind to bind, and answers nil.
    nonisolated static func contentType(ofFileAt path: String) -> UTType? {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        // A type macOS invented on the spot for an unknown extension ("dyn.ah62d4…") can be
        // bound, and binding it is what makes the unknown kind open the way the user wants.
        return type
    }

    /// The extension as the menu should say it — ".png", or nil when there is nothing to bind.
    nonisolated static func kindLabel(forFileAt path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ".\(ext)"
    }

    /// The app that currently opens this kind.
    static func current(forFileAt path: String) -> URL? {
        guard let type = contentType(ofFileAt: path) else {
            return NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path))
        }
        return NSWorkspace.shared.urlForApplication(toOpen: type)
    }

    /// Bind this kind to this application, for the whole system.
    ///
    /// The answer arrives asynchronously — macOS asks LaunchServices, and on a fresh binding it
    /// may put its own confirmation in front of the user. Failure is reported rather than
    /// swallowed: a silent no-op here would look exactly like success until the next launch.
    static func makeDefault(appURL: URL, forFileAt path: String,
                            completion: @escaping (Error?) -> Void) {
        guard let type = contentType(ofFileAt: path) else {
            completion(NSError(
                domain: "DefaultApplication", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L("openWith.always.noType")]))
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }
}
