import SwiftUI

/// The always-on floating indicator. Instead of a static badge in a crowded
/// menu bar, Murmur shows a small flowing waveform near the bottom of the
/// screen: it breathes gently when idle (so you know it's alive and ready),
/// surges with your voice while listening, and reports transcribe → insert.
struct HUDView: View {
    @ObservedObject var controller: DictationController

    /// This app's display name (Murmur / Murmur Solo / Murmur WK) — the HUD is
    /// shared across all three, so the restart label must not be hardcoded.
    private static let appName: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? "Murmur"

    // Permission / hotkey-restart state, snapshotted into @State the body reads.
    // We poll (rather than bump an unread counter) because SwiftUI only re-renders
    // when state the body *reads* changes — so the "set up" / "restart to apply"
    // pill appears on its own within ~1.5s of granting a permission or changing
    // the activation key, without needing a phase change to force a repaint.
    @State private var setupNeeded = false
    @State private var needsRestart = false
    private let permTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            capsule
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // center within the panel
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: width)
        .animation(.easeInOut(duration: 0.2), value: phaseKey)
        .onReceive(permTimer) { _ in refreshPermissionState() }
        .onAppear { refreshPermissionState() }
    }

    private func refreshPermissionState() {
        let setup = Permissions.hasUnconfigured
        let restart = Permissions.needsRestart
        if setup != setupNeeded { setupNeeded = setup }
        if restart != needsRestart { needsRestart = restart }
    }

    private var capsule: some View {
        HStack(spacing: 9) {
            glyph.transition(.scale.combined(with: .opacity))
            content                              // waveform/text stay full opacity
        }
        .padding(.horizontal, 14)
        .frame(width: width, height: 40)
        .background(glassBackground)
        .help("Drag to move • Right-click for permissions & options")
        .contextMenu {
            if !Permissions.allReady {
                Text("Permissions — click to enable:")
                ForEach(Permissions.Perm.allCases, id: \.self) { p in
                    Button(Permissions.menuLabel(p)) { Permissions.fix(p) }
                }
                Divider()
            }
            if Permissions.needsRestart {
                Button("↻ Restart now to apply changes") {
                    NotificationCenter.default.post(name: .murmurRestart, object: nil)
                }
                Divider()
            }
            Button("Settings…") {
                NotificationCenter.default.post(name: .murmurOpenSettings, object: nil)
            }
            Button("Restart \(Self.appName)") {
                NotificationCenter.default.post(name: .murmurRestart, object: nil)
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }

    /// Almost-transparent glass: a faint blurred material at low opacity with a
    /// soft rim light and shadow. Only the foreground (waveform/glyph/text)
    /// renders at full strength, so the wave reads as "normal" over glass.
    private var glassBackground: some View {
        Capsule(style: .continuous)
            .fill(.ultraThinMaterial)
            .opacity(0.45)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.30), Color.white.opacity(0.06)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
    }

    // MARK: - Content per state

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .idle:
            if setupNeeded {
                label("Right-click to set up").foregroundStyle(.orange)
            } else if needsRestart {
                label("Right-click → Restart").foregroundStyle(.orange)
            } else {
                FlowingWaveform(amplitude: 0.16, speed: 1.0, color: .secondary, harmonics: 2)
            }
        case .listening:
            FlowingWaveform(amplitude: 0.22 + CGFloat(controller.level) * 0.78,
                            speed: 3.0, color: accent, harmonics: 3)
        case .transcribing:
            label(controller.modelReady ? "Transcribing…" : "Loading model…")
        case .inserting:
            label("Inserting")
        case .error(let msg):
            label(msg).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var glyph: some View {
        switch controller.phase {
        case .idle:
            if setupNeeded {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
            } else if needsRestart {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 6, height: 6)
            }
        case .listening:
            Image(systemName: controller.locked ? "lock.fill" : "mic.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accent)
        case .transcribing:
            ProgressView().controlSize(.small).scaleEffect(0.7)
        case .inserting:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Layout / state helpers

    private var width: CGFloat {
        switch controller.phase {
        case .idle:        return (setupNeeded || needsRestart) ? 210 : 116
        case .listening:   return 232
        case .transcribing, .inserting: return 184
        case .error:       return 220
        }
    }

    /// A stable key so the cross-fade animation fires on state changes.
    private var phaseKey: Int {
        switch controller.phase {
        case .idle: return 0
        case .listening: return 1
        case .transcribing: return 2
        case .inserting: return 3
        case .error: return 4
        }
    }

    private var accent: Color { controller.locked ? .orange : .accentColor }
}

/// A horizontal waveform that continuously travels (flows) and tapers to zero
/// at both ends so it reads as a contained ribbon. `amplitude` (0...1) scales
/// the height — driven by the live mic level while listening — and `speed`
/// sets how fast it flows.
struct FlowingWaveform: View {
    var amplitude: CGFloat
    var speed: Double
    var color: Color
    var harmonics: Int

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let midY = size.height / 2
                let w = size.width
                guard w > 1 else { return }

                var path = Path()
                let step: CGFloat = 2
                var x: CGFloat = 0
                while x <= w {
                    let rel = x / w
                    // Envelope tapers the ends to zero (sin lobe).
                    let env = sin(rel * .pi)
                    // Sum a couple of traveling sines for an organic flow.
                    var y = midY
                    for h in 1...max(1, harmonics) {
                        let freq = Double(h) * 3.0
                        let phase = t * speed * (1.0 + Double(h) * 0.25)
                        let amp = amplitude * midY * env / CGFloat(h)
                        y += sin(rel * .pi * freq - phase) * amp
                    }
                    if x == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                    x += step
                }
                ctx.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .frame(height: 24)
        .frame(maxWidth: .infinity)
    }
}
