import SwiftUI
import UniformTypeIdentifiers

/// Default sentence to read when recording from scratch. OmniVoice clones best
/// when the transcript faithfully matches the audio, so the field stays editable
/// — read a custom line, or import a clip and type what it actually says.
let kVoiceReferenceText = """
Hello, this is a sample of my voice. \
I'm here to help you with whatever you need.
"""

@MainActor
final class VoiceRecorderModel: ObservableObject {
    @Published var isRecording = false
    @Published var label: String = ""
    @Published var referenceText: String = kVoiceReferenceText
    @Published var error: String? = nil
    @Published var hasAudio = false
    @Published var importedName: String? = nil
    @Published var isImporting = false
    @Published var importStatus: String? = nil
    @Published var notice: String? = nil   // non-error guidance (e.g. trimmed)

    private let capture = AudioCapture()
    private(set) var lastWav: Data? = nil

    /// Description stored on the saved voice — distinguishes recorded vs imported.
    var sourceDescription: String {
        if let name = importedName { return "imported: \(name)" }
        return "user-recorded sample"
    }

    func start() {
        do {
            try capture.start()
            isRecording = true
            error = nil
            notice = nil
            hasAudio = false
            lastWav = nil
            importedName = nil
        } catch {
            self.error = "Mic error: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRecording else { return }
        lastWav = capture.stop()
        isRecording = false
        importedName = nil
        hasAudio = (lastWav?.count ?? 0) > 44 // > WAV header alone
        // 16 kHz mono PCM16 ⇒ 32000 bytes/sec. Recordings aren't auto-trimmed
        // (the transcript is yours), but past ~10s the extra audio leaks into
        // output, so warn to keep it short with a matching transcript.
        let seconds = Double((lastWav?.count ?? 44) - 44) / 32000.0
        notice = seconds > FFmpeg.maxRefSeconds + 1.0
            ? "Recording is \(Int(seconds))s — OmniVoice only uses ~\(Int(FFmpeg.maxRefSeconds))s. Keep it short or the extra audio can leak into output."
            : nil
    }

    /// Import an existing audio (or video) file: transcode it to the reference
    /// WAV format and auto-transcribe it so the transcript is prefilled. The
    /// user reviews/corrects the text before saving (Whisper is good but not
    /// infallible). Transcription failure is non-fatal — type it manually.
    func importAudio(_ url: URL, client: OmlxClient) async {
        if isRecording { _ = capture.stop(); isRecording = false }
        isImporting = true; error = nil; notice = nil
        importStatus = "Converting…"
        do {
            let srcDur = (try? await FFmpeg.duration(of: url)) ?? 0
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("vd-import-\(UUID().uuidString).wav")
            // Cap to the clone window so the (capped) audio matches the
            // transcript we make from it — otherwise the tail leaks into output.
            try await FFmpeg.convertToRefAudio(from: url, to: tmp,
                                               maxSeconds: FFmpeg.maxRefSeconds)
            let data = try Data(contentsOf: tmp)
            try? FileManager.default.removeItem(at: tmp)
            lastWav = data
            hasAudio = data.count > 44
            importedName = url.lastPathComponent
            if srcDur > FFmpeg.maxRefSeconds + 0.5 {
                notice = "Clip is \(Int(srcDur))s — using the first \(Int(FFmpeg.maxRefSeconds))s (longer references leak into output)."
            }
            if label.trimmingCharacters(in: .whitespaces).isEmpty {
                label = url.deletingPathExtension().lastPathComponent
            }
        } catch {
            self.error = "Import failed: \(error.localizedDescription)"
            importStatus = nil; isImporting = false
            return
        }
        // The transcript MUST match this imported audio (a mismatched ref_text
        // makes OmniVoice speak the reference before the target). So clear any
        // stale/default text first and only accept a real transcription — on
        // failure leave it empty so Save stays blocked until the user types it.
        referenceText = ""
        importStatus = "Transcribing…"
        do {
            if let data = lastWav {
                let tr = try await client.transcribe(wav: data, language: nil)
                let text = tr.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    self.error = "Auto-transcription returned nothing — type the transcript (it must match the clip) before saving."
                } else {
                    referenceText = text
                }
            }
        } catch {
            self.error = "Auto-transcription failed — type the transcript (it must match the clip) before saving. (\(error.localizedDescription))"
        }
        importStatus = nil
        isImporting = false
    }

    func reset() {
        if isRecording { _ = capture.stop() }
        isRecording = false
        hasAudio = false
        lastWav = nil
        label = ""
        referenceText = kVoiceReferenceText
        importedName = nil
        isImporting = false
        importStatus = nil
        notice = nil
        error = nil
    }
}

struct VoiceRecorderSheet: View {
    @ObservedObject var catalog: VoiceCatalog
    let client: OmlxClient
    @StateObject private var rec = VoiceRecorderModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a voice")
                .font(.headline)

            Text("Record yourself reading the transcript below, or import an existing clip — it's auto-transcribed so you can just review (and fix any errors) before saving. OmniVoice clones from this audio + transcript pair.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("Transcript (must match the audio)")
                .font(.caption).foregroundColor(.secondary)
            TextEditor(text: $rec.referenceText)
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            HStack(spacing: 10) {
                Button(action: {
                    if rec.isRecording { rec.stop() } else { rec.start() }
                }) {
                    Label(
                        rec.isRecording ? "Stop" : (rec.hasAudio && rec.importedName == nil ? "Re-record" : "Record"),
                        systemImage: rec.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                    .frame(minWidth: 100)
                }
                .controlSize(.large)
                .tint(rec.isRecording ? .red : .accentColor)

                Button { importAudio() } label: {
                    Label("Import audio…", systemImage: "square.and.arrow.down")
                }
                .disabled(rec.isRecording || rec.isImporting)

                if rec.isImporting {
                    ProgressView().controlSize(.small)
                    Text(rec.importStatus ?? "Importing…")
                        .font(.caption).foregroundColor(.secondary)
                } else if rec.hasAudio {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(rec.importedName ?? "Captured \(rec.lastWav?.count ?? 0) bytes")
                        .font(.caption).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }

            Label("OmniVoice clones from ~\(Int(FFmpeg.maxRefSeconds))s — longer clips are capped to the first \(Int(FFmpeg.maxRefSeconds))s, then transcribed.",
                  systemImage: "scissors")
                .font(.caption).foregroundColor(.secondary)

            TextField("Voice name (e.g. \"My Voice\")", text: $rec.label)
                .textFieldStyle(.roundedBorder)

            if let err = rec.error {
                Text(err).foregroundColor(.red).font(.caption)
            }
            if let notice = rec.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange).font(.caption)
            }

            HStack {
                Button("Cancel") {
                    rec.reset()
                    dismiss()
                }
                Spacer()
                Button("Save voice") { save() }
                    .keyboardShortcut(.return)
                    .disabled(!rec.hasAudio
                              || rec.label.trimmingCharacters(in: .whitespaces).isEmpty
                              || rec.referenceText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Audio, .wav, .mp3]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await rec.importAudio(url, client: client) }
        }
    }

    private func save() {
        guard let wav = rec.lastWav else { return }
        do {
            _ = try catalog.addRecordedVoice(
                label: rec.label.trimmingCharacters(in: .whitespaces),
                wav: wav,
                refText: rec.referenceText.trimmingCharacters(in: .whitespacesAndNewlines),
                description: rec.sourceDescription
            )
            rec.reset()
            dismiss()
        } catch {
            rec.error = "Save failed: \(error.localizedDescription)"
        }
    }
}
