import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            detail
                .frame(minWidth: 460)
                .navigationTitle(app.pane.title)
                .navigationSubtitle(subtitle)
                .inspector(isPresented: $app.showInspector) {
                    InspectorHost()
                        .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
                }
                .toolbar { toolbar }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch app.pane {
        case .create: CreateView(model: app.create)
        case .cover: CoverView(model: app.cover)
        case .library: LibraryView(library: app.library, player: app.player)
        }
    }

    private var subtitle: String {
        switch app.pane {
        case .create: "A new song from a style and lyrics"
        case .cover: "Your melody, re-sung in a new style"
        case .library: app.library.songs.count == 1 ? "1 song" : "\(app.library.songs.count) songs"
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            StatusView(job: app.activeJob)
        }
        if app.pane != .library {
            ToolbarItem {
                if app.isRunning {
                    Button { app.cancel() } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                    .help("Cancel generation (⌘.)")
                } else {
                    Button { app.generate() } label: {
                        Label(app.generateTitle, systemImage: "sparkles")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!app.canGenerate)
                    .help("\(app.generateTitle) (⌘↩)")
                }
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button { app.showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(app.showInspector ? "Hide Inspector" : "Show Inspector")
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        List(selection: Binding(get: { app.pane }, set: { if let p = $0 { app.pane = p } })) {
            Section("Make") {
                row(.create, running: app.create.job.isRunning)
                row(.cover, running: app.cover.job.isRunning || app.cover.transcribeJob.isRunning)
            }
            Section("Library") {
                Label("All Songs", systemImage: Pane.library.symbol)
                    .symbolEffect(.bounce, options: .speed(0.8), value: reduceMotion ? 0 : app.completions)
                    .badge(app.library.songs.count)
                    .tag(Pane.library)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Text("Model weights CC BY-NC 4.0 · one song renders at a time")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private func row(_ pane: Pane, running: Bool) -> some View {
        HStack {
            Label(pane.title, systemImage: pane.symbol)
            Spacer()
            if running {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                    .foregroundStyle(brandAccent)
                    .accessibilityLabel("Generating")
            }
        }
        .tag(pane)
    }
}

/// Centre of the toolbar: the running job's stage, or the model server's state when idle.
struct StatusView: View {
    let job: SongJob?
    @EnvironmentObject var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if let job, job.isRunning {
                if let f = job.fraction {
                    ProgressView(value: f).progressViewStyle(.circular).controlSize(.mini)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(job.phase.title).fontWeight(.medium)
                Text(SongJob.clock(job.elapsed))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            } else if let job, job.phase == .done, !job.progressText.isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(job.progressText)
            } else if let job, job.phase == .failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text("Generation failed")
            } else if let job, job.phase == .cancelled {
                Image(systemName: "stop.circle").foregroundStyle(.secondary)
                Text("Cancelled").foregroundStyle(.secondary)
            } else {
                server
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .animation(reduceMotion ? nil : .smooth, value: job?.phase)
    }

    @ViewBuilder
    private var server: some View {
        switch app.server.state {
        case .ready:
            Circle().fill(.green).frame(width: 7, height: 7)
            Text("Ready").foregroundStyle(.secondary)
        case .starting:
            ProgressView().controlSize(.mini)
            Text("Starting model server…").foregroundStyle(.secondary)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).foregroundStyle(.secondary)
            Button("Retry") { Task { await app.server.ensureRunning() } }
                .controlSize(.small)
        }
    }
}
