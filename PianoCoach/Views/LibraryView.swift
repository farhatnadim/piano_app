import PianoCoachCore
import SwiftUI

/// The list of pieces (the sidebar).
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var showAddPiece = false
    @State private var showSettings = false
    @State private var renaming: Piece?
    @State private var newTitle = ""
    @State private var deleting: Piece?

    var body: some View {
        List(selection: selection) {
            ForEach(model.pieces) { piece in
                NavigationLink(value: piece.id) {
                    PieceRow(piece: piece)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { deleting = piece } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                    Button { startRenaming(piece) } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                }
                .contextMenu {
                    Button { startRenaming(piece) } label: {
                        Label("Rename…", systemImage: "pencil")
                    }
                    Button(role: .destructive) { deleting = piece } label: {
                        Label("Delete…", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.pieces.isEmpty {
                ContentUnavailableView {
                    Label("No pieces yet", systemImage: "music.note")
                } description: {
                    Text("Add a YouTube video of the song your child is learning.")
                } actions: {
                    Button { showAddPiece = true } label: {
                        Label("Add a piece", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = model.libraryError {
                NoticeBanner(error, style: .error)
                    .padding()
            }
        }
        .navigationTitle("Piano Coach")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddPiece = true } label: {
                    Label("Add a piece", systemImage: "plus")
                }
                .help("Add a YouTube video")
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            #endif
        }
        .sheet(isPresented: $showAddPiece) {
            AddPieceView()
                .environment(model)
        }
        #if os(iOS)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(model)
        }
        #endif
        .alert("Rename piece", isPresented: isRenaming) {
            TextField("Name", text: $newTitle)
            Button("Save") { finishRenaming() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete this piece?", isPresented: isDeleting, titleVisibility: .visible,
                            presenting: deleting) { piece in
            Button("Delete “\(piece.title)”", role: .destructive) {
                if let current = current(piece) { model.delete(current) }
                deleting = nil
            }
        } message: { _ in
            Text("The notes Piano Coach learned and the game progress are deleted too.")
        }
    }

    /// Selecting a piece opens it. On iPhone, going back to the list closes it (and stops listening).
    private var selection: Binding<UUID?> {
        let appModel = model
        return Binding(
            get: { appModel.openPieceID },
            set: { id in
                if let id {
                    if let piece = appModel.pieces.first(where: { $0.id == id }) { appModel.openPiece(piece) }
                } else {
                    #if os(iOS)
                    appModel.closePiece()
                    #endif
                }
            }
        )
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private func current(_ piece: Piece) -> Piece? {
        model.pieces.first { $0.id == piece.id }
    }

    private func startRenaming(_ piece: Piece) {
        newTitle = piece.title
        renaming = piece
    }

    private func finishRenaming() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let piece = renaming.flatMap(current), !title.isEmpty, title != piece.title {
            model.rename(piece, to: title)
        }
        renaming = nil
    }
}

/// One piece in the library: thumbnail, title, whether its notes are ready, and game progress.
private struct PieceRow: View {
    let piece: Piece

    var body: some View {
        HStack(spacing: 12) {
            VideoThumbnail(videoID: piece.videoID)
            VStack(alignment: .leading, spacing: 5) {
                Text(piece.title)
                    .font(.headline)
                    .lineLimit(2)
                if hasNotes {
                    if piece.difficulty != nil || piece.game != nil {
                        GameSummary(difficulty: piece.difficulty, progress: piece.game)
                    }
                } else {
                    Badge(text: "Needs listening", systemImage: "ear")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var hasNotes: Bool {
        piece.sheet?.kind.hasNotes == true || piece.hasLearnedTrack
    }
}

/// How hard the song is and how the child is doing in the game.
private struct GameSummary: View {
    let difficulty: Int?
    let progress: GameProgress?

    var body: some View {
        HStack(spacing: 10) {
            if let difficulty {
                HStack(spacing: 1) {
                    ForEach(1...5, id: \.self) { i in
                        Image(systemName: i <= difficulty ? "circle.fill" : "circle")
                            .font(.system(size: 6))
                    }
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Difficulty \(difficulty) of 5")
            }
            if let progress, progress.gamesPlayed > 0 {
                IconText(text: "Level \(progress.level)", systemImage: "gamecontroller.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tint)
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { i in
                        Image(systemName: i < progress.bestStars ? "star.fill" : "star")
                            .font(.system(size: 9))
                    }
                }
                .foregroundStyle(.yellow)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Best: \(progress.bestStars) stars")
            }
        }
    }
}

private struct Badge: View {
    let text: String
    let systemImage: String

    var body: some View {
        IconText(text: text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

/// A small icon and its text. (A `Label` here lost its text in the iPad sidebar, which lays out labels as
/// row icons and titles.)
private struct IconText: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(text)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
