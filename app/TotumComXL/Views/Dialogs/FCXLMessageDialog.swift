import AppKit
import SwiftUI

// MARK: - Shared message / confirmation / input dialog
//
// One component that replaces the app's NSAlert family with the settings-window
// look (FCXLDialog kit): a title + optional SF-Symbol icon + message, an optional
// "don't show again" checkbox, an optional text/secure input field, and a bottom
// bar of EQUAL-WIDTH buttons (accent primary / red destructive / quiet normal).
//
// DialogService routes showInfo/Warning/Error, showConfirmation,
// showDestructiveConfirmation, showSaveChangesConfirmation, showDeleteConfirmation,
// showTextInput and the cancel/NTFS prompts through here so every alert in the app
// shares one style. The synchronous return contract of the old NSAlert is kept:
// `run(_:)` blocks and returns which button was pressed (nil == ESC/cancel).

/// One button spec for the message dialog. `index` is preserved so callers can map
/// results exactly like NSAlert's alertFirstButtonReturn / SecondButtonReturn.
struct FCXLMessageButton {
    enum Kind { case primary, destructive, normal }
    let title: String
    var kind: Kind = .normal
}

struct FCXLMessageConfig {
    var title: String
    var message: String = ""
    /// SF Symbol name shown to the left of the text (e.g. warning/error glyph).
    var icon: String? = nil
    var iconColor: Color? = nil
    /// Buttons left→right; index 0 is the leading button (NSAlert's first button).
    var buttons: [FCXLMessageButton]
    /// "Don't show again" style checkbox under the message (nil = none).
    var checkboxTitle: String? = nil
    /// Non-nil turns on a single input field pre-filled with this value.
    var textFieldInitial: String? = nil
    var textFieldPlaceholder: String = ""
    var secureText: Bool = false
    /// Select only the base name (up to the last dot) on focus, like a rename field.
    var selectNameOnly: Bool = false
    var width: CGFloat = 460
}

struct FCXLMessageResult {
    /// Pressed button index, or nil on ESC/cancel.
    let buttonIndex: Int?
    let checkboxOn: Bool
    let text: String

    static let cancelled = FCXLMessageResult(buttonIndex: nil, checkboxOn: false, text: "")
}

@MainActor
enum FCXLMessageDialog {

    /// How the window is sized for a message: its height, and whether the text had to be
    /// given a scroll because even the tallest window could not hold it.
    struct Layout: Equatable {
        let windowHeight: CGFloat
        let messageScrolls: Bool
    }

    static let barHeight: CGFloat = 49
    static let minWindowHeight: CGFloat = 120
    /// The tallest a message window gets. Beyond it the text scrolls rather than the window
    /// growing past the screen — a stack trace of an error used to be cut off at the bottom,
    /// buttons and all.
    static let maxWindowHeight: CGFloat = 640

    /// Present the message dialog modally and block until dismissed (like NSAlert).
    static func run(_ config: FCXLMessageConfig) -> FCXLMessageResult {
        let layout = layout(for: config)
        let result: FCXLMessageResult? = FCXLDialog.runModal(
            size: NSSize(width: config.width, height: layout.windowHeight)
        ) { session in
            FCXLMessageDialogView(config: config, layout: layout, session: session)
        }
        return result ?? .cancelled
    }

    /// Exact window height: render the REAL content block (`FCXLMessageBody` — the same view
    /// shown above the button bar) offscreen at the dialog width and read its laid-out
    /// height, then add the fixed button bar. Because the window fits the text precisely,
    /// nothing scrolls and nothing is clipped, in any font — up to the tallest window, past
    /// which the text gets a scroll. Beats guessing from font metrics (which drift).
    static func layout(for config: FCXLMessageConfig) -> Layout {
        let probe = FCXLMessageBody(config: config,
                                    checkboxOn: .constant(false),
                                    text: .constant(config.textFieldInitial ?? ""),
                                    isMeasuring: true)
            .frame(width: config.width, alignment: .leading)
        let host = NSHostingView(rootView: AnyView(probe))
        host.frame = NSRect(x: 0, y: 0, width: config.width, height: 4000)
        host.layoutSubtreeIfNeeded()
        return layout(contentHeight: ceil(host.fittingSize.height))
    }

    /// The arithmetic behind the window: content plus the bar, held between the shortest and
    /// the tallest window; the text scrolls only when the tallest is not enough.
    static func layout(contentHeight: CGFloat) -> Layout {
        // +8 slack absorbs any sub-point rounding so the text never touches the bar.
        let wanted = contentHeight + barHeight + 8
        return Layout(windowHeight: min(max(wanted, minWindowHeight), maxWindowHeight),
                      messageScrolls: wanted > maxWindowHeight)
    }
}

// MARK: - View

private struct FCXLMessageDialogView: View {
    let config: FCXLMessageConfig
    let layout: FCXLMessageDialog.Layout
    let session: FCXLDialogSession<FCXLMessageResult>

    @State private var checkboxOn = false
    @State private var text: String

    init(config: FCXLMessageConfig, layout: FCXLMessageDialog.Layout,
         session: FCXLDialogSession<FCXLMessageResult>) {
        self.config = config
        self.layout = layout
        self.session = session
        _text = State(initialValue: config.textFieldInitial ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // NO ScrollView while the text fits: with "Always show scroll bars" enabled in
            // macOS, a SwiftUI ScrollView shows a permanent scrollbar even when its content
            // fits. The window is sized to the MEASURED content height (see layout(for:)), so
            // the text fits with no clipping — a scroll appears only past the tallest window,
            // where there really is something to scroll.
            if layout.messageScrolls {
                ScrollView(.vertical) { messageBody }
            } else {
                messageBody
            }

            Spacer(minLength: 0)

            FCXLDialogMultiButtonBar(buttons: barButtons)
        }
    }

    private var messageBody: some View {
        FCXLMessageBody(config: config, checkboxOn: $checkboxOn, text: $text,
                        onSubmit: confirmDefault, onCancel: { session.cancel() })
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Map config buttons → bar buttons, wiring each to finish with its index.
    private var barButtons: [FCXLDialogBarButton] {
        config.buttons.enumerated().map { index, button in
            let role: FCXLDialogBarButton.Role
            switch button.kind {
            case .primary:     role = .primary
            case .destructive: role = .destructive
            case .normal:      role = .normal
            }
            return FCXLDialogBarButton(title: button.title, role: role) {
                session.finish(FCXLMessageResult(buttonIndex: index,
                                                 checkboxOn: checkboxOn, text: text))
            }
        }
    }

    /// Return-key path: trigger the default (primary/destructive) button, else the first.
    private func confirmDefault() {
        let defaultIndex = config.buttons.firstIndex { $0.kind != .normal } ?? 0
        session.finish(FCXLMessageResult(buttonIndex: defaultIndex,
                                         checkboxOn: checkboxOn, text: text))
    }
}

// MARK: - Content block (shared by the live dialog and the offscreen size measurement)

/// Everything above the button bar: icon + title + message, plus an optional input field
/// and "don't show again" checkbox. Rendered live inside the dialog AND offscreen to
/// measure the exact window height — using ONE view guarantees the measurement matches
/// what's drawn, so the window always fits the text with no scrollbars.
struct FCXLMessageBody: View {
    let config: FCXLMessageConfig
    @Binding var checkboxOn: Bool
    @Binding var text: String
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    /// True only for the offscreen size measurement — renders a plain placeholder instead
    /// of the real focus-grabbing text field, which must exist only ONCE (in the live
    /// dialog). A second, offscreen FCXLDialogTextField steals focus from the live one.
    var isMeasuring: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                if let icon = config.icon {
                    Image(systemName: icon)
                        .font(.system(size: 30))
                        .foregroundStyle(config.iconColor ?? .secondary)
                        .frame(width: 32)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(config.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    if !config.message.isEmpty {
                        Text(config.message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            if config.textFieldInitial != nil {
                inputField
            }

            if let checkboxTitle = config.checkboxTitle {
                // Свой переключатель, а не системный флажок: в программе один вид этого
                // контрола — тот, что в настройках и во всех остальных окнах.
                HStack(spacing: 8) {
                    FCXLSwitch(isOn: $checkboxOn)
                    Text(checkboxTitle).font(.system(size: 12))
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var inputField: some View {
        FCXLFormCard {
            FCXLFormRow(showDivider: false) {
                if isMeasuring {
                    Text(text.isEmpty ? " " : text)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if config.secureText {
                    SecureField(config.textFieldPlaceholder, text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .onSubmit { onSubmit?() }
                } else {
                    FCXLDialogTextField(
                        text: $text,
                        placeholder: config.textFieldPlaceholder,
                        focusOnAppear: true,
                        initialSelection: config.selectNameOnly ? .baseName : .all,
                        onSubmit: { onSubmit?() },
                        onCancel: { onCancel?() }
                    )
                }
            }
        }
    }
}
