import SwiftUI

@main
struct BensVoiceApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(VoiceSession.shared)
                .environmentObject(ModelStore.shared)
                .onOpenURL { VoiceSession.shared.handle($0) }
        }
    }
}
