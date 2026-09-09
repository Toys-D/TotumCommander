import AVKit
import SwiftUI

struct MediaPreviewView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> SizedAVPlayerView {
        let view = SizedAVPlayerView()
        view.controlsStyle = .floating
        view.player = player
        return view
    }

    func updateNSView(_ nsView: SizedAVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

/// AVPlayerView with fixed intrinsic size to prevent SwiftUI layout loops
final class SizedAVPlayerView: AVPlayerView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: 400, height: 300)
    }
}
