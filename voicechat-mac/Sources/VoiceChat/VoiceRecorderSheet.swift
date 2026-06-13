import SwiftUI

/// Reference sentence the user reads aloud. OmniVoice clones better when
/// ref_text is a faithful transcript of ref_audio, so we display this verbatim
/// and store it alongside the WAV in the catalog.
let kVoiceRecorderReferenceText = """
Hello, this is a sample of my voice. \
I'm here to help you with whatever you need.
"""

@MainActor
final class VoiceRecorderModel: ObservableObject {
    @Published var isRecording = false
    @Published var label: String = ""
    @Published var error: String? = nil
    @Published var hasRecording = false

    private let capture = AudioCapture()
    private(set) var lastWav: Data? = nil

    func start() {
        do {
            try capture.start()
            isRecording = true
            error = nil
            hasRecording = false
            lastWav = nil
        } catch {
            self.error = "Mic error: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRecording else { return }
        lastWav = capture.stop()
        isRecording = false
        hasRecording = (lastWav?.count ?? 0) > 44 // > WAV header alone
    }

    func reset() {
        if isRecording { _ = capture.stop() }
        isRecording = false
        hasRecording = false
        lastWav = nil
        label = ""
        error = nil
    }
}

struct VoiceRecorderSheet: View {
    @ObservedObject var catalog: VoiceCatalog
    @StateObject private var rec = VoiceRecorderModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Record a voice sample")
                .font(.headline)

            Text("Read the sentence below in your normal voice. It becomes the reference OmniVoice clones from — keep the take clean and consistent.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("\u{201C}\(kVoiceRecorderReferenceText)\u{201D}")
                .italic()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)

            HStack {
                Button(action: {
                    if rec.isRecording { rec.stop() } else { rec.start() }
                }) {
                    Label(
                        rec.isRecording ? "Stop" : (rec.hasRecording ? "Re-record" : "Record"),
                        systemImage: rec.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                    .frame(minWidth: 110)
                }
                .controlSize(.large)
                .tint(rec.isRecording ? .red : .accentColor)

                if rec.hasRecording {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Captured \(rec.lastWav?.count ?? 0) bytes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            TextField("Voice name (e.g. \"My Voice\")", text: $rec.label)
                .textFieldStyle(.roundedBorder)

            if let err = rec.error {
                Text(err).foregroundColor(.red).font(.caption)
            }

            HStack {
                Button("Cancel") {
                    rec.reset()
                    dismiss()
                }
                Spacer()
                Button("Save voice") {
                    save()
                }
                .keyboardShortcut(.return)
                .disabled(!rec.hasRecording || rec.label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func save() {
        guard let wav = rec.lastWav else { return }
        do {
            _ = try catalog.addRecordedVoice(
                label: rec.label.trimmingCharacters(in: .whitespaces),
                wav: wav,
                refText: kVoiceRecorderReferenceText
            )
            rec.reset()
            dismiss()
        } catch {
            rec.error = "Save failed: \(error.localizedDescription)"
        }
    }
}
