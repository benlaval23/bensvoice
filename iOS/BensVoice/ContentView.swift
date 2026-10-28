import AVFoundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var session: VoiceSession
    @EnvironmentObject private var models: ModelStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var apiKey = Keychain.apiKey ?? ""
    @State private var micAllowed = AVAudioApplication.shared.recordPermission == .granted

    var body: some View {
        NavigationStack {
            Form {
                if session.phase != .off {
                    Section {
                        HStack {
                            Circle().fill(session.phase == .recording ? .red : .green).frame(width: 10, height: 10)
                            Text(session.phase == .recording ? "Recording" : session.phase == .working ? "Working…" : "Mic is on")
                            Spacer()
                            Button("Turn off") { session.endSession() }
                        }
                    }
                }

                Section {
                    if models.isReady {
                        Label("Speech model ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if let progress = models.progress {
                        ProgressView(value: progress) { Text("Downloading speech model…") }
                    } else {
                        Button("Download speech model (450 MB)") { Task { await models.download() } }
                        if let error = models.error { Text(error).font(.footnote).foregroundStyle(.red) }
                    }
                    if micAllowed {
                        Label("Microphone allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow microphone") {
                            Task { micAllowed = await AVAudioApplication.requestRecordPermission() }
                        }
                    }
                    Button("Turn on the keyboard") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } header: {
                    Text("Setup")
                } footer: {
                    Text("In Settings, tap Keyboards, then turn on BensVoice and Allow Full Access. Then tap 🌐 on any keyboard to switch to it.")
                }

                Section {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Keychain.apiKey = apiKey }
                    Button("Save") { Keychain.apiKey = apiKey }
                        .disabled(apiKey == (Keychain.apiKey ?? ""))
                } header: {
                    Text("Claude API key")
                } footer: {
                    Text("For Compose. Dictate works offline.")
                }

                Section {
                    Picker("Keep mic on for", selection: $session.sessionMinutes) {
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("1 hour").tag(60)
                        Text("4 hours").tag(240)
                    }
                } footer: {
                    Text("After the first tap, the mic stays on this long so the keyboard works without opening BensVoice again.")
                }
            }
            .navigationTitle("BensVoice")
            .task { session.preloadModel() }
        }
        .overlay {
            if session.openedFromKeyboard {
                GoBackView(session: session) { session.openedFromKeyboard = false }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.openedFromKeyboard = false }
        }
    }
}

/// Shown when the keyboard opened the app to turn the mic on. iOS has no API to return to the
/// previous app, so this points at the "◀ App" link iOS puts in the top-left corner.
private struct GoBackView: View {
    @ObservedObject var session: VoiceSession
    let dismiss: () -> Void

    var body: some View {
        let failed = session.phase == .off && session.message != nil
        VStack(spacing: 0) {
            if !failed {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.tint)
                    Text("Tap ◀ up here to go back")
                        .font(.title3.weight(.semibold))
                        .padding(.top, 14)
                    Spacer()
                }
                .padding(.leading, 4)
            }
            Spacer()
            Image(systemName: failed ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 54))
                .foregroundStyle(.white)
                .frame(width: 120, height: 120)
                .background(Circle().fill(failed ? .gray : session.phase == .recording ? .red : .green))
            Text(failed ? "Couldn't turn the mic on" : session.phase == .recording ? "Listening" : "Mic is on")
                .font(.title.bold())
                .padding(.top, 20)
            Text(failed ? session.message ?? "" : "Go back and keep talking. Tap the button in the keyboard again to finish.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer()
            Spacer()
            Button(failed ? "Close" : "Stay in BensVoice", action: dismiss)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
