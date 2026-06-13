import Foundation
import AVFoundation

/// Captures microphone audio via AVAudioEngine, downsamples to 16 kHz mono,
/// and on stop() returns a PCM16 WAV blob ready to POST to omlx. While
/// recording it emits a smoothed RMS level (0...1) so the HUD can draw a live
/// "I'm hearing you" meter.
///
/// (Adapted from voicechat-mac's AudioCapture; the level metering is folded in
/// here so Murmur stays a standalone package with no shared dependency.)
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let targetSampleRate: Double = 16_000
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    /// Smoothed level in 0...1, delivered on the main queue ~30x/sec.
    var onLevel: ((Float) -> Void)?
    private var levelEMA: Float = 0
    private var lastLevelEmit = Date.distantPast

    private(set) var isRecording = false

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // Guard against a dead input device (0ch/0Hz) — installing a tap on it
        // crashes inside CoreAudio rather than throwing.
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw NSError(domain: "AudioRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No usable microphone input device"])
        }
        guard let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot build target audio format"])
        }
        outputFormat = outFmt
        converter = AVAudioConverter(from: inputFormat, to: outFmt)

        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        levelEMA = 0

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
        DebugLog.log("AudioRecorder: started (input \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch)")
    }

    /// Stops capture and returns the recorded audio as a 16 kHz mono PCM16 WAV.
    @discardableResult
    func stop() -> Data {
        guard isRecording else { return Data() }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false
        lock.lock()
        let snap = samples
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
        DebugLog.log("AudioRecorder: stopped (\(snap.count) samples, \(String(format: "%.2f", Double(snap.count) / targetSampleRate))s)")
        return Self.wav(from: snap, sampleRate: Int(targetSampleRate))
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let outFmt = outputFormat else { return }
        let ratio = targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: capacity) else { return }

        var err: NSError?
        var providedOnce = false
        converter.convert(to: out, error: &err) { _, status in
            if providedOnce { status.pointee = .noDataNow; return nil }
            providedOnce = true
            status.pointee = .haveData
            return buffer
        }
        if err != nil { return }
        guard let chan = out.floatChannelData?[0] else { return }
        let n = Int(out.frameLength)
        if n == 0 { return }
        let slice = UnsafeBufferPointer(start: chan, count: n)

        lock.lock()
        samples.append(contentsOf: slice)
        lock.unlock()

        emitLevel(slice)
    }

    /// RMS → perceptual level with attack/decay smoothing. Fast attack so the
    /// bar jumps to your voice; slower decay so it doesn't strobe.
    private func emitLevel(_ slice: UnsafeBufferPointer<Float>) {
        var sumSq: Float = 0
        for s in slice { sumSq += s * s }
        let rms = sqrt(sumSq / Float(max(slice.count, 1)))
        // Map RMS (~0...0.3 for speech) onto 0...1 with a gentle gain curve.
        let scaled = min(1, rms * 8)
        let perceptual = pow(scaled, 0.6)
        let attack: Float = 0.5, decay: Float = 0.12
        let k = perceptual > levelEMA ? attack : decay
        levelEMA += (perceptual - levelEMA) * k

        let now = Date()
        guard now.timeIntervalSince(lastLevelEmit) > 0.033 else { return }
        lastLevelEmit = now
        let value = levelEMA
        DispatchQueue.main.async { [weak self] in self?.onLevel?(value) }
    }

    // MARK: - WAV packing

    static func wav(from floats: [Float], sampleRate: Int) -> Data {
        var pcm = Data(capacity: floats.count * 2)
        for f in floats {
            let clipped = max(-1.0, min(1.0, f))
            let i = Int16(clipped * 32_767)
            var le = i.littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
        }
        return wrapWAV(pcm: pcm, sampleRate: sampleRate, channels: 1, bitsPerSample: 16)
    }

    private static func wrapWAV(pcm: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        var d = Data()
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataLen = pcm.count

        d.append("RIFF".data(using: .ascii)!)
        d.append(UInt32(36 + dataLen).leBytes)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        d.append(UInt32(16).leBytes)
        d.append(UInt16(1).leBytes)                            // PCM
        d.append(UInt16(channels).leBytes)
        d.append(UInt32(sampleRate).leBytes)
        d.append(UInt32(byteRate).leBytes)
        d.append(UInt16(blockAlign).leBytes)
        d.append(UInt16(bitsPerSample).leBytes)
        d.append("data".data(using: .ascii)!)
        d.append(UInt32(dataLen).leBytes)
        d.append(pcm)
        return d
    }
}

private extension FixedWidthInteger {
    var leBytes: Data {
        var v = self.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
}
