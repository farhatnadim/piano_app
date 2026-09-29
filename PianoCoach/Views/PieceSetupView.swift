import PianoCoachCore
import SwiftUI
import UniformTypeIdentifiers

/// The parent's setup for the open piece: sheet music, tempo, lining the music up with the video,
/// teaching the coach, and the name.
///
/// The coach is switched off while this is open (it would otherwise mute or pause the video) and
/// switched back on afterwards.
struct PieceSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var showImporter = false
    @State private var importError: String?
    @State private var confirmRemoveSheets = false
    @State private var confirmForget = false
    @State private var tapTempo = TapTempo()
    @State private var tappedBPM: Double?
    /// Video times tapped so far in "Tap along" (nil when not tapping).
    @State private var measureTaps: [Double]?
    @State private var tapAlongResult: String?
    @State private var estimator = VideoTimeEstimator()
    @State private var modeBeforeSetup: CoachMode?

    var body: some View {
        NavigationStack {
            Group {
                if let piece = model.openPiece {
                    form(piece)
                } else {
                    ContentUnavailableView("No piece is open", systemImage: "music.note")
                }
            }
            .navigationTitle("Set up")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { begin() }
        .onDisappear { end() }
        #if os(macOS)
        .frame(minWidth: 540, idealWidth: 600, minHeight: 560, idealHeight: 720)
        #endif
    }

    private func form(_ piece: Piece) -> some View {
        Form {
            Section {
                VideoControlsRow(estimator: estimator)
                if model.player.autoplayBlocked {
                    Label("The video needs one tap on the practice screen before it can play. Close this, tap the video, then come back.",
                          systemImage: "hand.tap.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Picker("Speed", selection: speedBinding) {
                    ForEach(model.coach.availableRates, id: \.self) { rate in
                        Text(speedName(rate)).tag(rate)
                    }
                }
            } header: {
                Text("Video")
            } footer: {
                Text("Control the video from here while you set things up.")
            }
            sheetSection(piece)
            tempoSection(piece)
            if let score = model.openScore {
                syncSection(piece, score: score)
            }
            teachSection(piece)
            Section("Name") {
                TextField("Name", text: $title)
                    .onSubmit { commitTitle() }
                Link(destination: YouTubeLink.watchURL(videoID: piece.videoID)) {
                    Label("Open the video in YouTube", systemImage: "arrow.up.right.square")
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.sheetTypes) { importSheet($0) }
    }

    // MARK: - Sheet music

    /// MusicXML (.musicxml, .xml, .mxl), MIDI, PDF and pictures.
    private static let sheetTypes: [UTType] = {
        var types: [UTType] = [.pdf, .image, .midi]
        for ext in ["musicxml", "mxl", "xml", "mid", "midi"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }()

    private func sheetSection(_ piece: Piece) -> some View {
        let hasSheets = piece.sheet != nil || piece.displaySheet != nil
        return Section {
            if !hasSheets {
                Text("No sheet music yet.")
                    .foregroundStyle(.secondary)
            }
            if let sheet = piece.sheet {
                AttachmentRow(attachment: sheet)
            }
            if let display = piece.displaySheet {
                AttachmentRow(attachment: display)
            }
            Button {
                importError = nil
                showImporter = true
            } label: {
                Label(hasSheets ? "Add or replace sheet music…" : "Add sheet music…", systemImage: "doc.badge.plus")
            }
            if hasSheets {
                Button(role: .destructive) { confirmRemoveSheets = true } label: {
                    Label("Remove sheet music", systemImage: "trash")
                }
                .confirmationDialog("Remove the sheet music?", isPresented: $confirmRemoveSheets,
                                    titleVisibility: .visible) {
                    Button("Remove", role: .destructive) {
                        if let piece = model.openPiece { model.removeSheets(from: piece) }
                    }
                } message: {
                    Text("Lining it up with the video is removed too.")
                }
            }
            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Sheet music")
        } footer: {
            Text("MusicXML (.musicxml or .mxl, e.g. exported from MuseScore) shows the music with a moving cursor and lets the coach follow the notes. A MIDI file gives the coach the notes; add a PDF or photo too to see the music. PDFs and photos on their own are only shown.")
        }
    }

    private func importSheet(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard let piece = model.openPiece else { return }
            do {
                try model.attachSheet(from: url, to: piece)
                importError = nil
            } catch {
                importError = "Couldn't use “\(url.lastPathComponent)”: \(error.localizedDescription)"
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    // MARK: - Tempo

    private func tempoSection(_ piece: Piece) -> some View {
        let bpm = piece.videoBPM ?? model.openScore?.initialTempoBPM ?? 90
        return Section {
            LabeledContent("Beats per minute") {
                HStack(spacing: 8) {
                    TextField("BPM", value: tempoBinding(bpm), format: .number.precision(.fractionLength(0)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                    Stepper("Beats per minute", value: tempoBinding(bpm), in: 20...300, step: 1)
                        .labelsHidden()
                }
            }
            HStack {
                Button(action: tapBeat) {
                    Label("Tap the beat", systemImage: "hand.tap")
                }
                .buttonStyle(.bordered)
                Spacer()
                if let tapped = tappedBPM {
                    Text("\(Int(tapped.rounded())) BPM")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Use") { useTappedTempo(tapped) }
                        .buttonStyle(.borderedProminent)
                } else if tapTempo.tapCount == 1 {
                    Text("Keep tapping…")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Tempo")
        } footer: {
            Text("How fast the music in the video goes, in quarter notes per minute. Play the video and tap along with the beat, then press Use. Only needed with sheet music that has notes.")
        }
    }

    private func tempoBinding(_ current: Double) -> Binding<Double> {
        let appModel = model
        return Binding(
            get: { current },
            set: { newValue in
                if let piece = appModel.openPiece { appModel.setTempo(newValue.rounded(), for: piece) }
            }
        )
    }

    private func tapBeat() {
        tappedBPM = tapTempo.tap(at: MonotonicClock.now())
    }

    private func useTappedTempo(_ bpm: Double) {
        if let piece = model.openPiece { model.setTempo(bpm.rounded(), for: piece) }
        tapTempo.reset()
        tappedBPM = nil
    }

    // MARK: - Lining up the music with the video

    private func syncSection(_ piece: Piece, score: Score) -> some View {
        Section {
            Text("So the green cursor follows the video: play the video, pause right where the first note sounds, then press the button.")
                .font(.callout)
            Button(action: setStart) {
                Label("The first note is here", systemImage: "flag.fill")
            }
            .buttonStyle(.borderedProminent)
            LabeledContent("Fine-tune") {
                HStack(spacing: 8) {
                    Button("−0.1 s") { nudge(-0.1) }
                    Button("+0.1 s") { nudge(0.1) }
                }
                .buttonStyle(.bordered)
                .disabled(piece.syncMap == nil)
            }
            tapAlongRows(score)
            if let sync = piece.syncMap {
                Text(syncSummary(sync, score: score))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Line up the music with the video")
        } footer: {
            Text("If the cursor runs ahead of the music, press +0.1 s; if it lags behind, press −0.1 s. If the video speeds up or slows down, use Tap along: tap on the first beat of every measure while the video plays. Slowing the video down makes tapping easier.")
        }
    }

    @ViewBuilder private func tapAlongRows(_ score: Score) -> some View {
        if let taps = measureTaps {
            let measures = Self.fullMeasures(of: score)
            let prompt: String = taps.count < measures.count
                ? "Tap on beat 1 of measure \(label(of: measures[taps.count], index: taps.count))"
                : "That was the last measure. Press Apply."
            VStack(spacing: 12) {
                Text(prompt)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                Button(action: recordTap) {
                    Text("Tap!")
                        .font(.title.bold())
                        .frame(maxWidth: .infinity, minHeight: 72)
                }
                .buttonStyle(.borderedProminent)
                .macKeyboardShortcut(.space)
                .sensoryFeedback(.impact(weight: .light), trigger: taps.count)
                .disabled(taps.count >= measures.count)
                HStack {
                    Button("Undo", action: undoTap)
                        .disabled(taps.isEmpty)
                    Spacer()
                    Text("\(taps.count) of \(measures.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: cancelTapAlong)
                    Button("Apply", action: applyTapAlong)
                        .buttonStyle(.borderedProminent)
                        .disabled(taps.count < 2)
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        } else {
            Button(action: startTapAlong) {
                Label("Tap along with the video…", systemImage: "hand.tap")
            }
            if let tapAlongResult {
                Text(tapAlongResult)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Measures the tap-along counts, as `AppModel.applyTappedSync` does (a short pickup is skipped).
    private static func fullMeasures(of score: Score) -> [ScoreMeasure] {
        score.measures.filter { $0.lengthBeats + 1e-6 >= $0.timeSignature.quarterBeatsPerMeasure }
    }

    private func label(of measure: ScoreMeasure, index: Int) -> String {
        measure.number.isEmpty ? "\(index + 1)" : measure.number
    }

    private func syncSummary(_ sync: SyncMap, score: Score) -> String {
        var parts = ["First note at \(timeText(sync.videoTime(forBeat: score.events.first?.beat ?? 0), tenths: true))",
                     "\(Int(sync.bpm.rounded())) BPM"]
        if !sync.anchors.isEmpty { parts.append("\(sync.anchors.count) measures tapped") }
        return parts.joined(separator: " · ")
    }

    private func setStart() {
        guard let piece = model.openPiece else { return }
        model.setSyncStart(videoTime: estimator.estimate(player: model.player), for: piece)
    }

    private func nudge(_ seconds: Double) {
        guard let piece = model.openPiece else { return }
        model.nudgeSync(by: seconds, for: piece)
    }

    private func startTapAlong() {
        tapAlongResult = nil
        measureTaps = []
        if !model.player.isPlaying { model.coach.userPlay() }
    }

    private func recordTap() {
        guard var taps = measureTaps else { return }
        let time = estimator.estimate(player: model.player)
        // Ignore double taps and taps after the video jumped back.
        if let last = taps.last, time <= last + 0.1 { return }
        taps.append(time)
        measureTaps = taps
    }

    private func undoTap() {
        guard var taps = measureTaps, !taps.isEmpty else { return }
        taps.removeLast()
        measureTaps = taps
    }

    private func cancelTapAlong() {
        measureTaps = nil
        model.coach.userPause()
    }

    private func applyTapAlong() {
        guard let taps = measureTaps, taps.count >= 2, let piece = model.openPiece else { return }
        model.coach.userPause()
        model.applyTappedSync(measureTapTimes: taps, for: piece)
        measureTaps = nil
        tapAlongResult = "Lined up \(taps.count) measures."
    }

    // MARK: - Teaching the coach

    private func teachSection(_ piece: Piece) -> some View {
        let coach = model.coach
        return Section {
            Label(coach.trackDescription, systemImage: coach.canFollow ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(coach.canFollow ? Color.green : Color.secondary)
            if coach.isLearning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Listening… \(coach.learnedNoteCount) notes")
                        .monospacedDigit()
                }
                HStack {
                    Button("Stop & save") { _ = coach.finishLearning() }
                        .buttonStyle(.borderedProminent)
                    Button("Cancel") { coach.cancelLearning() }
                        .buttonStyle(.bordered)
                }
            } else {
                Button { coach.startLearning() } label: {
                    Label(piece.hasLearnedTrack ? "Learn more of the song" : "Start listening", systemImage: "ear")
                }
                if piece.hasLearnedTrack {
                    Button(role: .destructive) { confirmForget = true } label: {
                        Label("Forget what it learned", systemImage: "trash")
                    }
                    .confirmationDialog("Forget what the coach learned?", isPresented: $confirmForget,
                                        titleVisibility: .visible) {
                        Button("Forget", role: .destructive) {
                            if let piece = model.openPiece { model.forgetLearnedTrack(for: piece) }
                        }
                    } message: {
                        Text("You can teach it again at any time.")
                    }
                }
            }
            if let notice = coach.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error = coach.listeningError {
                Label(error, systemImage: "mic.slash.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Teach the coach")
        } footer: {
            Text("For “Follow me” without sheet music, the coach listens to the video once. It plays the video with sound from where it is now, so start just before the music. Turn the volume up, keep the room quiet and keep the device near the speaker. Stop whenever you like — you can teach more later.")
        }
    }

    // MARK: - Speed, name, open/close

    private var speedBinding: Binding<Double> {
        let appModel = model
        return Binding(get: { appModel.coach.speedSetting }, set: { appModel.setSpeed($0) })
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let piece = model.openPiece, !trimmed.isEmpty, trimmed != piece.title else { return }
        model.rename(piece, to: trimmed)
    }

    private func begin() {
        title = model.openPiece?.title ?? ""
        if model.coach.mode != .off {
            modeBeforeSetup = model.coach.mode
            model.coach.setMode(.off)
        }
    }

    private func end() {
        commitTitle()
        // While learning, the practice screen shows its progress; the coach mode comes back after that.
        guard !model.coach.isLearning, let mode = modeBeforeSetup, model.openPiece != nil else { return }
        modeBeforeSetup = nil
        model.coach.setMode(mode)
    }
}

// MARK: - Pieces

/// One attached sheet-music file.
private struct AttachmentRow: View {
    let attachment: SheetAttachment

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.originalName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
        }
    }

    private var description: String {
        switch attachment.kind {
        case .musicXML, .compressedMusicXML: return "MusicXML: shown with a cursor, the coach can follow it"
        case .midi: return "MIDI: the coach can follow the notes"
        case .pdf: return "PDF: shown only"
        case .image: return "Picture: shown only"
        }
    }

    private var symbol: String {
        switch attachment.kind {
        case .musicXML, .compressedMusicXML: return "music.note.list"
        case .midi: return "pianokeys"
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        }
    }
}

/// Play/pause, jumps and the current time, for setting things up without the practice screen.
private struct VideoControlsRow: View {
    @Environment(AppModel.self) private var model
    let estimator: VideoTimeEstimator

    var body: some View {
        let player = model.player
        let coach = model.coach
        HStack(spacing: 8) {
            Button { coach.seek(to: 0) } label: {
                Image(systemName: "backward.end.fill")
            }
            .accessibilityLabel("Go to the start")
            Button { coach.skip(by: -5) } label: {
                Image(systemName: "gobackward.5")
            }
            .accessibilityLabel("Back 5 seconds")
            Button {
                if player.isPlaying { coach.userPause() } else { coach.userPlay() }
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 22)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { coach.skip(by: 5) } label: {
                Image(systemName: "goforward.5")
            }
            .accessibilityLabel("Forward 5 seconds")
            Spacer(minLength: 8)
            Text("\(timeText(player.currentTime, tenths: true)) / \(timeText(player.duration))")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .onChange(of: player.currentTime) { _, time in
            estimator.record(time)
        }
    }
}

/// Estimates the exact video time of a tap: the player only reports its position about ten times a
/// second, so the time since the last report is added (at the current rate).
private final class VideoTimeEstimator {
    private var reportedTime: Double = 0
    private var reportedAt: Double = 0

    func record(_ time: Double) {
        reportedTime = time
        reportedAt = MonotonicClock.now()
    }

    @MainActor
    func estimate(player: YouTubePlayerController) -> Double {
        guard player.isPlaying, abs(reportedTime - player.currentTime) < 0.001 else { return player.currentTime }
        let elapsed = MonotonicClock.now() - reportedAt
        guard elapsed >= 0, elapsed < 0.5 else { return player.currentTime }
        return reportedTime + elapsed * player.rate
    }
}
