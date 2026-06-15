import SwiftUI

/// Create a brand-new voice from a text description. We send the description to
/// OmniVoice's instruct channel, capture the generated WAV, let the user
/// preview it, and (on save) freeze it as a reusable cloning voice.
@MainActor
final class VoiceDesignModel: ObservableObject {
    @Published var label = ""
    @Published var description = ""
    @Published var sampleText = kVoiceReferenceText
    @Published var isGenerating = false
    @Published var error: String? = nil
    @Published var hasPreview = false

    private(set) var lastWav: Data? = nil
    private let player = AudioPlayer()

    func generate(client: OmlxClient) async {
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !desc.isEmpty else { error = "Describe the voice first."; return }
        isGenerating = true; error = nil
        do {
            let wav = try await client.designVoice(
                description: desc,
                model: VoiceCatalog.omniModel,
                sampleText: sampleText.isEmpty ? kVoiceReferenceText : sampleText
            )
            lastWav = wav
            hasPreview = true
            try? player.play(wav: wav)
        } catch {
            self.error = "Design failed: \(error.localizedDescription)"
        }
        isGenerating = false
    }

    func playPreview() {
        if let wav = lastWav { try? player.play(wav: wav) }
    }

    func reset() {
        player.stop()
        label = ""; description = ""; sampleText = kVoiceReferenceText
        isGenerating = false; error = nil; hasPreview = false; lastWav = nil
    }
}

struct VoiceDesignSheet: View {
    @ObservedObject var catalog: VoiceCatalog
    let client: OmlxClient
    @StateObject private var model = VoiceDesignModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Design a voice")
                .font(.headline)
            Text("Describe the voice in plain language — age, gender, tone, accent, pace. OmniVoice generates a matching speaker you can reuse.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            TextField("Voice name (e.g. \"Gravelly Detective\")", text: $model.label)
                .textFieldStyle(.roundedBorder)

            Text("Description")
                .font(.caption).foregroundColor(.secondary)
            TextEditor(text: $model.description)
                .frame(height: 64)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            Text("Sample line it reads (becomes the cloning reference)")
                .font(.caption).foregroundColor(.secondary)
            TextEditor(text: $model.sampleText)
                .frame(height: 44)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            HStack {
                Button {
                    Task { await model.generate(client: client) }
                } label: {
                    if model.isGenerating {
                        ProgressView().controlSize(.small)
                        Text("  Generating…")
                    } else {
                        Label(model.hasPreview ? "Regenerate" : "Generate", systemImage: "waveform")
                    }
                }
                .disabled(model.isGenerating || model.description.trimmingCharacters(in: .whitespaces).isEmpty)

                if model.hasPreview {
                    Button { model.playPreview() } label: {
                        Label("Play", systemImage: "play.circle")
                    }
                }
                Spacer()
            }

            if let err = model.error {
                Text(err).foregroundColor(.red).font(.caption)
            }

            HStack {
                Button("Cancel") { model.reset(); dismiss() }
                Spacer()
                Button("Save voice") { save() }
                    .keyboardShortcut(.return)
                    .disabled(!model.hasPreview || model.label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func save() {
        guard let wav = model.lastWav else { return }
        do {
            _ = try catalog.addDesignedVoice(
                label: model.label.trimmingCharacters(in: .whitespaces),
                wav: wav,
                refText: model.sampleText.isEmpty ? kVoiceReferenceText : model.sampleText,
                description: model.description.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            model.reset()
            dismiss()
        } catch {
            model.error = "Save failed: \(error.localizedDescription)"
        }
    }
}
