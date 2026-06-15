import Foundation
import AVFoundation

final class AudioPlayer {
    private var player: AVAudioPlayer?

    var isPlaying: Bool { player?.isPlaying ?? false }

    func play(wav: Data) throws {
        player?.stop()
        let p = try AVAudioPlayer(data: wav)
        p.prepareToPlay()
        p.play()
        player = p
    }

    func play(url: URL) throws {
        player?.stop()
        let p = try AVAudioPlayer(contentsOf: url)
        p.prepareToPlay()
        p.play()
        player = p
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
