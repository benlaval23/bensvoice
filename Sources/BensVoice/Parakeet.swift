import CoreML
import Foundation

/// Minimal Parakeet TDT greedy decoder over the CoreML models FluidVoice/FluidAudio downloads.
final class Parakeet {
    #if os(macOS)
    static let defaultModelDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2-coreml")

    static var configuredModelDir: URL {
        Composer.loadConfig().modelDir.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) } ?? defaultModelDir
    }
    #endif

    private let sampleRate = 16_000
    private let windowSamples = 240_000 // 15 s, fixed by the models
    private let blankId: Int32 = 1024
    private let maxSymbolsPerFrame = 10
    private let hiddenSize = 640

    private let preprocessor: MLModel
    private let encoder: MLModel
    private let decoder: MLModel
    private let joint: MLModel
    private let vocab: [Int: String]

    init(modelDir: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        func load(_ name: String) throws -> MLModel {
            try MLModel(contentsOf: modelDir.appendingPathComponent("\(name).mlmodelc"), configuration: config)
        }
        preprocessor = try load("Preprocessor")
        encoder = try load("Encoder")
        decoder = try load("Decoder")
        joint = try load("JointDecision")

        let data = try Data(contentsOf: modelDir.appendingPathComponent("parakeet_vocab.json"))
        let raw = try JSONDecoder().decode([String: String].self, from: data)
        vocab = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    func warmUp() {
        _ = try? transcribe([Float](repeating: 0, count: sampleRate))
    }

    func transcribe(_ samples: [Float]) throws -> String {
        guard samples.count > sampleRate / 4 else { return "" }
        var state = try DecoderState(model: decoder, blank: blankId, hidden: hiddenSize)
        var tokens: [Int32] = []
        var offset = 0
        while offset < samples.count {
            let end = chunkEnd(samples, from: offset)
            tokens += try decodeWindow(Array(samples[offset..<end]), state: &state)
            offset = end
        }
        let text = tokens.compactMap { vocab[Int($0)] }.joined()
        return text.replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cut long audio at the quietest 100 ms in the last 3 s of each 15 s window.
    private func chunkEnd(_ s: [Float], from start: Int) -> Int {
        let hardEnd = start + windowSamples
        if hardEnd >= s.count { return s.count }
        let step = sampleRate / 10
        var best = hardEnd, bestEnergy = Float.greatestFiniteMagnitude
        var i = hardEnd - 3 * sampleRate
        while i + step <= hardEnd {
            var e: Float = 0
            for j in i..<(i + step) { e += s[j] * s[j] }
            if e < bestEnergy { bestEnergy = e; best = i + step / 2 }
            i += step
        }
        return best
    }

    private func decodeWindow(_ chunk: [Float], state: inout DecoderState) throws -> [Int32] {
        let audio = try MLMultiArray(shape: [1, NSNumber(value: windowSamples)], dataType: .float32)
        let ap = audio.dataPointer.bindMemory(to: Float.self, capacity: windowSamples)
        ap.initialize(repeating: 0, count: windowSamples)
        chunk.withUnsafeBufferPointer { ap.update(from: $0.baseAddress!, count: chunk.count) }
        let pre = try preprocessor.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": audio,
            "audio_length": try int32Array([Int32(chunk.count)]),
        ]))
        let enc = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "mel": pre.featureValue(for: "mel")!.multiArrayValue!,
            "mel_length": pre.featureValue(for: "mel_length")!.multiArrayValue!,
        ]))
        let encOut = enc.featureValue(for: "encoder")!.multiArrayValue!
        let encLen = min(enc.featureValue(for: "encoder_length")!.multiArrayValue![0].intValue, encOut.shape[2].intValue)

        let dim = encOut.shape[1].intValue
        let s1 = encOut.strides[1].intValue, s2 = encOut.strides[2].intValue
        let step = try MLMultiArray(shape: [1, NSNumber(value: dim), 1], dataType: .float32)
        let sp = step.dataPointer.bindMemory(to: Float.self, capacity: dim)

        var out: [Int32] = []
        var t = 0, symbols = 0
        while t < encLen {
            copyFrame(encOut, t: t, dim: dim, s1: s1, s2: s2, into: sp)
            let j = try joint.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "encoder_step": step,
                "decoder_step": state.output,
            ]))
            let token = j.featureValue(for: "token_id")!.multiArrayValue![0].int32Value
            var duration = j.featureValue(for: "duration")!.multiArrayValue![0].intValue
            if token < blankId {
                out.append(token)
                try state.advance(with: token)
                symbols += 1
            }
            if duration == 0 && (token >= blankId || symbols >= maxSymbolsPerFrame) { duration = 1 }
            if duration > 0 { symbols = 0 }
            t += duration
        }
        return out
    }

    private func copyFrame(_ a: MLMultiArray, t: Int, dim: Int, s1: Int, s2: Int, into dst: UnsafeMutablePointer<Float>) {
        switch a.dataType {
        case .float16:
            let p = a.dataPointer.bindMemory(to: Float16.self, capacity: a.count)
            for d in 0..<dim { dst[d] = Float(p[d * s1 + t * s2]) }
        default:
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: a.count)
            for d in 0..<dim { dst[d] = p[d * s1 + t * s2] }
        }
    }
}

/// LSTM prediction-network state, carried across 15 s windows.
private struct DecoderState {
    let model: MLModel
    var h: MLMultiArray
    var c: MLMultiArray
    var output: MLMultiArray

    init(model: MLModel, blank: Int32, hidden: Int) throws {
        self.model = model
        h = try MLMultiArray(shape: [2, 1, NSNumber(value: hidden)], dataType: .float32)
        c = try MLMultiArray(shape: [2, 1, NSNumber(value: hidden)], dataType: .float32)
        for a in [h, c] { a.dataPointer.bindMemory(to: Float.self, capacity: a.count).initialize(repeating: 0, count: a.count) }
        output = h // placeholder, replaced below
        try advance(with: blank)
    }

    mutating func advance(with token: Int32) throws {
        let r = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "targets": try int32Array([token], shape: [1, 1]),
            "target_length": try int32Array([1]),
            "h_in": h,
            "c_in": c,
        ]))
        output = r.featureValue(for: "decoder")!.multiArrayValue!
        h = r.featureValue(for: "h_out")!.multiArrayValue!
        c = r.featureValue(for: "c_out")!.multiArrayValue!
    }
}

private func int32Array(_ values: [Int32], shape: [NSNumber]? = nil) throws -> MLMultiArray {
    let a = try MLMultiArray(shape: shape ?? [NSNumber(value: values.count)], dataType: .int32)
    for (i, v) in values.enumerated() { a[i] = NSNumber(value: v) }
    return a
}
