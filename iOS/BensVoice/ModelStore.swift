import Foundation

/// Downloads the Parakeet CoreML model (~450 MB) from Hugging Face on first launch.
@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()
    static let repo = "FluidInference/parakeet-tdt-0.6b-v2-coreml"
    nonisolated static let modelDir = URL.applicationSupportDirectory.appending(path: "parakeet-tdt-0.6b-v2-coreml")
    private static let parts = ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc"]
    private static let marker = modelDir.appending(path: ".complete")

    @Published private(set) var isReady = FileManager.default.fileExists(atPath: ModelStore.marker.path)
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?

    private struct Entry: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    func download() async {
        guard progress == nil, !isReady else { return }
        error = nil
        progress = 0
        defer { progress = nil }
        do {
            var files: [Entry] = []
            for part in Self.parts {
                let url = URL(string: "https://huggingface.co/api/models/\(Self.repo)/tree/main/\(part)?recursive=true")!
                let (data, _) = try await URLSession.shared.data(from: url)
                files += try JSONDecoder().decode([Entry].self, from: data).filter { $0.type == "file" }
            }
            files.append(Entry(type: "file", path: "parakeet_vocab.json", size: nil))

            let total = Double(files.compactMap(\.size).reduce(0, +))
            var done: Int64 = 0
            for file in files {
                let dest = Self.modelDir.appending(path: file.path)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let base = done
                try await Self.fetch(URL(string: "https://huggingface.co/\(Self.repo)/resolve/main/\(file.path)")!, to: dest) { bytes in
                    Task { @MainActor in self.progress = total > 0 ? Double(base + bytes) / total : nil }
                }
                done += file.size ?? 0
            }

            var dir = Self.modelDir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try dir.setResourceValues(values)
            FileManager.default.createFile(atPath: Self.marker.path, contents: nil)
            isReady = true
            VoiceSession.shared.preloadModel()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private nonisolated static func fetch(_ url: URL, to dest: URL, onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var observation: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                observation?.invalidate()
                if let error { return cont.resume(throwing: error) }
                guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return cont.resume(throwing: fail("Download failed for \(url.lastPathComponent)"))
                }
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.completedUnitCount) { p, _ in onProgress(p.completedUnitCount) }
            task.resume()
        }
    }
}
