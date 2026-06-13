import Foundation
import AVFoundation

/// Audio I/O for the voice assistant: mic capture (energy-VAD) + low-latency
/// streaming playback of Qwen3-Omni Talker output.
///
/// IMPORTANT — two SEPARATE engines, by necessity:
///   - `captureEngine`: input-only, drives the mic tap + VAD.
///   - `playbackEngine`: a player node → mixer → output for Talker audio.
///
/// We tried a single Voice-Processing IO engine (hardware AEC) for true
/// full-duplex barge-in, but on this hardware VPIO can't acquire the input
/// device (it enumerates as 0 ch / 0 Hz, `start()` fails with -10875), and a
/// merged input+output engine doesn't deliver mic buffers at all — the tap
/// never fires. An input-only capture engine is the configuration that
/// reliably captures here. Echo is handled at the app layer by muting the mic
/// while the assistant speaks (half-duplex): `aecActive` reports false so
/// `ChatSession` knows to do that.
///
/// Because the engines are independent, `stopPlayback()` can stop the playback
/// engine outright (barge-in) without touching capture.
final class AudioIO {
    private let captureEngine = AVAudioEngine()
    private let playbackEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat: AVAudioFormat   // 24 kHz mono — Talker output

    private let lock = NSLock()
    private var listening = false
    private var playbackStarted = false
    private var pendingBuffers = 0

    private var converter: AVAudioConverter?
    private var tapBufferCount = 0

    /// Always false here (no hardware AEC). Kept so callers can branch: when
    /// false, mute the mic during playback instead of relying on cancellation.
    private(set) var aecActive = false

    // MARK: VAD state
    private var inUtterance = false
    private var silentFrames = 0
    private var speechFrames = 0
    private var levelEMA: Float = 0
    private var lastLevelEmit = Date.distantPast
    private var rollingSamples: [Float] = []

    // MARK: Tunables (RMS on float samples in [-1, 1]).
    var energyThreshold: Float = 0.012
    var minSpeechFrames = 3
    var trailingSilenceFrames = 22      // ~0.45s at 1024-sample frames @ 16 kHz
    var maxPreSpeechSamples = 8_000

    /// Hard mute for VAD: skips speech evaluation while set (level still emits).
    /// Used during playback so the assistant doesn't trigger its own listener.
    var muted: Bool = false

    var onSpeechStart: (() -> Void)?
    var onUtterance: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?

    init(playbackSampleRate: Double = 24_000) {
        playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: playbackSampleRate,
            channels: 1,
            interleaved: false
        )!
        playbackEngine.attach(player)
        playbackEngine.connect(player, to: playbackEngine.mainMixerNode, format: playbackFormat)
    }

    // MARK: - Capture (hands-free)

    /// Begin continuous listening: build the VAD converter, install the mic tap,
    /// then start the input-only capture engine (tap BEFORE start — the order
    /// that reliably delivers buffers).
    func startListening() throws {
        let input = captureEngine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "AudioIO", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Cannot build capture converter from \(inFormat)"])
        }
        lock.lock()
        converter = conv
        rollingSamples.removeAll(keepingCapacity: true)
        inUtterance = false; silentFrames = 0; speechFrames = 0; levelEMA = 0
        listening = true
        lock.unlock()
        tapBufferCount = 0

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        captureEngine.prepare()
        try captureEngine.start()
        DebugLog.log("AudioIO: listening, fmt=\(inFormat) running=\(captureEngine.isRunning)")
    }

    func stopListening() {
        captureEngine.inputNode.removeTap(onBus: 0)
        if captureEngine.isRunning { captureEngine.stop() }
        lock.lock()
        listening = false
        rollingSamples.removeAll(keepingCapacity: false)
        inUtterance = false; silentFrames = 0; speechFrames = 0; levelEMA = 0
        lock.unlock()
    }

    // MARK: - Playback (Talker streaming)

    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingBuffers > 0
    }

    private func startPlaybackIfNeeded() throws {
        if !playbackStarted {
            playbackEngine.prepare()
            try playbackEngine.start()
            playbackStarted = true
        }
        if !player.isPlaying { player.play() }
    }

    /// Schedule one PCM16-LE 24 kHz chunk for playback.
    func enqueue(pcm16: Data) {
        guard let buffer = Self.makeBuffer(pcm16: pcm16, format: playbackFormat) else { return }
        do { try startPlaybackIfNeeded() } catch {
            DebugLog.log("AudioIO: playback start failed: \(error.localizedDescription)")
            return
        }
        lock.lock(); pendingBuffers += 1; lock.unlock()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.pendingBuffers -= 1; self.lock.unlock()
        }
    }

    /// Stop playback instantly and flush queued audio (barge-in). Independent of
    /// the capture engine, so listening is unaffected.
    func stopPlayback() {
        player.stop()
        lock.lock(); pendingBuffers = 0; lock.unlock()
        if playbackStarted {
            playbackEngine.stop()
            playbackStarted = false
        }
    }

    func waitUntilDrained() async {
        while isPlaying {
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    // MARK: - VAD tap

    private func handle(buffer: AVAudioPCMBuffer) {
        tapBufferCount += 1
        let first = tapBufferCount == 1
        if first { DebugLog.log("AudioIO: first tap buffer frames=\(buffer.frameLength)") }

        lock.lock()
        let conv = converter
        lock.unlock()
        guard let converter = conv else { return }

        let outFormat = converter.outputFormat
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var err: NSError?
        var provided = false
        converter.convert(to: out, error: &err) { _, status in
            if provided { status.pointee = .noDataNow; return nil }
            provided = true
            status.pointee = .haveData
            return buffer
        }
        if err != nil { return }
        guard let chan = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let n = Int(out.frameLength)

        var sum: Float = 0
        for i in 0..<n { sum += chan[i] * chan[i] }
        let rms = sqrtf(sum / Float(n))
        if tapBufferCount % 50 == 0 { DebugLog.log("AudioIO: tap #\(tapBufferCount) rms=\(rms)") }

        var emitLevel: Float? = nil
        lock.lock()
        levelEMA = 0.6 * levelEMA + 0.4 * rms
        let now = Date()
        if now.timeIntervalSince(lastLevelEmit) > 0.1 {
            lastLevelEmit = now
            emitLevel = levelEMA
        }
        lock.unlock()
        if let lvl = emitLevel, let cb = onLevel {
            DispatchQueue.main.async { cb(lvl) }
        }

        if muted { return }
        let isSpeech = rms > energyThreshold

        var fireStart = false
        var fireUtterance: Data? = nil

        lock.lock()
        let slice = UnsafeBufferPointer(start: chan, count: n)
        rollingSamples.append(contentsOf: slice)

        if isSpeech {
            silentFrames = 0
            if !inUtterance {
                speechFrames += 1
                if speechFrames >= minSpeechFrames {
                    inUtterance = true
                    fireStart = true
                }
            }
        } else {
            speechFrames = 0
            if inUtterance {
                silentFrames += 1
                if silentFrames >= trailingSilenceFrames {
                    let captured = rollingSamples
                    rollingSamples.removeAll(keepingCapacity: true)
                    inUtterance = false
                    silentFrames = 0
                    fireUtterance = AudioCapture.wav(from: captured, sampleRate: 16_000)
                }
            } else if rollingSamples.count > maxPreSpeechSamples {
                rollingSamples.removeFirst(rollingSamples.count - maxPreSpeechSamples)
            }
        }
        lock.unlock()

        if fireStart, let cb = onSpeechStart {
            DispatchQueue.main.async(execute: cb)
        }
        if let wav = fireUtterance, let cb = onUtterance {
            DispatchQueue.main.async { cb(wav) }
        }
    }

    // MARK: - PCM packing

    private static func makeBuffer(pcm16: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = pcm16.count / 2
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let dst = buffer.floatChannelData?[0] else { return nil }
        pcm16.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: Int16.self)
            let scale: Float = 1.0 / 32768.0
            for i in 0..<frameCount {
                dst[i] = Float(Int16(littleEndian: src[i])) * scale
            }
        }
        return buffer
    }
}
