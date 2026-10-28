import ActivityKit
import AVFoundation
import UIKit

/// Holds the mic session for the keyboard. The keyboard can't record, so the first tap opens this app,
/// which turns the mic on in the foreground. It then keeps running in the background, and the keyboard
/// starts and stops captures through `Bridge` until the session times out.
@MainActor
final class VoiceSession: ObservableObject {
    static let shared = VoiceSession()
    static let maxRecording: Duration = .seconds(180)
    static let model = "claude-haiku-5-5"

    enum Phase: String { case off, ready, recording, working }

    @Published private(set) var phase = Phase.off
    @Published private(set) var message: String?
    @Published private(set) var sessionEndsAt: Date?
    @Published var openedFromKeyboard = false
    @Published var sessionMinutes = UserDefaults.standard.object(forKey: "sessionMinutes") as? Int ?? 15 {
        didSet {
            UserDefaults.standard.set(sessionMinutes, forKey: "sessionMinutes")
            if phase != .off { extendSession() }
        }
    }

    private let recorder = Recorder()
    private var parakeet: Parakeet?
    private var loading: Task<Parakeet, Error>?
    private var activity: Activity<VoiceActivityAttributes>?
    private var mode = Mode.dictate
    private var startedAt = Date()
    private var timeout: Task<Void, Never>?
    private var heartbeat: Timer?

    private init() {
        Bridge.observe(.startDictate) { VoiceSession.shared.startCapture(.dictate) }
        Bridge.observe(.startCompose) { VoiceSession.shared.startCapture(.compose) }
        Bridge.observe(.stop) { VoiceSession.shared.finishCapture() }
        Bridge.observe(.cancel) { VoiceSession.shared.cancelCapture() }
        Bridge.observe(.endSession) { VoiceSession.shared.endSession() }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            // A phone call or another recording app took the mic.
            guard (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { VoiceSession.shared.endSession() }
        }
        publish()
    }

    // MARK: Keyboard requests

    /// bensvoice://start?mode=dictate, opened by the keyboard when the mic is off.
    func handle(_ url: URL) {
        Log.write("opened \(url.absoluteString)")
        openedFromKeyboard = true
        let mode = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "mode" }?.value.flatMap(Mode.init(rawValue:))
        Task {
            if await openSession(), let mode { startCapture(mode) }
        }
    }

    /// Turns the mic on. Only works while the app is in the foreground; iOS refuses it from the background.
    @discardableResult
    func openSession() async -> Bool {
        if phase != .off { return true }
        do {
            guard ModelStore.shared.isReady else { throw fail("Download the speech model in BensVoice first.") }
            guard await AVAudioApplication.requestRecordPermission() else {
                throw fail("Microphone access is off. Turn it on in Settings › BensVoice.")
            }
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try audio.setActive(true)
            try recorder.start(capturing: false)
        } catch {
            Log.write("session failed: \(error.localizedDescription)")
            publish(message: error.localizedDescription)
            Bridge.defaults.set(Bridge.defaults.string(forKey: Bridge.requestKey), forKey: Bridge.resultForKey)
            Bridge.defaults.set("", forKey: Bridge.resultKey)
            return false
        }
        Log.write("session on")
        phase = .ready
        extendSession()
        startActivity()
        preloadModel()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { VoiceSession.shared.tick() }
        }
        tick()
        publish()
        return true
    }

    func startCapture(_ mode: Mode) {
        guard phase == .ready else {
            if phase == .off { publish(message: "The mic turned off. Tap again to turn it back on.") }
            return
        }
        self.mode = mode
        startedAt = Date()
        recorder.beginCapture()
        phase = .recording
        Log.write("recording \(mode.rawValue)")
        updateActivity(.listening)
        publish()
        timeout = Task {
            try? await Task.sleep(for: Self.maxRecording)
            if !Task.isCancelled { finishCapture() }
        }
    }

    func finishCapture() {
        guard phase == .recording else { return }
        timeout?.cancel()
        let samples = recorder.endCapture()
        let request = Bridge.defaults.string(forKey: Bridge.requestKey) ?? ""
        let context = Bridge.defaults.string(forKey: Bridge.contextKey) ?? ""
        let selected = Bridge.defaults.string(forKey: Bridge.selectedKey) ?? ""
        let mode = self.mode
        phase = .working
        Log.write("captured \(samples.count / 16_000) s")
        updateActivity(.transcribing)
        publish()

        let bg = UIApplication.shared.beginBackgroundTask(withName: "BensVoice")
        Task {
            defer { UIApplication.shared.endBackgroundTask(bg) }
            var text = ""
            var problem: String?
            do {
                let model = try await loadedModel()
                let heard = try await Task.detached(priority: .userInitiated) { try model.transcribe(samples) }.value
                guard !heard.isEmpty else { throw fail("Didn't catch anything. Try again.") }
                text = heard
                if mode == .compose {
                    updateActivity(.writing)
                    guard let key = Keychain.apiKey, !key.isEmpty else {
                        throw fail("Add your Claude API key in the BensVoice app to use Compose.")
                    }
                    var prompt = "App: iPhone\n"
                    if !selected.isEmpty {
                        prompt += "Selected text:\n<<<\n\(selected)\n>>>\n"
                    } else if !context.isEmpty {
                        prompt += "Text already typed before the cursor:\n<<<\n\(context)\n>>>\n"
                    }
                    prompt += "Instruction: \(heard)"
                    let modelID = Self.model
                    text = try await Task.detached(priority: .userInitiated) {
                        try Composer.viaAPI(prompt: prompt, key: key, model: modelID)
                    }.value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                Log.write("result \(text.count) chars")
            } catch {
                problem = error.localizedDescription
                Log.write("failed: \(error.localizedDescription)")
            }
            Bridge.defaults.set(text, forKey: Bridge.resultKey)
            Bridge.defaults.set(request, forKey: Bridge.resultForKey)
            if phase == .working { phase = .ready }
            extendSession()
            updateActivity(.ready)
            publish(message: problem)
        }
    }

    func cancelCapture() {
        guard phase == .recording else { return }
        timeout?.cancel()
        _ = recorder.endCapture()
        phase = .ready
        updateActivity(.ready)
        publish()
    }

    func stopButton() {
        if phase == .recording { finishCapture() } else { endSession() }
    }

    func endSession() {
        guard phase != .off else { return }
        timeout?.cancel()
        heartbeat?.invalidate()
        heartbeat = nil
        recorder.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .off
        sessionEndsAt = nil
        Bridge.defaults.set(0, forKey: Bridge.heartbeatKey)
        Log.write("session off")
        let finished = activity
        activity = nil
        Task { await finished?.end(nil, dismissalPolicy: .immediate) }
        publish()
    }

    private func tick() {
        Bridge.defaults.set(Date().timeIntervalSince1970, forKey: Bridge.heartbeatKey)
        if phase == .ready, let end = sessionEndsAt, Date() > end { endSession() }
    }

    private func extendSession() {
        sessionEndsAt = Date().addingTimeInterval(Double(sessionMinutes) * 60)
    }

    private func publish(message: String? = nil) {
        self.message = message
        let d = Bridge.defaults
        d.set(phase.rawValue, forKey: Bridge.phaseKey)
        d.set(mode.rawValue, forKey: Bridge.modeKey)
        d.set(startedAt.timeIntervalSince1970, forKey: Bridge.startedAtKey)
        d.set(message, forKey: Bridge.messageKey)
        Bridge.post(.changed)
    }

    // MARK: Live Activity

    private func startActivity() {
        for old in Activity<VoiceActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        let state = VoiceActivityAttributes.ContentState(phase: .ready, startedAt: Date())
        do {
            activity = try Activity.request(attributes: VoiceActivityAttributes(), content: .init(state: state, staleDate: nil))
        } catch {
            Log.write("Live Activity failed: \(error.localizedDescription)")
        }
    }

    private func updateActivity(_ phase: VoiceActivityAttributes.Phase) {
        let state = VoiceActivityAttributes.ContentState(phase: phase, startedAt: startedAt, mode: mode == .compose ? "Compose" : "Dictate")
        let current = activity
        Task { await current?.update(.init(state: state, staleDate: nil)) }
    }

    // MARK: Model

    /// Loads Parakeet in the background so the first transcription is quick.
    func preloadModel() {
        guard parakeet == nil, loading == nil, ModelStore.shared.isReady else { return }
        let dir = ModelStore.modelDir
        loading = Task.detached(priority: .userInitiated) {
            let p = try Parakeet(modelDir: dir)
            p.warmUp()
            return p
        }
    }

    private func loadedModel() async throws -> Parakeet {
        if let parakeet { return parakeet }
        preloadModel()
        guard let loading else { throw fail("Download the speech model in BensVoice first.") }
        do {
            let p = try await loading.value
            parakeet = p
            return p
        } catch {
            self.loading = nil
            throw error
        }
    }
}

func fail(_ message: String) -> NSError {
    NSError(domain: "BensVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
