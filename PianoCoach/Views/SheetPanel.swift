import PDFKit
import PianoCoachCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The sheet music for the open piece: MusicXML with a moving cursor, a PDF, or a photo.
struct SheetPanel: View {
    @Environment(AppModel.self) private var model
    /// Nil until the practice screen has created it.
    let controller: SheetMusicController?
    var onOpenSetup: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = errorMessage {
                NoticeBanner(error, style: .warning)
                    .padding(10)
            }
        }
        .background(Color.panelBackground)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Music", systemImage: "music.note.list")
                .font(.headline)
            Spacer()
            if canZoom {
                Button { zoom(by: -0.1) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .accessibilityLabel("Smaller")
                Text(verbatim: "\(Int((model.settings.sheetZoom * 100).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40)
                Button { zoom(by: 0.1) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .accessibilityLabel("Bigger")
            }
            Button { model.showSheet = false } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Hide the music")
        }
        .font(.title3)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        switch model.sheetContent {
        case .musicXML(let xml)?:
            if let controller {
                MusicXMLSheet(controller: controller, xml: xml)
            } else {
                ProgressView()
            }
        case .pdf(let url)?:
            PDFSheet(url: url)
        case .image(let url)?:
            ImageSheet(url: url)
        case nil:
            ContentUnavailableView {
                Label(hasOnlyMIDI ? "Nothing to show" : "No sheet music yet", systemImage: "music.note.list")
            } description: {
                Text(hasOnlyMIDI
                     ? "The MIDI file gives the coach the notes but can't be shown. Add a PDF or a photo of the music in Set up."
                     : "Add MusicXML, MIDI, a PDF or a photo of the music in Set up.")
            } actions: {
                Button("Set up", action: onOpenSetup)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var hasOnlyMIDI: Bool {
        model.openPiece?.sheet?.kind == .midi && model.openPiece?.displaySheet == nil
    }

    private var canZoom: Bool {
        switch model.sheetContent {
        case .musicXML?, .image?: return true
        case .pdf?, nil: return false
        }
    }

    private var errorMessage: String? {
        if let error = model.sheetError { return error }
        if case .musicXML? = model.sheetContent { return controller?.errorMessage }
        return nil
    }

    private func zoom(by step: Double) {
        let settings = model.settings
        settings.sheetZoom = min(3, max(0.5, ((settings.sheetZoom + step) * 10).rounded() / 10))
    }
}

// MARK: - MusicXML

/// OpenSheetMusicDisplay in a web view, with the cursor following the coach. Tapping a measure jumps there.
private struct MusicXMLSheet: View {
    @Environment(AppModel.self) private var model
    let controller: SheetMusicController
    let xml: String

    var body: some View {
        WebViewContainer(webView: controller.webView)
            .overlay {
                if !controller.isLoaded && controller.errorMessage == nil {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .onAppear {
                let coach = model.coach
                controller.onTapMeasure = { coach.goToSourceMeasure($0) }
                controller.setZoom(model.settings.sheetZoom)
                controller.load(musicXML: xml)
                controller.setPosition(coach.sheetPosition)
            }
            .onChange(of: xml) { _, newXML in
                controller.load(musicXML: newXML)
                controller.setPosition(model.coach.sheetPosition)
            }
            .onChange(of: model.coach.sheetPosition) { _, position in
                controller.setPosition(position)
            }
            .onChange(of: model.settings.sheetZoom) { _, zoom in
                controller.setZoom(zoom)
            }
    }
}

// MARK: - PDF

private struct PDFSheet: View {
    let url: URL

    var body: some View {
        PDFKitView(url: url)
    }
}

#if os(iOS)
private struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        show(url, in: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { show(url, in: view) }
    }

    private func show(_ url: URL, in view: PDFView) {
        view.document = PDFDocument(url: url)
        view.autoScales = true
    }
}
#elseif os(macOS)
private struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor
        show(url, in: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { show(url, in: view) }
    }

    private func show(_ url: URL, in view: PDFView) {
        view.document = PDFDocument(url: url)
        view.autoScales = true
    }
}
#endif

// MARK: - Image

/// A scanned page or photo: fits the width, zooms with the buttons or a pinch, scrolls both ways.
private struct ImageSheet: View {
    @Environment(AppModel.self) private var model
    let url: URL
    @State private var image: Image?
    @State private var failed = false
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                if let image {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: max(100, geo.size.width * CGFloat(model.settings.sheetZoom) * pinch))
                        .background(Color.white)
                } else if failed {
                    Label("Couldn't open this picture.", systemImage: "photo")
                        .foregroundStyle(.secondary)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ProgressView()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in
                        let settings = model.settings
                        settings.sheetZoom = min(3, max(0.5, settings.sheetZoom * Double(value.magnification)))
                    }
            )
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        failed = false
        let url = self.url
        let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        guard let data else {
            failed = true
            return
        }
        #if os(iOS)
        if let picture = UIImage(data: data) { image = Image(uiImage: picture) } else { failed = true }
        #elseif os(macOS)
        if let picture = NSImage(data: data) { image = Image(nsImage: picture) } else { failed = true }
        #endif
    }
}
