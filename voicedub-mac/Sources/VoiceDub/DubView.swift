import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// Tab 2 — load a video, transcribe + (optionally) translate it, regenerate the
/// dialogue in the selected voice, and play the redubbed video. Export writes a
/// .mov with the video passed through losslessly and the new audio track.
struct DubView: View {
    @ObservedObject var catalog: VoiceCatalog
    @EnvironmentObject var app: AppModel
    @StateObject private var model = DubModel()

    var body: some View {
        HSplitView {
            playerPane
                .frame(minWidth: 380)
            segmentPane
                .frame(minWidth: 300, idealWidth: 360)
        }
    }

    // MARK: - Left: video + controls

    private var playerPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    pickVideo()
                } label: {
                    Label("Open video…", systemImage: "folder")
                }
                if let url = model.videoURL {
                    Text(url.lastPathComponent).font(.caption).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }

            PlayerView(player: model.player)
                .frame(minHeight: 220)
                .background(Color.black)
                .cornerRadius(6)

            if model.hasDub {
                Picker("Audio", selection: Binding(
                    get: { model.playingDubbed },
                    set: { $0 ? model.showDubbed() : model.showOriginal() }
                )) {
                    Text("Dubbed").tag(true)
                    Text("Original").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }

            controls

            if model.isProcessing {
                ProgressView(value: model.progress)
                Text(model.status).font(.caption).foregroundColor(.secondary)
            } else if !model.status.isEmpty {
                Text(model.status).font(.caption).foregroundColor(.secondary)
            }
            if let err = model.error {
                Text(err).font(.caption).foregroundColor(.red)
            }
            Spacer()
        }
        .padding(14)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Voice:").foregroundColor(.secondary)
                Picker("", selection: Binding(
                    get: { catalog.current.id },
                    set: { id in if let v = catalog.voices.first(where: { $0.id == id }) { catalog.current = v } }
                )) {
                    ForEach(catalog.voices) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .disabled(model.useOriginalVoice)
            }
            Toggle(isOn: $model.useOriginalVoice) {
                Text("Use original speaker's voice (clone from video)")
            }
            .toggleStyle(.checkbox)
            if model.useOriginalVoice {
                Text("Clones one dominant speaker from the video — best with translation on. Multi-speaker clips will all use a single blended voice.")
                    .font(.caption2).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $model.keepBackground) {
                Text("Keep background music & sound effects (separate voice)")
            }
            .toggleStyle(.checkbox)
            .disabled(!Demucs.isAvailable)
            if !Demucs.isAvailable {
                Text("Requires the Demucs separation venv — see README setup.")
                    .font(.caption2).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.keepBackground {
                Text("Splits voice from music/SFX, replaces only the voice, and keeps everything else. Adds a separation pass (tens of seconds).")
                    .font(.caption2).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Translate to:").foregroundColor(.secondary)
                Picker("", selection: $model.targetLanguage) {
                    ForEach(AppModel.languages, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            HStack {
                Button {
                    Task { await model.generate(client: app.client, voice: catalog.current) }
                } label: {
                    Label(model.hasDub ? "Regenerate dub" : "Generate dub", systemImage: "waveform.badge.mic")
                }
                .controlSize(.large)
                .disabled(model.videoURL == nil || model.isProcessing)

                Button { exportVideo() } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .disabled(!model.hasDub || model.isProcessing)
            }
        }
    }

    // MARK: - Right: segments

    private var segmentPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Dialogue").font(.headline)
                Spacer()
                if staleCount > 0 {
                    Button {
                        Task { await model.revoiceStale(client: app.client, voice: catalog.current) }
                    } label: {
                        Label("Re-voice \(staleCount) edited", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .controlSize(.small)
                    .disabled(model.isProcessing)
                }
            }
            .padding(10)

            if model.segments.isEmpty {
                VStack {
                    Spacer()
                    Text(model.isProcessing ? "Transcribing…" : "Segments appear here after you generate a dub.")
                        .font(.caption).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).padding()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach($model.segments) { seg in
                        segmentRow(seg)
                    }
                }
            }
        }
    }

    private var staleCount: Int { model.segments.filter(\.needsRevoice).count }

    @ViewBuilder
    private func segmentRow(_ seg: Binding<DubSegment>) -> some View {
        let s = seg.wrappedValue
        let busy = model.busySegments.contains(s.id)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("\(timecode(s.start)) – \(timecode(s.end))")
                    .font(.caption2.monospaced()).foregroundColor(.secondary)
                if s.needsRevoice {
                    Label("edited", systemImage: "pencil.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2).foregroundColor(.orange)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }

            // Source transcript (editable).
            TextField("Source text", text: seg.sourceText, axis: .vertical)
                .font(.callout).lineLimit(1...4)
                .textFieldStyle(.roundedBorder)

            // Translation (editable) — shown only when a target language is set.
            if model.translationEnabled {
                TextField("Translation in \(model.targetLanguage)…",
                          text: Binding(get: { s.translatedText ?? "" },
                                        set: { seg.translatedText.wrappedValue = $0 }),
                          axis: .vertical)
                    .font(.callout).lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .foregroundColor(.accentColor)
            }

            HStack(spacing: 8) {
                if model.translationEnabled {
                    Button {
                        Task { await model.retranslate(s.id, client: app.client) }
                    } label: { Label("Translate", systemImage: "globe") }
                        .controlSize(.small)
                }
                Button {
                    Task { await model.revoice(s.id, client: app.client, voice: catalog.current) }
                } label: { Label("Re-voice", systemImage: "waveform") }
                    .controlSize(.small)
                    .tint(s.needsRevoice ? .orange : nil)

                if model.segmentAudioURL(s.id) != nil {
                    Button {
                        if let url = model.segmentAudioURL(s.id) {
                            try? app.player.play(url: url)
                        }
                    } label: { Image(systemName: "play.circle") }
                        .controlSize(.small)
                        .help("Preview this segment")
                }
                Spacer()
            }
            .disabled(busy || model.isProcessing)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Pickers

    private func pickVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.pick(url)
        }
    }

    private func exportVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        let base = model.videoURL?.deletingPathExtension().lastPathComponent ?? "dubbed"
        panel.nameFieldStringValue = "\(base)-dubbed.mov"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await model.export(to: url) }
            catch { model.error = error.localizedDescription }
        }
    }

    private func timecode(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
