import Foundation
import AVFoundation

/// Captures microphone audio via AVAudioEngine, downsamples to 16 kHz mono
/// Float32, and returns a PCM16 WAV blob on stop().
final class AudioCapture {
    private let engine = AVAudioEngine()
    private let targetSampleRate: Double = 16_000
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot build target audio format"])
        }
        outputFormat = outFmt
        converter = AVAudioConverter(from: inputFormat, to: outFmt)

        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() -> Data {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        lock.lock()
        let snap = samples
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
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
            if providedOnce {
                status.pointee = .noDataNow
                return nil
            }
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
