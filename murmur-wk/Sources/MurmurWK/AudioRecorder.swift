import Foundation
import AVFoundation

/// Captures microphone audio via AVAudioEngine, downsamples to 16 kHz mono
/// Float32, and on stop() returns the raw sample buffer — exactly the format
/// whisper.cpp consumes (no WAV round-trip needed). While recording it emits a
/// smoothed RMS level (0...1) so the HUD can draw a live meter.
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

    /// 16 kHz, used by callers to reason about clip length.
    var sampleRate: Int { Int(targetSampleRate) }

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
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

    /// Stops capture and returns the recorded 16 kHz mono Float32 samples.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false
        lock.lock()
        let snap = samples
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
        DebugLog.log("AudioRecorder: stopped (\(snap.count) samples, \(String(format: "%.2f", Double(snap.count) / targetSampleRate))s)")
        return snap
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
}
