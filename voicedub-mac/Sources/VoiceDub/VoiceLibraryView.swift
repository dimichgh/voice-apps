import SwiftUI

/// Tab 1 — manage voices (record / design / delete) and a text→speech
/// playground that speaks any text in the selected voice.
struct VoiceLibraryView: View {
    @ObservedObject var catalog: VoiceCatalog
    @EnvironmentObject var app: AppModel

    @State private var showRecord = false
    @State private var showDesign = false

    // Playground state
    @State private var text = "Hello! This is the voice you selected, reading whatever you type here."
    @State private var speaking = false
    @State private var error: String? = nil

    var body: some View {
        HSplitView {
            voiceList
                .frame(minWidth: 240, idealWidth: 280)
            playground
                .frame(minWidth: 360)
        }
        .sheet(isPresented: $showRecord) {
            VoiceRecorderSheet(catalog: catalog, client: app.client)
        }
        .sheet(isPresented: $showDesign) {
            VoiceDesignSheet(catalog: catalog, client: app.client)
        }
    }

    private var voiceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Voices").font(.headline)
                Spacer()
                Button { showRecord = true } label: { Image(systemName: "mic.circle") }
                    .help("Record a voice")
                Button { showDesign = true } label: { Image(systemName: "wand.and.stars") }
                    .help("Design a voice from a description")
            }
            .padding(10)

            List(selection: Binding(
                get: { catalog.current.id },
                set: { id in if let v = catalog.voices.first(where: { $0.id == id }) { catalog.current = v } }
            )) {
                ForEach(catalog.voices) { v in
                    HStack {
                        Image(systemName: icon(for: v))
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(v.label)
                            Text(subtitle(for: v)).font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        if case .omniCloned = v.kind {
                            Button { catalog.delete(v) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Delete voice")
                        }
                    }
                    .tag(v.id)
                }
            }
        }
    }

    private var playground: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Text → Speech").font(.headline)
            Text("Speaking as: \(catalog.current.label)")
                .font(.subheadline).foregroundColor(.secondary)

            TextEditor(text: $text)
                .font(.body)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            HStack {
                Button {
                    Task { await speak() }
                } label: {
                    if speaking {
                        ProgressView().controlSize(.small); Text("  Synthesizing…")
                    } else {
                        Label("Speak", systemImage: "play.fill")
                    }
                }
                .controlSize(.large)
                .disabled(speaking || text.trimmingCharacters(in: .whitespaces).isEmpty)

                Button { app.player.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                Spacer()
            }

            if let error { Text(error).foregroundColor(.red).font(.caption) }
            Spacer()
        }
        .padding(14)
    }

    private func speak() async {
        speaking = true; error = nil
        do {
            let wav = try await app.client.tts(text: text, voice: catalog.current)
            try app.player.play(wav: wav)
        } catch {
            self.error = error.localizedDescription
        }
        speaking = false
    }

    private func icon(for v: VoicePreset) -> String {
        switch v.kind {
        case .plainTTS:   return "speaker.wave.2"
        case .kokoro:     return "person.wave.2"
        case .omniCloned: return "waveform.circle"
        }
    }

    private func subtitle(for v: VoicePreset) -> String {
        switch v.kind {
        case .plainTTS:                       return "zero-shot"
        case .kokoro:                         return "preset"
        case .omniCloned(_, _, let desc):     return desc
        }
    }
}
