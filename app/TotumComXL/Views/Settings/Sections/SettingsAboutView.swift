import AppKit
import SwiftUI

/// "About" section: what this app is, which build is running, who made it, and where the source
/// lives. Version and build come from the bundle and the APP_BUILD constant.
struct SettingsAboutView: View {
    private let repositoryURL = AppIdentity.repositoryURL
    @ObservedObject private var updates = UpdateChecker.shared

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Totum Commander"
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    appIcon
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appName).font(.system(size: 20, weight: .semibold))
                        Text("\(L("about.version")) \(version) (\(L("about.build")) \(APP_BUILD))")
                            .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent(L("about.developer")) {
                    Text(AppIdentity.developer).textSelection(.enabled)
                }
                LabeledContent(L("about.company")) {
                    Text(AppIdentity.company).textSelection(.enabled)
                }
                LabeledContent(L("about.license")) {
                    Link(AppIdentity.license, destination: AppIdentity.licenseURL)
                        .pointerStyle(.link)
                }
                LabeledContent(L("about.repository")) {
                    Link(destination: repositoryURL) {
                        HStack(spacing: 6) {
                            GitHubMark().frame(width: 15, height: 15)
                            Text(AppIdentity.repositorySlug)
                        }
                    }
                    .pointerStyle(.link)
                }
                // Куда писать. Рядом с репозиторием: там ищут исходники, здесь — живого автора.
                LabeledContent(L("about.contact")) {
                    Link(AppIdentity.email, destination: AppIdentity.contactURL)
                        .pointerStyle(.link)
                }
                // Releases, not branches: a person who opened About wants a newer build, not
                // the development tree.
                LabeledContent(L("about.releases")) {
                    Link(L("about.releases.open"), destination: AppIdentity.releasesURL)
                        .pointerStyle(.link)
                }
                LabeledContent(L("about.updates")) {
                    if let release = updates.available {
                        Link(String(format: L("about.updates.available"), release.version),
                             destination: release.url)
                            .pointerStyle(.link)
                    } else {
                        HStack(spacing: 10) {
                            Text(updates.lastChecked == nil ? L("about.updates.never") : L("about.updates.upToDate"))
                                .foregroundStyle(.secondary)
                            Button(L("about.updates.checkNow")) { Task { await updates.checkNow() } }
                                .buttonStyle(FCXLChipButtonStyle(compact: true))
                        }
                    }
                }
            }

            // Last, after the facts: the ask. One person, free and open, one button — and the
            // line that nothing in the program depends on it, so nobody suspects a crippled
            // edition. Never at launch, never on a timer: that is what kills trust.
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("about.support.title")).font(.system(size: 13, weight: .semibold))
                    Text(L("about.support.body"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { NSWorkspace.shared.open(AppIdentity.supportURL) } label: {
                        Text(L("about.support.button")).frame(minWidth: 200)
                    }
                    .buttonStyle(FCXLDialogPrimaryButtonStyle(
                        accent: accent,
                        textColor: PanelAppearanceSettings.contrastingTextColor(on: accent),
                        fontSize: 13, height: 32, cornerRadius: 8))
                    .pointerStyle(.link)
                    // Lines of their own, wrapping: beside the button the thanks had one line
                    // and ended in an ellipsis.
                    Text(L("about.support.thanks")).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("about.support.note")).font(.system(size: 11)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .accentColor)
    }

    /// The app's own icon, falling back to a generic one when the bundle has none (dev builds).
    private var appIcon: some View {
        Group {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "square.split.2x1").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 52)
    }
}

/// The GitHub mark, drawn from the official monochrome logo. Rendered from inline SVG rather than a
/// bundled asset so the section carries no binary resource; the mark follows the current text
/// colour, as GitHub's brand guidance requires for monochrome use.
private struct GitHubMark: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let image = Self.render(dark: scheme == .dark) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "chevron.left.forwardslash.chevron.right").resizable()
            }
        }
    }

    private static var cache: [Bool: NSImage] = [:]

    private static func render(dark: Bool) -> NSImage? {
        if let cached = cache[dark] { return cached }
        let fill = dark ? "#FFFFFF" : "#1B1F24"
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">\
        <path fill="\(fill)" d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 \
        0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 \
        1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 \
        0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 \
        2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 \
        1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/>\
        </svg>
        """
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        cache[dark] = image
        return image
    }
}
