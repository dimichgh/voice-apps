import SwiftUI

// MARK: - Generative artwork

/// Album art drawn from a song's style + seed: a 3×3 mesh gradient, so the same song always gets the same cover.
struct SongArt: View {
    let seed: Int
    let style: String
    var symbol: String?
    /// Drift the mesh while a song is being generated.
    var animating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = ArtPalette(key: "\(Song.headline(style))#\(seed)")
        Group {
            if animating && !reduceMotion {
                // Slow drift at 12 fps: a 60 fps mesh redraw competes with MLX for the GPU and slows generation.
                TimelineView(.animation(minimumInterval: 1.0 / 12)) { timeline in
                    mesh(palette, t: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                mesh(palette, t: 0)
            }
        }
        .overlay {
            if let symbol {
                GeometryReader { geo in
                    Image(systemName: symbol)
                        .resizable()
                        .scaledToFit()
                        .fontWeight(.light)
                        .foregroundStyle(.white.opacity(0.28))
                        .blendMode(.plusLighter)
                        .frame(width: geo.size.width * 0.34, height: geo.size.height * 0.34)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func mesh(_ p: ArtPalette, t: Double) -> some View {
        MeshGradient(width: 3, height: 3, points: p.points(t), colors: p.colors)
    }
}

struct ArtPalette {
    let colors: [Color]
    private let jitter: [Double]

    init(key: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a: stable across launches, unlike String.hashValue
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        var rng = SplitMix64(state: hash)
        let base = rng.unit()
        let contrast = rng.unit() > 0.5 ? 0.42 : -0.33
        let hues = [base, base + 0.05, base - 0.06, base + 0.11, base + contrast, base - 0.02, base + 0.08, base - 0.10, base + 0.03]
        colors = hues.enumerated().map { i, hue in
            let h = hue - hue.rounded(.down)
            if i == 4 { return Color(hue: h, saturation: 0.55, brightness: 0.98) }   // the bright accent in the middle
            return Color(hue: h, saturation: 0.55 + 0.35 * rng.unit(), brightness: 0.38 + 0.5 * rng.unit())
        }
        jitter = (0..<18).map { _ in rng.unit() }
    }

    func points(_ t: Double) -> [SIMD2<Float>] {
        var points: [SIMD2<Float>] = []
        for y in 0..<3 {
            for x in 0..<3 {
                let i = y * 3 + x
                var px = Double(x) / 2, py = Double(y) / 2
                let phase = jitter[i * 2] * .pi * 2
                // Edge points only slide along their edge so the mesh always fills the frame.
                if x == 1 { px += (jitter[i * 2] - 0.5) * 0.4 + sin(t * 0.55 + phase) * 0.12 }
                if y == 1 { py += (jitter[i * 2 + 1] - 0.5) * 0.4 + cos(t * 0.45 + phase) * 0.12 }
                points.append(SIMD2(Float(px), Float(py)))
            }
        }
        return points
    }
}

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

// MARK: - Generation progress

/// The four pipeline stages with live detail for the active one.
struct PhaseTimeline: View {
    @ObservedObject var job: SongJob
    let isCover: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum StageState { case pending, active, done }
    private struct Stage { let phase: JobPhase; let title: String; let symbol: String }

    private var stages: [Stage] {
        [
            Stage(phase: .planning, title: isCover ? "Read melody score" : "Compose score", symbol: "music.quarternote.3"),
            Stage(phase: .tokens, title: "Generate audio tokens", symbol: "waveform"),
            Stage(phase: .synthesizing, title: "Synthesize audio", symbol: "waveform.path"),
            Stage(phase: .decoding, title: "Decode and save", symbol: "square.and.arrow.down"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.phase.title).font(.headline)
                Spacer()
                Text(SongJob.clock(job.elapsed))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(stages, id: \.phase) { stage in row(stage) }
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: job.phase)
        .animation(reduceMotion ? nil : .default, value: job.elapsed)
    }

    private func state(_ stage: Stage) -> StageState {
        if stage.phase == .decoding {   // decoding + saving share one row
            return job.phase >= .done ? .done : job.phase >= .decoding ? .active : .pending
        }
        return job.phase > stage.phase ? .done : job.phase == stage.phase ? .active : .pending
    }

    private func detail(_ stage: Stage, _ state: StageState) -> String? {
        switch (stage.phase, state) {
        case (.planning, .active): return job.tokens > 0 ? "\(job.tokens) tokens" : "Starting…"
        case (.planning, .done): return job.skippedPlanning ? "Skipped" : "\(job.planTokens) tokens"
        case (.tokens, .active):
            return job.tokens > 0 ? "\(job.tokens) tokens · \(timecode(Double(job.tokens) / SongJob.tokensPerSecond)) of audio" : "Starting…"
        case (.synthesizing, .active): return job.totalSteps > 0 ? "Step \(job.step) of \(job.totalSteps)" : "Starting…"
        case (.decoding, .active): return job.phase == .saving ? "Writing FLAC and MP3" : "Running the VAE"
        default: return nil
        }
    }

    @ViewBuilder
    private func row(_ stage: Stage) -> some View {
        let s = state(stage)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: s == .done ? "checkmark.circle.fill" : s == .active ? stage.symbol : "circle.dotted")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(s == .done ? AnyShapeStyle(.green) : s == .active ? AnyShapeStyle(brandAccent) : AnyShapeStyle(.tertiary))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: s == .active && !reduceMotion)
                .contentTransition(.symbolEffect(.replace))
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(stage.title)
                    .fontWeight(s == .active ? .semibold : .regular)
                    .foregroundStyle(s == .pending ? .secondary : .primary)
                if let text = detail(stage, s) {
                    Text(text)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                if stage.phase == .synthesizing, s == .active, job.totalSteps > 0 {
                    ProgressView(value: Double(job.step), total: Double(job.totalSteps))
                        .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(s == .done ? "Done" : s == .active ? "In progress" : "Pending")
    }
}

// MARK: - Form controls

struct LyricsEditor: View {
    @Binding var text: String
    let placeholder: String
    var height: CGFloat = 240
    var monospaced = false

    var body: some View {
        let font: Font = monospaced ? .system(.callout, design: .monospaced) : .body
        TextEditor(text: $text)
            .font(font)
            .scrollContentBackground(.hidden)
            .frame(height: height)   // fixed: a growing editor fights the Form's own scroll view
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(font)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
    }
}

struct QualityPicker: View {
    @Binding var steps: Int

    var body: some View {
        Picker("Render quality", selection: $steps) {
            Text("Draft").tag(8)
            Text("Standard").tag(16)
            Text("Fine").tag(32)
        }
        .pickerStyle(.segmented)
    }

    static func name(_ steps: Int) -> String {
        switch steps {
        case 8: "Draft · 8 steps"
        case 16: "Standard · 16 steps"
        case 32: "Fine · 32 steps"
        default: "\(steps) steps"
        }
    }
}

struct SeedField: View {
    @Binding var seed: Int

    var body: some View {
        LabeledContent("Seed") {
            HStack(spacing: 6) {
                TextField("Seed", value: $seed, format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)
                Button { seed = Int.random(in: 0..<1_000_000) } label: { Image(systemName: "dice") }
                    .buttonStyle(.borderless)
                    .help("Random seed")
                    .accessibilityLabel("Random seed")
            }
        }
    }
}

/// m:ss for players and durations.
func timecode(_ seconds: Double) -> String {
    let t = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", t / 60, t % 60)
}
