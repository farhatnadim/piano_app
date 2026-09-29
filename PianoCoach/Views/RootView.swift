import SwiftUI

/// The library in a sidebar, and the practice screen for the open piece.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    /// The library shows next to the empty screen at launch (also in iPad portrait, where `.automatic` hides it).
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showAddPiece = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            LibraryView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            // Only `openPieceID` is read here, so edits to pieces don't rebuild the practice screen.
            if model.openPieceID != nil {
                PracticeView()
            } else {
                emptyState
            }
        }
        .onChange(of: model.openPieceID) { _, id in
            compactColumn = id == nil ? .sidebar : .detail
            #if os(iOS)
            // Give the video and the music the whole iPad screen; the sidebar button brings the list back.
            columnVisibility = id == nil ? .all : .detailOnly
            #endif
        }
        .sheet(isPresented: $model.showVoiceHelp) {
            NavigationStack {
                VoiceHelpView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.showVoiceHelp = false }
                        }
                    }
            }
            .environment(model)
            #if os(macOS)
            .frame(minWidth: 440, idealWidth: 500, minHeight: 480, idealHeight: 640)
            #endif
        }
        .sheet(isPresented: $showAddPiece) {
            AddPieceView()
                .environment(model)
        }
    }

    private var emptyState: some View {
        let hasSongs = !model.pieces.isEmpty
        return ContentUnavailableView {
            Label(hasSongs ? "Choose a song" : "Add a YouTube link to get started", systemImage: "pianokeys")
        } description: {
            Text(hasSongs ? "Pick a song from the library to play the game or watch the video."
                          : "Add the video of a song your child is learning.")
        } actions: {
            if hasSongs && columnVisibility == .detailOnly {
                Button { columnVisibility = .all } label: {
                    Label("Show the library", systemImage: "sidebar.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            Button { showAddPiece = true } label: {
                Label("Add a piece", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
