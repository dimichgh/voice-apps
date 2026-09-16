import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Whisper language codes for the omlx transcription endpoint.
let asrLanguages: [(name: String, code: String?)] = [
    ("Auto-detect", nil), ("English", "en"), ("Chinese", "zh"), ("Cantonese", "yue"),
    ("Japanese", "ja"), ("Korean", "ko"), ("Spanish", "es"),
]

@MainActor
final class CoverModel: ObservableObject {
    @Published var source: URL?
    @Published var asrLanguage = "Auto-detect"
    @Published var style = ""
    @Published var lyrics = ""
    @Published var abc = ""
    @Published var seed = 831001
    @Published var steps = 16

    @Published var transcribing = false
    @Published var transcriptionStatus = ""
    @Published var transcriptionIsError = false
    let transcribeJob = SongJob()
    let job = SongJob()

    /// SheetSage2 melody ABC (YuE2 server) and lyrics ASR (omlx) run in parallel.
    func transcribe() async {
        guard let source else { setStatus("Add a source song first.", error: true); return }
        transcribing = true
        setStatus("", error: false)
        defer { transcribing = false }

        let code = asrLanguages.first { $0.name == asrLanguage }?.code
        async let lyricsText: Result<String, Error> = {
            do {
                let wav = try await FFmpeg.asrWav(from: source)
                return .success(try await OmlxClient.shared.transcribe(wav: wav, language: code))
            } catch { return .failure(error) }
        }()
        let path = source.path
        let melody = await transcribeJob.run { try await ServerClient.shared.transcribe(path: path) }

        var problems: [String] = []
        if let score = melody?.abc, !score.isEmpty {
            abc = score
        } else {
            problems.append("Source analysis failed: \(transcribeJob.errorMessage ?? "SheetSage2 did not produce an ABC score for this audio.")")
        }
        switch await lyricsText {
        case .success(let text) where !text.isEmpty:
            lyrics = text
        case .success:
            problems.append("Whisper did not detect any lyrics in this audio.")
        case .failure(let error):
            problems.append("Lyrics transcription failed: \(error.localizedDescription)")
        }
        if problems.isEmpty {
            setStatus("Melody and lyrics are ready. Add section labels and review both before generating.", error: false)
        } else {
            setStatus(problems.joined(separator: "\n"), error: true)
        }
    }

    func generate() async {
        let score = abc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !score.isEmpty else {
            setStatus("Transcribe the source song or paste a melody-only ABC score first.", error: true)
            return
        }
        let (style, lyrics, steps, seed) = (self.style, self.lyrics, self.steps, self.seed)
        await job.run {
            try await ServerClient.shared.generate(style: style, lyrics: lyrics, cot: "melody", steps: steps, seed: seed, abc: score)
        }
    }

    private func setStatus(_ text: String, error: Bool) {
        transcriptionStatus = text
        transcriptionIsError = error
    }
}

struct CoverView: View {
    @ObservedObject var model: CoverModel

    var body: some View {
        Form {
            Section {
                DropZone(source: $model.source)
                Picker("Lyrics language", selection: $model.asrLanguage) {
                    ForEach(asrLanguages, id: \.name) { Text($0.name).tag($0.name) }
                }
                HStack(spacing: 10) {
                    Button { Task { await model.transcribe() } } label: {
                        Label("Transcribe Melody and Lyrics", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .disabled(model.source == nil || model.transcribing || model.job.isRunning)
                    if model.transcribing {
                        TranscribeProgress(job: model.transcribeJob)
                    }
                    Spacer()
                }
                if !model.transcriptionStatus.isEmpty {
                    Label(model.transcriptionStatus,
                          systemImage: model.transcriptionIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(model.transcriptionIsError ? .red : .secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Source Song")
            } footer: {
                Text("SheetSage2 reads the melody and Whisper (omlx) transcribes the words. Review both before generating.")
            }

            Section("New Style") {
                TextField("New style", text: $model.style,
                          prompt: Text("Jazz-funk, warm lead vocal, Rhodes piano, tight drums…"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(2...5)
            }

            Section {
                LyricsEditor(text: $model.lyrics, placeholder: "[Verse]\nLyrics aligned with the source song…", height: 220)
            } header: {
                Text("Lyrics")
            } footer: {
                Text("Use lyrics whose sections match the recording.")
            }

            Section {
                LyricsEditor(text: $model.abc, placeholder: "X:1\nT:Source melody\nM:4/4\nL:1/8\nK:C\n…",
                             height: 220, monospaced: true)
            } header: {
                Text("Melody Score (ABC)")
            } footer: {
                Text("Edit notes, bars or key before generating; the cover follows this melody.")
            }

            Section("Rendering") {
                QualityPicker(steps: $model.steps)
                SeedField(seed: $model.seed)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TranscribeProgress: View {
    @ObservedObject var job: SongJob

    var body: some View {
        ProgressView().controlSize(.small)
        Text(job.progressText.isEmpty ? "Transcribing…" : job.progressText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Drop target plus file importer for the source recording.
struct DropZone: View {
    @Binding var source: URL?
    @State private var targeted = false
    @State private var importing = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 12) {
            Image(systemName: source == nil ? "arrow.down.circle" : "waveform.circle.fill")
                .font(.system(size: 30))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(brandAccent)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(source?.lastPathComponent ?? "Drop a song here")
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(source.map { $0.deletingLastPathComponent().path(percentEncoded: false) } ?? "Any audio or video file")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Button(source == nil ? "Choose…" : "Replace…") { importing = true }
        }
        .padding(12)
        .background(targeted ? brandAccent.opacity(0.08) : Color.clear, in: shape)
        .overlay {
            shape.strokeBorder(targeted ? brandAccent : Color.secondary.opacity(0.35),
                               style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [5, 4]))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            source = url
            return true
        } isTargeted: { targeted = $0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie]) { result in
            if case .success(let url) = result { source = url }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source song")
    }
}
