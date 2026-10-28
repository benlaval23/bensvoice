import ActivityKit
import AppIntents
import Foundation

/// The Live Activity shown in the Dynamic Island while the mic session is on.
struct VoiceActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable { case ready, listening, transcribing, writing }

    struct ContentState: Codable, Hashable {
        var phase: Phase
        var startedAt: Date
        var mode = ""
    }
}

/// The button in the Live Activity: finishes a recording, or turns the mic off.
/// LiveActivityIntent always runs in the app's process, so the widget's copy never does anything.
struct StopRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop BensVoice"
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if APP
        await MainActor.run { VoiceSession.shared.stopButton() }
        #endif
        return .result()
    }
}
