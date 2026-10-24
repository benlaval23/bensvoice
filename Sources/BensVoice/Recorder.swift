import AVFoundation

/// Captures the default mic as 16 kHz mono Float32. The engine only runs while recording.
final class Recorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw NSError(domain: "BensVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported mic format \(format)"])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / format.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard let ch = out.floatChannelData?[0] else { return }
            self.lock.lock()
            self.samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
            self.lock.unlock()
        }
        engine.prepare()
        try engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); defer { lock.unlock() }
        let result = samples
        samples = []
        return result
    }
}
