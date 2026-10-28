import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct BensVoiceWidgets: WidgetBundle {
    var body: some Widget { VoiceLiveActivity() }
}

struct VoiceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceActivityAttributes.self) { context in
            HStack(spacing: 12) {
                PhaseIcon(phase: context.state.phase).font(.title2)
                Detail(state: context.state)
                Spacer(minLength: 0)
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
            .foregroundStyle(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: state.phase).font(.title2).padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.phase == .listening {
                        Text(state.startedAt, style: .timer).monospacedDigit().foregroundStyle(.red).frame(width: 48).padding(.trailing, 6)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Detail(state: state).padding(.horizontal, 6)
                }
            } compactLeading: {
                if state.phase == .listening {
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 9, height: 9)
                        Text("REC").font(.caption.weight(.bold)).foregroundStyle(.red)
                    }
                } else {
                    PhaseIcon(phase: state.phase)
                }
            } compactTrailing: {
                switch state.phase {
                case .listening: Text(state.startedAt, style: .timer).monospacedDigit().foregroundStyle(.red).frame(maxWidth: 40)
                case .ready: Text("On").font(.caption2).foregroundStyle(.green)
                case .transcribing, .writing: Text("…").font(.caption2)
                }
            } minimal: {
                if state.phase == .listening {
                    Circle().fill(.red).frame(width: 10, height: 10)
                } else {
                    PhaseIcon(phase: state.phase)
                }
            }
            .keylineTint(state.phase == .listening ? .red : .green)
        }
    }
}

private struct PhaseIcon: View {
    let phase: VoiceActivityAttributes.Phase

    var body: some View {
        switch phase {
        case .ready: Image(systemName: "mic.fill").foregroundStyle(.green)
        case .listening: Image(systemName: "record.circle.fill").foregroundStyle(.red)
        case .transcribing: Image(systemName: "text.bubble").foregroundStyle(.orange)
        case .writing: Image(systemName: "sparkles").foregroundStyle(.orange)
        }
    }
}

private struct Detail: View {
    let state: VoiceActivityAttributes.ContentState

    var body: some View {
        HStack {
            switch state.phase {
            case .ready: Text("Mic is on for the BensVoice keyboard").font(.callout)
            case .listening: Text("Recording · \(state.mode)").font(.callout)
            case .transcribing: Text("Transcribing…").font(.callout).foregroundStyle(.secondary)
            case .writing: Text("Claude is writing…").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if state.phase == .ready || state.phase == .listening {
                Button(intent: StopRecordingIntent()) {
                    Label(state.phase == .listening ? "Stop" : "Turn off", systemImage: state.phase == .listening ? "stop.fill" : "mic.slash.fill")
                }
                .tint(state.phase == .listening ? .red : .gray)
            }
        }
    }
}
