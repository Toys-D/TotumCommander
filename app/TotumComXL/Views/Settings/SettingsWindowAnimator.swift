import AppKit

/// Animates the settings NSWindow: a centred "grow" on open and a shrink-and-fade
/// on close. The window is a fixed size; tall sections scroll inside it.
enum SettingsWindowAnimator {

    /// Duration of the open "grow".
    static let openDuration: TimeInterval = 0.30

    /// Place the window's frame at the TRUE centre of the screen (unlike
    /// NSWindow.center(), which sits slightly above centre).
    static func centerOnScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let f = window.frame
        window.setFrameOrigin(NSPoint(x: vf.minX + (vf.width - f.width) / 2,
                                      y: vf.minY + (vf.height - f.height) / 2))
    }

    /// Grow the WHOLE window frame from ~70% up to its current size, expanding
    /// symmetrically from the centre. The content is flexible, so it grows
    /// together with the frame. Call `centerOnScreen` first.
    static func growOpen(_ window: NSWindow) {
        let target = window.frame
        let s: CGFloat = 0.70
        // Ниже минимума окна не опускаемся даже на время анимации: программный setFrame
        // проходит мимо minSize и мимо делегата (проверено), поэтому прерванная анимация
        // оставляла окно уменьшенным — и следующее открытие ужимало его ещё раз.
        let startSize = NSSize(width: max(target.width * s, window.minSize.width),
                               height: max(target.height * s, window.minSize.height))
        let start = NSRect(x: target.midX - startSize.width / 2,
                           y: target.midY - startSize.height / 2,
                           width: startSize.width,
                           height: startSize.height)
        window.setFrame(start, display: true)
        window.alphaValue = 0.0
        DispatchQueue.main.async {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = openDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1.0
                window.animator().setFrame(target, display: true)
            }
        }
    }

    /// Shrink + fade the window out (for the OK button), then close it. The
    /// frame/alpha are restored afterwards so the next open's grow starts clean.
    static func closeWithShrink(_ window: NSWindow) {
        // End the modal session SYNCHRONOUSLY, up front. The window is shown via
        // NSApp.runModal, so the app is blocked in a nested modal run loop until
        // stopModal fires. Doing it in the animation's completion handler is fragile:
        // under the modal run-loop mode that completion can fail to run, leaving the
        // window faded to alpha 0 (invisible) while the modal loop keeps blocking ALL
        // input — the app looks frozen. Stopping the modal first makes that impossible;
        // the visual shrink/close then runs normally. stopModal is a no-op if no modal
        // session is running.
        NSApp.stopModal()
        let target = window.frame
        let s: CGFloat = 0.9
        // Та же оговорка, что и при открытии: меньше минимума окно не сжимается, иначе
        // прерванное закрытие оставляет его усохшим.
        let smallSize = NSSize(width: max(target.width * s, window.minSize.width),
                               height: max(target.height * s, window.minSize.height))
        let small = NSRect(x: target.midX - smallSize.width / 2,
                           y: target.midY - smallSize.height / 2,
                           width: smallSize.width,
                           height: smallSize.height)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0.0
            window.animator().setFrame(small, display: true)
        }, completionHandler: {
            window.close()
            window.setFrame(target, display: false)
            window.alphaValue = 1.0
        })
    }
}
