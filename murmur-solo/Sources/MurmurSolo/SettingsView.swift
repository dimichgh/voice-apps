import SwiftUI

/// Compact settings for Murmur Solo. No server or model fields — transcription
/// is on-device with the bundled model.
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
                .onChange(of: settings.trigger) { _ in Permissions.triggerChanged = true }
                Text("Hold to dictate; release to insert. Double-tap to lock a hands-free session.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Picker("Language", selection: $settings.language) {
                    ForEach(Settings.languages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                Text("Runs entirely on-device (whisper.cpp, large-v3-turbo). No network, no server.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Sound feedback", isOn: $settings.soundFeedback)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 300)
    }
}
