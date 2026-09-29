import PianoCoachCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Adds a piece from a pasted YouTube link and opens it.
struct AddPieceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var title = ""
    @State private var isAdding = false
    @FocusState private var linkFocused: Bool

    private var videoID: String? { YouTubeLink.videoID(from: link) }
    private var existingPiece: Piece? {
        guard let videoID else { return nil }
        return model.pieces.first { $0.videoID == videoID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        TextField("YouTube link", text: $link, prompt: Text("https://youtu.be/…"))
                            .labelsHidden()
                            .focused($linkFocused)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .onSubmit { add() }
                        Button(action: paste) {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                    }
                    linkStatus
                } header: {
                    Text("YouTube link")
                } footer: {
                    Text("In YouTube, tap Share, then Copy link, and paste it here.")
                }

                Section {
                    TextField("Name", text: $title, prompt: Text("Leave empty to use the video's title"))
                        .onSubmit { add() }
                } header: {
                    Text("Name (optional)")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add a piece")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isAdding {
                        ProgressView()
                    } else {
                        Button(existingPiece == nil ? "Add" : "Open", action: add)
                            .disabled(videoID == nil)
                    }
                }
            }
            .onAppear { linkFocused = true }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 380, idealHeight: 420)
        #endif
    }

    @ViewBuilder private var linkStatus: some View {
        if let videoID {
            HStack(spacing: 12) {
                VideoThumbnail(videoID: videoID, width: 112)
                if existingPiece != nil {
                    Label("Already in your library", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Found the video", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .font(.subheadline)
        } else if !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Label("That doesn't look like a YouTube link.", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
        }
    }

    private func paste() {
        #if os(iOS)
        let pasteboard = UIPasteboard.general
        let text = pasteboard.hasStrings ? pasteboard.string : pasteboard.url?.absoluteString
        #elseif os(macOS)
        let text = NSPasteboard.general.string(forType: .string)
        #endif
        if let text = nonEmpty(text) {
            link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func add() {
        guard videoID != nil, !isAdding else { return }
        if let existing = existingPiece {
            model.openPiece(existing)
            dismiss()
            return
        }
        isAdding = true
        Task {
            if let piece = await model.addPiece(link: link, title: title) {
                model.openPiece(piece)
            }
            isAdding = false
            dismiss()
        }
    }
}
