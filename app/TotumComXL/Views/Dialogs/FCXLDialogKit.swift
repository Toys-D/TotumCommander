import AppKit
import SwiftUI

// MARK: - FCXL dialog kit
//
// Reusable "settings-window style" for the app's dialogs: a chrome-less floating
// panel (hidden titlebar, no window buttons, movable by background) with grouped
// form cards inside and a big accent button bar at the bottom, presented modally
// with the same grow-open / shrink-close animation as the Settings window.
//
// Usage:
//   let result: MyResult? = FCXLDialog.runModal(size: ...) { (session: FCXLDialogSession<MyResult>) in
//       MyDialogView(session: session)
//   }
// The content calls session.finish(value) (OK) or session.cancel() (Cancel/ESC).

/// Runs `action` as a RUNLOOP callout on the next tick — never as main-queue work.
/// Use in SwiftUI Button actions that present something modal (NSOpenPanel, an
/// FCXLDialog, NSAlert): SwiftUI actions execute as main-QUEUE blocks, and a modal
/// run loop inside such a block starves all queued main-queue work — an NSOpenPanel
/// takes seconds to appear (its XPC UI callbacks are queued), dialog buttons go
/// dead. Scheduled in .common modes so it also fires inside modal sessions.
/// Runs `body` with `window` off screen, and puts it back exactly as it was afterwards.
///
/// For a dialog that is ABOUT what is behind it: the cursor editor previews on the live panels,
/// and the settings window it was opened from only sits in the way. Restoring happens on every
/// path out of `body`, so the window can never be left hidden while the app is modal.
@MainActor
@discardableResult
func fcxlHiding<T>(_ window: NSWindow?, while body: () -> T) -> T {
    let hide = window?.isVisible == true
    if hide { window?.orderOut(nil) }
    defer { if hide { window?.makeKeyAndOrderFront(nil) } }
    return body()
}

@MainActor
func fcxlPresentModal(_ action: @escaping @MainActor () -> Void) {
    RunLoop.main.perform(inModes: [.common]) {
        MainActor.assumeIsolated { action() }
    }
}

/// Async variant for use INSIDE a Task / async context (e.g. the editor's save-changes
/// check): presents a blocking dialog on a runloop callout — so its SwiftUI buttons aren't
/// starved by the parked main queue the Task runs on — and awaits the result. Use like:
///   let decision = await fcxlPresentModalAsync { DialogService.shared.showSaveChangesConfirmation(...) }
@MainActor
func fcxlPresentModalAsync<T>(_ body: @escaping @MainActor () -> T) async -> T {
    await withCheckedContinuation { continuation in
        fcxlPresentModal { continuation.resume(returning: body()) }
    }
}

/// Shared result box between the SwiftUI content and the modal runner.
@MainActor
final class FCXLDialogSession<Result> {
    fileprivate(set) weak var window: NSWindow?
    fileprivate(set) var result: Result?
    /// Guards against double-finish (e.g. Enter + Esc racing, or a queued second
    /// keypress landing after the first already ended the modal session). A second
    /// close would stopModal AGAIN — killing the NEXT dialog's session — and
    /// double-run the close animation/close, over-releasing the window.
    private var finished = false

    /// Close the dialog returning `value` (the OK path).
    func finish(_ value: Result) {
        guard !finished else { return }
        finished = true
        result = value
        closeAnimated()
    }

    /// Close the dialog returning nil (Cancel / ESC path).
    func cancel() {
        guard !finished else { return }
        finished = true
        result = nil
        closeAnimated()
    }

    private func closeAnimated() {
        guard let window else { NSApp.stopModal(); return }
        // Stops the modal session synchronously FIRST, then shrink-fades (see
        // SettingsWindowAnimator.closeWithShrink for why the order matters).
        SettingsWindowAnimator.closeWithShrink(window)
    }
}

@MainActor
enum FCXLDialog {

    /// Present `content` in a settings-style panel, run it modally (blocks like
    /// NSAlert.runModal) and return whatever the content passed to
    /// `session.finish`, or nil on cancel/ESC.
    static func runModal<Result, Content: View>(
        size: NSSize,
        @ViewBuilder content: (FCXLDialogSession<Result>) -> Content
    ) -> Result? {
        let session = FCXLDialogSession<Result>()
        let root = FCXLDialogChrome(onCancel: { [weak session] in session?.cancel() }) {
            content(session)
        }
        // No system focus ring ANYWHERE in the kit's dialogs — set once at the root and
        // inherited by every control inside, present and future. The app draws its own
        // accents; the blue halo is a stranger that kept sneaking back one control at a
        // time (buttons, checkboxes, pickers…), so it is banned at the door instead.
        .focusEffectDisabled()

        let hosting = NSHostingController(rootView: root)
        // AppKit (setContentSize + animator) owns the window size, not SwiftUI.
        hosting.sizingOptions = []
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.titled, .closable, .utilityWindow, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        // Normal window level (not .floating) and no forced space pinning: a floating,
        // space-pinned modal panel makes macOS block Mission Control / trackpad space
        // switching while the dialog is up. A normal-level modal is still key & front but
        // lets the system gestures work.
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.setContentSize(size)
        // Build the SwiftUI tree at full size BEFORE the grow animation (cold
        // first render would stutter against the animated frame).
        panel.contentView?.layoutSubtreeIfNeeded()
        // A .titled panel keeps a titlebar SAFE AREA (19pt for .utilityWindow) even with the
        // bar transparent, hidden and buttonless — so SwiftUI was laid out into (height - 19)
        // and everything that could not shrink got squeezed. The bottom bar paid: its 48pt
        // buttons came out at 42.5 with the letters below centre, but ONLY in dialogs sized
        // exactly to their content (the message dialog); the ones with slack looked right,
        // which is why two dialogs side by side had different button heights. Grow the window
        // by that inset instead of ignoring it — the layout inside every dialog stays exactly
        // as it was, and the content finally gets the height it asked for.
        let titlebarInset = panel.contentView?.safeAreaInsets.top ?? 0
        if titlebarInset > 0 {
            panel.setContentSize(NSSize(width: size.width, height: size.height + titlebarInset))
            panel.contentView?.layoutSubtreeIfNeeded()
        }
        SettingsWindowAnimator.centerOnScreen(panel)

        session.window = panel

        // Open at FULL size, FULLY VISIBLE immediately (alpha = 1). No entrance fade/scale:
        // any animation driver (AppKit animator, SwiftUI onAppear, or a runloop timer) can be
        // starved or skipped when the dialog is opened from an unusual context — a parked main
        // queue (context-menu Delete) or right after a drag-and-drop session ends. If the
        // window is left at alpha 0 while runModal blocks, the modal is INVISIBLE and the whole
        // app looks frozen (even the trackpad/space gestures stop). Visible-from-frame-1 makes
        // that impossible. The content is laid out once, correctly, before the modal starts.
        panel.alphaValue = 1
        // Only force-activate if we're NOT already the active app. After a drag-and-drop the
        // app is already frontmost; a redundant activate(ignoringOtherApps:) there re-grabs
        // focus in a way that makes macOS block trackpad space-switch gestures while the modal
        // is up (F5, where the app is already calmly active, never hit this).
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        panel.makeKeyAndOrderFront(nil)

        // Safety net: if the window closes by any path that didn't go through the
        // animator (e.g. Cmd+W), still end the modal session so the app can't hang.
        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { _ in
            NSApp.stopModal()
        }
        defer { NotificationCenter.default.removeObserver(closeObserver) }

        NSApp.runModal(for: panel)
        // No orderOut here: closeWithShrink is already animating the window away
        // and closes it in its completion handler.
        return session.result
    }
}

/// Root wrapper: applies the app accent to the whole dialog and routes ESC to Cancel.
/// Deliberately has NO entrance animation of its own: the content must be fully visible
/// from its first (synchronous, pre-modal) render. A SwiftUI opacity/scale entrance driven
/// by `onAppear` can be starved when the dialog is opened from a parked main queue (e.g. a
/// context-menu action), leaving the content stuck invisible — an empty box. The gentle
/// fade-in is done on the WINDOW's alpha by a runloop timer in `runModal` instead.
private struct FCXLDialogChrome<Content: View>: View {
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    let onCancel: () -> Void
    @ViewBuilder let content: Content

    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .tint(accent)
            .onExitCommand { onCancel() }
    }
}

// MARK: - Building blocks

/// Dialog title, styled exactly like the Settings section header.
struct FCXLDialogHeader: View {
    let title: String
    var subtitle: String?
    /// A symbol beside the title, in the same manner the message dialogs use one: the red
    /// trash says "this removes things" before a word is read.
    var icon: String?
    var iconColor: Color = .red
    /// While true the symbol breathes — the dialog is doing something, and the movement says
    /// so without a second spinner.
    var iconBusy: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(iconColor)
                    .frame(width: 32)
                    .symbolEffect(.pulse, options: .repeating, isActive: iconBusy)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }
}

/// Bottom button bar: [Cancel | big accent primary], 48pt tall, full width —
/// the dialog twin of the Settings window's OK bar.
struct FCXLDialogButtonBar: View {
    let primaryTitle: String
    var primaryEnabled: Bool = true
    let primaryAction: () -> Void
    var cancelTitle: String = L("button.cancel")
    /// A button that removes things is red, as everywhere else in this program — the accent
    /// means "the usual answer", and this one is not that.
    var destructive: Bool = false
    let cancelAction: () -> Void

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color {
        destructive ? .red
            : PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    /// White on red, always — this is a convention, not a calculation.
    ///
    /// The contrast formula genuinely prefers black there (5.92 against 3.55 by WCAG), and it
    /// is right about the arithmetic and wrong about the button: every destructive button in
    /// macOS, and every one in this program, is white on red. The measurement stays for the
    /// ACCENT colour, where the person can pick any hue and the maths is the only guide.
    private var primaryTextColor: Color {
        destructive ? .white : PanelAppearanceSettings.contrastingTextColor(on: accent)
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                // No system focus ring anywhere in the bar: macOS parks it on the FIRST
                // button (usually Cancel) while the accent fill marks the real default —
                // two things reading as a cursor, in different places. The accent IS the
                // indicator; Enter still fires the primary via .defaultAction.
                // One rule for every dialog bar: 13pt text at full size, 48pt tall — the
                // WIDTH flexes with the title, the height and the letters never do.
                Button(action: cancelAction) { barLabel(cancelTitle) }
                    .buttonStyle(FCXLDialogSecondaryButtonStyle(fontSize: 13))
                    .focusEffectDisabled()
                Divider().frame(height: 48)
                Button(action: primaryAction) { barLabel(primaryTitle) }
                    .buttonStyle(FCXLDialogPrimaryButtonStyle(
                        accent: accent,
                        textColor: primaryTextColor,
                        fontSize: 13))
                    .keyboardShortcut(.defaultAction)
                    .focusEffectDisabled()
                    .disabled(!primaryEnabled)
            }
        }
    }

    private func barLabel(_ title: String) -> some View {
        Text(title)
            .lineLimit(1)
            .padding(.horizontal, 4)
    }
}

/// A drop-down in the app's own style: the popup is the same accent-highlighted NSMenu every
/// context menu uses, not the system one. SwiftUI's `.menu` picker draws AppKit's default menu,
/// whose selection bar follows the SYSTEM accent — the one place in a dialog that ignored the
/// user's chosen colour.
struct FCXLDialogMenuPicker<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    /// SF Symbol per item, for menus whose options ARE icons (the panel's "up" icon, say).
    /// The current choice still shows the checkmark — same marker everywhere.
    var icon: ((Item) -> String)? = nil
    /// Toolbars get the small variant; dialogs the regular one.
    var compact: Bool = false
    /// Fixes the label width so a long option (a font name) cannot stretch a toolbar.
    var chipWidth: CGFloat? = nil

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    @State private var isHovered = false

    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    var body: some View {
        FCXLMenuAnchor(present: { anchor in
            let menu = NSMenu()
            for item in items {
                // The checkmark marks the current choice the way the system menu did.
                menu.addStyledItem(title: title(item),
                                   symbolName: item == selection ? "checkmark" : (icon?(item) ?? "")) {
                    selection = item
                }
            }
            menu.applyAccentStyle()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
        }) {
            HStack(spacing: compact ? 4 : 6) {
                if let icon {
                    Image(systemName: icon(selection))
                        .font(.system(size: compact ? 10 : 12))
                }
                Text(title(selection))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: chipWidth, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: compact ? 8 : 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(compact ? .system(size: 11) : .body)
            .padding(.horizontal, compact ? 7 : 10)
            .padding(.vertical, compact ? 3 : 5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? accent.opacity(0.18) : Color.secondary.opacity(0.10)))
            .contentShape(Rectangle())
        }
        .onHover { isHovered = $0 }
        .fixedSize()
    }
}

/// The chip look of FCXLDialogMenuPicker as a button style, so "Choose…" next to a picker is
/// visibly the same family of control — one style, not a coincidence of similar values.
struct FCXLChipButtonStyle: ButtonStyle {
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration, compact: compact)
    }

    private struct Chip: View {
        let configuration: Configuration
        let compact: Bool
        @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
        @State private var isHovered = false

        private var accent: Color {
            PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
        }

        var body: some View {
            configuration.label
                .font(compact ? .system(size: 11) : .body)
                .padding(.horizontal, compact ? 7 : 10)
                .padding(.vertical, compact ? 3 : 5)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? accent.opacity(0.30)
                          : isHovered ? accent.opacity(0.18)
                          : Color.secondary.opacity(0.10)))
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}

/// Bridges "pop an NSMenu from this exact spot" into SwiftUI: the label renders as content, a
/// click hands the backing NSView to `present`, which is what NSMenu needs to anchor itself.
/// Internal, not private: the monitor's options menu presents its own styled NSMenu through it.
struct FCXLMenuAnchor<Content: View>: NSViewRepresentable {
    let present: (NSView) -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> ClickThroughHost<Content> {
        ClickThroughHost(rootView: content(), onClick: present)
    }

    func updateNSView(_ nsView: ClickThroughHost<Content>, context: Context) {
        nsView.rootView = content()
        nsView.onClick = present
    }

    final class ClickThroughHost<Inner: View>: NSHostingView<Inner> {
        var onClick: ((NSView) -> Void)?

        init(rootView: Inner, onClick: @escaping (NSView) -> Void) {
            self.onClick = onClick
            super.init(rootView: rootView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        @available(*, unavailable)
        required init(rootView: Inner) { fatalError() }

        override func mouseDown(with event: NSEvent) {
            onClick?(self)
        }

        /// Claim every click inside the chip. SwiftUI's internal views under the hosting view
        /// swallow mouseDown for their own gesture machinery, so clicks on the TEXT never reached
        /// our handler — only the chevron, which happens to sit outside any gesture region,
        /// opened the menu. Hover is unaffected: tracking areas are geometric and do not consult
        /// hitTest.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return bounds.contains(local) ? self : nil
        }
    }
}

/// One button of a multi-button bar row.
struct FCXLDialogBarButton: Identifiable {
    /// `.primary` = accent-filled default (answers Return). `.destructive` = red-filled
    /// default (answers Return) for delete/discard actions. `.normal` = quiet.
    enum Role { case normal, primary, destructive }
    let id = UUID()
    let title: String
    var role: Role = .normal
    var enabled: Bool = true
    let action: () -> Void
}

/// Bottom bar with N EQUAL-WIDTH buttons (HIG: uniform sizes, single default),
/// 48pt tall like the two-button bar. The `.primary` button is accent-filled and
/// answers Return; ESC is handled by the dialog chrome (session.cancel).
struct FCXLDialogMultiButtonBar: View {
    let buttons: [FCXLDialogBarButton]

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                // Identity by INDEX, not by element.id: the buttons array is rebuilt on every
                // render (message dialogs recompute it per keystroke) with fresh UUIDs, so an
                // id-based ForEach would RECREATE the buttons each time. Recreating the
                // .defaultAction button steals first responder from a text field in the dialog
                // — typed characters vanish. Index identity keeps the buttons stable.
                ForEach(Array(buttons.enumerated()), id: \.offset) { index, button in
                    if index > 0 { Divider().frame(height: 48) }
                    switch button.role {
                    case .primary:
                        Button(action: button.action) { barLabel(button.title) }
                            .buttonStyle(FCXLDialogPrimaryButtonStyle(
                                accent: accent,
                                textColor: PanelAppearanceSettings.contrastingTextColor(on: accent),
                                fontSize: 13))
                            .keyboardShortcut(.defaultAction)
                            .focusEffectDisabled()
                            .disabled(!button.enabled)
                    case .destructive:
                        Button(action: button.action) { barLabel(button.title) }
                            .buttonStyle(FCXLDialogPrimaryButtonStyle(
                                accent: .red, textColor: .white, fontSize: 13))
                            .keyboardShortcut(.defaultAction)
                            .focusEffectDisabled()
                            .disabled(!button.enabled)
                    case .normal:
                        Button(action: button.action) { barLabel(button.title) }
                            .buttonStyle(FCXLDialogSecondaryButtonStyle(fontSize: 13))
                            .focusEffectDisabled()
                            .disabled(!button.enabled)
                    }
                }
            }
        }
    }

    private func barLabel(_ title: String) -> some View {
        Text(title)
            .lineLimit(1)
            .padding(.horizontal, 4)
    }
}

/// Full-width accent primary button (same look as the Settings OK button).
struct FCXLDialogPrimaryButtonStyle: ButtonStyle {
    let accent: Color
    let textColor: Color
    var fontSize: CGFloat = 15
    /// Bar height (48 = the flush dialog bottom bar). Smaller for standalone buttons.
    var height: CGFloat = 48
    /// 0 = flush bar (dialogs); >0 = rounded standalone button (e.g. popover OK).
    var cornerRadius: CGFloat = 0
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundColor(textColor.opacity(isEnabled ? 1 : 0.5))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(accent.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.4),
                       in: RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.995 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Small bordered action button for a toolbar sitting under a list/table
/// (Add / Edit / Duplicate / Delete rows). Rounded, 28pt tall, quiet fill —
/// the canonical "secondary action next to a list" control across the app.
struct FCXLToolbarButtonStyle: ButtonStyle {
    var destructive: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let tint: Color = destructive ? .red : .primary
        return configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint.opacity(isEnabled ? (destructive ? 0.9 : 0.85) : 0.35))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06),
                       in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet secondary (Cancel) button with the same geometry as the primary.
struct FCXLDialogSecondaryButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 15
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .regular))
            .foregroundColor(.primary.opacity(isEnabled ? 1 : 0.35))
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.05))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Form card + rows (canonical grouped-form look outside of Form)
//
// SwiftUI's Form(.grouped) can't host a stretching results list, so windows like
// the search panel build their "cards" manually. These components ARE the canon
// for that: any window that can't use Form must compose FCXLFormCard/FCXLFormRow
// so every card, row, label and control looks identical across the app.

/// Rounded card that visually matches a grouped-form section.
struct FCXLFormCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One row of a form card: label on the left, control(s) on the right.
/// Matches the grouped-form row metrics (13pt label, ~38pt row, 14pt insets).
struct FCXLFormRow<Content: View>: View {
    var label: String = ""
    var showDivider: Bool = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: 13))
                        .frame(minWidth: 90, alignment: .leading)
                }
                content
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            if showDivider {
                Divider().padding(.leading, 14)
            }
        }
    }
}

/// Full-width toggle row: label left, switch trailing — exactly like a grouped
/// Form's Toggle row.
struct FCXLToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    var showDivider: Bool = true

    var body: some View {
        FCXLFormRow(showDivider: showDivider) {
            Text(label).font(.system(size: 13))
            Spacer()
            FCXLSwitch(isOn: $isOn)
        }
    }
}

/// The switch itself, wrapped from AppKit. A plain SwiftUI `Toggle(.switch)` draws a blue
/// focus ring as soon as it becomes first responder, and `.focusEffectDisabled()` does not
/// reach it — the ring belongs to the NSSwitch underneath, so it has to be turned off there.
struct FCXLSwitch: NSViewRepresentable {
    @Binding var isOn: Bool
    /// Мелкий вариант — для списков, где переключатель стоит в каждой строке: там обычный
    /// выглядит тяжело и перетягивает взгляд на себя.
    var size: NSControl.ControlSize = .small

    func makeNSView(context: Context) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = size
        control.focusRingType = .none
        control.target = context.coordinator
        control.action = #selector(Coordinator.toggled(_:))
        return control
    }

    func updateNSView(_ control: NSSwitch, context: Context) {
        context.coordinator.isOn = $isOn
        if control.controlSize != size { control.controlSize = size }
        let wanted: NSControl.StateValue = isOn ? .on : .off
        if control.state != wanted { control.state = wanted }
    }

    func makeCoordinator() -> Coordinator { Coordinator(isOn: $isOn) }

    final class Coordinator: NSObject {
        var isOn: Binding<Bool>
        init(isOn: Binding<Bool>) { self.isOn = isOn }
        @objc func toggled(_ sender: NSSwitch) { isOn.wrappedValue = (sender.state == .on) }
    }
}

// MARK: - Dropdown (pop-up) styled like the grouped-form pickers

/// A pop-up menu matching the app's Settings pickers — a native AppKit NSPopUpButton, which puts
/// the gray up/down chevron on the RIGHT (SwiftUI's Menu/borderlessButton keeps its indicator on
/// the left and ignores menuIndicator(.hidden), so we wrap AppKit directly).
struct FCXLDropdown<T: Hashable>: NSViewRepresentable {
    @Binding var selection: T
    let options: [(value: T, label: String)]
    var onChange: (() -> Void)?

    init(selection: Binding<T>, options: [(value: T, label: String)], onChange: (() -> Void)? = nil) {
        self._selection = selection
        self.options = options
        self.onChange = onChange
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        // No blue halo, here as everywhere: the ring belongs to the AppKit control, so
        // `.focusEffectDisabled()` on the SwiftUI side never reaches it — it has to be turned
        // off on the button itself.
        button.focusRingType = .none
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 13)
        // Flat, like the grouped-form pickers in Settings: no bezel box, no blue chevron button —
        // just the value with a subtle gray up/down chevron on the right.
        button.isBordered = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = options.map { $0.label }
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        if let idx = options.firstIndex(where: { $0.value == selection }) {
            button.selectItem(at: idx)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: FCXLDropdown
        init(_ parent: FCXLDropdown) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) {
            let idx = sender.indexOfSelectedItem
            guard idx >= 0, idx < parent.options.count else { return }
            parent.selection = parent.options[idx].value
            parent.onChange?()
        }
    }
}

/// A flat pull-down menu button (native NSPopUpButton in pull-down mode). Chevron on the right,
/// no bezel — like the Settings dropdowns. The title stays fixed; picking an item calls onSelect.
/// `groups` render as disabled section headers with their items beneath.
struct FCXLMenuButton: NSViewRepresentable {
    let title: String
    let groups: [(header: String, items: [String])]
    let onSelect: (String) -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.focusRingType = .none
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        context.coordinator.rebuild(button)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        context.coordinator.rebuild(button)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: FCXLMenuButton
        init(_ parent: FCXLMenuButton) { self.parent = parent }

        func rebuild(_ button: NSPopUpButton) {
            let menu = NSMenu()
            // Item 0 is the fixed label shown on the button (pull-down convention).
            let titleItem = NSMenuItem(title: parent.title, action: nil, keyEquivalent: "")
            titleItem.attributedTitle = NSAttributedString(
                string: parent.title,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                             .font: NSFont.systemFont(ofSize: 12)])
            menu.addItem(titleItem)
            for group in parent.groups {
                menu.addItem(.separator())
                let header = NSMenuItem(title: group.header, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for tag in group.items {
                    let item = NSMenuItem(title: tag, action: #selector(pick(_:)), keyEquivalent: "")
                    item.target = self
                    menu.addItem(item)
                }
            }
            button.menu = menu
        }

        @objc func pick(_ sender: NSMenuItem) { parent.onSelect(sender.title) }
    }
}

// MARK: - Text field with AppKit-grade focus/selection control

/// NSTextField wrapper for dialog forms: can grab focus on appear, pre-select
/// just the base name (without the extension) the way file dialogs do, submit on
/// Return and cancel the dialog on ESC. Styled to sit flat inside a grouped form row.
/// Отличает «значение поменяли снаружи» от «SwiftUI прислал эхо нашего же набора».
///
/// Поле пишет каждый набранный знак в привязку, а SwiftUI возвращает её обратно следующим
/// кругом отрисовки. Пока эхо идёт, человек успевает нажать ещё клавишу — и поле уже ушло
/// вперёд. Если в этот момент переписать поле «значением из привязки», последний знак
/// пропадёт. Так из пароля и пропадала буква: пароль сохранялся на один знак короче, сервер
/// отвечал «530», а выглядело это как «программа не сохраняет пароль».
struct FCXLFieldEcho {
    /// Что поле само записало в привязку и ещё не увидело обратно, по порядку набора.
    private var pending: [String] = []

    /// Больше и не нужно: эхо отстаёт на круг отрисовки, а не на страницу текста.
    private static let limit = 32

    mutating func pushed(_ value: String) {
        pending.append(value)
        if pending.count > Self.limit { pending.removeFirst(pending.count - Self.limit) }
    }

    /// Пришло ли из привязки то, что мы сами туда положили. Всё, что было записано раньше
    /// этого значения, уже неактуально — оно уходит вместе с ним.
    mutating func isEcho(of binding: String) -> Bool {
        guard let index = pending.lastIndex(of: binding) else { return false }
        pending.removeSubrange(0...index)
        return true
    }
}

struct FCXLDialogTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    /// Select on first focus: .all, or .baseName (up to the last dot).
    enum InitialSelection { case none, all, baseName }
    var focusOnAppear: Bool = false
    var initialSelection: InitialSelection = .none
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Down-arrow handler (e.g. jump from a query field into a results list).
    var onMoveDown: (() -> Void)?
    /// Dots instead of characters — a password.
    var isSecure: Bool = false
    /// Small inline uses (the octal code in the permissions grid) want their own size,
    /// a monospaced face and centred digits; every existing call site keeps the defaults.
    var fontSize: CGFloat = 13
    var monospaced: Bool = false
    var alignment: NSTextAlignment = .natural

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = isSecure ? NSSecureTextField(string: text) : NSTextField(string: text)
        field.placeholderString = placeholder
        field.font = monospaced
            ? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : .systemFont(ofSize: fontSize)
        field.alignment = alignment
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingMiddle
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if focusOnAppear {
            // RunLoop.perform, NOT DispatchQueue.main.async: the dialog may be modal
            // from inside a main-queue block (drag&drop path), where queued GCD work
            // can't run until the modal ends — runloop blocks in .common DO run.
            RunLoop.main.perform(inModes: [.common]) { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                context.coordinator.applyInitialSelection(to: field)
            }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // The hint can change while the field lives on — a rule row whose "Name" turns into
        // "Extension" keeps the same field and would otherwise keep suggesting a name mask.
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        // Sync the bound value into the field whenever they differ. This also covers changes made
        // from OUTSIDE the field while it has focus — e.g. the Multi-Rename "Теги" menu inserting
        // a tag, or a stepper changing a counter value. During normal typing the two are already
        // equal (controlTextDidChange writes text synchronously), so this is a no-op then and the
        // caret is left alone; it only moves to the end when an external edit lands mid-focus.
        guard field.stringValue != text else { return }
        // Эхо собственного набора: поле уже правее привязки на только что нажатый знак,
        // и «синхронизация» стёрла бы его.
        guard !context.coordinator.echo.isEcho(of: text) else { return }
        let editor = field.currentEditor()
        field.stringValue = text
        if editor != nil {
            let end = (text as NSString).length
            field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FCXLDialogTextField
        private var didApplyInitialSelection = false
        /// Что поле отдало в привязку и ещё не получило обратно — см. `FCXLFieldEcho`.
        var echo = FCXLFieldEcho()

        init(_ parent: FCXLDialogTextField) { self.parent = parent }

        func applyInitialSelection(to field: NSTextField) {
            guard !didApplyInitialSelection else { return }
            didApplyInitialSelection = true
            guard let editor = field.currentEditor() else { return }
            switch parent.initialSelection {
            case .none:
                editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
            case .all:
                field.selectText(nil)
            case .baseName:
                let name = field.stringValue
                if let dotRange = name.range(of: ".", options: .backwards),
                   dotRange.lowerBound != name.startIndex {
                    let len = name.distance(from: name.startIndex, to: dotRange.lowerBound)
                    editor.selectedRange = NSRange(location: 0, length: len)
                } else {
                    field.selectText(nil)
                }
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            echo.pushed(field.stringValue)
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)), let onSubmit = parent.onSubmit {
                echo.pushed(control.stringValue)
                parent.text = control.stringValue
                onSubmit()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)), let onCancel = parent.onCancel {
                onCancel()
                return true
            }
            if selector == #selector(NSResponder.moveDown(_:)), let onMoveDown = parent.onMoveDown {
                onMoveDown()
                return true
            }
            return false
        }
    }
}
