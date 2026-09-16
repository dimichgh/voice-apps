import SwiftUI

let lyricLanguages = ["English", "Chinese", "Cantonese", "Japanese", "Korean", "Spanish"]
let lyricStructures = [
    "Verse – Chorus – Verse – Chorus – Bridge – Chorus – Outro",
    "Verse – Pre-Chorus – Chorus – Verse – Pre-Chorus – Chorus – Bridge – Chorus",
    "Intro – Verse – Chorus – Instrumental – Verse – Chorus – Outro",
]

let timedSectionPlan = "[intro 0:00-0:15]\n[verse 0:15-0:45]\n[chorus 0:45-1:10]\n[bridge 1:10-1:40]\n[chorus 1:40-2:05]\n[outro 2:05-2:30]"
let untimedSectionPlan = "[intro]\n[verse]\n[chorus]\n[bridge]\n[chorus]\n[outro]"

enum PlanningMode: String, CaseIterable, Identifiable {
    case full, melody, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .full: return "Melody + Chords"
        case .melody: return "Melody"
        case .off: return "None"
        }
    }
}

struct Example {
    let style: String
    let lyrics: String
    let planning: PlanningMode
    let steps: Int
    let seed: Int
}

let examples = [
    Example(style: "Dreamy synth-pop, warm female lead vocal, pulsing bass, shimmering synths, uplifting",
            lyrics: "[Verse]\nCity windows turn to gold\nEvery streetlight has a story\nWe are brave and we are bold\nRunning toward the morning glory\n\n[Chorus]\nStay awake, the night is ours\nWe can dance beneath the stars\nHold this moment, hold it tight\nWe are sparks inside the night\n\n[Outro]\nInside the night",
            planning: .full, steps: 16, seed: 42),
    Example(style: "Acoustic indie folk, intimate male vocal, fingerpicked guitar, gentle strings",
            lyrics: "[Verse]\nDust is dancing in the doorway\nSummer settles on the road\nI can hear the old trees whisper\nAll the secrets that they know\n\n[Chorus]\nTake me home across the river\nWhere the evening moves so slow\nIf the wind can find its way there\nThen I know that I can go",
            planning: .melody, steps: 16, seed: 831001),
]

@MainActor
final class CreateModel: ObservableObject {
    @Published var style = "Dreamy synth-pop, warm female lead vocal, pulsing bass, shimmering synths"
    @Published var concept = ""
    @Published var language = "English"
    @Published var structure = lyricStructures[0]
    @Published var lyricSeed = 42
    @Published var lyrics = ""
    @Published var instrumental = false
    // Timed tags are the only plan that reliably ends on its own; bare/untimed plans ran to the 6-min cap.
    @Published var sectionPlan = timedSectionPlan
    @Published var planning: PlanningMode = .full
    @Published var steps = 16
    @Published var seed = 42

    @Published var writingLyrics = false
    @Published var lyricsError: String?
    let job = SongJob()

    func writeLyrics() async {
        let idea = concept.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idea.isEmpty else { lyricsError = "Describe the song idea or story."; return }
        writingLyrics = true
        lyricsError = nil
        defer { writingLyrics = false }
        do {
            lyrics = try await OmlxClient.shared.writeLyrics(
                concept: idea, style: style.trimmingCharacters(in: .whitespacesAndNewlines),
                language: language, structure: structure, seed: lyricSeed)
        } catch {
            lyricsError = error.localizedDescription
        }
    }

    func generate() async {
        let instrumental = self.instrumental
        let (style, cot, steps, seed) = (self.style, planning.rawValue, self.steps, self.seed)
        let lyrics = instrumental ? sectionPlan : self.lyrics
        await job.run {
            try await ServerClient.shared.generate(style: style, lyrics: lyrics, cot: cot, steps: steps, seed: seed,
                                                   instrumental: instrumental)
        }
    }

    func apply(_ e: Example) {
        style = e.style; lyrics = e.lyrics; planning = e.planning; steps = e.steps; seed = e.seed
        instrumental = false
    }

    /// Loads a finished song's settings back into the form.
    func apply(_ song: Song) {
        style = song.style
        if let s = song.seed { seed = s }
        if let s = song.steps { steps = s }
        if let p = song.planning.flatMap(PlanningMode.init(rawValue:)) { planning = p }
        instrumental = song.instrumental
        if song.instrumental {
            sectionPlan = song.lyrics.lowercased() == "[instrumental]" ? "" : song.lyrics
        } else {
            lyrics = song.lyrics
        }
    }
}

struct CreateView: View {
    @ObservedObject var model: CreateModel
    @State private var showWriter = false

    var body: some View {
        Form {
            Section {
                TextField("Style", text: $model.style, prompt: Text("Genre, mood, vocal, instruments, tempo…"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(2...5)
                Toggle(isOn: $model.instrumental) {
                    Text("Instrumental")
                    Text("No vocals. Uses the YuE2 instrumental LoRA.")
                }
                .onChange(of: model.instrumental) { _, on in
                    if on { model.planning = .full }   // the instrumental LoRA is trained score-first
                }
            } header: {
                Text("Style")
            }

            if model.instrumental {
                Section {
                    LyricsEditor(text: $model.sectionPlan,
                                 placeholder: "Leave empty and the model picks the structure and length.",
                                 height: 170, monospaced: true)
                    HStack {
                        Menu("Templates") {
                            Button("Timed Sections (2:30)") { model.sectionPlan = timedSectionPlan }
                            Button("Sections Without Times") { model.sectionPlan = untimedSectionPlan }
                            Divider()
                            Button("Clear") { model.sectionPlan = "" }
                        }
                        .fixedSize()
                        Spacer()
                    }
                } header: {
                    Text("Section Plan")
                } footer: {
                    Text("One tag per line: intro, verse, pre-chorus, chorus, bridge, outro. Keep the m:ss times; without them the model plans about nine minutes and is cut off at the 6-minute limit.")
                }
            } else {
                Section {
                    LyricsEditor(text: $model.lyrics,
                                 placeholder: "[Verse]\nYour lyrics…\n\n[Chorus]\nYour chorus…",
                                 height: 280)
                    HStack {
                        Button { showWriter = true } label: {
                            Label("Write with AI…", systemImage: "sparkles")
                        }
                        .popover(isPresented: $showWriter, arrowEdge: .bottom) {
                            LyricWriter(model: model, isPresented: $showWriter)
                        }
                        Spacer()
                        let lines = model.lyrics.split(separator: "\n").count
                        Text(lines == 1 ? "1 line" : "\(lines) lines")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Lyrics")
                } footer: {
                    Text("Label each section, such as [Verse] and [Chorus].")
                }
            }

            Section {
                Picker("Score planning", selection: $model.planning) {
                    ForEach(PlanningMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                QualityPicker(steps: $model.steps)
                SeedField(seed: $model.seed)
            } header: {
                Text("Rendering")
            } footer: {
                Text("Planning writes a melody and chords first for a more coherent song. Draft renders in 8 steps, Standard 16, Fine 32.")
            }

            Section("Start from an Example") {
                ForEach(examples.indices, id: \.self) { i in
                    let e = examples[i]
                    Button { model.apply(e) } label: {
                        HStack(spacing: 12) {
                            SongArt(seed: e.seed, style: e.style)
                                .frame(width: 38, height: 38)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Song.headline(e.style)).fontWeight(.medium)
                                Text("\(e.planning.label) · \(QualityPicker.name(e.steps)) · seed \(e.seed)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.left.circle")
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.job.isRunning)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct LyricWriter: View {
    @ObservedObject var model: CreateModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Idea", text: $model.concept,
                              prompt: Text("Two friends chasing one last summer night"), axis: .vertical)
                        .lineLimit(2...4)
                    Picker("Language", selection: $model.language) {
                        ForEach(lyricLanguages, id: \.self) { Text($0) }
                    }
                    Picker("Structure", selection: $model.structure) {
                        ForEach(lyricStructures, id: \.self) { Text($0) }
                    }
                    SeedField(seed: $model.lyricSeed)
                } header: {
                    Label("Write Lyrics with Qwen3-Omni", systemImage: "sparkles")
                } footer: {
                    if let error = model.lyricsError {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("Runs on your local omlx server and replaces the current lyrics.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                if model.writingLyrics { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Write Lyrics") {
                    Task {
                        await model.writeLyrics()
                        if model.lyricsError == nil { isPresented = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.writingLyrics)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460, height: 340)
    }
}
