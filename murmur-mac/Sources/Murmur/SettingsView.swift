import SwiftUI

/// Compact settings sheet reached from the menu bar. Mirrors the quick toggles
/// and exposes the server / model fields for people not on the default omlx
/// setup.
struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section("Activation") {
                Picker("Hold key", selection: $settings.trigger) {
                    ForEach(Settings.Trigger.allCases) { t in
                        Text(t.label).tag(t)
                    }
                }
                Text("Hold to dictate; release to insert. Double-tap to lock a hands-free session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Toggle("Clean up with local model", isOn: $settings.cleanupEnabled)
                Text("Runs the transcript through the chat model to fix punctuation and drop filler words. Adds latency; off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Sound feedback", isOn: $settings.soundFeedback)
            }

            Section("Local server (omlx)") {
                TextField("Server URL", text: $settings.serverURL)
                TextField("Speech model", text: $settings.sttModel)
                TextField("Cleanup model", text: $settings.cleanupModel)
                    .disabled(!settings.cleanupEnabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 360)
    }
}
