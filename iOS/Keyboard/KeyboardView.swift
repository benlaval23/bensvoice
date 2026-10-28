import SwiftUI

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                HStack(spacing: 6) {
                    if model.phase != "off" {
                        Circle().fill(model.phase == "recording" ? Color.red : Color.green).frame(width: 7, height: 7)
                    }
                    Text(model.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .padding(.horizontal, 40)

                HStack {
                    if model.showsGlobe {
                        Button { model.controller?.nextKeyboard() } label: {
                            Image(systemName: "globe").font(.title3).foregroundStyle(.primary)
                        }
                        .accessibilityLabel("Next keyboard")
                    }
                    Spacer()
                    if model.phase == "recording" {
                        Button { model.cancel() } label: {
                            Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Cancel recording")
                    }
                }
            }
            .frame(height: 34)
            .padding(.horizontal, 4)

            HStack(spacing: 8) {
                ModeButton(model: model, mode: .dictate, label: "Dictate", icon: "mic.fill")
                ModeButton(model: model, mode: .compose, label: "Compose", icon: "square.and.pencil")
            }
            .frame(maxHeight: .infinity)
        }
        .padding(6)
    }
}

private struct ModeButton: View {
    @ObservedObject var model: KeyboardModel
    @Environment(\.colorScheme) private var scheme
    let mode: Mode
    let label: String
    let icon: String

    var body: some View {
        let mine = model.mode == mode
        let recording = model.phase == "recording" && mine
        let working = model.phase == "working" && mine
        let busy = (model.phase == "recording" || model.phase == "working") && !mine
        Button { model.tap(mode) } label: {
            VStack(spacing: 6) {
                if recording {
                    Image(systemName: "stop.fill").font(.system(size: 30))
                    Text(model.startedAt, style: .timer).font(.subheadline.monospacedDigit())
                } else if working {
                    ProgressView().controlSize(.large).tint(scheme == .dark ? .white : .primary)
                } else {
                    Image(systemName: icon).font(.system(size: 34))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(recording ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(recording ? Color.red : Color.white.opacity(scheme == .dark ? 0.22 : 1))
                    .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.4 : 1)
        .accessibilityLabel(recording ? "Finish \(label.lowercased())" : label)
    }
}
