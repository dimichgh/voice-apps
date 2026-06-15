import SwiftUI
import AVKit

/// AppKit-backed video view. SwiftUI's `VideoPlayer` (from `_AVKit_SwiftUI`) can
/// abort with a generic-metadata fatal error (`getSuperclassMetadata`) the
/// moment it's instantiated on some macOS builds. Wrapping AVKit's `AVPlayerView`
/// directly sidesteps that framework path and is rock-solid.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
