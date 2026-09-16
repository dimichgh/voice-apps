import SwiftUI

struct LibraryView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerModel
    @EnvironmentObject var app: AppModel
    @State private var query = ""
    @State private var scope: Scope = .all
    @State private var pendingTrash: Song?

    enum Scope: String, CaseIterable, Identifiable {
        case all = "All", songs = "Songs", instrumentals = "Instrumentals", covers = "Covers"
        var id: Self { self }
    }

    private var filtered: [Song] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return library.songs.filter { song in
            let inScope = switch scope {
            case .all: true
            case .songs: song.kind == .song && !song.instrumental
            case .instrumentals: song.instrumental
            case .covers: song.kind == .cover
            }
            guard inScope else { return false }
            guard !q.isEmpty else { return true }
            return song.style.lowercased().contains(q) || song.lyrics.lowercased().contains(q)
                || song.seed.map { String($0) == q } == true
        }
    }

    var body: some View {
        Group {
            if library.songs.isEmpty {
                ContentUnavailableView {
                    Label("No Songs Yet", systemImage: "music.note.list")
                } description: {
                    Text("Songs and covers you generate are collected here.")
                } actions: {
                    Button("Create a Song") { app.pane = .create }
                        .buttonStyle(.borderedProminent)
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: 20)],
                              alignment: .leading, spacing: 26) {
                        ForEach(filtered) { song in
                            SongCard(song: song,
                                     selected: app.librarySelection == song.id,
                                     playing: player.songID == song.id && player.isPlaying) {
                                app.librarySelection = song.id
                                player.toggle(song)
                            }
                            .onTapGesture(count: 2) {
                                app.librarySelection = song.id
                                player.toggle(song)
                            }
                            .onTapGesture { app.librarySelection = song.id }
                            .contextMenu { menu(for: song) }
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                    .padding(20)
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Style or lyrics")
        .searchScopes($scope) {
            ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
        }
        .onAppear { library.reload() }
        .confirmationDialog("Move “\(pendingTrash?.title ?? "")” to the Trash?",
                            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
                            presenting: pendingTrash) { song in
            Button("Move to Trash", role: .destructive) { app.trash(song) }
        } message: { _ in
            Text("The song folder, including the FLAC, MP3 and score, moves to the Trash.")
        }
    }

    @ViewBuilder
    private func menu(for song: Song) -> some View {
        Button(player.songID == song.id && player.isPlaying ? "Pause" : "Play",
               systemImage: player.songID == song.id && player.isPlaying ? "pause" : "play") {
            player.toggle(song)
        }
        Divider()
        Button("Remix in Create", systemImage: "slider.horizontal.3") { app.remix(song) }
        Button("Make a Cover", systemImage: "music.mic") { app.makeCover(of: song) }
        Divider()
        Button("Show in Finder", systemImage: "folder") { app.reveal(song) }
        Button("Save FLAC…", systemImage: "square.and.arrow.down") { app.save(song, type: "flac") }
            .disabled(song.flac == nil)
        Divider()
        Button("Move to Trash…", systemImage: "trash", role: .destructive) { pendingTrash = song }
    }
}

struct SongCard: View {
    let song: Song
    let selected: Bool
    let playing: Bool
    let onPlay: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SongArt(seed: song.seed ?? 0, style: song.style, symbol: song.symbol)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    // Scrim keeps the white caption legible over any palette.
                    HStack {
                        Text(song.kindLabel)
                        Spacer()
                        if let d = song.duration { Text(timecode(d)).monospacedDigit() }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom))
                }
                .overlay {
                    if hovering || playing {
                        Button(action: onPlay) {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 50, height: 50)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(playing ? "Pause" : "Play")
                        .transition(.opacity)
                    }
                }
                .clipShape(shape)
                .overlay { shape.strokeBorder(selected ? brandAccent : .clear, lineWidth: 3) }
                .shadow(color: .black.opacity(hovering ? 0.24 : 0.12), radius: hovering ? 12 : 5, y: hovering ? 6 : 2)
                .scaleEffect(hovering && !reduceMotion ? 1.02 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.headline).lineLimit(1)
                Text(song.date.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.snappy(duration: 0.2)) { hovering = h } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
